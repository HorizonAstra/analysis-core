#!/usr/bin/env Rscript
#
# Compute Composite Immune Signature from All Immune SVs
# Method: Weighted sum of gene loadings with correct signs
#

library(data.table)
library(dplyr)
library(fgsea)

cat("================================================================================\n")
cat("Composite Immune Signature Analysis\n")
cat("================================================================================\n\n")

# ============================================================================
# CONFIGURATION
# ============================================================================

output_dir <- "local/outputs/GSE193460_cohort_isg_analysis/gsea_immune"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# Immune SV modes with pathway counts (from GSEA FDR<0.1)
# Sign matching: SV_Neg contributes NEGATIVE, SV_Pos contributes POSITIVE
immune_svs <- data.table(
  SV = c("SV1", "SV2", "SV3", "SV4", "SV5"),
  Direction = c("Neg", "Pos", "Pos", "Pos", "Pos"),
  Pathway_Count = c(26, 26, 11, 12, 19),
  Category = c("Strongly Immune", "Strongly Immune", "Immune", "Immune", "Immune")
)

cat("Immune SV modes to combine:\n")
print(immune_svs)
cat("\n")

# ============================================================================
# LOAD V MATRIX (GENE LOADINGS)
# ============================================================================

cat("Loading V matrix (gene loadings)...\n")
v_matrix <- fread("local/outputs/GSE193460_cohort_isg_analysis/svd_v_matrix_long.txt")

cat(sprintf("  Total genes: %d\n", length(unique(v_matrix$Gene))))
cat(sprintf("  Total SVs: %d\n", length(unique(v_matrix$SV))))

# Load gene annotation to convert Ensembl IDs to symbols
cat("\nLoading gene annotations...\n")
annotations <- fread("local/outputs/GSE193460_cohort_isg_analysis/top_genes_per_sv_annotated.txt")
gene_map <- unique(annotations[, .(Gene, Symbol)])
gene_map <- gene_map[!is.na(Symbol) & Symbol != ""]

cat(sprintf("  Annotated genes: %d\n\n", nrow(gene_map)))

# Merge symbols into V matrix
v_matrix <- merge(v_matrix, gene_map, by = "Gene", all.x = TRUE)

# Keep only genes with symbols
v_matrix_symbols <- v_matrix[!is.na(Symbol) & Symbol != ""]
cat(sprintf("Genes with symbols: %d (%.1f%% of total)\n\n",
            length(unique(v_matrix_symbols$Symbol)),
            100 * length(unique(v_matrix_symbols$Symbol)) / length(unique(v_matrix$Gene))))

# Filter to immune SVs only
v_immune <- v_matrix_symbols[SV %in% immune_svs$SV]

cat(sprintf("Filtered to immune SVs (SV1-SV5): %d gene-SV pairs\n", nrow(v_immune)))
cat(sprintf("Unique genes with symbols: %d\n\n", length(unique(v_immune$Symbol))))

# ============================================================================
# COMPUTE COMPOSITE IMMUNE SCORE
# ============================================================================

cat("Computing composite immune score...\n")
cat("Formula: Immune_Score = -(SV1) + SV2 + SV3 + SV4 + SV5\n")
cat("  SV1_Neg: negative coefficient (depleted immune = immune signature)\n")
cat("  SV2-5_Pos: positive coefficients (enriched immune = immune signature)\n\n")

# Merge with direction info
v_immune <- merge(v_immune, immune_svs[, .(SV, Direction)], by = "SV")

# Apply sign: Neg modes get negative sign, Pos modes get positive sign
v_immune[, Signed_Loading := ifelse(Direction == "Neg", -Loading, Loading)]

# Sum across all immune SVs for each gene (use Symbol)
composite_scores <- v_immune %>%
  group_by(Symbol) %>%
  summarise(
    Immune_Score = sum(Signed_Loading),
    SV1_Loading = Loading[SV == "SV1"],
    SV2_Loading = Loading[SV == "SV2"],
    SV3_Loading = Loading[SV == "SV3"],
    SV4_Loading = Loading[SV == "SV4"],
    SV5_Loading = Loading[SV == "SV5"],
    .groups = "drop"
  ) %>%
  arrange(desc(Immune_Score))

composite_scores <- as.data.table(composite_scores)

cat(sprintf("Computed immune scores for %d genes\n\n", nrow(composite_scores)))

# Summary statistics
cat("Composite Immune Score Distribution:\n")
cat(sprintf("  Min:    %9.6f\n", min(composite_scores$Immune_Score)))
cat(sprintf("  Q1:     %9.6f\n", quantile(composite_scores$Immune_Score, 0.25)))
cat(sprintf("  Median: %9.6f\n", median(composite_scores$Immune_Score)))
cat(sprintf("  Mean:   %9.6f\n", mean(composite_scores$Immune_Score)))
cat(sprintf("  Q3:     %9.6f\n", quantile(composite_scores$Immune_Score, 0.75)))
cat(sprintf("  Max:    %9.6f\n\n", max(composite_scores$Immune_Score)))

# Top positive (immune-enriched) genes
cat("Top 20 Immune-Enriched Genes (Positive Scores):\n")
print(head(composite_scores[, .(Symbol, Immune_Score)], 20))
cat("\n")

# Top negative (immune-depleted) genes
cat("Top 20 Immune-Depleted Genes (Negative Scores):\n")
print(tail(composite_scores[, .(Symbol, Immune_Score)], 20))
cat("\n")

