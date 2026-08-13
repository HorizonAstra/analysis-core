#!/usr/bin/env Rscript
#
# Gene Annotation Function Library
#
# Converts Ensembl or Entrez gene IDs to gene symbols and classifies genes
# into functional categories (immune, stromal, tumor, metabolic) using
# organism-specific annotation databases.
#
# Designed for general use across any organism with Bioconductor annotation
# package (org.*.eg.db). Default marker patterns are optimized for mouse/human
# cancer immunology studies but can be customized.
#
# Dependencies: AnnotationDbi, org.Mm.eg.db (or other org.*.eg.db packages)

library(data.table)
library(dplyr)

#' Default Immune Gene Marker Patterns
#' 
#' Returns a character vector of regex patterns for identifying immune-related
#' genes based on gene symbol patterns.
#' 
#' @return Character vector of immune marker patterns
#' 
#' @details
#'   Patterns cover major immune cell types and functions:
#'   - Cell surface markers: CD3, CD4, CD8, CD19, CD20, CD68, CD163
#'   - T cell signaling: PTPRC, LCK, ZAP70
#'   - Interferon pathway: IFNG, IFNA, IFNB, IRF, STAT1, STAT3
#'   - Cytokines: IL1-18, TNF family, chemokines (CXCL, CCL, CXCR, CCR)
#'   - Cytotoxicity: GZMB, PRF1, GNLY
#'   - Checkpoints/Tregs: FOXP3, CTLA4, PDCD1, LAG3, HAVCR2
#'   - Antigen presentation: HLA, H2, B2M, TAP1, TAP2
#' 
#' @export
default_immune_markers <- function() {
  c(
    "CD3", "CD4", "CD8", "CD19", "CD20", "CD68", "CD163",  # Cell markers
    "PTPRC", "LCK", "ZAP70",  # T cell signaling
    "IFNG", "IFNA", "IFNB", "IRF", "STAT1", "STAT3",  # Interferon
    "IL1", "IL2", "IL6", "IL10", "IL12", "IL17", "IL18",  # Interleukins
    "TNF", "TNFRSF", "TNFSF",  # TNF family
    "CXCL", "CXCR", "CCL", "CCR",  # Chemokines
    "GZMB", "PRF1", "GNLY",  # Cytotoxicity
    "FOXP3", "CTLA4", "PDCD1", "LAG3", "HAVCR2",  # Checkpoints/Tregs
    "HLA-", "H2-", "B2M", "TAP1", "TAP2"  # MHC/antigen presentation
  )
}

#' Default Stromal Gene Marker Patterns
#' 
#' Returns a character vector of regex patterns for stromal/microenvironment genes.
#' 
#' @return Character vector of stromal marker patterns
#' 
#' @details
#'   Patterns cover major stromal cell types:
#'   - Collagens: COL1A, COL3A, COL4A, COL5A
#'   - Fibroblast/CAF: POSTN, FAP, PDGFR, PDPN, THY1, FN1
#'   - Mesenchymal/smooth muscle: VIM, ACTA2, TAGLN, MYH11
#'   - Endothelial: VWF, PECAM1, CDH5, MCAM
#'   - Pericyte: PDGFRA, PDGFRB
#' 
#' @export
default_stromal_markers <- function() {
  c(
    "COL1A", "COL3A", "COL4A", "COL5A",  # Collagens
    "VIM", "ACTA2", "TAGLN", "MYH11",  # Mesenchymal/smooth muscle
    "POSTN", "FAP", "PDGFR", "PDPN",  # Fibroblast
    "VWF", "PECAM1", "CDH5", "MCAM",  # Endothelial
    "PDGFRA", "PDGFRB", "THY1", "FN1"  # Pericyte/CAF
  )
}

