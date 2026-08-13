#!/usr/bin/env Rscript
#
# GrowChain Integration Execution Script
#
# Integrates iSG SV profiles with GrowChain depth metrics using the
# growchain_integration_functions.R library. Project-specific configuration.
#
# Input:  iSG analysis outputs, GrowChain depth files
# Output: Integration statistics, correlations, immune comparisons

# Load function library
source("workflows/R/growchain_integration_functions.R")

# ============================================================================
# CONFIGURATION
# ============================================================================

cat("=== iSG-GrowChain Integration Analysis ===\n\n")

base_dir <- "/project/araman/vivek/TumorSPACE_AWS"

# Sample information (EDIT FOR YOUR COHORT)
samples <- data.frame(
  sample_id = c("KP_1", "KP_2", "KP_3", "KP_4"),
  sample_dir = c(
    "local/outputs/GSE193460_GSM5808054_KP_1_native_prod_20260214_213405",
    "local/outputs/GSE193460_GSM5808055_KP_2_native_prod_20260214_220319",
    "local/outputs_native_prod_20260214_230807",
    "local/outputs_native_prod_20260214_230817"
  ),
  stringsAsFactors = FALSE
)

# iSG analysis directory
isg_dir <- "local/outputs/GSE193460_cohort_isg_analysis"

# Output directory
output_dir <- file.path(base_dir, isg_dir, "integration_growchain")

# GrowChain depth filename
gc_filename <- "SG_GrowChain_depths.txt"

# Immune SV IDs (will be populated from pathway enrichment if available)
# For now, set manually or leave NULL
immune_sv_ids <- NULL  # e.g., c("SV1", "SV2") based on pathway enrichment

# Try to load immune SVs from pathway enrichment
pathway_enrichment_file <- file.path(base_dir, isg_dir, "pathway_enrichment", 
                                    "pathway_enrichment_overview.txt")
if (file.exists(pathway_enrichment_file)) {
  pathway_overview <- fread(pathway_enrichment_file)
  
  # Identify immune SVs  (example: high pathway count)
  # Extract base SV from SV_Direction format (e.g., "SV1_Pos" -> "SV1")
  if ("SV_Direction" %in% colnames(pathway_overview) && "N_Pathways_FDR01" %in% colnames(pathway_overview)) {
    immune_sv_ids <- pathway_overview %>%
      filter(N_Pathways_FDR01 >= 5) %>%  # Threshold: >= 5 pathways
      mutate(SV_Base = gsub("_Pos|_Neg", "", SV_Direction)) %>%
      pull(SV_Base) %>%
      unique()
    
    if (length(immune_sv_ids) > 0) {
      cat(sprintf("Loaded immune SVs from pathway enrichment: %s\n\n", 
                  paste(immune_sv_ids, collapse = ", ")))
    }
  }
}

# ============================================================================
# VALIDATION
# ============================================================================

isg_analysis_dir <- file.path(base_dir, isg_dir)
if (!dir.exists(isg_analysis_dir)) {
  stop(sprintf("iSG analysis directory not found: %s\nRun iSG SVD analysis first.", isg_analysis_dir))
}

cat(sprintf("iSG analysis dir: %s\n", isg_analysis_dir))
cat(sprintf("Samples: %d (%s)\n", nrow(samples), paste(samples$sample_id, collapse = ", ")))
cat(sprintf("Output dir: %s\n\n", output_dir))

# ============================================================================
# RUN INTEGRATION
# ============================================================================

results <- run_growchain_integration(
  isg_analysis_dir = isg_analysis_dir,
  sample_info_df = samples,
  output_dir = output_dir,
  gc_filename = gc_filename,
  immune_sv_ids = immune_sv_ids
)

# ============================================================================
# POST-ANALYSIS INTERPRETATION
# ============================================================================

cat("\n=== Integration Summary ===\n\n")

cat("Sample-level GrowChain metrics:\n")
print(results$growchain_metrics)

cat("\n\nTop 10 SVs by mean GrowChain depth:\n")
print(head(results$sv_depth_stats, 10))

if (nrow(results$correlations) > 0) {
  cat("\n\nTop 10 SV-depth correlations:\n")
  print(head(results$correlations %>% arrange(desc(abs(Correlation))), 10))
}

if (!is.null(results$immune_analysis)) {
  cat("\n\nImmune vs Non-immune SV depth comparison:\n")
  print(results$immune_analysis$comparison_stats)
  
  if (!is.null(results$immune_analysis$wilcox_test)) {
    cat(sprintf("\nWilcoxon test p-value: %.4f\n", 
                results$immune_analysis$wilcox_test$p.value))
  }
}

cat("\n\nKey Findings:\n")
cat(sprintf("  - Median depth range: %.1f - %.1f\n",
            min(results$growchain_metrics$Median_Depth),
            max(results$growchain_metrics$Median_Depth)))
cat(sprintf("  - SV categories analyzed: %d\n", nrow(results$sv_depth_stats)))
cat(sprintf("  - Deepest SV: %s (mean depth = %.2f)\n",
            results$sv_depth_stats[1, "SV_Signed"],
            results$sv_depth_stats[1, "Mean_Depth"]))

cat("\nNext Steps:\n")
cat("  1. Compare with NSCLC: Do KP immune SVs match NSCLC SV4_Pos patterns?\n")
cat("  2. Visualize: Depth distributions by SV, correlation heatmaps\n")
cat("  3. Clinical translation: Test if immune depth organization predicts outcomes\n\n")

cat("Analysis complete!\n")
# ============================================================================

