#!/usr/bin/env Rscript
#
# Compare KP and NSCLC REACTOME Pathway Enrichment
#
# Filters NSCLC SV4_Pos results to REACTOME-only pathways and computes
# Jaccard similarity with KP immune SVs to identify the best mouse match
# for the human "organized cold zones" phenotype.

library(data.table)
library(dplyr)

cat("=== KP vs NSCLC REACTOME Pathway Comparison ===\n\n")

# ============================================================================
# CONFIGURATION
# ============================================================================

# NSCLC results (human)
nsclc_file <- "/project/araman/vivek/SG-TreeVAE/outputs/isg_analysis/pathway_enrichment_n10/hypergeometric_results/SV4_pos_enrichment.txt"

# KP results (mouse)
kp_dir <- "/project/araman/vivek/TumorSPACE_AWS/local/outputs/GSE193460_cohort_isg_analysis/pathway_enrichment"
kp_immune_scores_file <- file.path(kp_dir, "immune_enrichment_scores.txt")

# Output
output_file <- file.path(kp_dir, "kp_nsclc_reactome_comparison.txt")

# FDR threshold for significance
fdr_threshold <- 0.1

# Immune pathway keywords (matches pathway_enrichment_functions.R)
immune_keywords <- c("IMMUNE", "INTERFERON", "CYTOKINE", "INTERLEUKIN", 
                     "T_CELL", "B_CELL", "MHC", "ANTIGEN", "INFLAMMATION")
immune_pattern <- paste(immune_keywords, collapse = "|")

# ============================================================================
# LOAD NSCLC RESULTS AND FILTER TO REACTOME
# ============================================================================

cat("Loading NSCLC SV4_Pos enrichment results...\n")
nsclc <- fread(nsclc_file)
cat(sprintf("  Total pathways: %d\n", nrow(nsclc)))

# Filter to REACTOME pathways, then to immune-related only
nsclc_reactome <- nsclc %>%
  filter(grepl("^REACTOME_", pathway)) %>%
  filter(padj < fdr_threshold) %>%
  filter(grepl(immune_pattern, pathway, ignore.case = TRUE))

cat(sprintf("  REACTOME pathways (FDR < %.2f): %d\n", fdr_threshold, 
            nrow(nsclc %>% filter(grepl("^REACTOME_", pathway)) %>% filter(padj < fdr_threshold))))
cat(sprintf("  Immune-related REACTOME: %d\n", nrow(nsclc_reactome)))

if (nrow(nsclc_reactome) == 0) {
  stop("No significant REACTOME pathways found in NSCLC SV4_Pos")
}

nsclc_pathway_set <- nsclc_reactome$pathway
cat("\nNSCLC SV4_Pos top 10 REACTOME pathways:\n")
print(head(nsclc_reactome[, .(pathway, overlap, padj)], 10))
cat("\n")

# ============================================================================
# LOAD KP IMMUNE SVs
# ============================================================================

cat("Loading KP immune enrichment scores...\n")
kp_immune <- fread(kp_immune_scores_file)
cat(sprintf("  Immune-enriched SVs: %d\n\n", nrow(kp_immune)))

if (nrow(kp_immune) == 0) {
  stop("No immune-enriched SVs found in KP analysis")
}

# ============================================================================
# COMPUTE JACCARD SIMILARITY
# ============================================================================

cat("Computing Jaccard similarity for each KP immune SV...\n\n")

comparison_results <- list()

for (i in 1:nrow(kp_immune)) {
  sv <- kp_immune$Test[i]  # Column is named "Test" not "SV"
  
  # Load KP SV enrichment file
  sv_parts <- strsplit(sv, "_")[[1]]
  sv_file <- file.path(kp_dir, paste0(sv_parts[1], "_", sv_parts[2], "_enrichment.txt"))
  
  if (!file.exists(sv_file)) {
    cat(sprintf("  WARNING: %s - file not found, skipping\n", sv))
    next
  }
  
  kp_sv <- fread(sv_file)
  kp_sv_sig <- kp_sv %>% filter(padj < fdr_threshold)
  
  if (nrow(kp_sv_sig) == 0) {
    cat(sprintf("  %s: No significant pathways, skipping\n", sv))
    next
  }
  
  kp_pathway_set <- kp_sv_sig$pathway
  
  # Compute Jaccard similarity
  overlap <- intersect(kp_pathway_set, nsclc_pathway_set)
  union <- union(kp_pathway_set, nsclc_pathway_set)
  jaccard <- length(overlap) / length(union)
  
  # Store results
  comparison_results[[length(comparison_results) + 1]] <- data.frame(
    KP_SV = sv,
    KP_N_Pathways = length(kp_pathway_set),
    NSCLC_N_Pathways = length(nsclc_pathway_set),
    N_Overlap = length(overlap),
    N_Union = length(union),
    Jaccard = jaccard,
    Overlapping_Pathways = paste(overlap, collapse = ";"),
    stringsAsFactors = FALSE
  )
  
  cat(sprintf("  %s: %d pathways, Jaccard = %.3f (%d overlapping)\n", 
              sv, length(kp_pathway_set), jaccard, length(overlap)))
}

# ============================================================================
# SUMMARIZE AND SAVE
# ============================================================================

if (length(comparison_results) == 0) {
  stop("No valid comparisons could be computed")
}

comparison_df <- bind_rows(comparison_results) %>%
  arrange(desc(Jaccard))

cat("\n=== Top KP Matches to NSCLC SV4_Pos (Immune REACTOME Pathways) ===\n\n")
print(comparison_df %>% select(KP_SV, KP_N_Pathways, N_Overlap, Jaccard))

# Save results
fwrite(comparison_df, output_file, sep = "\t")
cat(sprintf("\nResults saved to: %s\n", output_file))

# ============================================================================
# DETAILED REPORT FOR TOP MATCH
# ============================================================================

if (nrow(comparison_df) > 0) {
  top_match <- comparison_df[1,]
  
  cat("\n=== BEST MATCH ===\n")
  cat(sprintf("KP SV: %s\n", top_match$KP_SV))
  cat(sprintf("Jaccard similarity: %.3f\n", top_match$Jaccard))
  cat(sprintf("Shared pathways: %d / %d total\n", top_match$N_Overlap, top_match$N_Union))
  
  if (top_match$N_Overlap > 0) {
    cat("\nOverlapping REACTOME pathways:\n")
    overlapping <- strsplit(top_match$Overlapping_Pathways, ";")[[1]]
    for (pathway in overlapping) {
      cat(sprintf("  - %s\n", pathway))
    }
  }
  
  cat("\nInterpretation:\n")
  if (top_match$Jaccard > 0.3) {
    cat("  ✓ Strong similarity - KP SV likely represents similar immune architecture\n")
  } else if (top_match$Jaccard > 0.1) {
    cat("  ≈ Moderate similarity - some shared immune features\n")
  } else {
    cat("  ✗ Weak similarity - different immune architectures\n")
  }
}

cat("\nAnalysis complete!\n")
