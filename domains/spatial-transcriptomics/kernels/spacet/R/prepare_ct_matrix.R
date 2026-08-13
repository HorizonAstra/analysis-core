#!/usr/bin/env Rscript

# prepare_ct_matrix.R — SpaCET CT Feature-Space Prep (TumorSPACE_AWS)
#
# Converts Spacet_Matrix.txt (barcode × cell_type proportions) into the standard
# TumorSPACE DA/SLAB interface format expected by sg_diff_abundance.jl and
# sg_slab_score.jl, writing outputs to {outdir}/ (default: {optimal-dir}/ct/).
#
# Outputs written to outdir:
#   M.txt                  — numeric matrix, no header, no row names (barcodes × CTs)
#   barcodes.txt           — single column, header "barcode", one barcode per line
#   genes.txt              — single column, header "cell_type", one CT name per line
#   barcodes_positions.txt — copy from --input-dir
#   OptimalTree_pruned_node_compare_list.txt   — symlink to --optimal-dir
#   OptimalTree_pruned_node_compare_leaves.txt — symlink to --optimal-dir
#   feature_space_info.txt — metadata: type, n_features, source, spacet_matrix
#
# Usage:
#   Rscript prepare_ct_matrix.R \
#     --spacet-matrix PATH \
#     --optimal-dir PATH \
#     --input-dir PATH \
#     [--outdir PATH]
#
# Required:
#   --spacet-matrix   Path to Spacet_Matrix.txt (barcode × cell_type, tab-sep)
#   --optimal-dir     Path to optimal/ directory (tree files symlinked from here)
#   --input-dir       Input data directory containing barcodes_positions.txt
#
# Optional:
#   --outdir          Output directory [default: {optimal-dir}/ct]

library(optparse)

option_list <- list(
  make_option("--spacet-matrix", type = "character", default = NULL,
              help = "Path to Spacet_Matrix.txt (required)"),
  make_option("--optimal-dir", type = "character", default = NULL,
              help = "Path to optimal/ directory containing tree files (required)"),
  make_option("--input-dir", type = "character", default = NULL,
              help = "Input data dir containing barcodes_positions.txt (required)"),
  make_option("--outdir", type = "character", default = NULL,
              help = "Output directory [default: {optimal-dir}/ct]")
)

parser <- OptionParser(option_list = option_list,
                       description = "Prepare SpaCET cell-type proportions for TumorSPACE DA/SLAB interface")
args <- parse_args(parser)

if (is.null(args[["spacet-matrix"]]))  { print_help(parser); stop("--spacet-matrix is required") }
if (is.null(args[["optimal-dir"]]))    { print_help(parser); stop("--optimal-dir is required") }
if (is.null(args[["input-dir"]]))      { print_help(parser); stop("--input-dir is required") }

spacet_matrix_path <- args[["spacet-matrix"]]
optimal_dir        <- normalizePath(args[["optimal-dir"]], mustWork = TRUE)
input_dir          <- normalizePath(args[["input-dir"]], mustWork = TRUE)
outdir             <- if (!is.null(args[["outdir"]])) args[["outdir"]] else file.path(optimal_dir, "ct")

# ── Validate inputs ───────────────────────────────────────────────────────────

if (!file.exists(spacet_matrix_path)) {
  stop("Spacet_Matrix.txt not found: ", spacet_matrix_path)
}

barcode_pos_path <- file.path(input_dir, "barcodes_positions.txt")
if (!file.exists(barcode_pos_path)) {
  stop("barcodes_positions.txt not found in --input-dir: ", input_dir)
}

tree_list_path   <- file.path(optimal_dir, "OptimalTree_pruned_node_compare_list.txt")
tree_leaves_path <- file.path(optimal_dir, "OptimalTree_pruned_node_compare_leaves.txt")
for (f in c(tree_list_path, tree_leaves_path)) {
  if (!file.exists(f)) {
    stop("Required tree file missing (has Step 7 completed?): ", f)
  }
}

# ── Load data ─────────────────────────────────────────────────────────────────

cat("Loading Spacet_Matrix.txt ...\n")
spacet <- read.table(spacet_matrix_path, header = TRUE, sep = "\t",
                     check.names = FALSE, stringsAsFactors = FALSE)

# First column is Barcode regardless of its exact column name
barcode_col  <- colnames(spacet)[1]
barcodes_raw <- spacet[[barcode_col]]
ct_names     <- colnames(spacet)[-1]

