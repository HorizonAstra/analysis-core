#!/usr/bin/env Rscript
#
# compute_ripley_k.R
#
# Step 3: Ripley's K Spatial Clustering Analysis
#
# Computes the border-corrected Ripley's K spatial clustering statistic for all
# internal nodes in the phylogenetic tree. This R/spatstat implementation is the
# default and provides substantially faster computation than the prior Julia version,
# which is required for larger datasets.
#
# Usage:
#   Rscript compute_ripley_k.R <step2_output_dir> <data_dir> <output_dir>
#
# Arguments:
#   step2_output_dir  Directory containing Step 2 outputs (allnodes_leaves.tsv)
#   data_dir          Directory with original data (reserved; unused here but kept
#                     for interface consistency with spatial_optimize.jl)
#   output_dir        Directory to write allnodes_ripley.tsv
#
# Input:
#   <step2_output_dir>/allnodes_leaves.tsv
#     Required columns: Node, pxl_row_in_mm (X), pxl_col_in_mm (Y)
#
# Output:
#   <output_dir>/allnodes_ripley.tsv
#     Columns: Node (int), RipleySum (double), NodeSize (int)
#     RipleySum: sum(|K_border(r) - pi*r^2|) over spatstat default r-sequence
#     RipleySum = 0 for degenerate nodes (<2 points)
#
# Method:
#   Border-corrected Ripley's K via spatstat::Kest(correction="border")
#   Global observation window from full dataset extent (matching Julia implementation)
#
# Ported from: /project/araman/vivek/TME_SPI/Revisions/scripts_2/Revisions_TumorSPACE_v1.R
#   (task == "tree_ripley" block)
#

