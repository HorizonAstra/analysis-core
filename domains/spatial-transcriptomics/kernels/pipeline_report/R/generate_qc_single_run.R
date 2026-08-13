#!/usr/bin/env Rscript

# Pipeline Report for Single Pipeline Run
# Generates validation plots and summary for a single pipeline execution

suppressPackageStartupMessages({
  library(ape)
  library(ggplot2)
  library(dplyr)
  library(tidyr)
  library(gridExtra)
})

# Parse command-line arguments
args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2) {
  stop("Usage: Rscript generate_qc_single_run.R <output_dir> <qc_report_dir> [reference_dir]")
}

output_dir    <- args[1]
qc_report_dir <- args[2]
reference_dir <- if (length(args) >= 3) args[3] else NULL

# Create QC report directory
if (!dir.exists(qc_report_dir)) {
  dir.create(qc_report_dir, recursive = TRUE)
}

cat("Pipeline Report Generation\n")
cat("==========================\n")
cat("Output Directory:", output_dir, "\n")
cat("QC Report Directory:", qc_report_dir, "\n")
if (!is.null(reference_dir)) {
  cat("Reference Directory:", reference_dir, "\n")
}
cat("\n")

# Initialize results list
results <- list()

# Load optimal hyperparameters from cor_dat_all.tsv
cor_dat_file <- file.path(output_dir, "cor_dat_all.tsv")
if (file.exists(cor_dat_file)) {
  cor_dat <- tryCatch({
    read.table(cor_dat_file, header = TRUE, sep = "\t", stringsAsFactors = FALSE)
  }, error = function(e) { NULL })

  if (!is.null(cor_dat) && nrow(cor_dat) > 0) {
    results$nodecor           <- cor_dat$NodeCor[1]
    results$support_threshold <- cor_dat$Prune[1]
    results$spatial_threshold <- cor_dat$Spatial[1]
    results$knn               <- cor_dat$KNN[1]
    cat("Loaded optimal hyperparameters from cor_dat_all.tsv\n")
    cat("  NodeCor (Pearson correlation): ", round(results$nodecor, 4), "\n")
    cat("  Support threshold: ", round(results$support_threshold, 4), "\n")
    cat("  Spatial threshold: ", round(results$spatial_threshold, 4), "\n")
    cat("  KNN: ", results$knn, "\n\n")
  }
}

# =============================================================================
# PLOT 1: Post-Prune Tree Structure (single fan tree)
# =============================================================================
cat("Generating Plot 1: Post-Prune Tree Structure...\n")

# Collect stats for both stages (used in metrics); only post-prune is plotted
tree_files  <- c("OptimalTree_preprune.nw", "OptimalTree_pruned.nw")
tree_labels <- c("Pre-Prune", "Post-Prune")
tree_stats  <- data.frame(
  Stage             = tree_labels,
  Tips              = NA_real_,
  Total_Nodes       = NA_real_,
  Polytomies        = NA_real_,
  Support_Threshold = NA_real_
)

for (i in seq_along(tree_files)) {
  tree_path <- file.path(output_dir, tree_files[i])
  if (file.exists(tree_path)) {
    tree_tmp <- read.tree(tree_path)
    tree_stats$Tips[i]        <- length(tree_tmp$tip.label)
    tree_stats$Total_Nodes[i] <- length(tree_tmp$tip.label) + tree_tmp$Nnode
    edge_table <- table(tree_tmp$edge[, 1])
    tree_stats$Polytomies[i]  <- sum(edge_table > 2)
    if (i == 2 && !is.null(tree_tmp$node.label)) {
      support_vals <- suppressWarnings(as.numeric(tree_tmp$node.label))
      if (any(!is.na(support_vals))) {
        tree_stats$Support_Threshold[i] <- 0.5
      }
    }
  }
}

sub_text <- paste0(
  ifelse(is.na(tree_stats$Tips[2]),       "?", as.integer(tree_stats$Tips[2])),
  " tips  |  ",
  ifelse(is.na(tree_stats$Polytomies[2]), "?", as.integer(tree_stats$Polytomies[2])),
  " polytomies"
)

post_prune_path <- file.path(output_dir, "OptimalTree_pruned.nw")
tree_post <- NULL
if (file.exists(post_prune_path)) tree_post <- read.tree(post_prune_path)

draw_plot1 <- function() {
  par(mar = c(4, 4, 5, 4))
  if (!is.null(tree_post)) {
    plot(tree_post,
         type = "fan",
         main = "Post-Prune Phylogenetic Tree",
         sub  = sub_text,
         cex  = 0.3,
         show.tip.label  = FALSE,
         use.edge.length = FALSE)
  } else {
    plot.new()
    text(0.5, 0.5, "Missing: OptimalTree_pruned.nw", cex = 1.2)
  }
}

pdf(file.path(qc_report_dir, "plot1_tree_postprune.pdf"), width = 8, height = 8)
draw_plot1()
dev.off()

png(file.path(qc_report_dir, "plot1_tree_postprune.png"), width = 1200, height = 1200, res = 150)
draw_plot1()
dev.off()

