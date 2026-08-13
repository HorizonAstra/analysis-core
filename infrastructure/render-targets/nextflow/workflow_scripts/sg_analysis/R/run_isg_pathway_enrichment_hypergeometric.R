#!/usr/bin/env Rscript
#
# Hypergeometric Pathway Enrichment Execution Script
#
# Runs hypergeometric enrichment analysis on iSG SVD signatures using REACTOME
# pathways via msigdbr, matching NSCLC analysis methodology (REACTOME-only subset).
#
# Input:  svd_v_matrix.txt
# Output: Per-SV enrichment files, overview, visualizations
#
# This script implements REACTOME-focused enrichment:
#   - All REACTOME pathways (size 15-500 genes)
#   - Hypergeometric test (phyper) on top 200 genes per SV direction
#   - FDR correction per SV-direction
#   - Output format matches NSCLC reference

# Load function libraries
source("workflows/R/pathway_enrichment_functions.R")
source("workflows/R/gene_annotation_functions.R")  # For gene ID conversion if needed

# ============================================================================
# CONFIGURATION
# ============================================================================

cat("=== Hypergeometric Pathway Enrichment Analysis ===\n\n")

base_dir <- "/project/araman/vivek/TumorSPACE_AWS"
isg_dir <- "local/outputs/GSE193460_cohort_isg_analysis"

# Input files
v_matrix_file <- file.path(base_dir, isg_dir, "svd_v_matrix_symbols.txt")

# Output directory
output_dir <- file.path(base_dir, isg_dir, "pathway_enrichment")
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

# Pathway filtering parameters
min_pathway_genes <- 15
max_pathway_genes <- 500
species <- "Mus musculus"  # Mouse for GSE193460 KP cohort

# Enrichment parameters
n_top_svs <- 10  # Analyze SV1-SV10
n_genes_per_direction <- 200  # Top 200 genes per direction (Pos/Neg)
fdr_threshold <- 0.1  # FDR < 0.1 for significance

# ============================================================================
# VALIDATION
# ============================================================================

if (!file.exists(v_matrix_file)) {
  stop(sprintf("V matrix not found: %s\nRun iSG SVD analysis first.", v_matrix_file))
}

cat(sprintf("V matrix: %s\n", basename(v_matrix_file)))
cat(sprintf("Species:  %s\n", species))
cat(sprintf("Output:   %s\n\n", output_dir))

# ============================================================================
# LOAD DATA
# ============================================================================

cat("Loading SVD V matrix...\n")
v_matrix <- fread(v_matrix_file, header = TRUE)
cat(sprintf("  Genes: %d\n", nrow(v_matrix)))
cat(sprintf("  SVs: %d\n\n", ncol(v_matrix) - 1))

universe_genes <- v_matrix$Gene

# ============================================================================
# LOAD REACTOME PATHWAYS
# ============================================================================

cat("Loading REACTOME pathways via msigdbr...\n")
cat(sprintf("  Size filter: %d - %d genes\n", min_pathway_genes, max_pathway_genes))

pathway_db_all <- load_reactome_pathways_msigdbr(
  species = species,
  min_genes = min_pathway_genes,
  max_genes = max_pathway_genes
)

# Filter to immune-related REACTOME pathways only
cat("Filtering to immune-related REACTOME pathways...\n")
immune_keywords <- c("IMMUNE", "INTERFERON", "CYTOKINE", "INTERLEUKIN", 
                     "T_CELL", "B_CELL", "MHC", "ANTIGEN", "INFLAMMATION")
immune_pattern <- paste(immune_keywords, collapse = "|")

# Filter pathway names
immune_pathway_names <- grep(immune_pattern, names(pathway_db_all$pathways), 
                             ignore.case = TRUE, value = TRUE)

pathway_db <- list(
  pathways = pathway_db_all$pathways[immune_pathway_names],
  gene_sets = pathway_db_all$gene_sets[immune_pathway_names]
)

cat(sprintf("  Total REACTOME pathways: %d\n", length(pathway_db_all$pathways)))
cat(sprintf("  Immune-related REACTOME: %d\n", length(pathway_db$pathways)))

# ============================================================================
# PREPARE GENE LISTS
# ============================================================================

cat("\nPreparing gene lists for enrichment...\n")
cat(sprintf("  Top SVs: SV1-SV%d\n", n_top_svs))
cat(sprintf("  Genes per direction: %d\n\n", n_genes_per_direction))

# Extract top genes per SV direction
gene_lists <- list()

