#!/usr/bin/env Rscript
#
# ===== DEPRECATED =====
# This script has been superseded by the refactored pathway enrichment system.
#
# Use instead:
#   - Library: workflows/R/pathway_enrichment_functions.R
#   - Hypergeometric: workflows/R/run_isg_pathway_enrichment_hypergeometric.R
#   - clusterProfiler: Create custom script using pathway_enrichment_functions.R
#
# Reason for deprecation:
#   - Hardcoded paths (not reusable)
#   - Uses clusterProfiler method (not matching NSCLC hypergeometric approach)
#   - Superseded by general function library with both methods
#
# This file kept for reference only.
# Date deprecated: February 17, 2026
# ======================
#
# Original: Pathway Enrichment Analysis for iSG Signatures
#
# Performs gene set enrichment analysis on top genes per SV using MSigDB
# collections (Hallmark, Immunologic Signatures, GO Biological Process).
# Identifies immune-related SVs and characterizes biological functions.
#
# Requires: clusterProfiler, msigdbr, enrichplot packages

library(data.table)
library(dplyr)
library(tidyr)

# Check required packages (minimal set - avoid enrichplot due to graphlayouts dependency issues)
required_packages <- c("clusterProfiler", "msigdbr")
missing_packages <- required_packages[!sapply(required_packages, 
                                               function(p) requireNamespace(p, quietly = TRUE))]

if (length(missing_packages) > 0) {
  cat("ERROR: Required packages not installed:\n")
  cat(paste("  -", missing_packages, collapse = "\n"), "\n")
  cat("\nInstall via:\n")
  cat("BiocManager::install('clusterProfiler')\n")
  cat("install.packages('msigdbr')\n")
  quit(status = 1)
}

library(clusterProfiler)
library(msigdbr)

# For gene ID conversion
if (!requireNamespace("org.Mm.eg.db", quietly = TRUE)) {
  cat("ERROR: org.Mm.eg.db package not installed\n")
  cat("Install via: BiocManager::install('org.Mm.eg.db')\n")
  quit(status = 1)
}
library(org.Mm.eg.db)

# ============================================================================
# CONFIGURATION
# ============================================================================

# Input/output directories
base_dir <- "/project/araman/vivek/TumorSPACE_AWS"
isg_dir <- "local/outputs/GSE193460_cohort_isg_analysis"

# Use annotated file if available, otherwise use Ensembl IDs
annotated_file <- file.path(base_dir, isg_dir, "top_genes_per_sv_annotated.txt")
original_file <- file.path(base_dir, isg_dir, "top_genes_per_sv.txt")

if (file.exists(annotated_file)) {
  input_file <- annotated_file
  use_symbols <- TRUE
} else {
  input_file <- original_file
  use_symbols <- FALSE
  cat("WARNING: Annotated file not found, using Ensembl IDs\n")
  cat("  Run isg_annotate_genes.R first for better results\n\n")
}

output_dir <- file.path(base_dir, isg_dir, "pathway_enrichment")
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

# Analysis parameters
n_top_svs <- 10  # Focus on top 10 SVs (most variance explained)
n_genes_per_direction <- 100  # Number of genes per SV direction for enrichment
p_cutoff <- 0.05  # FDR cutoff
q_cutoff <- 0.1   # More lenient q-value cutoff for discovery

# ============================================================================
# LOAD DATA
# ============================================================================

cat("Loading top genes from iSG analysis...\n")
top_genes <- fread(input_file, header = TRUE)

cat(sprintf("  Loaded %d gene-SV associations\n", nrow(top_genes)))

# Get list of top SVs (by number, SV1-SV10 are highest variance)
sv_numbers <- as.integer(gsub("SV", "", unique(top_genes$SV)))
top_sv_ids <- paste0("SV", sort(sv_numbers)[1:min(n_top_svs, length(sv_numbers))])

cat(sprintf("  Focusing on top %d SVs: %s\n", 
            length(top_sv_ids), 
            paste(top_sv_ids, collapse = ", ")))

# Focus on top SVs
top_genes_subset <- top_genes %>% filter(SV %in% top_sv_ids)

# ============================================================================
# PREPARE GENE LISTS
# ============================================================================