results$tree_stats <- tree_stats
cat("  Pre-prune: ", tree_stats$Tips[1], "tips,", tree_stats$Total_Nodes[1],
    "total nodes,", tree_stats$Polytomies[1], "polytomies\n")
cat("  Post-prune:", tree_stats$Tips[2], "tips,", tree_stats$Total_Nodes[2],
    "total nodes,", tree_stats$Polytomies[2], "polytomies\n")
if (!is.na(tree_stats$Polytomies[1]) && !is.na(tree_stats$Polytomies[2])) {
  if (tree_stats$Polytomies[1] == tree_stats$Polytomies[2]) {
    cat("  WARNING: Polytomy count unchanged - no nodes pruned",
        "(all nodes had support >= threshold)\n")
  } else {
    cat("  Pruning created",
        tree_stats$Polytomies[2] - tree_stats$Polytomies[1], "new polytomies\n")
  }
}

# =============================================================================
# PLOT 2: DA Genes and SG Pairs on Post-Prune Tree
# =============================================================================
cat("Generating Plot 2: DA Genes and SG Pairs on Tree...\n")

da_file   <- file.path(output_dir, "gene", "DA_significant.txt")
sg_file   <- file.path(output_dir, "OptimalTree_pruned_node_compare_list.txt")
tree_file <- file.path(output_dir, "OptimalTree_pruned.nw")

if (file.exists(da_file) && file.exists(sg_file) && file.exists(tree_file)) {
  da_data <- tryCatch({
    read.table(da_file, header = TRUE, stringsAsFactors = FALSE,
               sep = "\t", comment.char = "")
  }, error = function(e) {
    cat("  Error reading DA file:", e$message, "\n"); NULL
  })

  sg_data <- tryCatch(
    read.table(sg_file, header = TRUE, stringsAsFactors = FALSE),
    error = function(e) NULL
  )

  tree <- tryCatch(read.tree(tree_file), error = function(e) NULL)

  if (!is.null(da_data) && !is.null(sg_data) && !is.null(tree) &&
      nrow(da_data) > 0 && nrow(sg_data) > 0) {

    da_count_val <- nrow(da_data)
    sg_count_val <- nrow(sg_data)
    results$da_count <- da_count_val
    results$sg_count <- sg_count_val

    node_da_counts   <- table(da_data$Node)
    max_da           <- max(node_da_counts)
    sg_nodes         <- unique(c(sg_data$Node, sg_data$Sibling))
    node_ids_with_da <- as.numeric(names(node_da_counts))

    sg_pairs_with_da <- sum(sapply(seq_len(nrow(sg_data)), function(i) {
      sg_data$Node[i] %in% node_ids_with_da || sg_data$Sibling[i] %in% node_ids_with_da
    }))
    results$sg_pairs_with_da <- sg_pairs_with_da

    draw_plot2 <- function() {
      par(mar = c(4, 4, 5, 4))
      plot(tree,
           type = "fan",
           show.tip.label  = FALSE,
           use.edge.length = FALSE,
           main = paste0(da_count_val, " DA Genes Across ",
                         length(node_da_counts), " Nodes  |  ",
                         sg_count_val, " SG Pairs"),
           cex = 0.3)

      if (length(node_ids_with_da) > 0) {
        nodelabels(node = node_ids_with_da, pch = 21, cex = 2,
                   bg = "#FF8C00", col = "darkorange4", lwd = 1)
      }

      legend("topleft",
             legend = paste0("Nodes with DA genes (n=", length(node_ids_with_da),
                             ", ", da_count_val, " total DA genes)"),
             pch    = 21,
             pt.cex = 2,
             pt.bg  = "#FF8C00",
             col    = "darkorange4",
             pt.lwd = 1,
             bty    = "n")
    }

    pdf(file.path(qc_report_dir, "plot2_da_sg_tree.pdf"), width = 12, height = 12)
    draw_plot2()
    dev.off()

    png(file.path(qc_report_dir, "plot2_da_sg_tree.png"),
        width = 1800, height = 1800, res = 150)
    draw_plot2()
    dev.off()

    cat("  DA genes:", da_count_val, "across", length(node_da_counts), "nodes\n")
    cat("  SG pairs:", sg_count_val, "(", length(sg_nodes), "unique nodes)\n")

    for (i in 1:nrow(sg_data)) {
      node_leaves    <- sg_data$Node_Leaves[i]
      sibling_leaves <- sg_data$Sibling_Leaves_Total[i]
      ratio <- max(node_leaves, sibling_leaves) / min(node_leaves, sibling_leaves)
      if (ratio > 10) {
        node_id       <- sg_data$Node[i]
        da_count_node <- ifelse(as.character(node_id) %in% names(node_da_counts),
                                node_da_counts[as.character(node_id)], 0)
        cat("  WARNING: Unbalanced SG pair - Node", node_id, ":",
            node_leaves, "leaves vs", sibling_leaves, "leaves (ratio",
            round(ratio, 1), ":1),", da_count_node, "DA genes\n")
      }
    }

  } else {
    pdf(file.path(qc_report_dir, "plot2_da_sg_tree.pdf"), width = 8, height = 6)
    plot.new()
    text(0.5, 0.5, "Missing or empty: DA genes, SG pairs, or tree data", cex = 1.2)
    dev.off()
    results$da_count <- 0
    results$sg_count <- 0
    cat("  DA/SG data: 0 or missing\n")
  }
} else {
  pdf(file.path(qc_report_dir, "plot2_da_sg_tree.pdf"), width = 8, height = 6)
  plot.new()
  text(0.5, 0.5, "Missing: DA file, SG file, or tree", cex = 1.2)
  dev.off()
  results$da_count <- NA
  results$sg_count <- NA
  cat("  DA/SG data: Missing files\n")
}