for (sv_num in 1:n_top_svs) {
  sv_col <- paste0("SV", sv_num)
  
  if (!sv_col %in% colnames(v_matrix)) {
    warning(sprintf("%s not found in V matrix, skipping", sv_col))
    next
  }
  
  # Positive direction (high loadings)
  top_genes_pos <- v_matrix %>%
    arrange(desc(.data[[sv_col]])) %>%
    head(n_genes_per_direction) %>%
    pull(Gene)
  
  gene_lists[[paste0(sv_col, "_Pos")]] <- top_genes_pos
  
  # Negative direction (low loadings)
  top_genes_neg <- v_matrix %>%
    arrange(.data[[sv_col]]) %>%
    head(n_genes_per_direction) %>%
    pull(Gene)
  
  gene_lists[[paste0(sv_col, "_Neg")]] <- top_genes_neg
}

cat(sprintf("  Created %d gene lists (%d SVs × 2 directions)\n\n", 
            length(gene_lists), n_top_svs))

# ============================================================================
# RUN HYPERGEOMETRIC ENRICHMENT
# ============================================================================

enrichment_results <- run_hypergeometric_enrichment(
  gene_lists = gene_lists,
  pathway_db = pathway_db,
  universe_genes = universe_genes,
  fdr_threshold = fdr_threshold,
  output_dir = output_dir
)

cat(sprintf("\nEnrichment complete! Tested %d pathway-SV combinations\n", nrow(enrichment_results)))

# ============================================================================
# GENERATE OVERVIEW SUMMARY
# ============================================================================

cat("\nGenerating enrichment overview...\n")

pathway_overview <- enrichment_results %>%
  filter(FDR < fdr_threshold) %>%
  group_by(Test) %>%
  summarize(
    N_Pathways_FDR01 = n(),
    Top_Pathway = first(Pathway),
    Min_FDR = min(FDR),
    .groups = "drop"
  ) %>%
  arrange(desc(N_Pathways_FDR01))

colnames(pathway_overview)[1] <- "SV_Direction"

fwrite(pathway_overview,
       file.path(output_dir, "pathway_enrichment_overview.txt"),
       sep = "\t")

cat("\nTop 10 SV-directions by pathway enrichment:\n")
print(head(pathway_overview, 10))

# ============================================================================
# SCORE IMMUNE ENRICHMENT
# ============================================================================

cat("\nScoring immune enrichment...\n")

immune_scores <- score_immune_enrichment(
  enrichment_df = enrichment_results,
  fdr_threshold = fdr_threshold
)

if (nrow(immune_scores) > 0) {
  fwrite(immune_scores,
         file.path(output_dir, "immune_enrichment_scores.txt"),
         sep = "\t")
  
  cat("\nImmune-enriched SVs:\n")
  print(immune_scores)
}

# ============================================================================
# POST-ANALYSIS SUMMARY
# ============================================================================

cat("\n\n=== Enrichment Analysis Summary ===\n\n")

cat(sprintf("Total pathways tested: %d\n", length(pathway_db$pathways)))
cat(sprintf("SV-direction combinations: %d\n", length(gene_lists)))
cat(sprintf("Genes per combination: %d\n", n_genes_per_direction))
cat(sprintf("Universe size: %d genes\n\n", length(universe_genes)))

n_sig_tests <- sum(pathway_overview$N_Pathways_FDR01 > 0)
cat(sprintf("SV-directions with significant enrichment: %d / %d\n", 
            n_sig_tests, length(gene_lists)))

if (nrow(immune_scores) > 0) {
  cat(sprintf("Immune-enriched SVs (≥5 pathways): %d\n", 
              sum(immune_scores$N_Pathways >= 5)))
}

cat("\nOutput Files:\n")
cat(sprintf("  - Per-SV enrichment: %s\n", file.path(output_dir, "SV*_enrichment.txt")))
cat(sprintf("  - Overview: %s\n", file.path(output_dir, "pathway_enrichment_overview.txt")))
if (nrow(immune_scores) > 0) {
  cat(sprintf("  - Immune scores: %s\n", file.path(output_dir, "immune_enrichment_scores.txt")))
}

cat("\nNext Steps:\n")
cat("  1. Visualize: Create dotplot and heatmap of enrichment results\n")
cat("  2. Compare with NSCLC: Load SV4_Pos enrichment, compute Jaccard similarity\n")
cat("  3. Integrate with GrowChain: Correlate immune enrichment with spatial depth\n")
cat("  4. Biological interpretation: Focus on SVs with high immune pathway enrichment\n\n")

cat("Analysis complete!\n")