cat("\nPreparing gene lists for enrichment...\n")

# For each SV direction, get gene list
# Need Entrez IDs for clusterProfiler
gene_lists <- list()

for (sv in top_sv_ids) {
  for (direction in c("Pos", "Neg")) {
    sv_label <- paste0(sv, "_", direction)
    
    genes_in_set <- top_genes_subset %>%
      filter(SV == sv, Direction == direction) %>%
      arrange(Rank) %>%
      head(n_genes_per_direction)
    
    if (nrow(genes_in_set) == 0) next
    
    # Convert to Entrez IDs
    if (use_symbols) {
      # Use gene symbols
      gene_ids <- genes_in_set$Symbol
      # Convert symbols to Entrez
      entrez_ids <- mapIds(org.Mm.eg.db, keys = gene_ids, 
                          column = "ENTREZID", keytype = "SYMBOL",
                          multiVals = "first")
    } else {
      # Use Ensembl IDs
      gene_ids <- genes_in_set$Gene
      # Convert Ensembl to Entrez
      entrez_ids <- mapIds(org.Mm.eg.db, keys = gene_ids,
                          column = "ENTREZID", keytype = "ENSEMBL",
                          multiVals = "first")
    }
    
    # Remove NAs
    entrez_ids <- entrez_ids[!is.na(entrez_ids)]
    
    if (length(entrez_ids) > 5) {  # Need at least 5 genes for enrichment
      gene_lists[[sv_label]] <- entrez_ids
      cat(sprintf("  %s: %d genes (%.1f%% converted to Entrez)\n",
                  sv_label, length(entrez_ids),
                  100 * length(entrez_ids) / nrow(genes_in_set)))
    }
  }
}

cat(sprintf("\nPrepared %d gene lists for enrichment\n", length(gene_lists)))

# ============================================================================
# LOAD MSIGDB GENE SETS
# ============================================================================

cat("\nLoading MSigDB gene sets for mouse...\n")

# Hallmark: Well-defined biological processes
msigdb_hallmark <- msigdbr(species = "Mus musculus", category = "H")
cat(sprintf("  Hallmark: %d gene sets\n", 
            length(unique(msigdb_hallmark$gs_name))))

# Immunologic Signatures (C7)
msigdb_immunologic <- msigdbr(species = "Mus musculus", category = "C7",
                              subcategory = "IMMUNESIGDB")
cat(sprintf("  Immunologic Signatures: %d gene sets\n",
            length(unique(msigdb_immunologic$gs_name))))

# GO Biological Process (subset to immune-related)
msigdb_go_bp <- msigdbr(species = "Mus musculus", category = "C5",
                        subcategory = "GO:BP")
# Filter to immune/inflammatory GO terms
immune_go_terms <- msigdb_go_bp %>%
  filter(grepl("IMMUNE|INFLAMMATORY|INTERFERON|CYTOKINE|CHEMOKINE|T_CELL|B_CELL|MACROPHAGE|DENDRITIC",
               gs_name, ignore.case = TRUE))
cat(sprintf("  GO Biological Process (immune-related): %d gene sets\n",
            length(unique(immune_go_terms$gs_name))))

# ============================================================================
# RUN ENRICHMENT ANALYSIS
# ============================================================================

cat("\n=== Running Pathway Enrichment Analysis ===\n\n")

all_enrichment_results <- list()

# Function to run enrichment for a gene set collection
run_enrichment <- function(gene_list, gene_set_df, set_name, sv_label) {
  tryCatch({
    result <- enricher(
      gene = gene_list,
      TERM2GENE = gene_set_df[, c("gs_name", "entrez_gene")],
      pvalueCutoff = p_cutoff,
      qvalueCutoff = q_cutoff,
      minGSSize = 5,
      maxGSSize = 500
    )
    
    if (!is.null(result) && nrow(result@result) > 0) {
      result_df <- result@result %>%
        mutate(SV = sv_label,
               GeneSet = set_name) %>%
        arrange(p.adjust)
      return(result_df)
    }
  }, error = function(e) {
    return(NULL)
  })
  return(NULL)
}

