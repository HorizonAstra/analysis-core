#!/usr/bin/env Rscript
#
# GSEA for KP Mouse iSG Analysis - Immune REACTOME Pathways
# Uses fgsea to compute NES scores matching NSCLC methodology
#

# Install fgsea if not already installed
if (!requireNamespace("fgsea", quietly = TRUE)) {
  cat("Installing fgsea package...\n")
  if (!requireNamespace("BiocManager", quietly = TRUE))
    install.packages("BiocManager", repos='https://cloud.r-project.org')
  BiocManager::install("fgsea")
}

library(fgsea)
library(data.table)
library(msigdbr)
library(dplyr)

# Source pathway loading functions
source("workflows/R/pathway_enrichment_functions.R")

cat("================================================================================\n")
cat("GSEA for KP Mouse iSG Analysis - Immune REACTOME Pathways\n")
cat("================================================================================\n\n")

# ============================================================================
# PARAMETERS
# ============================================================================

species <- "Mus musculus"
min_pathway_genes <- 15
max_pathway_genes <- 500
output_dir <- "local/outputs/GSE193460_cohort_isg_analysis/gsea_immune"
v_matrix_file <- "local/outputs/GSE193460_cohort_isg_analysis/svd_v_matrix_symbols.txt"

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# ============================================================================
# LOAD PATHWAYS
# ============================================================================

cat("Loading REACTOME pathways via msigdbr...\n")
cat(sprintf("  Species: %s\n", species))
cat(sprintf("  Size filter: %d - %d genes\n", min_pathway_genes, max_pathway_genes))

pathway_db_all <- load_reactome_pathways_msigdbr(
  species = species,
  min_genes = min_pathway_genes,
  max_genes = max_pathway_genes
)

# Filter to immune-related REACTOME pathways
cat("\nFiltering to immune-related REACTOME pathways...\n")
immune_keywords <- c("IMMUNE", "INTERFERON", "CYTOKINE", "INTERLEUKIN", 
                     "T_CELL", "B_CELL", "MHC", "ANTIGEN", "INFLAMMATION")
immune_pattern <- paste(immune_keywords, collapse = "|")

immune_pathway_names <- grep(immune_pattern, names(pathway_db_all$pathways), 
                             ignore.case = TRUE, value = TRUE)

pathways_list <- pathway_db_all$pathways[immune_pathway_names]

cat(sprintf("  Total REACTOME pathways: %d\n", length(pathway_db_all$pathways)))
cat(sprintf("  Immune-related REACTOME: %d\n", length(pathways_list)))
cat(sprintf("  Pathways to test: %d\n\n", length(pathways_list)))

# ============================================================================
# LOAD V MATRIX
# ============================================================================

cat("Loading V matrix with gene symbols...\n")
v_matrix <- fread(v_matrix_file)
cat(sprintf("  Genes: %d\n", nrow(v_matrix)))
cat(sprintf("  SVs: %d\n\n", ncol(v_matrix) - 1))

# ============================================================================
# RUN GSEA FOR ALL SV DIRECTIONS
# ============================================================================

all_results <- list()
sv_nums <- 1:10

for (sv_num in sv_nums) {
  sv_col <- paste0("SV", sv_num)
  
  if (!(sv_col %in% colnames(v_matrix))) {
    cat(sprintf("Warning: %s not found in V matrix, skipping\n", sv_col))
    next
  }
  
  cat(sprintf("Processing %s...\n", sv_col))
  
  # Rank genes by descending loading (high to low)
  # NES sign indicates direction:
  #   Positive NES = pathway enriched in genes with HIGH loadings
  #   Negative NES = pathway enriched in genes with LOW/NEGATIVE loadings
  gene_ranks <- setNames(v_matrix[[sv_col]], v_matrix$Gene)
  gene_ranks <- sort(gene_ranks, decreasing = TRUE)
  
  cat(sprintf("  Genes ranked: %d\n", length(gene_ranks)))
  cat(sprintf("  Range: %.2e to %.2e\n", max(gene_ranks), min(gene_ranks)))
  
  # Run fgsea
  fgsea_res <- fgsea(pathways = pathways_list,
                     stats = gene_ranks,
                     minSize = min_pathway_genes,
                     maxSize = max_pathway_genes)
  
  # Sort by NES (descending)
  fgsea_res <- fgsea_res[order(NES, decreasing = TRUE)]
  
  # Add SV label
  fgsea_res$SV <- sv_col
  
  # Convert leading edge to comma-separated string
  fgsea_res$leadingEdge <- sapply(fgsea_res$leadingEdge, 
                                  function(x) paste(x, collapse = ','))
  
  # Count significant
  n_sig_total <- sum(fgsea_res$padj < 0.1, na.rm = TRUE)
  n_enriched <- sum(fgsea_res$padj < 0.1 & fgsea_res$NES > 0, na.rm = TRUE)
  n_depleted <- sum(fgsea_res$padj < 0.1 & fgsea_res$NES < 0, na.rm = TRUE)
  
  cat(sprintf("  Significant pathways (FDR<0.1): %d total (%d enriched, %d depleted)\n", 
              n_sig_total, n_enriched, n_depleted))
  
  # Save results
  output_file <- file.path(output_dir, sprintf("SV%d_gsea.txt", sv_num))
  fwrite(fgsea_res, output_file, sep = "\t")
  cat(sprintf("  ✓ Saved: %s\n\n", output_file))
  
  all_results[[sv_col]] <- fgsea_res
}

# ============================================================================
# COMBINE ALL RESULTS
# ============================================================================

cat("Combining all SV results...\n")
combined_results <- rbindlist(all_results)
combined_file <- file.path(output_dir, "all_svs_gsea_immune.txt")
fwrite(combined_results, combined_file, sep = "\t")
cat(sprintf("✓ Combined results saved: %s\n", combined_file))

# ============================================================================
# SUMMARY STATISTICS
# ============================================================================

cat("\n================================================================================\n")
cat("GSEA SUMMARY\n")
cat("================================================================================\n\n")

cat(sprintf("Total SVs analyzed: %d\n", length(all_results)))
cat(sprintf("Total pathway tests: %d\n", nrow(combined_results)))
cat(sprintf("Immune REACTOME pathways: %d\n\n", length(pathways_list)))

# Count significant per SV
sig_per_sv <- combined_results[, .(N_Significant = sum(padj < 0.1, na.rm = TRUE),
                                    N_Enriched = sum(padj < 0.1 & NES > 0, na.rm = TRUE),
                                    N_Depleted = sum(padj < 0.1 & NES < 0, na.rm = TRUE)),
                                by = SV]
sig_per_sv <- sig_per_sv[order(-N_Significant)]

cat("Significant enrichments per SV (FDR<0.1):\n")
print(sig_per_sv, row.names = FALSE)

cat("\n================================================================================\n")
cat("GSEA Complete!\n")
cat(sprintf("Results saved to: %s/\n", output_dir))
cat("================================================================================\n")