# =============================================================================
# PLOT 3: SLAB Score Distribution
# =============================================================================
cat("Generating Plot 3: SLAB Score Distribution...\n")

slab_file <- file.path(output_dir, "gene", "SLAB_scores.txt")

if (file.exists(slab_file)) {
  slab_data <- tryCatch(
    read.table(slab_file, header = TRUE, stringsAsFactors = FALSE),
    error = function(e) NULL
  )

  if (!is.null(slab_data) && nrow(slab_data) > 0) {
    slab_count <- nrow(slab_data)
    results$slab_count <- slab_count

    score_col <- if ("SLAB_score" %in% colnames(slab_data)) {
      "SLAB_score"
    } else if ("score" %in% colnames(slab_data)) {
      "score"
    } else {
      colnames(slab_data)[ncol(slab_data)]
    }
    id_col <- colnames(slab_data)[1]

    slab_data <- slab_data[order(-slab_data[[score_col]]), ]
    top_genes <- head(slab_data, 10)

    repo_root     <- getwd()
    gene_ref_file <- file.path(repo_root, "reference_data",
                               "Hg38_GeneNames_MultipleFormats.txt")

    gene_translation <- tryCatch({
      trans <- read.table(gene_ref_file, header = TRUE,
                          stringsAsFactors = FALSE, sep = "\t")
      setNames(trans$external_gene_name, trans$ensembl_gene_id)
    }, error = function(e) {
      cat("  Warning: Could not load gene translation file:", gene_ref_file, "\n")
      NULL
    })

    if (!is.null(gene_translation)) {
      top_genes$gene_label <- sapply(top_genes[[id_col]], function(x) {
        name <- gene_translation[x]
        if (!is.na(name) && name != "" && !grepl("^ENSG", name)) name else NA
      })
    } else {
      top_genes$gene_label <- rep(NA, nrow(top_genes))
    }

    top_genes_labeled <- top_genes[!is.na(top_genes$gene_label), ]
    n_to_label        <- min(5, nrow(top_genes_labeled))

    draw_plot3 <- function() {
      par(mfrow = c(1, 2))

      hist(slab_data[[score_col]],
           main   = "SLAB Score Distribution",
           xlab   = "SLAB Score",
           col    = "lightgreen",
           breaks = 50)

      dens <- density(slab_data[[score_col]])
      plot(dens,
           main = "SLAB Score Density with Top Genes",
           xlab = "SLAB Score",
           col  = "darkgreen",
           lwd  = 2,
           xlim = range(slab_data[[score_col]]),
           ylim = c(0, max(dens$y) * 1.3))

      points(top_genes[[score_col]], rep(0, nrow(top_genes)),
             pch = 19, col = "red", cex = 1.2)

      if (n_to_label > 0) {
        y_positions <- seq(max(dens$y) * 0.1, max(dens$y) * 0.25,
                           length.out = n_to_label)
        for (i in 1:n_to_label) {
          text(top_genes_labeled[[score_col]][i], y_positions[i],
               labels = top_genes_labeled$gene_label[i],
               cex = 0.7, col = "red", font = 2)
          segments(top_genes_labeled[[score_col]][i], 0,
                   top_genes_labeled[[score_col]][i], y_positions[i] * 0.9,
                   col = "red", lty = 2, lwd = 0.5)
        }
      }
    }

    if (nrow(top_genes_labeled) == 0) {
      cat("  WARNING: No genes have valid common names for labeling\n")
    } else if (nrow(top_genes_labeled) < nrow(top_genes)) {
      cat("  Note:", nrow(top_genes) - nrow(top_genes_labeled),
          "genes excluded from labels (no valid names)\n")
    }

    pdf(file.path(qc_report_dir, "plot3_slab_distribution.pdf"), width = 12, height = 6)
    draw_plot3()
    dev.off()

    png(file.path(qc_report_dir, "plot3_slab_distribution.png"),
        width = 1800, height = 900, res = 150)
    draw_plot3()
    dev.off()

    results$slab_stats <- summary(slab_data[[score_col]])
    results$top_gene   <- list(id    = top_genes[[id_col]][1],
                               score = top_genes[[score_col]][1])
    cat("  SLAB scores:", slab_count, "entries\n")
    cat("  Score range: [", min(slab_data[[score_col]]), ",",
        max(slab_data[[score_col]]), "]\n")
    top_name <- if (nrow(top_genes_labeled) > 0) top_genes_labeled$gene_label[1] else top_genes[[id_col]][1]
    cat("  Top gene:", top_name, "(", top_genes[[id_col]][1], ") =",
        top_genes[[score_col]][1], "\n")

  } else {
    pdf(file.path(qc_report_dir, "plot3_slab_distribution.pdf"), width = 8, height = 6)
    plot.new()
    text(0.5, 0.5, "No SLAB scores data available", cex = 1.2)
    dev.off()
    results$slab_count <- 0
    cat("  SLAB scores: 0 (file empty or malformed)\n")
  }
} else {
  pdf(file.path(qc_report_dir, "plot3_slab_distribution.pdf"), width = 8, height = 6)
  plot.new()
  text(0.5, 0.5, "Missing: SLAB_scores.txt", cex = 1.2)
  dev.off()
  results$slab_count <- NA
  cat("  SLAB scores: Missing file\n")
}