if (length(ct_names) < 2) {
  stop("Spacet_Matrix.txt must contain at least 2 cell-type columns; found: ",
       length(ct_names))
}
cat(sprintf("  %d spots × %d cell types\n", nrow(spacet), length(ct_names)))

# ── Filter to barcodes in barcodes_positions.txt ──────────────────────────────

barcode_pos <- read.table(barcode_pos_path, header = TRUE, sep = "\t",
                          stringsAsFactors = FALSE)
valid_barcodes <- barcode_pos[[1]]  # first column is always barcode

keep_idx        <- which(barcodes_raw %in% valid_barcodes)
n_before        <- nrow(spacet)
spacet_filtered <- spacet[keep_idx, ]
barcodes_out    <- barcodes_raw[keep_idx]
n_after         <- nrow(spacet_filtered)

if (n_after < n_before) {
  cat(sprintf("  Filtered %d spots not in barcodes_positions.txt (%d → %d)\n",
              n_before - n_after, n_before, n_after))
}
if (n_after == 0) {
  stop("No barcodes overlap between Spacet_Matrix.txt and barcodes_positions.txt")
}

# Extract numeric proportion matrix (no row names, no header)
M_ct <- as.matrix(spacet_filtered[, ct_names, drop = FALSE])

# ── Write outputs ─────────────────────────────────────────────────────────────

dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
cat(sprintf("Writing outputs to: %s\n", outdir))

# M.txt — numeric matrix, no header, no row names, tab-separated
write.table(M_ct,
            file      = file.path(outdir, "M.txt"),
            quote     = FALSE,
            sep       = "\t",
            row.names = FALSE,
            col.names = FALSE)
cat(sprintf("  ✓ M.txt  (%d rows × %d cols)\n", nrow(M_ct), ncol(M_ct)))

# barcodes.txt — header "barcode", one barcode per line
write.table(data.frame(barcode = barcodes_out),
            file      = file.path(outdir, "barcodes.txt"),
            quote     = FALSE,
            sep       = "\t",
            row.names = FALSE,
            col.names = TRUE)
cat(sprintf("  ✓ barcodes.txt  (%d barcodes)\n", length(barcodes_out)))

# genes.txt — header "cell_type", one cell type per line
write.table(data.frame(cell_type = ct_names),
            file      = file.path(outdir, "genes.txt"),
            quote     = FALSE,
            sep       = "\t",
            row.names = FALSE,
            col.names = TRUE)
cat(sprintf("  ✓ genes.txt  (%d cell types)\n", length(ct_names)))

# barcodes_positions.txt — copy from input_dir (skip if src == dest)
dest_bp <- file.path(outdir, "barcodes_positions.txt")
if (normalizePath(barcode_pos_path, mustWork = FALSE) !=
    normalizePath(dest_bp,          mustWork = FALSE)) {
  file.copy(barcode_pos_path, dest_bp, overwrite = TRUE)
  cat("  ✓ barcodes_positions.txt  (copied)\n")
} else {
  cat("  ✓ barcodes_positions.txt  (already in place)\n")
}

# Tree symlinks — point back to optimal/ (single source of truth)
for (tree_fname in c("OptimalTree_pruned_node_compare_list.txt",
                     "OptimalTree_pruned_node_compare_leaves.txt")) {
  src  <- file.path(optimal_dir, tree_fname)
  dest <- file.path(outdir, tree_fname)
  unlink(dest)  # remove any existing file/symlink; no-op if absent
  # Use relative symlink so the directory stays portable
  rel_src <- file.path("..", tree_fname)
  file.symlink(rel_src, dest)
  cat(sprintf("  ✓ %s  (symlink → ../)\n", tree_fname))
}

# feature_space_info.txt — machine-readable metadata
info_lines <- c(
  paste0("type=cell_type_proportion"),
  paste0("n_features=", length(ct_names)),
  paste0("source=SpaCET"),
  paste0("spacet_matrix=", normalizePath(spacet_matrix_path, mustWork = FALSE)),
  paste0("prepared=", format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
)
writeLines(info_lines, file.path(outdir, "feature_space_info.txt"))
cat("  ✓ feature_space_info.txt\n")

cat(sprintf("\n✓ CT feature space prepared: %s\n", outdir))
cat(sprintf("  %d spots × %d cell types ready for sg_diff_abundance.jl\n",
            n_after, length(ct_names)))
