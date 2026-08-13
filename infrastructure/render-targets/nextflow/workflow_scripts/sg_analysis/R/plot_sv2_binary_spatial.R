#!/usr/bin/env Rscript
#
# Binary Spatial Visualization of SV2_Pos Distribution
# Reclassifies SG_Pairs using only top 10 SVs, then creates 2x2 spatial plot
#

library(data.table)
library(ggplot2)
library(cowplot)
library(dplyr)

cat("================================================================================\n")
cat("Strongly Immune SV Spatial Visualization (SV1_Neg + SV2_Pos)\n")
cat("================================================================================\n\n")

# ============================================================================
# CONFIGURATION
# ============================================================================

output_dir <- "local/outputs/GSE193460_cohort_isg_analysis"
output_file_pdf <- file.path(output_dir, "strongly_immune_binary_spatial.pdf")
output_file_png <- file.path(output_dir, "strongly_immune_binary_spatial.png")

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
# LOAD U MATRIX AND FILTER TO TOP 10 SVs
# ============================================================================

cat("Loading U matrix...\n")
u_matrix <- fread("local/outputs/GSE193460_cohort_isg_analysis/svd_u_matrix.txt")

cat(sprintf("  Total SVs: %d\n", length(unique(u_matrix$SV))))
cat(sprintf("  Total SG pairs: %d\n", length(unique(u_matrix$SG_Pair))))

# Filter to top 5 SVs only (SV1-SV5 are highest variance)
top_5_svs <- paste0("SV", 1:5)
u_matrix_top5 <- u_matrix[SV %in% top_5_svs]

cat(sprintf("\nFiltered to top 5 SVs: %s\n", paste(top_5_svs, collapse = ", ")))
cat(sprintf("  Retained: %d SG-SV pairs\n", nrow(u_matrix_top5)))

# ============================================================================
# RECLASSIFY SG_PAIRS TO DOMINANT SV (WITHIN TOP 5)
# ============================================================================

cat("\nReclassifying SG_Pairs to dominant SV (top 5 only)...\n")

# For each SG pair, find SV with maximum absolute loading among top 5
sg_assignments_top5 <- u_matrix_top5 %>%
  group_by(SG_Pair) %>%
  slice_max(abs(Loading), n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  mutate(SV_Signed = paste0(SV, "_", ifelse(Loading > 0, "Pos", "Neg")))

cat(sprintf("  Classified %d SG pairs\n\n", nrow(sg_assignments_top5)))

# Summary of classifications
cat("SG pairs per SV_Signed category (top 5 only):\n")
sv_signed_counts <- table(sg_assignments_top5$SV_Signed)
print(sv_signed_counts)

# Check for SV2_Pos
sv2_pos_count <- sum(sg_assignments_top5$SV_Signed == "SV2_Pos")
cat(sprintf("\n✓ SV2_Pos SG pairs: %d (%.1f%% of total)\n", 
            sv2_pos_count, 
            100 * sv2_pos_count / nrow(sg_assignments_top5)))

if (sv2_pos_count == 0) {
  cat("Note: No SG pairs classified as SV2_Pos.\n")
}

# ============================================================================
# MERGE WITH METADATA TO GET NODE AND SAMPLE INFORMATION
# ============================================================================

cat("\nMerging with metadata...\n")

# Load metadata
metadata <- fread("local/outputs/GSE193460_cohort_isg_analysis/sg_pair_metadata.txt")

# Merge to get sample info
sg_assignments_full <- merge(sg_assignments_top5, metadata, by = "SG_Pair")

cat(sprintf("  Merged: %d SG pairs across %d samples\n", 
            nrow(sg_assignments_full), 
            length(unique(sg_assignments_full$SampleID))))

# Count strongly immune modes (SV1_Neg + SV2_Pos)
cat("\nStrongly immune (SV1_Neg + SV2_Pos) SG pair distribution by sample:\n")
strongly_immune_by_sample <- sg_assignments_full %>%
  filter(SV_Signed %in% c("SV1_Neg", "SV2_Pos")) %>%
  count(SampleID, SV_Signed) %>%
  arrange(SampleID, SV_Signed)
print(strongly_immune_by_sample)

cat(sprintf("\nTotal strongly immune SG pairs: %d (%.1f%% of total)\n",
            sum(strongly_immune_by_sample$n),
            100 * sum(strongly_immune_by_sample$n) / nrow(sg_assignments_full)))

# ============================================================================
# LOAD SPATIAL COORDINATES FROM TUMORSPACE OUTPUTS
# ============================================================================

cat("\nLoading spatial coordinates from TumorSPACE outputs...\n")

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
    cat(sprintf("  Warning: allnodes_leaves.tsv not found for %s\n", sample_info$SampleID[i]))
  }
}

