#!/usr/bin/env Rscript
#
# Gene Annotation Execution Script
#
# Annotates genes from iSG SVD analysis using the gene_annotation_functions.R library.
# This is an execution script with project-specific configuration.
#
# Input:  top_genes_per_sv.txt (from iSG SVD analysis)
# Output: top_genes_per_sv_annotated.txt, annotation_summary.txt

# Load function library
source("workflows/R/gene_annotation_functions.R")

# Load annotation packages
if (!requireNamespace("org.Mm.eg.db", quietly = TRUE)) {
  cat("ERROR: org.Mm.eg.db package not installed\n")
  cat("Install via: BiocManager::install('org.Mm.eg.db')\n")
  quit(status = 1)
}
library(org.Mm.eg.db)

# ============================================================================
# CONFIGURATION
# ============================================================================

cat("=== Gene Annotation for iSG SVD Analysis ===\n\n")

# Input/output directories (EDIT THESE FOR YOUR ANALYSIS)
base_dir <- "/project/araman/vivek/TumorSPACE_AWS"
isg_dir <- "local/outputs/GSE193460_cohort_isg_analysis"

input_file <- file.path(base_dir, isg_dir, "top_genes_per_sv.txt")
output_dir <- file.path(base_dir, isg_dir)

# Annotation parameters
organism_db <- org.Mm.eg.db  # Mouse annotation database
# For human, use: org.Hs.eg.db

# Optional: customize marker gene patterns (NULL = use defaults)
marker_lists <- NULL  # Use default_immune_markers(), etc.

# ============================================================================
# VALIDATION
# ============================================================================

if (!file.exists(input_file)) {
  stop(sprintf("Input file not found: %s\nRun iSG SVD analysis first.", input_file))
}

cat(sprintf("Input:  %s\n", input_file))
cat(sprintf("Output: %s\n\n", output_dir))

# ============================================================================
# RUN ANNOTATION
# ============================================================================

results <- run_gene_annotation(
  top_genes_file = input_file,
  output_dir = output_dir,
  organism_db = organism_db,
  marker_lists = marker_lists
)

# ============================================================================
# POST-ANALYSIS SUMMARY
# ============================================================================

cat("\n=== Annotation Summary ===\n")
cat(sprintf("Annotation rate: %.1f%%\n", 100 * results$annotation_stats$annotation_rate))
cat("\nGene categories:\n")
print(results$category_counts)

cat("\nNext Steps:\n")
cat("  1. Run pathway enrichment: workflows/R/run_isg_pathway_enrichment_hypergeometric.R\n")
cat("  2. Integrate with GrowChain: Use results in GrowChain integration\n")
cat("  3. Visualize: Create gene loading heatmaps with annotated symbols\n\n")

cat("Analysis complete!\n")