#' Default Tumor Gene Marker Patterns
#' 
#' Returns a character vector of regex patterns for tumor/epithelial genes.
#' 
#' @return Character vector of tumor marker patterns
#' 
#' @details
#'   Patterns cover tumor biology:
#'   - Epithelial markers: KRT, EPCAM, CDH1
#'   - Oncogenes: KRAS, EGFR, MET, ERBB
#'   - Tumor suppressors: TP53, CDKN, RB1
#'   - Proliferation: MKI67, PCNA, TOP2A
#'   - Neuroendocrine: CHGA, SYP, NCAM1
#' 
#' @export
default_tumor_markers <- function() {
  c(
    "KRT", "EPCAM", "CDH1",  # Epithelial
    "KRAS", "EGFR", "MET", "ERBB",  # Oncogenes
    "TP53", "CDKN", "RB1",  # Tumor suppressors
    "MKI67", "PCNA", "TOP2A",  # Proliferation
    "CHGA", "SYP", "NCAM1"  # Neuroendocrine
  )
}

#' Default Metabolic Gene Marker Patterns
#' 
#' Returns a character vector of regex patterns for metabolic pathway genes.
#' 
#' @return Character vector of metabolic marker patterns
#' 
#' @details
#'   Patterns cover key metabolic pathways:
#'   - Glucose/lactate transport: SLC2A, SLC16A, LDHA, LDHB
#'   - Glycolysis: PKM, HK, PFKP, GAPDH
#'   - TCA cycle: IDH, CS, ACO, SDHA
#'   - Lipid metabolism: ACLY, FASN, ACACA
#'   - Hypoxia response: CA9, HIF1A, VEGFA
#' 
#' @export
default_metabolic_markers <- function() {
  c(
    "SLC2A", "SLC16A", "LDHA", "LDHB",  # Glucose/lactate
    "PKM", "HK", "PFKP", "GAPDH",  # Glycolysis
    "IDH", "CS", "ACO", "SDHA",  # TCA cycle
    "ACLY", "FASN", "ACACA",  # Lipid metabolism
    "CA9", "HIF1A", "VEGFA"  # Hypoxia
  )
}

#' Annotate Ensembl Gene IDs with Symbols and Descriptions
#' 
#' Converts Ensembl IDs to gene symbols, gene names, and gene types using
#' an organism-specific annotation database.
#' 
#' @param ensembl_ids Character vector of Ensembl gene IDs (e.g., "ENSMUSG00000000001")
#' @param organism_db Annotation database object (default: org.Mm.eg.db for mouse)
#' 
#' @return data.frame with columns:
#'   - Ensembl: Original Ensembl ID
#'   - Symbol: Gene symbol (or Ensembl ID if no symbol found)
#'   - GeneName: Full gene name/description
#'   - GeneType: Gene type (protein_coding, lncRNA, etc.)
#' 
#' @details
#'   Uses AnnotationDbi::mapIds() to query the annotation database.
#'   For genes without symbols, the Ensembl ID is used as the symbol.
#'   Falls back gracefully if GeneName or GeneType columns are unavailable.
#' 
#' @examples
#'   ensembl_ids <- c("ENSMUSG00000000001", "ENSMUSG00000000003")
#'   annotations <- annotate_genes_ensembl(ensembl_ids, org.Mm.eg.db)
#' 
#' @export
annotate_genes_ensembl <- function(ensembl_ids, organism_db = NULL) {
  
  # Check for annotation database
  if (is.null(organism_db)) {
    if (!requireNamespace("org.Mm.eg.db", quietly = TRUE)) {
      stop("org.Mm.eg.db package not installed. Install via: BiocManager::install('org.Mm.eg.db')")
    }
    organism_db <- org.Mm.eg.db::org.Mm.eg.db
  }
  
  if (!requireNamespace("AnnotationDbi", quietly = TRUE)) {
    stop("AnnotationDbi package not installed. Install via: BiocManager::install('AnnotationDbi')")
  }
  
  # Query annotation database
  annotation_results <- tryCatch({
    data.frame(
      Ensembl = ensembl_ids,
      Symbol = AnnotationDbi::mapIds(organism_db, keys = ensembl_ids, column = "SYMBOL", 
                      keytype = "ENSEMBL", multiVals = "first"),
      GeneName = AnnotationDbi::mapIds(organism_db, keys = ensembl_ids, column = "GENENAME",
                        keytype = "ENSEMBL", multiVals = "first"),
      GeneType = AnnotationDbi::mapIds(organism_db, keys = ensembl_ids, column = "GENETYPE",
                        keytype = "ENSEMBL", multiVals = "first"),
      stringsAsFactors = FALSE
    )
  }, error = function(e) {
    # Fallback: just try SYMBOL
    data.frame(
      Ensembl = ensembl_ids,
      Symbol = AnnotationDbi::mapIds(organism_db, keys = ensembl_ids, column = "SYMBOL",
                      keytype = "ENSEMBL", multiVals = "first"),
      GeneName = NA,
      GeneType = NA,
      stringsAsFactors = FALSE
    )
  })
  
  # For genes with no symbol, use Ensembl ID
  annotation_results$Symbol[is.na(annotation_results$Symbol)] <- 
    annotation_results$Ensembl[is.na(annotation_results$Symbol)]
  
  return(annotation_results)
}

