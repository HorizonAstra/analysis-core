#!/usr/bin/env Rscript
#
# Volcano Plot for Composite Immune Signature GSEA
# Shows NES vs -log10(FDR) with top 2 pathways labeled
#

library(data.table)
library(ggplot2)
library(ggrepel)

cat("================================================================================\n")
cat("Composite Immune Signature GSEA Volcano Plot\n")
cat("================================================================================\n\n")

# ============================================================================
# CONFIGURATION
# ============================================================================

output_dir <- "local/outputs/GSE193460_cohort_isg_analysis/gsea_immune"
gsea_file <- file.path(output_dir, "composite_immune_gsea.txt")
output_pdf <- file.path(output_dir, "composite_immune_volcano.pdf")
output_png <- file.path(output_dir, "composite_immune_volcano.png")

fdr_threshold <- 0.1

# ============================================================================
# LOAD GSEA RESULTS
# ============================================================================

cat("Loading GSEA results...\n")
gsea <- fread(gsea_file)

cat(sprintf("  Total pathways: %d\n", nrow(gsea)))
cat(sprintf("  Significant (FDR < %.2f): %d\n\n", fdr_threshold, sum(gsea$padj < fdr_threshold)))

# ============================================================================
# PREPARE DATA FOR VOLCANO PLOT
# ============================================================================

# Add -log10(padj) for y-axis
gsea[, neg_log10_padj := -log10(padj)]

# Clean pathway names (remove REACTOME_ prefix for readability)
gsea[, pathway_clean := gsub("^REACTOME_", "", pathway)]
gsea[, pathway_clean := gsub("_", " ", pathway_clean)]

# Create significance category
gsea[, Significance := ifelse(padj < fdr_threshold, 
                              paste0("FDR < ", fdr_threshold),
                              "Not Significant")]

# Identify top 2 pathways by significance (lowest FDR)
# Since all significant pathways are enriched, we'll label top 2 overall
gsea_sorted <- gsea[order(padj)]

# Top 2 most significant (lowest FDR, highest -log10(padj))
top_sig <- gsea_sorted[1:2]

cat("Top 2 most significant pathways to label:\n")
for (i in 1:nrow(top_sig)) {
  cat(sprintf("  %d. %s (NES=%.2f, FDR=%.2e)\n",
              i, top_sig$pathway_clean[i], top_sig$NES[i], top_sig$padj[i]))
}
cat("\n")

# Mark which pathways to label
gsea[, Label := ""]
gsea[pathway %in% top_sig$pathway, Label := pathway_clean]

# ============================================================================
# CREATE VOLCANO PLOT
# ============================================================================

cat("Creating volcano plot...\n")

# Color scheme
color_sig <- "#E31A1C"      # Red for significant
color_nonsig <- "#999999"   # Gray for non-significant

# Create plot
p <- ggplot(gsea, aes(x = NES, y = neg_log10_padj)) +
  geom_point(aes(color = Significance), size = 3, alpha = 0.7) +
  scale_color_manual(
    values = c("FDR < 0.1" = color_sig, "Not Significant" = color_nonsig),
    name = NULL
  ) +
  geom_hline(yintercept = -log10(fdr_threshold), linetype = "dashed", color = "gray40") +
  geom_vline(xintercept = 0, linetype = "solid", color = "gray40") +
  geom_text_repel(
    aes(label = Label),
    size = 3.5,
    box.padding = 0.5,
    point.padding = 0.3,
    segment.color = "gray30",
    max.overlaps = 20,
    min.segment.length = 0
  ) +
  labs(
    title = "Composite Immune Signature GSEA",
    subtitle = "REACTOME Immune Pathways",
    x = "Normalized Enrichment Score (NES)",
    y = expression(-log[10](FDR))
  ) +
  theme_classic() +
  theme(
    plot.title = element_text(hjust = 0.5, face = "bold", size = 14),
    plot.subtitle = element_text(hjust = 0.5, size = 11, color = "gray30"),
    axis.title = element_text(size = 12, face = "bold"),
    axis.text = element_text(size = 10),
    legend.position = "top",
    legend.text = element_text(size = 10)
  )

# ============================================================================
# SAVE OUTPUT
# ============================================================================

cat("\nSaving plots...\n")

# Save PDF
ggsave(output_pdf, p, width = 10, height = 8)
cat(sprintf("  ✓ PDF: %s\n", output_pdf))

# Save PNG
ggsave(output_png, p, width = 10, height = 8, dpi = 300)
cat(sprintf("  ✓ PNG: %s\n", output_png))

cat("\n================================================================================\n")
cat("COMPLETE\n")
cat("================================================================================\n")
