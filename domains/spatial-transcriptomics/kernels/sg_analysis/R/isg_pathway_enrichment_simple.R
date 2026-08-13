#!/usr/bin/env Rscript
#
# Simple Pathway Enrichment Analysis for iSG Signatures
#
# Uses basic hypergeometric testing (Fisher's exact test) to identify enriched
# pathways without requiring clusterProfiler (which has library compatibility issues).
# Analyzes MSigDB Hallmark and Immunologic gene sets.

library(data.table)
library(dplyr)
library(tidyr)

# Check msigdbr
if (!requireNamespace("msigdbr", quietly = TRUE)) {
  cat("ERROR: msigdbr package not installed\n")
  cat("Install via: install.packages('msigdbr')\n")
  quit(status = 1)
}

library(msigdbr)

# For gene ID conversion
if (!requireNamespace("org.Mm.eg.db", quietly = TRUE)) {
  cat("ERROR: org.Mm.eg.db package not installed\n")
  quit(status = 1)
}
suppressPackageStartupMessages(library(org.Mm.eg.db))
suppressPackageStartupMessages(library(AnnotationDbi))

# ============================================================================
# CONFIGURATION
# ============================================================================

base_dir <- "/project/araman/vivek/TumorSPACE_AWS"
isg_dir <- "local/outputs/GSE193460_cohort_isg_analysis"

# Use annotated file
annotated_file <- file.path(base_dir, isg_dir, "top_genes_per_sv_annotated.txt")
input_file <- annotated_file

output_dir <- file.path(base_dir, isg_dir, "pathway_enrichment")
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

# Parameters
n_top_svs <- 10
n_genes_per_direction <- 100
p_cutoff <- 0.05

# ============================================================================
# LOAD DATA
# ============================================================================

cat("Loading top genes from iSG analysis...\n")
top_genes <- fread(input_file, header = TRUE)

cat(sprintf("  Loaded %d gene-SV associations\n", nrow(top_genes)))

# Top SVs
sv_numbers <- as.integer(gsub("SV", "", unique(top_genes$SV)))
top_sv_ids <- paste0("SV", sort(sv_numbers)[1:min(n_top_svs, length(sv_numbers))])

cat(sprintf("  Focusing on top %d SVs\n", length(top_sv_ids)))

top_genes_subset <- top_genes %>% filter(SV %in% top_sv_ids)

# ============================================================================
# PREPARE GENE LISTS & CONVERT TO ENTREZ
# ============================================================================

cat("\nPreparing gene lists...\n")

gene_lists <- list()
all_genes_entrez <- c()

for (sv in top_sv_ids) {
  for (direction in c("Pos", "Neg")) {
    sv_label <- paste0(sv, "_", direction)
    
    genes_in_set <- top_genes_subset %>%
      filter(SV == sv, Direction == direction) %>%
      arrange(Rank) %>%
      head(n_genes_per_direction)
    
    if (nrow(genes_in_set) == 0) next
    
    # Convert symbols to Entrez
    gene_ids <- genes_in_set$Symbol
    entrez_ids <- mapIds(org.Mm.eg.db, keys = gene_ids, 
                        column = "ENTREZID", keytype = "SYMBOL",
                        multiVals = "first")
    
    entrez_ids <- entrez_ids[!is.na(entrez_ids)]
    
    if (length(entrez_ids) > 5) {
      gene_lists[[sv_label]] <- entrez_ids
      all_genes_entrez <- c(all_genes_entrez, entrez_ids)
      cat(sprintf("  %s: %d genes\n", sv_label, length(entrez_ids)))
    }
  }
}

# Universe: all genes tested
universe_genes <- unique(all_genes_entrez)
cat(sprintf("\nGene universe: %d unique Entrez IDs\n", length(universe_genes)))

# ============================================================================
# LOAD MSIGDB GENE SETS
# ============================================================================

cat("\nLoading MSigDB gene sets...\n")

msigdb_hallmark <- msigdbr(species = "Mus musculus", category = "H")
cat(sprintf("  Hallmark: %d gene sets\n", 
            length(unique(msigdb_hallmark$gs_name))))

msigdb_immunologic <- msigdbr(species = "Mus musculus", category = "C7",
                              subcategory = "IMMUNESIGDB")