#' Classify Genes into Functional Categories
#' 
#' Assigns genes to functional categories (Immune, Stromal, Tumor, Metabolic, Other)
#' based on gene symbol pattern matching.
#' 
#' @param gene_symbols Character vector of gene symbols
#' @param marker_lists Named list of marker pattern vectors with names:
#'   immune, stromal, tumor, metabolic. Use default_*_markers() functions
#'   or provide custom patterns.
#' 
#' @return Character vector of category assignments (same length as gene_symbols)
#' 
#' @details
#'   Categories are assigned in priority order:
#'   1. Immune (if matches any immune pattern)
#'   2. Stromal (if matches any stromal pattern)
#'   3. Tumor (if matches any tumor pattern)
#'   4. Metabolic (if matches any metabolic pattern)
#'   5. Other (no matches)
#'   
#'   Pattern matching is case-insensitive using grepl().
#' 
#' @examples
#'   symbols <- c("CD8A", "COL1A1", "KRAS", "LDHA", "ACTB")
#'   categories <- classify_gene_categories(symbols)
#' 
#' @export
classify_gene_categories <- function(gene_symbols, marker_lists = NULL) {
  
  # Use default markers if not provided
  if (is.null(marker_lists)) {
    marker_lists <- list(
      immune = default_immune_markers(),
      stromal = default_stromal_markers(),
      tumor = default_tumor_markers(),
      metabolic = default_metabolic_markers()
    )
  }
  
  # Helper function to check pattern matches
  matches_pattern <- function(symbol, patterns) {
    if (is.na(symbol)) return(FALSE)
    any(sapply(patterns, function(p) grepl(p, symbol, ignore.case = TRUE)))
  }
  
  # Categorize each gene
  categories <- sapply(gene_symbols, function(s) {
    if (matches_pattern(s, marker_lists$immune)) return("Immune")
    if (matches_pattern(s, marker_lists$stromal)) return("Stromal")
    if (matches_pattern(s, marker_lists$tumor)) return("Tumor")
    if (matches_pattern(s, marker_lists$metabolic)) return("Metabolic")
    return("Other")
  })
  
  return(as.character(categories))
}

