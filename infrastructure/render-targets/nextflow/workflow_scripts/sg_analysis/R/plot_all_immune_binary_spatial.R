#!/usr/bin/env Rscript
#
# Binary Spatial Visualization of All Immune-Activated SVs
# Combines: SV1_Neg, SV2_Pos, SV3_Pos, SV4_Pos, SV5_Pos
#

library(data.table)
library(ggplot2)
library(cowplot)
library(dplyr)

cat("================================================================================\n")
cat("All Immune-Activated SV Spatial Visualization\n")
cat("================================================================================\n\n")

# ============================================================================
# CONFIGURATION
# ============================================================================

output_dir <- "local/outputs/GSE193460_cohort_isg_analysis"
output_file_pdf <- file.path(output_dir, "all_immune_binary_spatial.pdf")
output_file_png <- file.path(output_dir, "all_immune_binary_spatial.png")

# Immune SV modes (from GSEA analysis with correct sign matching)
# Strongly immune (>=20 pathways): SV1_Neg (26), SV2_Pos (26)
# Moderate immune (10-19 pathways): SV5_Pos (19), SV4_Pos (12), SV3_Pos (11)
immune_modes <- c("SV1_Neg", "SV2_Pos", "SV3_Pos", "SV4_Pos", "SV5_Pos")

cat("Immune SV modes to combine:\n")
cat(paste("  -", immune_modes, collapse = "\n"))
cat("\n\n")

# Sample directory info (from iSG analysis)
sample_info <- data.table(
  SampleID = c("KP_1", "KP_2", "KP_3", "KP_4"),
  sample_dir = c(
    "GSE193460_GSM5808054_KP_1_native_prod_20260214_213405",
    "GSE193460_GSM5808055_KP_2_native_prod_20260214_220319",
    "outputs_native_prod_20260214_230807",
    "outputs_native_prod_20260214_230817"
  )
)

# ============================================================================
# LOAD CLASSIFICATIONS
# ============================================================================

cat("Loading SG assignments (top 5 SVs)...\n")
sg_assignments <- fread("local/outputs/GSE193460_cohort_isg_analysis/sg_sv_assignments_top5.txt")

cat(sprintf("  Total SG pairs: %d\n", length(unique(sg_assignments$SG_Pair))))
cat(sprintf("  SV modes: %d\n\n", length(unique(sg_assignments$SV_Signed))))

# Count immune SG pairs by mode
cat("Immune SG pair distribution by sample:\n")
immune_counts <- sg_assignments %>%
  filter(SV_Signed %in% immune_modes) %>%
  count(SampleID, SV_Signed) %>%
  arrange(SampleID, SV_Signed)
print(immune_counts)

cat(sprintf("\nTotal immune SG pairs: %d (%.1f%% of total)\n\n",
            sum(immune_counts$n),
            100 * sum(immune_counts$n) / nrow(sg_assignments)))

# ============================================================================
# LOAD SPATIAL COORDINATES FROM TUMORSPACE OUTPUTS
# ============================================================================

cat("Loading spatial coordinates from TumorSPACE outputs...\n")

# Load allnodes_leaves.tsv for each sample
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
    stop(sprintf("File not found: %s", leaves_file))
  }
}

# Combine all leaves
all_leaves <- rbindlist(all_leaves_list)
cat(sprintf("\nTotal node-barcode mappings: %d\n\n", nrow(all_leaves)))

# ============================================================================
# MAP SG ASSIGNMENTS TO SPATIAL BARCODES
# ============================================================================

cat("Mapping nodes to barcodes and classifying spots...\n")

# Merge spatial data with SG assignments
# Each Node from the phylogenetic tree can map to multiple barcodes
sg_assignments_subset <- sg_assignments %>%
  select(SampleID, Node, SV_Signed, SV, Loading)

spatial_data <- merge(
  all_leaves, 
  sg_assignments_subset,
  by = c("SampleID", "Node"),
  all.x = TRUE
)

# Convert to data.table
spatial_data <- as.data.table(spatial_data)

# For node-barcode combinations without assignment, mark as "Other"
spatial_data[is.na(SV_Signed), SV_Signed := "Other"]

cat(sprintf("  Total node-barcode mappings: %d\n", nrow(spatial_data)))

# ============================================================================
# DEDUPLICATE TO UNIQUE BARCODES
# ============================================================================
# Each barcode appears multiple times (once per ancestor node in the tree)
# We need to classify each UNIQUE barcode as Immune if it belongs to ANY immune SG_Pair

cat("\nDeduplicating to unique barcodes...\n")

# For each unique barcode, check if it's in any immune node
# Priority: if a barcode is in both Immune and Other nodes, classify as Immune
spatial_data_unique <- spatial_data %>%
  group_by(SampleID, Leaf, array_row, array_col, pxl_row_in_fullres, pxl_col_in_fullres) %>%
  summarise(
    # Classify as Immune if ANY of the nodes this barcode belongs to is in immune_modes
    Binary_Class = ifelse(any(SV_Signed %in% immune_modes), "Immune", "Other"),
    .groups = "drop"
  )

spatial_data_unique <- as.data.table(spatial_data_unique)