cat(sprintf("  Immunologic: %d gene sets\n",
            length(unique(msigdb_immunologic$gs_name))))

# Combine gene sets
all_gene_sets <- bind_rows(
  msigdb_hallmark %>% mutate(GeneSet = "Hallmark"),
  msigdb_immunologic %>% mutate(GeneSet = "Immunologic")
)

# Create gene set list
gene_set_list <- split(all_gene_sets$entrez_gene, 
                       interaction(all_gene_sets$gs_name, all_gene_sets$GeneSet))

names(gene_set_list) <- gsub("\\.(Hallmark|Immunologic)$", "", names(gene_set_list))

cat(sprintf("  Total gene sets: %d\n", length(gene_set_list)))

# ============================================================================
# HYPERGEOMETRIC ENRICHMENT
# ============================================================================

cat("\n=== Running Enrichment Analysis ===\n\n")

enrichment_results <- list()

for (sv_label in names(gene_lists)) {
  cat(sprintf("Analyzing %s...\n", sv_label))
  
  query_genes <- gene_lists[[sv_label]]
  n_query <- length(query_genes)
  
  sv_results <- list()
  
  for (gs_name in names(gene_set_list)) {
    gs_genes <- gene_set_list[[gs_name]]
    
    # Restrict to universe
    gs_genes_universe <- intersect(gs_genes, universe_genes)
    
    if (length(gs_genes_universe) < 5) next
    
    # Overlap
    overlap <- intersect(query_genes, gs_genes_universe)
    n_overlap <- length(overlap)
    
    if (n_overlap < 3) next  # Need at least 3 genes
    
    # Hypergeometric test
    # k = number of successes (overlapping genes)
    # m = number of success states in population (pathway size in universe)
    # n = number of failure states (universe - pathway)
    # q = number drawn (query size)
    
    m <- length(gs_genes_universe)
    n <- length(universe_genes) - m
    q <- n_query
    k <- n_overlap
    
    # P(X >= k)
    p_value <- phyper(k - 1, m, n, q, lower.tail = FALSE)
    
    # Fold enrichment
    expected <- (m / length(universe_genes)) * q
    fold_enrichment <- if(expected > 0) k / expected else NA
    
    sv_results[[length(sv_results) + 1]] <- data.frame(
      SV = sv_label,
      Pathway = gs_name,
      GeneSet = ifelse(grepl("Hallmark", gs_name), "Hallmark", "Immunologic"),
      Overlap = n_overlap,
      QuerySize = n_query,
      PathwaySize = m,
      UniverseSize = length(universe_genes),
      Expected = expected,
      FoldEnrichment = fold_enrichment,
      PValue = p_value,
      Genes = paste(overlap, collapse = ","),
      stringsAsFactors = FALSE
    )
  }
  
  if (length(sv_results) > 0) {
    sv_df <- bind_rows(sv_results)
    enrichment_results[[sv_label]] <- sv_df
    cat(sprintf("  Found %d enriched pathways (p < 0.05)\n", 
                sum(sv_df$PValue < 0.05)))
  } else {
    cat("  No enriched pathways found\n")
  }
}

# ============================================================================
# COMBINE & ADJUST P-VALUES
# ============================================================================