# Run enrichment for each SV direction
for (sv_label in names(gene_lists)) {
  cat(sprintf("Analyzing %s...\n", sv_label))
  
  gene_list <- gene_lists[[sv_label]]
  
  # Hallmark
  hallmark_result <- run_enrichment(gene_list, msigdb_hallmark, 
                                    "Hallmark", sv_label)
  if (!is.null(hallmark_result)) {
    all_enrichment_results[[paste0(sv_label, "_Hallmark")]] <- hallmark_result
    cat(sprintf("  Hallmark: %d significant pathways\n", nrow(hallmark_result)))
  } else {
    cat(sprintf("  Hallmark: No significant pathways\n"))
  }
  
  # Immunologic
  immuno_result <- run_enrichment(gene_list, msigdb_immunologic,
                                 "Immunologic", sv_label)
  if (!is.null(immuno_result)) {
    all_enrichment_results[[paste0(sv_label, "_Immunologic")]] <- immuno_result
    cat(sprintf("  Immunologic: %d significant signatures\n", nrow(immuno_result)))
  } else {
    cat(sprintf("  Immunologic: No significant signatures\n"))
  }
  
  # GO BP (immune)
  go_result <- run_enrichment(gene_list, immune_go_terms,
                              "GO_BP_Immune", sv_label)
  if (!is.null(go_result)) {
    all_enrichment_results[[paste0(sv_label, "_GO_BP")]] <- go_result
    cat(sprintf("  GO BP (immune): %d significant terms\n", nrow(go_result)))
  } else {
    cat(sprintf("  GO BP (immune): No significant terms\n"))
  }
  
  cat("\n")
}