# Combine all leaves
all_leaves <- rbindlist(all_leaves_list, fill = TRUE)
cat(sprintf("\nTotal node-barcode mappings: %d\n", nrow(all_leaves)))

# ============================================================================
# MAP NODES TO BARCODES AND CLASSIFY AS SV2_POS OR OTHER
# ============================================================================

cat("\nMapping nodes to barcodes and classifying spots...\n")

# Merge spatial data with SG assignments
# Each Node from the phylogenetic tree can map to multiple barcodes
sg_assignments_subset <- sg_assignments_full %>%
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
# We need to classify each UNIQUE barcode as SV2_Pos if it belongs to ANY SV2_Pos SG_Pair

cat("\nDeduplicating to unique barcodes...\n")

# For each unique barcode, check if it's in any strongly immune node (SV1_Neg or SV2_Pos)
# Priority: if a barcode is in both strongly immune and Other nodes, classify as Strongly Immune
spatial_data_unique <- spatial_data %>%
  group_by(SampleID, Leaf, array_row, array_col, pxl_row_in_fullres, pxl_col_in_fullres) %>%
  summarise(
    # Classify as Strongly Immune if ANY of the nodes this barcode belongs to is SV1_Neg or SV2_Pos
    Binary_Class = ifelse(any(SV_Signed %in% c("SV1_Neg", "SV2_Pos")), "Strongly Immune", "Other"),
    .groups = "drop"
  )

spatial_data_unique <- as.data.table(spatial_data_unique)

cat(sprintf("  Unique barcodes: %d\n", nrow(spatial_data_unique)))
cat(sprintf("  Strongly Immune barcodes: %d\n", sum(spatial_data_unique$Binary_Class == "Strongly Immune")))
cat(sprintf("  Other barcodes: %d\n", sum(spatial_data_unique$Binary_Class == "Other")))

# ============================================================================
# CALCULATE PERCENTAGES BY SAMPLE
# ============================================================================

cat("\n", strrep("=", 80), "\n", sep="")
cat("Strongly Immune Percentages by Sample (SV1_Neg + SV2_Pos)\n")
cat(strrep("=", 80), "\n\n", sep="")

sample_stats <- spatial_data_unique %>%
  group_by(SampleID) %>%
  summarise(
    Total_Spots = n(),
    Immune_Spots = sum(Binary_Class == "Strongly Immune"),
    Immune_Pct = 100 * sum(Binary_Class == "Strongly Immune") / n(),
    .groups = "drop"
  ) %>%
  arrange(SampleID)

for (i in 1:nrow(sample_stats)) {
  cat(sprintf("  %s: %5d / %5d spots (%5.1f%%) are Strongly Immune\n",
              sample_stats$SampleID[i],
              sample_stats$Immune_Spots[i],
              sample_stats$Total_Spots[i],
              sample_stats$Immune_Pct[i]))
}

# Overall statistics
overall_pct <- 100 * sum(spatial_data_unique$Binary_Class == "Strongly Immune") / nrow(spatial_data_unique)
cat(sprintf("\n  OVERALL: %5d / %5d spots (%5.1f%%) are Strongly Immune\n",
            sum(spatial_data_unique$Binary_Class == "Strongly Immune"),
            nrow(spatial_data_unique),
            overall_pct))

cat("\n", strrep("=", 80), "\n\n", sep="")

# ============================================================================
# CREATE 2X2 SPATIAL GRID WITH BINARY COLORING
# ============================================================================

cat("Creating binary spatial plots (2x2 grid)...\n")

# Define colors
color_immune <- "#E31A1C"  # Red for Strongly Immune
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
  
  p <- ggplot(samp_data, aes(x = array_col, y = array_row, fill = Binary_Class)) +
    geom_point(shape = 21, size = 2.5, stroke = 0.1) +
    scale_fill_manual(
      values = c("Strongly Immune" = color_immune, "Other" = color_other),
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
                     aes(x = array_col, y = array_row, fill = Binary_Class)) +
  geom_point(shape = 21, size = 2.5) +
  scale_fill_manual(
    values = c("Strongly Immune" = color_immune, "Other" = color_other),
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
    "Strongly Immune (SV1_Neg + SV2_Pos) Spatial Distribution",
    fontface = "bold",
    size = 16,
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

# Save classification results
classification_file <- file.path(output_dir, "sg_sv_assignments_top5.txt")
fwrite(sg_assignments_full, classification_file, sep = "\t")
cat(sprintf("  ✓ Classifications: %s\n", classification_file))

cat("\n================================================================================\n")
cat("COMPLETE\n")
cat("================================================================================\n")