if (length(enrichment_results) > 0) {
  combined_results <- bind_rows(enrichment_results)
  
  # FDR correction
  combined_results$FDR <- p.adjust(combined_results$PValue, method = "BH")
  
  # Filter & sort
  combined_results <- combined_results %>%
    filter(PValue < p_cutoff) %>%
    arrange(FDR, PValue)
  
  cat(sprintf("\n=== Analysis Complete ===\n"))
  cat(sprintf("Total significant enrichments (p < %.2f): %d\n", 
              p_cutoff, nrow(combined_results)))
  cat(sprintf("Significant after FDR correction (FDR < 0.05): %d\n",
              sum(combined_results$FDR < 0.05)))
  
  # Save all results
  fwrite(combined_results,
         file.path(output_dir, "pathway_enrichment_all.txt"),
         sep = "\t")
  
  # Save significant only (FDR < 0.05)
  sig_results <- combined_results %>% filter(FDR < 0.05)
  if (nrow(sig_results) > 0) {
    fwrite(sig_results,
           file.path(output_dir, "pathway_enrichment_significant.txt"),
           sep = "\t")
  }
  
  # ========================================================================
  # IDENTIFY IMMUNE SVs
  # ========================================================================
  
  cat("\n=== Identifying Immune-Related SVs ===\n\n")
  
  immune_keywords <- c(
    "INTERFERON", "INFLAMMATORY", "IMMUNE", "CYTOKINE", "CHEMOKINE",
    "TNF", "IL2", "IL6", "NFKB", "JAK_STAT",
    "T_CELL", "B_CELL", "LYMPHOCYTE", "MACROPHAGE", "DENDRITIC",
    "ANTIGEN", "MHC", "CD8", "CD4"
  )
  
  immune_scores <- combined_results %>%
    filter(PValue < 0.05) %>%
    mutate(IsImmune = grepl(paste(immune_keywords, collapse = "|"),
                           Pathway, ignore.case = TRUE)) %>%
    group_by(SV) %>%
    summarize(
      N_Total = n(),
      N_Immune = sum(IsImmune),
      Immune_Fraction = N_Immune / N_Total,
      Top_Pathway = Pathway[which.min(PValue)],
      Top_Immune_Pathway = ifelse(any(IsImmune),
                                   Pathway[IsImmune][which.min(PValue[IsImmune])],
                                   NA),
      Min_FDR = min(FDR),
      Mean_FoldEnrichment = mean(FoldEnrichment, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(desc(Immune_Fraction), desc(N_Immune))
  
  cat("Immune enrichment scores:\n")
  print(immune_scores, n = 20)
  
  fwrite(immune_scores,
         file.path(output_dir, "immune_enrichment_scores.txt"),
         sep = "\t")
  
  # Top enrichments per SV
  cat("\n\nTop 3 Enriched Pathways per SV:\n")
  cat("=================================\n\n")
  
  for (sv in unique(combined_results$SV)) {
    sv_top <- combined_results %>%
      filter(SV == sv) %>%
      arrange(PValue) %>%
      head(3)
    
    cat(sprintf("%s:\n", sv))
    for (i in 1:nrow(sv_top)) {
      cat(sprintf("  [%d] %s\n", i, sv_top$Pathway[i]))
      cat(sprintf("      p = %.2e, FDR = %.2e, Fold = %.2f, Genes = %d/%d\n",
                  sv_top$PValue[i], sv_top$FDR[i],
                  sv_top$FoldEnrichment[i],
                  sv_top$Overlap[i], sv_top$PathwaySize[i]))
    }
    cat("\n")
  }
  
  # Summary report
  summary_text <- sprintf(
    "iSG Pathway Enrichment Analysis Summary
========================================

Analysis Date: %s
Method: Hypergeometric test (Fisher's exact)

Input:
------
Gene lists: %d SV directions
Genes per list: up to %d

Results:
--------
Total tests: %d
Significant (p < %.2f): %d
Significant after FDR (< 0.05): %d

By gene set:
%s

Immune-Related SVs:
-------------------
%s

Top 10 Most Significant Enrichments:
------------------------------------
%s

Output Files:
-------------
- pathway_enrichment_all.txt: All enrichments (p < %.2f)
- pathway_enrichment_significant.txt: FDR < 0.05
- immune_enrichment_scores.txt: Immune scoring per SV
",
    Sys.time(),
    length(gene_lists), n_genes_per_direction,
    nrow(combined_results),
    p_cutoff, nrow(combined_results),
    sum(combined_results$FDR < 0.05),
    paste(capture.output({
      by_set <- combined_results %>%
        group_by(GeneSet) %>%
        summarize(N = n(), N_FDR05 = sum(FDR < 0.05))
      print(by_set)
    }), collapse = "\n"),
    paste(capture.output(print(immune_scores, n = 10)), collapse = "\n"),
    paste(capture.output({
      top10 <- combined_results %>%
        arrange(PValue) %>%
        select(SV, Pathway, PValue, FDR, FoldEnrichment, Overlap) %>%
        head(10)
      print(top10)
    }), collapse = "\n"),
    p_cutoff
  )
  
  writeLines(summary_text,
             file.path(output_dir, "enrichment_analysis_summary.txt"))
  
  cat("\n=== All Results Saved ===\n")
  cat(sprintf("Output directory: %s\n", output_dir))
  
} else {
  cat("\nERROR: No enrichments found\n")
}