# Combine all results
if (length(all_enrichment_results) > 0) {
  combined_results <- bind_rows(all_enrichment_results)
  
  # Save full results
  fwrite(combined_results, 
         file.path(output_dir, "pathway_enrichment_all.txt"),
         sep = "\t")
  
  cat(sprintf("\nTotal significant enrichments: %d\n", nrow(combined_results)))
  
  # ========================================================================
  # IDENTIFY IMMUNE-RELATED SVs
  # ========================================================================
  
  cat("\n=== Identifying Immune-Related SVs ===\n\n")
  
  # Define immune-related pathway keywords
  immune_keywords <- c(
    "INTERFERON", "INFLAMMATORY", "IMMUNE", "CYTOKINE", "CHEMOKINE",
    "TNF", "IL2", "IL6", "NFKB", "JAK_STAT",
    "T_CELL", "B_CELL", "LYMPHOCYTE", "MACROPHAGE", "DENDRITIC",
    "ANTIGEN", "MHC", "CD8", "CD4"
  )
  
  # Score each SV by immune enrichment
  immune_scores <- combined_results %>%
    mutate(IsImmune = grepl(paste(immune_keywords, collapse = "|"), 
                           ID, ignore.case = TRUE)) %>%
    group_by(SV) %>%
    summarize(
      N_Total = n(),
      N_Immune = sum(IsImmune),
      Immune_Fraction = N_Immune / N_Total,
      Top_Immune_Pathway = ID[IsImmune][which.min(p.adjust[IsImmune])],
      Min_FDR = min(p.adjust[IsImmune], na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(desc(Immune_Fraction))
  
  cat("Immune enrichment scores by SV:\n")
  print(immune_scores, n = 20)
  
  # Save immune scores
  fwrite(immune_scores,
         file.path(output_dir, "immune_enrichment_scores.txt"),
         sep = "\t")
  
  # Identify top immune SVs
  top_immune_svs <- immune_scores %>%
    filter(Immune_Fraction > 0.3, N_Immune >= 3) %>%
    pull(SV)
  
  if (length(top_immune_svs) > 0) {
    cat(sprintf("\nTop immune-related SVs: %s\n", 
                paste(unique(gsub("_Pos|_Neg", "", top_immune_svs)), 
                      collapse = ", ")))
  }
  
  # ========================================================================
  # CREATE SUMMARY VISUALIZATIONS
  # ========================================================================
  
  cat("\n=== Creating Summary Visualizations ===\n\n")
  
  # Enrichment heatmap: Top pathways × Top SVs
  if (nrow(combined_results) >= 5) {
    top_pathways <- combined_results %>%
      group_by(ID) %>%
      summarize(MeanFDR = mean(-log10(p.adjust)), .groups = "drop") %>%
      arrange(desc(MeanFDR)) %>%
      head(20) %>%
      pull(ID)
    
    heatmap_data <- combined_results %>%
      filter(ID %in% top_pathways) %>%
      mutate(NegLogFDR = -log10(p.adjust)) %>%
      select(SV, ID, NegLogFDR) %>%
      pivot_wider(names_from = SV, values_from = NegLogFDR, values_fill = 0)
    
    # Save heatmap data
    fwrite(heatmap_data,
           file.path(output_dir, "enrichment_heatmap_data.txt"),
           sep = "\t")
    
    cat("  Saved enrichment heatmap data\n")
  }
  
  # Bar plot: Number of enriched pathways per SV
  pathway_counts <- combined_results %>%
    group_by(SV, GeneSet) %>%
    summarize(N_Pathways = n(), .groups = "drop")
  
  fwrite(pathway_counts,
         file.path(output_dir, "pathway_counts_per_sv.txt"),
         sep = "\t")
  
  cat("  Saved pathway counts\n")
  
  # ========================================================================
  # GENERATE SUMMARY REPORT
  # ========================================================================
  
  summary_text <- sprintf(
    "iSG Pathway Enrichment Analysis Summary
========================================

Analysis Date: %s

Input:
------
Gene lists: %d SV directions (top %d SVs)
Genes per list: %d (after Entrez conversion)

Gene Set Collections:
---------------------
- MSigDB Hallmark: %d pathways
- MSigDB Immunologic Signatures: %d signatures  
- GO Biological Process (immune): %d terms

Enrichment Results:
-------------------
Total significant enrichments: %d
  (FDR < %.2f, Q < %.2f)

By gene set:
%s

Immune-Related SVs:
-------------------
%s

Top Immune-Enriched Pathways (across all SVs):
-----------------------------------------------
%s

Output Files:
-------------
- pathway_enrichment_all.txt: Complete enrichment results
- immune_enrichment_scores.txt: Immune scoring per SV
- enrichment_heatmap_data.txt: Heatmap matrix for visualization
- pathway_counts_per_sv.txt: Summary counts

Next Steps:
-----------
1. Review immune_enrichment_scores.txt to identify immune SVs
2. Focus biological interpretation on top immune-related SVs
3. Compare SV fraction profiles (sample_sv_fractions.txt) focusing on immune SVs
4. Correlate immune SV fractions with GrowChain depth metrics
5. Create visualizations: enrichment heatmap, pathway networks
6. Compare with NSCLC findings (SV4_Pos = organized cold zones)
",
    Sys.time(),
    length(gene_lists), n_top_svs, n_genes_per_direction,
    length(unique(msigdb_hallmark$gs_name)),
    length(unique(msigdb_immunologic$gs_name)),
    length(unique(immune_go_terms$gs_name)),
    nrow(combined_results), p_cutoff, q_cutoff,
    paste(capture.output({
      set_counts <- combined_results %>%
        group_by(GeneSet) %>%
        summarize(N = n(), .groups = "drop")
      print(set_counts)
    }), collapse = "\n"),
    paste(capture.output(print(immune_scores, n = 10)), collapse = "\n"),
    paste(capture.output({
      top_immune_pathways <- combined_results %>%
        mutate(IsImmune = grepl(paste(immune_keywords, collapse = "|"),
                                ID, ignore.case = TRUE)) %>%
        filter(IsImmune) %>%
        arrange(p.adjust) %>%
        select(SV, ID, p.adjust, qvalue) %>%
        head(15)
      print(top_immune_pathways)
    }), collapse = "\n")
  )
  
  writeLines(summary_text, 
             file.path(output_dir, "enrichment_analysis_summary.txt"))
  
  cat("\n=== Analysis Complete ===\n")
  cat(sprintf("All results saved to: %s\n", output_dir))
  
} else {
  cat("\nWARNING: No significant enrichments found\n")
  cat("Consider:\n")
  cat("  - Using more lenient cutoffs (q_cutoff = 0.2)\n")
  cat("  - Including more genes per SV direction (n_genes_per_direction)\n")
  cat("  - Checking gene ID conversion rates\n")
}