# =============================================================================
# Reference Reproducibility -- SLAB correlation metric only (no scatter plot)
# =============================================================================
if (!is.null(reference_dir)) {
  cat("Computing reference SLAB correlation (test mode)...\n")

  ref_slab_file  <- file.path(reference_dir, "gene", "SLAB_scores.txt")
  ref_file_valid <- file.exists(ref_slab_file) && file.info(ref_slab_file)$size > 100

  if (ref_file_valid) {
    ref_slab <- tryCatch(
      read.table(ref_slab_file, header = TRUE, stringsAsFactors = FALSE),
      error = function(e) NULL
    )
    curr_slab <- if (exists("slab_data") && !is.null(slab_data)) {
      slab_data
    } else {
      tryCatch(
        read.table(slab_file, header = TRUE, stringsAsFactors = FALSE),
        error = function(e) NULL
      )
    }

    if (!is.null(ref_slab) && !is.null(curr_slab) &&
        nrow(ref_slab) > 0 && nrow(curr_slab) > 0) {

      id_col_ref     <- colnames(ref_slab)[1]
      id_col_curr    <- colnames(curr_slab)[1]
      score_col_ref  <- if ("SLAB_score" %in% colnames(ref_slab)) "SLAB_score" else colnames(ref_slab)[ncol(ref_slab)]
      score_col_curr <- if ("SLAB_score" %in% colnames(curr_slab)) "SLAB_score" else colnames(curr_slab)[ncol(curr_slab)]

      merged <- merge(ref_slab, curr_slab,
                      by.x = id_col_ref, by.y = id_col_curr,
                      suffixes = c("_ref", "_curr"), all = TRUE)

      if (nrow(merged) > 0) {
        ref_scores  <- merged[[paste0(score_col_ref,  "_ref")]]
        curr_scores <- merged[[paste0(score_col_curr, "_curr")]]
        ref_scores[is.na(ref_scores)]   <- 0
        curr_scores[is.na(curr_scores)] <- 0

        correlation <- cor(ref_scores, curr_scores, use = "complete.obs")
        results$reference_correlation <- correlation

        identical_pct <- round(100 * sum(ref_scores == curr_scores) / nrow(merged), 1)
        cat("  Reference correlation: R =", round(correlation, 4),
            "across", nrow(merged), "genes\n")
        cat("  Identical scores:", identical_pct, "% of genes\n")
      } else {
        results$reference_correlation <- NA
        cat("  Reference validation: No matching genes\n")
      }
    } else {
      results$reference_correlation <- NA
      cat("  Reference validation: Data unavailable\n")
    }
  } else {
    results$reference_correlation <- NA
    cat("  Reference validation: Baseline not yet established\n")
  }
} else {
  cat("Skipping reference correlation: not in test mode\n")
}

# =============================================================================
# BayesSpace: cluster plot + coldata stats + reproducibility check
# =============================================================================
cat("\nChecking for BayesSpace outputs...\n")

bayesspace_dir      <- file.path(dirname(output_dir), "bayesspace")
bayesspace_plot_src <- file.path(bayesspace_dir, "cluster_plot.png")
bayesspace_plot_dst <- file.path(qc_report_dir, "plot_bayesspace_clusters.png")

if (file.exists(bayesspace_plot_src)) {
  file.copy(bayesspace_plot_src, bayesspace_plot_dst, overwrite = TRUE)
  results$bayesspace_available <- TRUE
  cat("  BayesSpace cluster plot found and copied\n")
} else {
  results$bayesspace_available <- FALSE
  test_coldata_exists   <- file.exists(file.path(bayesspace_dir, "test_coldata.csv"))
  normal_coldata_exists <- file.exists(file.path(bayesspace_dir, "bayesspace_coldata.csv"))
  if (test_coldata_exists) {
    cat("  NOTE: BayesSpace ran in test mode but did not generate cluster_plot.png\n")
    cat("  (Re-run BayesSpace with updated code to get cluster plot)\n")
  } else if (!test_coldata_exists && !normal_coldata_exists) {
    message("WARNING: No BayesSpace outputs found at ", bayesspace_dir,
            " -- was --no-bayesspace set?")
  } else {
    message("WARNING: bayesspace_coldata.csv found but cluster_plot.png missing at ",
            bayesspace_plot_src)
  }
}