cat(sprintf("  Unique barcodes: %d\n", nrow(spatial_data_unique)))
cat(sprintf("  Immune barcodes: %d\n", sum(spatial_data_unique$Binary_Class == "Immune")))
cat(sprintf("  Other barcodes: %d\n", sum(spatial_data_unique$Binary_Class == "Other")))

# ============================================================================
# CALCULATE PERCENTAGES BY SAMPLE
# ============================================================================

cat("\n", strrep("=", 80), "\n", sep="")
cat("Immune Percentages by Sample (All Immune SVs)\n")
cat(strrep("=", 80), "\n\n", sep="")

sample_stats <- spatial_data_unique %>%
  group_by(SampleID) %>%
  summarise(
    Total_Spots = n(),
    Immune_Spots = sum(Binary_Class == "Immune"),
    Immune_Pct = 100 * sum(Binary_Class == "Immune") / n(),
    .groups = "drop"
  ) %>%
  arrange(SampleID)

for (i in 1:nrow(sample_stats)) {
  cat(sprintf("  %s: %5d / %5d spots (%5.1f%%) are Immune\n",
              sample_stats$SampleID[i],
              sample_stats$Immune_Spots[i],
              sample_stats$Total_Spots[i],
              sample_stats$Immune_Pct[i]))
}

# Overall statistics
overall_pct <- 100 * sum(spatial_data_unique$Binary_Class == "Immune") / nrow(spatial_data_unique)
cat(sprintf("\n  OVERALL: %5d / %5d spots (%5.1f%%) are Immune\n",
            sum(spatial_data_unique$Binary_Class == "Immune"),
            nrow(spatial_data_unique),
            overall_pct))

cat("\n", strrep("=", 80), "\n\n", sep="")

# ============================================================================
# CREATE 2X2 SPATIAL GRID WITH BINARY COLORING
# ============================================================================

cat("Creating binary spatial plots (2x2 grid)...\n")

# Define colors
color_immune <- "#E31A1C"  # Red for Immune
color_other <- "#CCCCCC"   # Gray for Other

# Create individual spatial plots for each sample
spatial_plots <- list()
sample_names <- c("KP_1", "KP_2", "KP_3", "KP_4")

for (samp in sample_names) {
  samp_data <- spatial_data_unique[SampleID == samp]
  
  # Get stats for subtitle
  stats <- sample_stats[sample_stats$SampleID == samp, ]
  subtitle_text <- sprintf("%d / %d spots (%.1f%%)", 
                          stats$Immune_Spots, 
                          stats$Total_Spots,
                          stats$Immune_Pct)
  
  p <- ggplot(samp_data, aes(x = array_col, y = array_row, color = Binary_Class)) +
    geom_point(shape = 16, size = 1.8) +  # shape 16 = solid circle with no border
    scale_color_manual(
      values = c("Immune" = color_immune, "Other" = color_other),
      name = "Classification"
    ) +
    labs(title = samp, subtitle = subtitle_text, x = NULL, y = NULL) +
    theme_classic() +
    theme(
      plot.title = element_text(hjust = 0.5, face = "bold", size = 14),
      plot.subtitle = element_text(hjust = 0.5, size = 10, color = "gray30"),
      axis.text = element_blank(),
      axis.ticks = element_blank(),
      axis.line = element_blank(),
      legend.position = "none"
    ) +
    coord_fixed()
  
  spatial_plots[[samp]] <- p
}

# Create shared legend
legend_plot <- ggplot(spatial_data_unique[SampleID == "KP_1"], 
                     aes(x = array_col, y = array_row, color = Binary_Class)) +
  geom_point(shape = 16, size = 2.5) +
  scale_color_manual(
    values = c("Immune" = color_immune, "Other" = color_other),
    name = "Classification"
  ) +
  theme_classic() +
  theme(legend.position = "right",
        legend.title = element_text(face = "bold", size = 12),
        legend.text = element_text(size = 11))

shared_legend <- get_legend(legend_plot)

# Combine into 2x2 grid
spatial_grid <- plot_grid(
  spatial_plots[["KP_1"]], spatial_plots[["KP_2"]],
  spatial_plots[["KP_3"]], spatial_plots[["KP_4"]],
  ncol = 2, nrow = 2,
  labels = NULL
)

# Add legend
final_plot <- plot_grid(
  spatial_grid, shared_legend, 
  ncol = 2, 
  rel_widths = c(1, 0.15)
)

# Add overall title
title_grob <- ggdraw() + 
  draw_label(
    "Immune-Activated SVs Spatial Distribution (SV1_Neg, SV2_Pos, SV3_Pos, SV4_Pos, SV5_Pos)",
    fontface = "bold",
    size = 14,
    x = 0.5,
    hjust = 0.5
  )

final_plot_with_title <- plot_grid(
  title_grob,
  final_plot,
  ncol = 1,
  rel_heights = c(0.05, 1)
)

# ============================================================================
# SAVE OUTPUT
# ============================================================================

cat("\nSaving plots...\n")

# Save PDF
ggsave(output_file_pdf, final_plot_with_title, width = 12, height = 10)
cat(sprintf("  ✓ PDF: %s\n", output_file_pdf))

# Save PNG
ggsave(output_file_png, final_plot_with_title, width = 12, height = 10, dpi = 300)
cat(sprintf("  ✓ PNG: %s\n", output_file_png))

cat("\n================================================================================\n")
cat("COMPLETE\n")
cat("================================================================================\n")
