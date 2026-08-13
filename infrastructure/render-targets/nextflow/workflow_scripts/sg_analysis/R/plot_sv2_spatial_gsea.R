#!/usr/bin/env Rscript
#
# Plot SV2: Spatial 2x2 grid + GSEA volcano plot
# Panel 1: 4 spatial samples colored by SV2 loading
# Panel 2: SV2 GSEA volcano plot (NES vs -log10(padj))
#

library(data.table)
library(ggplot2)
library(cowplot)
library(dplyr)
library(ggrepel)

cat("================================================================================\n")
cat("SV2 Spatial + GSEA Visualization\n")
cat("================================================================================\n\n")

# ============================================================================
# LOAD DATA
# ============================================================================

# Load U matrix (spot-level SV loadings)
cat("Loading U matrix...\n")
u_matrix <- fread("local/outputs/GSE193460_cohort_isg_analysis/svd_u_matrix.txt")

# Extract SV2 loadings
sv2_data <- u_matrix[SV == "SV2", .(SG_Pair, Loading)]

# Parse SG_Pair to extract sample and node
sv2_data[, c("Node", "Sibling") := tstrsplit(SG_Pair, "_", keep = c(1, 3))]
sv2_data[, Node := as.integer(Node)]

# Load metadata to get sample IDs
metadata <- fread("local/outputs/GSE193460_cohort_isg_analysis/sg_pair_metadata.txt")
sv2_data <- merge(sv2_data, metadata[, .(SG_Pair, SampleID)], by = "SG_Pair")

cat(sprintf("  SV2 loadings: %d SG pairs across samples\n", nrow(sv2_data)))
cat(sprintf("  Samples: %s\n", paste(unique(sv2_data$SampleID), collapse = ", ")))

# ============================================================================
# LOAD SPATIAL COORDINATES FROM TUMORSPACE OUTPUTS
# ============================================================================

cat("\nLoading spatial coordinates from TumorSPACE outputs...\n")

# Sample directory info (from TumorSPACE pipeline outputs)
sample_info <- data.table(
  SampleID = c("KP_1", "KP_2", "KP_3", "KP_4"),
  sample_dir = c(
    "GSE193460_GSM5808054_KP_1_native_prod_20260214_213405",
    "GSE193460_GSM5808055_KP_2_native_prod_20260214_220319",
    "outputs_native_prod_20260214_230807",
    "outputs_native_prod_20260214_230817"
  )
)

# Load allnodes_leaves.tsv for each sample
# This file maps tree Nodes to their constituent barcodes with spatial coordinates
all_leaves_list <- list()

for (i in 1:nrow(sample_info)) {
  # Construct path - KP_3/KP_4 have different directory structure
  if (grepl("^outputs_native", sample_info$sample_dir[i])) {
    # KP_3/KP_4 are directly under local/
    leaves_file <- file.path("local", sample_info$sample_dir[i], 
                             "optimal", "allnodes_leaves.tsv")
  } else {
    # KP_1/KP_2 are under local/outputs/
    leaves_file <- file.path("local/outputs", sample_info$sample_dir[i], 
                             "optimal", "allnodes_leaves.tsv")
  }
  
  if (file.exists(leaves_file)) {
    leaves <- fread(leaves_file)
    leaves[, SampleID := sample_info$SampleID[i]]
    all_leaves_list[[sample_info$SampleID[i]]] <- leaves
    cat(sprintf("  %s: %d node-barcode mappings\n", sample_info$SampleID[i], nrow(leaves)))
  } else {
    cat(sprintf("  Warning: allnodes_leaves.tsv not found for %s\n", sample_info$SampleID[i]))
  }
}

# Combine all leaves
all_leaves <- rbindlist(all_leaves_list, fill = TRUE)

# Merge with SV2 loadings
# Note: Each Node appears multiple times (once per descendant barcode), 
# so each barcode in that node will get the same SV loading
spatial_data <- merge(all_leaves, sv2_data, by = c("SampleID", "Node"), all.x = TRUE)

cat(sprintf("\nMerged data: %d barcodes with SV2 loadings (%d unique nodes)\n", 
            sum(!is.na(spatial_data$Loading)),
            length(unique(spatial_data[!is.na(Loading)]$Node))))

# ============================================================================
# PANEL 1: SPATIAL 2x2 GRID
# ============================================================================

cat("\nCreating spatial 2x2 grid...\n")

# Create individual spatial plots for each sample
spatial_plots <- list()
sample_names <- c("KP_1", "KP_2", "KP_3", "KP_4")