# Parse BayesSpace coldata for cluster stats
bayesspace_coldata <- NULL
for (coldata_name in c("bayesspace_coldata.csv", "test_coldata.csv")) {
  coldata_path <- file.path(bayesspace_dir, coldata_name)
  if (file.exists(coldata_path)) {
    bayesspace_coldata <- tryCatch(
      read.csv(coldata_path, row.names = 1, stringsAsFactors = FALSE),
      error = function(e) NULL
    )
    if (!is.null(bayesspace_coldata)) {
      cat("  Loaded BayesSpace coldata from", coldata_name, "\n")
      break
    }
  }
}

if (!is.null(bayesspace_coldata) && "spatial.cluster" %in% colnames(bayesspace_coldata)) {
  cluster_ids                     <- bayesspace_coldata$spatial.cluster
  results$bayesspace_n_clusters   <- length(unique(cluster_ids))
  spots_per_cluster               <- as.numeric(table(cluster_ids))
  results$bayesspace_median_spots <- median(spots_per_cluster)
  cat("  BayesSpace clusters:", results$bayesspace_n_clusters,
      "  median spots/cluster:", results$bayesspace_median_spots, "\n")

  if (!is.null(reference_dir)) {
    ref_coldata <- NULL
    for (coldata_name in c("bayesspace_coldata.csv", "test_coldata.csv")) {
      ref_coldata_path <- file.path(reference_dir, coldata_name)
      if (file.exists(ref_coldata_path)) {
        ref_coldata <- tryCatch(
          read.csv(ref_coldata_path, row.names = 1, stringsAsFactors = FALSE),
          error = function(e) NULL
        )
        if (!is.null(ref_coldata)) break
      }
    }

    if (!is.null(ref_coldata) && "spatial.cluster" %in% colnames(ref_coldata)) {
      common_spots <- intersect(rownames(bayesspace_coldata), rownames(ref_coldata))
      if (length(common_spots) > 0) {
        curr_clusters <- bayesspace_coldata[common_spots, "spatial.cluster"]
        ref_clusters  <- ref_coldata[common_spots, "spatial.cluster"]
        match_pct     <- 100 * sum(curr_clusters == ref_clusters) / length(common_spots)
        results$bayesspace_match_pct <- match_pct
        cat("  BayesSpace vs reference cluster match:", round(match_pct, 2), "%\n")
      } else {
        cat("  BayesSpace PASS/FAIL: no common spots with reference coldata\n")
      }
    } else {
      cat("  BayesSpace PASS/FAIL: reference coldata not available\n")
    }
  }
} else {
  cat("  BayesSpace coldata not found or missing spatial.cluster column\n")
}

# =============================================================================
# Generate pipeline_summary.md
# =============================================================================
cat("\nGenerating summary report...\n")

summary_file <- file.path(qc_report_dir, "pipeline_summary.md")
sink(summary_file)

cat("# TumorSPACE Pipeline Report Summary\n\n")
cat("**Generated:** ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n\n")
cat("**Output Directory:** `", output_dir, "`\n\n")

run_dir <- basename(dirname(output_dir))
if (grepl("runs_", run_dir)) {
  mode_parts <- strsplit(run_dir, "_")[[1]]
  if (length(mode_parts) >= 3) {
    cat("**Execution Mode:** ", mode_parts[2], "\n\n")
    cat("**Test/Prod Mode:** ", mode_parts[3], "\n\n")
  }
}

if (!is.null(reference_dir)) {
  cat("**Reference Validation:** Enabled (test mode)\n\n")
} else {
  cat("**Reference Validation:** Disabled\n\n")
}

cat("## Metrics Overview\n\n")

if (!is.null(results$nodecor)) {
  cat("### Optimal Hyperparameters\n\n")
  cat("**NodeCor (Pearson correlation):** ", round(results$nodecor, 4), "\n\n")
  cat("  *Measures correlation between predicted and actual spot-spot distances.*\n")
  cat("  *Higher values indicate better spatial clustering performance.*\n\n")
  cat("**Support Threshold:** ", round(results$support_threshold, 4), "\n\n")
  cat("  *Bootstrap support threshold for tree pruning (0-1 scale).*\n\n")
  cat("**Spatial Threshold:** ", round(results$spatial_threshold, 4), "\n\n")
  cat("  *Ripley K quantile threshold for spatial clustering.*\n\n")
  cat("**K Nearest Neighbors:** ", results$knn, "\n\n")
  cat("  *Number of neighbors used for spatial optimization.*\n\n")
}