# ============================================================================
# CREATE RANKED GENE LIST FOR GSEA
# ============================================================================

cat("Creating ranked gene list for GSEA...\n")

# Convert to named vector (required for fgsea)
ranked_genes <- composite_scores$Immune_Score
names(ranked_genes) <- composite_scores$Symbol

cat(sprintf("  Ranked gene list: %d genes\n\n", length(ranked_genes)))

# ============================================================================
# LOAD REACTOME IMMUNE PATHWAYS
# ============================================================================

cat("Loading REACTOME immune pathways...\n")

# Load msigdbr for REACTOME pathways
library(msigdbr)

# Get REACTOME pathways for mouse
reactome_pathways <- msigdbr(species = "Mus musculus", category = "C2", subcategory = "CP:REACTOME")

cat(sprintf("  Total REACTOME pathways: %d\n", length(unique(reactome_pathways$gs_name))))

# Filter to immune-related pathways (same as previous analysis)
immune_keywords <- c(
  "IMMUNE", "INTERFERON", "INTERLEUKIN", "CYTOKINE", "CHEMOKINE",
  "ANTIGEN", "T_CELL", "B_CELL", "LYMPHOCYTE", "NEUTROPHIL", 
  "MACROPHAGE", "DENDRITIC", "NK_CELL", "MHC", "INFLAMMATION",
  "TOLL_LIKE", "NOD_LIKE", "COMPLEMENT", "IMMUNOGLOBULIN"
)

immune_pattern <- paste(immune_keywords, collapse = "|")
immune_pathways <- reactome_pathways %>%
  filter(grepl(immune_pattern, gs_name))

cat(sprintf("  Immune-related pathways: %d\n\n", length(unique(immune_pathways$gs_name))))

# Convert to list format for fgsea
pathway_list <- split(immune_pathways$gene_symbol, immune_pathways$gs_name)

# ============================================================================
# RUN GSEA ON COMPOSITE IMMUNE SIGNATURE
# ============================================================================

cat("Running GSEA on composite immune signature...\n")
cat("  This may take a few minutes...\n\n")

set.seed(42)

gsea_results <- fgsea(
  pathways = pathway_list,
  stats = ranked_genes,
  minSize = 10,
  maxSize = 500,
  nproc = 1
)

# Sort by p-value
gsea_results <- as.data.table(gsea_results)[order(pval)]

cat(sprintf("GSEA complete: %d pathways tested\n\n", nrow(gsea_results)))

# ============================================================================
# SUMMARIZE RESULTS
# ============================================================================

cat("================================================================================\n")
cat("GSEA RESULTS SUMMARY\n")
cat("================================================================================\n\n")

# Significant pathways (FDR < 0.1)
sig_pathways <- gsea_results[padj < 0.1]

cat(sprintf("Significant pathways (FDR < 0.1): %d\n", nrow(sig_pathways)))
cat(sprintf("  Enriched (NES > 0):  %d\n", sum(sig_pathways$NES > 0)))
cat(sprintf("  Depleted (NES < 0):  %d\n\n", sum(sig_pathways$NES < 0)))

if (nrow(sig_pathways) > 0) {
  cat("Top 20 Enriched Pathways (FDR < 0.1):\n")
  enriched <- sig_pathways[NES > 0][order(pval)][1:min(20, sum(sig_pathways$NES > 0))]
  for (i in 1:nrow(enriched)) {
    cat(sprintf("  %2d. %s\n", i, enriched$pathway[i]))
    cat(sprintf("      NES=%.2f, FDR=%.4f, size=%d\n", 
                enriched$NES[i], enriched$padj[i], enriched$size[i]))
  }
  cat("\n")
  
  if (sum(sig_pathways$NES < 0) > 0) {
    cat("Top 20 Depleted Pathways (FDR < 0.1):\n")
    depleted <- sig_pathways[NES < 0][order(pval)][1:min(20, sum(sig_pathways$NES < 0))]
    for (i in 1:nrow(depleted)) {
      cat(sprintf("  %2d. %s\n", i, depleted$pathway[i]))
      cat(sprintf("      NES=%.2f, FDR=%.4f, size=%d\n", 
                  depleted$NES[i], depleted$padj[i], depleted$size[i]))
    }
    cat("\n")
  }
}

# ============================================================================
# SAVE RESULTS
# ============================================================================

cat("Saving results...\n")

# Save composite scores
scores_file <- file.path(output_dir, "composite_immune_scores.txt")
fwrite(composite_scores, scores_file, sep = "\t")
cat(sprintf("  ✓ Composite scores: %s\n", scores_file))

# Save ranked gene list
ranked_file <- file.path(output_dir, "composite_immune_ranked_genes.txt")
ranked_df <- data.table(Symbol = names(ranked_genes), Immune_Score = ranked_genes)
fwrite(ranked_df, ranked_file, sep = "\t")
cat(sprintf("  ✓ Ranked genes: %s\n", ranked_file))

# Save GSEA results
gsea_file <- file.path(output_dir, "composite_immune_gsea.txt")
fwrite(gsea_results, gsea_file, sep = "\t")
cat(sprintf("  ✓ GSEA results: %s\n", gsea_file))

# Save significant pathways only
sig_file <- file.path(output_dir, "composite_immune_gsea_significant.txt")
fwrite(sig_pathways, sig_file, sep = "\t")
cat(sprintf("  ✓ Significant pathways: %s\n", sig_file))

cat("\n================================================================================\n")
cat("COMPLETE\n")
cat("================================================================================\n")