#' Run Complete Gene Annotation Pipeline
#' 
#' Master function that loads gene data, annotates Ensembl IDs, classifies
#' into functional categories, and saves results with summary statistics.
#' 
#' @param top_genes_file Character, path to input file (TSV with Gene column containing Ensembl IDs)
#' @param output_dir Character, directory to save annotated results
#' @param organism_db Annotation database object (default: org.Mm.eg.db for mouse)
#' @param marker_lists Named list of marker patterns (default: uses default_*_markers())
#' 
#' @return List with elements:
#'   - annotated_data: data.table with all annotations
#'   - annotation_stats: Summary statistics (n_annotated, n_total, etc.)
#'   - category_counts: Table of gene counts per category
#' 
#' @details
#'   Input file must have columns: SV, Direction, Rank, Gene, Loading
#'   (standard output from iSG SVD analysis extract_top_genes_per_sv function)
#'   
#'   Output files created:
#'   - top_genes_per_sv_annotated.txt: Annotated gene table
#'   - annotation_summary.txt: Text summary with statistics
#' 
#' @export
run_gene_annotation <- function(top_genes_file, 
                                output_dir,
                                organism_db = NULL,
                                marker_lists = NULL) {
  
  # Validate inputs
  if (!file.exists(top_genes_file)) {
    stop(sprintf("Input file not found: %s", top_genes_file))
  }
  
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  
  # Load data
  cat("Loading gene data...\n")
  top_genes <- fread(top_genes_file, header = TRUE)
  
  cat(sprintf("  Loaded %d gene-SV associations\n", nrow(top_genes)))
  cat(sprintf("  Unique genes: %d\n", length(unique(top_genes$Gene))))
  cat(sprintf("  Unique SVs: %d\n", length(unique(top_genes$SV))))
  
  # Annotate genes
  cat("\nAnnotating Ensembl IDs...\n")
  ensembl_ids <- unique(top_genes$Gene)
  
  annotation_results <- annotate_genes_ensembl(ensembl_ids, organism_db)
  
  # Join annotations to top genes
  top_genes_annotated <- top_genes %>%
    left_join(annotation_results, by = c("Gene" = "Ensembl")) %>%
    dplyr::select(SV, Direction, Rank, Gene, Symbol, GeneName, GeneType, Loading)
  
  # Classify into categories
  cat("\nClassifying genes into functional categories...\n")
  top_genes_annotated$Category <- classify_gene_categories(
    top_genes_annotated$Symbol, 
    marker_lists
  )
  
  # Summary statistics
  n_annotated <- sum(!is.na(annotation_results$Symbol) & 
                     annotation_results$Symbol != annotation_results$Ensembl)
  n_total <- length(ensembl_ids)
  
  cat(sprintf("\nAnnotation complete:\n"))
  cat(sprintf("  Successfully annotated: %d / %d (%.1f%%)\n", 
              n_annotated, n_total, 100 * n_annotated / n_total))
  cat(sprintf("  No annotation found: %d genes\n", n_total - n_annotated))
  
  category_summary <- table(top_genes_annotated$Category[!duplicated(top_genes_annotated$Gene)])
  cat("\nGene categories (unique genes):\n")
  print(category_summary)
  
  # Save results
  cat("\nSaving annotated results...\n")
  output_file <- file.path(output_dir, "top_genes_per_sv_annotated.txt")
  summary_file <- file.path(output_dir, "annotation_summary.txt")
  
  fwrite(top_genes_annotated, output_file, sep = "\t")
  cat(sprintf("  Saved: %s\n", basename(output_file)))
  
  # Generate summary report
  summary_text <- sprintf(
    "Gene Annotation Summary
=======================

Analysis Date: %s

Input:
------
File: %s
Total gene-SV associations: %d
Unique genes: %d
Unique SVs: %d

Annotation Results:
-------------------
Successfully annotated: %d / %d (%.1f%%)
No annotation found: %d genes
  (Using Ensembl ID for these genes)

Gene Categories (unique genes):
-------------------------------
%s

Output:
-------
Annotated file: %s
  Columns: SV, Direction, Rank, Gene, Symbol, GeneName, GeneType, Loading, Category
",
    Sys.time(),
    basename(top_genes_file),
    nrow(top_genes),
    length(unique(top_genes$Gene)),
    length(unique(top_genes$SV)),
    n_annotated, n_total, 100 * n_annotated / n_total,
    n_total - n_annotated,
    paste(capture.output(print(category_summary)), collapse = "\n"),
    basename(output_file)
  )
  
  writeLines(summary_text, summary_file)
  cat(sprintf("  Saved: %s\n\n", basename(summary_file)))
  
  # Return results
  return(list(
    annotated_data = top_genes_annotated,
    annotation_stats = list(
      n_annotated = n_annotated,
      n_total = n_total,
      annotation_rate = n_annotated / n_total
    ),
    category_counts = category_summary
  ))
}