if (!is.null(results$tree_stats)) {
  cat("### Tree Structure\n\n")
  cat("| Stage | Tips (spots) | Total Nodes | Polytomies |\n")
  cat("|-------|-------------|-------------|------------|\n")
  for (i in 1:nrow(results$tree_stats)) {
    cat(sprintf("| %s | %d | %d | %d |\n",
                results$tree_stats$Stage[i],
                as.integer(results$tree_stats$Tips[i]),
                as.integer(results$tree_stats$Total_Nodes[i]),
                as.integer(results$tree_stats$Polytomies[i])))
  }
  cat("\n")
}

sg_cnt      <- if (!is.null(results$sg_count) && !is.na(results$sg_count)) results$sg_count else NA
da_cnt      <- if (!is.null(results$da_count) && !is.na(results$da_count)) results$da_count else NA
total_spots <- if (!is.null(results$tree_stats) && !is.na(results$tree_stats$Tips[2])) results$tree_stats$Tips[2] else NA

cat("### Spatial Groups & Differential Abundance\n\n")
if (!is.na(total_spots)) cat("**Total spots (tree tips):** ", as.integer(total_spots), "\n\n")
if (!is.na(sg_cnt))      cat("**SG pairs:** ", sg_cnt, "\n\n")
if (!is.na(da_cnt))      cat("**DA genes:** ", da_cnt, "\n\n")
sg_pairs_w_da_val <- if (!is.null(results$sg_pairs_with_da)) results$sg_pairs_with_da else NA
if (!is.na(sg_cnt) && !is.na(sg_pairs_w_da_val) && sg_cnt > 0) {
  cat("**SG pairs with DA genes:** ", sg_pairs_w_da_val, "/", sg_cnt,
      paste0(" (", round(100 * sg_pairs_w_da_val / sg_cnt, 1), "%)\n\n"))
}

if (!is.null(results$slab_count)) {
  cat("### SLAB Scores\n\n")
  if (is.na(results$slab_count)) {
    cat("**SLAB Entries:** Missing data\n\n")
  } else {
    cat("**SLAB Entries:** ", results$slab_count, "\n\n")
    if (!is.null(results$slab_stats)) {
      cat("**Score Statistics:**\n\n")
      cat("- Min: ",    round(results$slab_stats["Min."],     4), "\n")
      cat("- 1st Qu: ", round(results$slab_stats["1st Qu."], 4), "\n")
      cat("- Median: ", round(results$slab_stats["Median"],   4), "\n")
      cat("- Mean: ",   round(results$slab_stats["Mean"],     4), "\n")
      cat("- 3rd Qu: ", round(results$slab_stats["3rd Qu."], 4), "\n")
      cat("- Max: ",    round(results$slab_stats["Max."],     4), "\n\n")
    }
  }
}

if (!is.null(results$bayesspace_n_clusters)) {
  cat("### BayesSpace Clustering\n\n")
  cat("**Clusters found:** ", results$bayesspace_n_clusters, "\n\n")
  cat("**Median spots per cluster:** ", results$bayesspace_median_spots, "\n\n")
}

if (!is.null(results$reference_correlation)) {
  cat("### Reference Validation (Test Mode)\n\n")
  ref_corr <- results$reference_correlation
  if (is.na(ref_corr)) {
    cat("**SLAB Correlation:** Not available (reference missing or data mismatch)\n\n")
  } else {
    cat("**SLAB Correlation:** R = ", round(ref_corr, 4),
        " -- ", if (ref_corr >= 0.95) "**PASS**" else "**FAIL**", "\n\n")
  }
  if (!is.null(results$bayesspace_match_pct)) {
    bs_pct <- results$bayesspace_match_pct
    cat("**BayesSpace cluster match:** ", round(bs_pct, 2),
        "% -- ", if (bs_pct >= 99) "**PASS**" else "**FAIL**", "\n\n")
  }
}

cat("## Plot Files\n\n")
cat("![Post-Prune Tree](plot1_tree_postprune.png)\n\n")
cat("![DA/SG Tree](plot2_da_sg_tree.png)\n\n")
cat("![SLAB Distribution](plot3_slab_distribution.png)\n\n")
if (!is.null(results$bayesspace_available) && results$bayesspace_available) {
  cat("![BayesSpace Clusters](plot_bayesspace_clusters.png)\n\n")
}
cat("\n**Download high-resolution versions:**\n\n")
cat("- [plot1_tree_postprune.pdf](plot1_tree_postprune.pdf) - Post-prune phylogenetic tree\n")
cat("- [plot2_da_sg_tree.pdf](plot2_da_sg_tree.pdf) - DA genes and SG pair nodes on tree\n")
cat("- [plot3_slab_distribution.pdf](plot3_slab_distribution.pdf) - SLAB score distribution\n")
if (!is.null(results$bayesspace_available) && results$bayesspace_available) {
  cat("- [plot_bayesspace_clusters.png](plot_bayesspace_clusters.png)",
      "- BayesSpace spatial cluster map\n")
}
cat("\n")

sink()

# =============================================================================
# Generate Comprehensive PDF Report
# =============================================================================
cat("\nGenerating comprehensive PDF report...\n")