for (samp in sample_names) {
  samp_data <- spatial_data[SampleID == samp]
  
  p <- ggplot(samp_data, aes(x = array_col, y = array_row, fill = Loading)) +
    geom_point(shape = 21, size = 2.5, stroke = 0.1) +
    scale_fill_gradient2(low = "blue", mid = "white", high = "red",
                         midpoint = 0, na.value = "grey80",
                         name = "SV2\nLoading",
                         limits = c(min(sv2_data$Loading, na.rm = TRUE),
                                   max(sv2_data$Loading, na.rm = TRUE))) +
    labs(title = samp, x = NULL, y = NULL) +
    theme_classic() +
    theme(
      plot.title = element_text(hjust = 0.5, face = "bold", size = 12),
      axis.text = element_blank(),
      axis.ticks = element_blank(),
      axis.line = element_blank(),
      legend.position = "none"
    ) +
    coord_fixed()
  
  spatial_plots[[samp]] <- p
}

# Create shared legend
legend_plot <- ggplot(spatial_data[SampleID == "KP_1"], 
                     aes(x = array_col, y = array_row, fill = Loading)) +
  geom_point(shape = 21, size = 2.5) +
  scale_fill_gradient2(low = "blue", mid = "white", high = "red",
                      midpoint = 0, na.value = "grey80",
                      name = "SV2\nLoading",
                      limits = c(min(sv2_data$Loading, na.rm = TRUE),
                                max(sv2_data$Loading, na.rm = TRUE))) +
  theme_classic() +
  theme(legend.position = "right")

shared_legend <- get_legend(legend_plot)

# Combine into 2x2 grid
spatial_grid <- plot_grid(
  spatial_plots[["KP_1"]], spatial_plots[["KP_2"]],
  spatial_plots[["KP_3"]], spatial_plots[["KP_4"]],
  ncol = 2, nrow = 2,
  labels = NULL
)

# Add legend
panel1 <- plot_grid(spatial_grid, shared_legend, ncol = 2, rel_widths = c(1, 0.15))

# ============================================================================
# PANEL 2: GSEA VOLCANO PLOT
# ============================================================================

cat("\nCreating GSEA volcano plot...\n")

# Load SV2 GSEA results
gsea_sv2 <- fread("local/outputs/GSE193460_cohort_isg_analysis/gsea_immune/SV2_gsea.txt")

# Calculate -log10(padj)
gsea_sv2[, log10padj := -log10(padj)]

# Define significance threshold
sig_threshold <- 0.1
gsea_sv2[, Significant := padj < sig_threshold]

# Shorten pathway names for plotting
gsea_sv2[, pathway_short := gsub("REACTOME_", "", pathway)]
gsea_sv2[, pathway_short := gsub("_", " ", pathway_short)]

# Select top pathways to label (most extreme NES + significant)
gsea_sv2[, abs_NES := abs(NES)]
top_pathways <- gsea_sv2[Significant == TRUE][order(-abs_NES)][1:10]

cat(sprintf("  Total pathways: %d\n", nrow(gsea_sv2)))
cat(sprintf("  Significant pathways (FDR<0.1): %d\n", sum(gsea_sv2$Significant)))
cat(sprintf("  Labeling top %d pathways\n", nrow(top_pathways)))

# Create volcano plot
panel2 <- ggplot(gsea_sv2, aes(x = NES, y = log10padj)) +
  geom_point(aes(color = Significant), size = 3, alpha = 0.7) +
  geom_hline(yintercept = -log10(sig_threshold), linetype = "dashed", color = "grey40") +
  geom_vline(xintercept = 0, linetype = "solid", color = "grey60", linewidth = 0.5) +
  scale_color_manual(values = c("grey60", "red"),
                    name = paste0("FDR < ", sig_threshold)) +
  geom_text_repel(data = top_pathways,
                  aes(label = pathway_short),
                  size = 3, max.overlaps = 15,
                  box.padding = 0.5, point.padding = 0.3) +
  labs(
    title = "SV2 Immune Pathway Enrichment",
    x = "Normalized Enrichment Score (NES)",
    y = "-log10(adj. p-value)"
  ) +
  theme_classic() +
  theme(
    plot.title = element_text(hjust = 0.5, face = "bold", size = 14),
    legend.position = "inside",
    legend.position.inside = c(0.15, 0.9),
    legend.background = element_rect(fill = "white", color = "black"),
    axis.title = element_text(size = 12),
    axis.text = element_text(size = 10)
  )

# ============================================================================
# COMBINE PANELS
# ============================================================================

cat("\nCombining panels...\n")

combined_plot <- plot_grid(
  panel1, panel2,
  ncol = 2,
  labels = c("A", "B"),
  label_size = 16,
  rel_widths = c(1, 1)
)

# Save figure
output_file <- "local/outputs/GSE193460_cohort_isg_analysis/sv2_spatial_gsea.pdf"
ggsave(output_file, combined_plot, width = 16, height = 8, units = "in")

cat(sprintf("\n✓ Figure saved: %s\n", output_file))

# Also save PNG
output_png <- "local/outputs/GSE193460_cohort_isg_analysis/sv2_spatial_gsea.png"
ggsave(output_png, combined_plot, width = 16, height = 8, units = "in", dpi = 300)

cat(sprintf("✓ Figure saved: %s\n", output_png))

cat("\n================================================================================\n")
cat("Complete!\n")
cat("================================================================================\n")