suppressPackageStartupMessages({
  library(data.table)
  library(dplyr)
  library(spatstat)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) {
  cat("Usage: Rscript compute_ripley_k.R <step2_output_dir> <data_dir> <output_dir>\n")
  quit(status = 1)
}

step2_output_dir <- args[1]
data_dir         <- args[2]   # reserved; kept for interface consistency
output_dir       <- args[3]

cat(strrep("=", 80), "\n", sep = "")
cat("Step 3: Ripley's K Spatial Clustering Analysis\n")
cat(strrep("=", 80), "\n", sep = "")
cat("Step 2 output: ", step2_output_dir, "\n")
cat("Output dir:    ", output_dir, "\n")
cat("\n")

# ── Load inputs ───────────────────────────────────────────────────────────────
allnodes_leaves_loc <- file.path(step2_output_dir, "allnodes_leaves.tsv")
if (!file.exists(allnodes_leaves_loc)) {
  stop("allnodes_leaves.tsv not found: ", allnodes_leaves_loc)
}

cat("[1/4] Loading allnodes_leaves.tsv...\n")
allnodes_leaves <- fread(allnodes_leaves_loc)

# Rename mm coordinate columns to X, Y
# Columns: Node, Leaf, barcode, in_tissue, array_row, array_col,
#          pxl_row_in_fullres, pxl_col_in_fullres, pxl_row_in_mm, pxl_col_in_mm
if (!"X" %in% names(allnodes_leaves)) {
  if (!"pxl_row_in_mm" %in% names(allnodes_leaves)) {
    stop("Expected column 'pxl_row_in_mm' not found in allnodes_leaves.tsv. ",
         "Columns present: ", paste(names(allnodes_leaves), collapse = ", "))
  }
  setnames(allnodes_leaves, "pxl_row_in_mm", "X")
}
if (!"Y" %in% names(allnodes_leaves)) {
  if (!"pxl_col_in_mm" %in% names(allnodes_leaves)) {
    stop("Expected column 'pxl_col_in_mm' not found in allnodes_leaves.tsv. ",
         "Columns present: ", paste(names(allnodes_leaves), collapse = ", "))
  }
  setnames(allnodes_leaves, "pxl_col_in_mm", "Y")
}

n_nodes <- length(unique(allnodes_leaves$Node))
cat("  Loaded", nrow(allnodes_leaves), "node-leaf relationships across", n_nodes, "nodes\n")
cat("\n")

# ── Global observation window (matches Julia implementation) ──────────────────
x_min <- min(allnodes_leaves$X)
x_max <- max(allnodes_leaves$X)
y_min <- min(allnodes_leaves$Y)
y_max <- max(allnodes_leaves$Y)

if ((x_max - x_min) <= 0 || (y_max - y_min) <= 0) {
  stop("Degenerate global window: all spots are collinear or identical. ",
       "Cannot compute Ripley's K.")
}

cat("[2/4] Computing Ripley's K for", n_nodes, "nodes...\n")
cat("  Global window: X=[", round(x_min, 3), ",", round(x_max, 3), "]",
    " Y=[", round(y_min, 3), ",", round(y_max, 3), "]\n")
cat("  This may take several minutes for large datasets.\n")
cat("\n")

# Sanity check: if all nodes have the same N, Step 2 likely failed
node_sizes <- allnodes_leaves[, .N, by = "Node"][order(-N)]
if (length(unique(node_sizes$N)) == 1) {
  stop("Error in Step 2 output: all ", nrow(node_sizes), " nodes contain the same ",
       "number of leaves (", node_sizes$N[1], "). ",
       "This indicates a problem with allnodes_leaves.tsv.")
}

# ── Per-node Ripley's K ────────────────────────────────────────────────────────
ripley_results <- vector("list", nrow(node_sizes))

for (i in seq_len(nrow(node_sizes))) {
  node_id   <- node_sizes$Node[i]
  node_size <- node_sizes$N[i]
  dat_in    <- allnodes_leaves[Node == node_id]

  # Degenerate case: fewer than 2 points → K-function undefined
  if (node_size < 2) {
    ripley_results[[i]] <- data.table(Node = node_id, RipleySum = 0.0, NodeSize = node_size)
    next
  }

  # Create point pattern with global observation window
  dat_ppp <- tryCatch(
    ppp(dat_in$X, dat_in$Y,
        xrange = c(x_min, x_max),
        yrange = c(y_min, y_max)),
    error = function(e) {
      warning("Node ", node_id, ": ppp() failed (", conditionMessage(e), ") — assigning RipleySum=0")
      NULL
    }
  )

  if (is.null(dat_ppp)) {
    ripley_results[[i]] <- data.table(Node = node_id, RipleySum = 0.0, NodeSize = node_size)
    next
  }

  # Compute border-corrected Ripley's K (spatstat default r-sequence)
  kest <- tryCatch(
    Kest(dat_ppp, correction = "border"),
    error = function(e) {
      warning("Node ", node_id, ": Kest() failed (", conditionMessage(e), ") — assigning RipleySum=0")
      NULL
    }
  )

  if (is.null(kest)) {
    ripley_results[[i]] <- data.table(Node = node_id, RipleySum = 0.0, NodeSize = node_size)
    next
  }

  # RipleySum = sum(|K_border(r) - K_theoretical(r)|)
  rip_sum <- sum(abs(kest$border - kest$theo), na.rm = TRUE)
  ripley_results[[i]] <- data.table(Node = node_id, RipleySum = rip_sum, NodeSize = node_size)

  if (i %% 50 == 0 || i == nrow(node_sizes)) {
    cat("  Processed", i, "/", nrow(node_sizes), "nodes\n")
    flush(stdout())
  }
}

allnodes_ripley <- rbindlist(ripley_results)

cat("\n[3/4] Ripley's K summary:\n")
cat("  Nodes computed: ", nrow(allnodes_ripley), "\n")
cat("  RipleySum range: [", round(min(allnodes_ripley$RipleySum), 4), ",",
    round(max(allnodes_ripley$RipleySum), 4), "]\n")
cat("  Nodes with RipleySum == 0:", sum(allnodes_ripley$RipleySum == 0), "\n")
cat("\n")

# ── Write output ──────────────────────────────────────────────────────────────
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_file <- file.path(output_dir, "allnodes_ripley.tsv")

cat("[4/4] Writing allnodes_ripley.tsv...\n")
write.table(allnodes_ripley, output_file, quote = FALSE, sep = "\t", row.names = FALSE)
cat("  ✓ Saved:", output_file, "(", nrow(allnodes_ripley), "nodes )\n")
cat("\n")

cat(strrep("=", 80), "\n", sep = "")
cat("Step 3 complete!\n")
cat(strrep("=", 80), "\n", sep = "")