pdf_dashboard_path <- file.path(qc_report_dir, "Pipeline_Report.pdf")
pdf(pdf_dashboard_path, width = 11, height = 8.5)

# ---------------------------------------------------------------------------
# Page 1: Title Page
# ---------------------------------------------------------------------------
par(mar = c(0, 0, 0, 0))
plot.new()
text(0.5, 0.76, "TumorSPACE Pipeline Report", cex = 2.5, font = 2)

dataset_id <- tryCatch(
  basename(dirname(dirname(dirname(output_dir)))),
  error = function(e) basename(dirname(output_dir))
)
run_name  <- tryCatch(basename(dirname(output_dir)), error = function(e) "")
param_set <- basename(output_dir)

text(0.5, 0.61, paste("Dataset:", dataset_id), cex = 1.4)
text(0.5, 0.51, paste("Run:", run_name), cex = 1.05, col = "gray30")
text(0.5, 0.42,
     paste0("Parameter set: ", param_set, "  (best SVD configuration)"),
     cex = 0.95, col = "gray30")
text(0.5, 0.32, paste("Generated:", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), cex = 1.0)
text(0.5, 0.19, "Validates phylogenetic tree building, spatial optimization,",
     cex = 0.9, col = "gray40")
text(0.5, 0.14, "differential abundance, and SLAB scoring reproducibility.",
     cex = 0.9, col = "gray40")

# ---------------------------------------------------------------------------
# Page 2: Metrics Summary
# ---------------------------------------------------------------------------
plot.new()
par(mar = c(1, 1, 3, 1))
text(0.5, 0.97, "Quality Metrics Summary", cex = 2, font = 2)

y_pos       <- 0.88
line_height <- 0.048

tree_stats_r <- if (!is.null(results$tree_stats)) results$tree_stats else
                  data.frame(Tips        = c(NA, NA),
                             Total_Nodes = c(NA, NA),
                             Polytomies  = c(NA, NA))
pre_poly  <- tree_stats_r$Polytomies[1]
post_tips <- tree_stats_r$Tips[2]
post_poly <- tree_stats_r$Polytomies[2]

text(0.05, y_pos, "Tree Structure:", cex = 1.1, font = 2, adj = 0)
y_pos <- y_pos - line_height
text(0.10, y_pos,
     sprintf("Spots: %s  |  Pre-prune polytomies: %s  |  Post-prune polytomies: %s",
             ifelse(is.na(post_tips), "N/A", as.character(as.integer(post_tips))),
             ifelse(is.na(pre_poly),  "N/A", as.character(as.integer(pre_poly))),
             ifelse(is.na(post_poly), "N/A", as.character(as.integer(post_poly)))),
     cex = 0.95, adj = 0)
if (!is.na(pre_poly) && !is.na(post_poly)) {
  y_pos <- y_pos - line_height
  text(0.10, y_pos,
       sprintf("Nodes collapsed by pruning: %d",
               as.integer(post_poly) - as.integer(pre_poly)),
       cex = 0.95, adj = 0)
}
y_pos <- y_pos - line_height * 1.4

da_count_m <- if (!is.null(results$da_count) && !is.na(results$da_count)) results$da_count else 0
sg_count_m <- if (!is.null(results$sg_count) && !is.na(results$sg_count)) results$sg_count else 0
text(0.05, y_pos, "Spatial Groups & Differential Abundance:", cex = 1.1, font = 2, adj = 0)
y_pos <- y_pos - line_height
text(0.10, y_pos,
     sprintf("SG pairs: %d  |  DA genes: %d", sg_count_m, da_count_m),
     cex = 0.95, adj = 0)
if (sg_count_m > 0) {
  y_pos <- y_pos - line_height
  sg_pairs_w_da_m <- if (!is.null(results$sg_pairs_with_da)) results$sg_pairs_with_da else 0
  text(0.10, y_pos,
       sprintf("SG pairs with DA genes: %d / %d (%.1f%%)",
               sg_pairs_w_da_m, sg_count_m, 100 * sg_pairs_w_da_m / sg_count_m),
       cex = 0.95, adj = 0)
}
y_pos <- y_pos - line_height * 1.4

slab_cnt     <- if (!is.null(results$slab_count) && !is.na(results$slab_count)) results$slab_count else 0
slab_summary <- if (!is.null(results$slab_stats)) results$slab_stats else c(Mean = NA, Median = NA)
text(0.05, y_pos, "SLAB Scores:", cex = 1.1, font = 2, adj = 0)
y_pos <- y_pos - line_height
text(0.10, y_pos, sprintf("Total genes: %d", slab_cnt), cex = 0.95, adj = 0)
y_pos <- y_pos - line_height
med_val <- if (!is.na(slab_summary["Median"])) sprintf("%.4f", slab_summary["Median"]) else "N/A"
text(0.10, y_pos, paste("Median score:", med_val), cex = 0.95, adj = 0)
y_pos <- y_pos - line_height * 1.4

if (!is.null(results$bayesspace_n_clusters)) {
  text(0.05, y_pos, "BayesSpace Clustering:", cex = 1.1, font = 2, adj = 0)
  y_pos <- y_pos - line_height
  text(0.10, y_pos,
       sprintf("Clusters: %d  |  Median spots/cluster: %.1f",
               results$bayesspace_n_clusters,
               results$bayesspace_median_spots),
       cex = 0.95, adj = 0)
  y_pos <- y_pos - line_height * 1.4
}

if (!is.null(reference_dir)) {
  text(0.05, y_pos, "Reproducibility (vs reference baseline):", cex = 1.1, font = 2, adj = 0)
  y_pos <- y_pos - line_height

  ref_corr <- results$reference_correlation
  if (!is.null(ref_corr) && !is.na(ref_corr)) {
    slab_pass <- ref_corr >= 0.95
    text(0.10, y_pos, sprintf("SLAB correlation: R = %.4f", ref_corr),
         cex = 0.95, adj = 0)
    text(0.62, y_pos,
         if (slab_pass) "PASS" else "FAIL",
         cex = 1.1, font = 2, adj = 0,
         col = if (slab_pass) "darkgreen" else "red")
    y_pos <- y_pos - line_height
  }

  bs_match <- results$bayesspace_match_pct
  if (!is.null(bs_match) && !is.na(bs_match)) {
    bs_pass <- bs_match >= 99
    text(0.10, y_pos,
         sprintf("BayesSpace cluster match: %.2f%%", bs_match),
         cex = 0.95, adj = 0)
    text(0.62, y_pos,
         if (bs_pass) "PASS" else "FAIL",
         cex = 1.1, font = 2, adj = 0,
         col = if (bs_pass) "darkgreen" else "red")
  }
}

# ---------------------------------------------------------------------------
# Pages 3+: Embedded Plots
# ---------------------------------------------------------------------------
tryCatch({
  if (requireNamespace("png", quietly = TRUE)) {

    # Page 3: Plot 1 (post-prune tree) + Plot 2 (DA/SG overlay) side-by-side
    p1_path <- file.path(qc_report_dir, "plot1_tree_postprune.png")
    p2_path <- file.path(qc_report_dir, "plot2_da_sg_tree.png")

    if (file.exists(p1_path) || file.exists(p2_path)) {
      # Title strip across full page
      par(fig = c(0, 1, 0.93, 1), new = FALSE, mar = c(0, 0, 1, 0))
      plot.new()
      text(0.5, 0.4,
           "Post-Prune Tree (left)  |  DA Gene & SG Pair Overlay (right)",
           cex = 1.3, font = 2)

      if (file.exists(p1_path)) {
        par(fig = c(0, 0.5, 0, 0.93), new = TRUE, mar = c(0, 0, 0, 0))
        plot.new()
        rasterImage(png::readPNG(p1_path), 0, 0, 1, 1)
      }
      if (file.exists(p2_path)) {
        par(fig = c(0.5, 1, 0, 0.93), new = TRUE, mar = c(0, 0, 0, 0))
        plot.new()
        rasterImage(png::readPNG(p2_path), 0, 0, 1, 1)
      }
      par(fig = c(0, 1, 0, 1), new = FALSE)
    }

    # Page 4: SLAB distribution; Page 5: BayesSpace clusters (last)
    for (plot_name in c("plot3_slab_distribution.png",
                        "plot_bayesspace_clusters.png")) {
      plot_path <- file.path(qc_report_dir, plot_name)
      if (file.exists(plot_path)) {
        img <- png::readPNG(plot_path)
        plot.new()
        par(mar = c(0, 0, 2, 0))
        rasterImage(img, 0, 0, 1, 1)
        plot_titles <- c(
          "plot3_slab_distribution.png"  = "SLAB Score Distribution",
          "plot_bayesspace_clusters.png" = "BayesSpace Spatial Clusters"
        )
        title(main = plot_titles[[plot_name]],
              cex.main = 1.5, font.main = 2)
      }
    }

  } else {
    plot.new()
    par(mar = c(1, 1, 1, 1))
    text(0.5, 0.5, "Individual plots are available as separate PDF files:",
         cex = 1.5, font = 2)
    text(0.5, 0.40, "- plot1_tree_postprune.pdf",    cex = 1.2, adj = 0.5)
    text(0.5, 0.35, "- plot2_da_sg_tree.pdf",        cex = 1.2, adj = 0.5)
    text(0.5, 0.30, "- plot3_slab_distribution.pdf", cex = 1.2, adj = 0.5)
    text(0.5, 0.15, "(Install 'png' package to embed plots in dashboard)",
         cex = 1.0, col = "gray50")
  }
}, error = function(e) {
  plot.new()
  text(0.5, 0.5, paste("Error embedding plots:", e$message), cex = 1.2, col = "red")
})

dev.off()

cat("PDF report saved to:", pdf_dashboard_path, "\n")
cat("Pipeline report generation complete!\n")
cat("Reports saved to:", qc_report_dir, "\n")
