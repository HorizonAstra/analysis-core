#!/usr/bin/env Rscript
#
# Pathway Enrichment Function Library
#
# Provides two complementary approaches for pathway enrichment analysis:
# 1. Hypergeometric test: Classical enrichment using phyper(), matches NSCLC methodology
# 2. clusterProfiler: Modern GSEA framework with visualization tools
#
# Both methods support custom pathway databases (MSigDB Reactome, GO, etc.)
# and organism-specific annotation packages.
#
# Dependencies:
#   - Core: data.table, dplyr, stats
#   - Hypergeometric: (no additional packages)
#   - clusterProfiler: clusterProfiler, msigdbr, AnnotationDbi, org.*.eg.db

library(data.table)
library(dplyr)

# ==============================================================================
# HYPERGEOMETRIC ENRICHMENT FUNCTIONS
# ==============================================================================

#' Load REACTOME Pathways via msigdbr Package
#' 
#' Loads REACTOME pathways from MSigDB via msigdbr package with species conversion.
#' This is the recommended approach for organism-specific pathway enrichment.
#' 
#' @param species Character, species name (e.g., "Mus musculus", "Homo sapiens")
#' @param min_genes Integer, minimum pathway size (default: 15)
#' @param max_genes Integer, maximum pathway size (default: 500)
#' 
#' @return List with two elements:
#'   - pathways: List of gene vectors, names = pathway IDs
#'   - metadata: data.frame with pathway information (Name, Size)
#' 
#' @details
#'   Uses msigdbr package to load C2:CP:REACTOME collection with automatic
#'   species conversion. Returns gene symbols appropriate for the specified organism.
#'   
#'   Requires msigdbr package: install.packages("msigdbr")
#' 
#' @examples
#'   # Mouse REACTOME pathways
#'   pathways_mm <- load_reactome_pathways_msigdbr("Mus musculus", 15, 500)
#'   
#'   # Human REACTOME pathways
#'   pathways_hs <- load_reactome_pathways_msigdbr("Homo sapiens", 15, 500)
#' 
#' @export
load_reactome_pathways_msigdbr <- function(species = "Mus musculus",
                                            min_genes = 15,
                                            max_genes = 500) {
  
  # Check if msigdbr is available
  if (!requireNamespace("msigdbr", quietly = TRUE)) {
    stop("msigdbr package required. Install with: install.packages('msigdbr')")
  }
  
  # Load REACTOME collection
  cat(sprintf("Loading REACTOME pathways for %s via msigdbr...\n", species))
  msigdb <- msigdbr::msigdbr(species = species, category = "C2", subcategory = "CP:REACTOME")
  
  if (nrow(msigdb) == 0) {
    stop(sprintf("No REACTOME pathways found for species: %s", species))
  }
  
  # Build pathway gene sets
  pathway_list <- split(msigdb$gene_symbol, msigdb$gs_name)
  pathway_list <- lapply(pathway_list, unique)
  
  # Filter by size
  pathway_sizes <- sapply(pathway_list, length)
  pathway_list <- pathway_list[pathway_sizes >= min_genes & pathway_sizes <= max_genes]
  
  # Create metadata
  pathway_metadata <- data.frame(
    Pathway = names(pathway_list),
    Size = sapply(pathway_list, length),
    stringsAsFactors = FALSE
  )
  
  cat(sprintf("  Loaded %d REACTOME pathways (size: %d-%d genes)\n", 
              nrow(pathway_metadata), min_genes, max_genes))
  
  return(list(
    pathways = pathway_list,
    metadata = pathway_metadata
  ))
}

#' Load MSigDB Reactome Pathway Database with Filtering
#' 
#' Loads MSigDB pathway file and filters to specific categories and size range.
#' 
#' @param msigdb_file Character, path to MSigDB tab-delimited file
#' @param filter_categories Character vector of Second_Level_Parent categories to keep
#'   (e.g., c("Adaptive Immune System", "Innate Immune System")). If NULL, keeps all.
#' @param min_genes Integer, minimum pathway size (default: 15)
#' @param max_genes Integer, maximum pathway size (default: 500)
#' 
#' @return List with two elements:
#'   - pathways: List of gene vectors, names = pathway IDs
#'   - metadata: data.frame with pathway information (Name, Size, Category)
#' 
#' @details
#'   Expected file format (tab-delimited):
#'   MSigDB_Name  Reactome_Name  Top_Level_Parent  Second_Level_Parent  Gene
#'   
#'   Filters by Second_Level_Parent for hierarchical category selection,
#'   then by pathway size (min_genes to max_genes).
#' 
#' @examples
#'   immune_categories <- c("Adaptive Immune System", "Cytokine Signaling in Immune system",
#'                         "Innate Immune System", "Diseases of Immune System")
#'   pathways <- load_msigdb_reactome("/path/to/MSigDB.txt", immune_categories, 15, 500)
#' 
#' @export
load_msigdb_reactome <- function(msigdb_file, 
                                filter_categories = NULL,
                                min_genes = 15,
                                max_genes = 500) {
  
  if (!file.exists(msigdb_file)) {
    stop(sprintf("MSigDB file not found: %s", msigdb_file))
  }
  
  # Load database
  msigdb <- fread(msigdb_file, header = TRUE)
  
  # Expected columns (adjust if needed)
  expected_cols <- c("MSigDB_Name", "Gene")
  if (!all(expected_cols %in% colnames(msigdb))) {
    stop(sprintf("MSigDB file missing required columns: %s", 
                paste(setdiff(expected_cols, colnames(msigdb)), collapse = ", ")))
  }
  
  # Filter by category if specified
  if (!is.null(filter_categories) && "Second_Level_Parent" %in% colnames(msigdb)) {
    msigdb <- msigdb %>%
      filter(Second_Level_Parent %in% filter_categories)
  }
  
  # Build pathway gene sets
  pathway_list <- split(msigdb$Gene, msigdb$MSigDB_Name)
  pathway_list <- lapply(pathway_list, unique)
  
  # Filter by size
  pathway_sizes <- sapply(pathway_list, length)
  pathway_list <- pathway_list[pathway_sizes >= min_genes & pathway_sizes <= max_genes]
  
  # Create metadata
  pathway_metadata <- data.frame(
    Pathway = names(pathway_list),
    Size = sapply(pathway_list, length),
    stringsAsFactors = FALSE
  )
  
  # Add category if available
  if ("Second_Level_Parent" %in% colnames(msigdb)) {
    pathway_categories <- msigdb %>%
      group_by(MSigDB_Name) %>%
      summarize(Category = first(Second_Level_Parent), .groups = "drop")
    
    pathway_metadata <- pathway_metadata %>%
      left_join(pathway_categories, by = c("Pathway" = "MSigDB_Name"))
  }
  
  return(list(
    pathways = pathway_list,
    metadata = pathway_metadata
  ))
}

#' Hypergeometric Enrichment Test
#' 
#' Performs single hypergeometric test for gene set over-representation.
#' 
#' @param gene_set Character vector of genes in query set
#' @param pathway_genes Character vector of genes in pathway
#' @param universe_size Integer, total number of genes in analysis universe
#' 
#' @return List with elements:
#'   - overlap: Integer, number of overlapping genes
#'   - p_value: Numeric, hypergeometric p-value
#'   - genes: Character, comma-separated overlapping gene names
#' 
#' @details
#'   Uses phyper(q, m, n, k, lower.tail=FALSE) where:
#'   - q = overlap - 1
#'   - m = pathway_size (successes in population)
#'   - n = universe_size - pathway_size (failures in population)
#'   - k = gene_set_size (sample size)
#'   
#'   Returns p-value = 1 if no overlap.
#' 
#' @export
hypergeometric_test <- function(gene_set, pathway_genes, universe_size) {
  
  overlap_genes <- intersect(gene_set, pathway_genes)
  overlap <- length(overlap_genes)
  gene_set_size <- length(gene_set)
  pathway_size <- length(pathway_genes)
  
  if (overlap == 0) {
    return(list(overlap = 0, p_value = 1, genes = ""))
  }
  
  # Hypergeometric test
  p_value <- phyper(overlap - 1, pathway_size, 
                   universe_size - pathway_size, 
                   gene_set_size, lower.tail = FALSE)
  
  return(list(
    overlap = overlap, 
    p_value = p_value,
    genes = paste(overlap_genes, collapse = ",")
  ))
}

#' Run Hypergeometric Enrichment for Multiple Gene Lists
#' 
#' Performs hypergeometric enrichment testing for multiple gene lists
#' (e.g., different SVs, different directions) against pathway database.
#' 
#' @param gene_lists Named list of character vectors, each element is a gene set
#'   Names should indicate test identity (e.g., "SV1_Pos", "SV2_Neg")
#' @param pathway_db List from load_msigdb_reactome() with $pathways and $metadata
#' @param universe_genes Character vector of all genes in analysis universe
#' @param fdr_threshold Numeric, FDR cutoff for reporting (default: 0.1)
#' @param output_dir Character, directory to save per-test enrichment files (optional)
#' 
#' @return data.frame with columns:
#'   - Test: Test identifier (gene list name)
#'   - Pathway: Pathway name
#'   - Overlap: Number of overlapping genes
#'   - Pathway_Size: Total genes in pathway
#'   - GeneSet_Size: Total genes in query set
#'   - P_value: Hypergeometric p-value
#'   - FDR: Benjamini-Hochberg adjusted p-value (per test)
#'   - Genes: Comma-separated overlapping gene names
#' 
#' @details
#'   FDR correction is applied within each test (gene list) independently.
#'   If output_dir provided, saves per-test files: <test_name>_enrichment.txt
#'   Output format matches NSCLC reference: pathway, overlap, pval, padj, genes
#' 
#' @export
run_hypergeometric_enrichment <- function(gene_lists,
                                         pathway_db,
                                         universe_genes,
                                         fdr_threshold = 0.1,
                                         output_dir = NULL) {
  
  if (!is.null(output_dir)) {
    dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  }
  
  universe_size <- length(universe_genes)
  all_results <- list()
  
  cat(sprintf("Running hypergeometric enrichment for %d gene lists...\n", length(gene_lists)))
  cat(sprintf("  Pathways: %d\n", length(pathway_db$pathways)))
  cat(sprintf("  Universe: %d genes\n\n", universe_size))
  
  for (test_name in names(gene_lists)) {
    gene_set <- gene_lists[[test_name]]
    cat(sprintf("  [%s] %d genes...", test_name, length(gene_set)))
    
    # Test each pathway
    pathway_results <- list()
    
    for (pathway_name in names(pathway_db$pathways)) {
      pathway_genes <- pathway_db$pathways[[pathway_name]]
      
      # Filter to universe
      pathway_genes <- intersect(pathway_genes, universe_genes)
      
      # Perform test
      test_result <- hypergeometric_test(gene_set, pathway_genes, universe_size)
      
      if (test_result$overlap > 0) {
        pathway_results[[length(pathway_results) + 1]] <- data.frame(
          Test = test_name,
          Pathway = pathway_name,
          Overlap = test_result$overlap,
          Pathway_Size = length(pathway_genes),
          GeneSet_Size = length(gene_set),
          P_value = test_result$p_value,
          Genes = test_result$genes,
          stringsAsFactors = FALSE
        )
      }
    }
    
    # Combine results
    if (length(pathway_results) > 0) {
      test_df <- bind_rows(pathway_results)
      
      # FDR correction within this test
      test_df$FDR <- p.adjust(test_df$P_value, method = "BH")
      test_df <- test_df %>% arrange(P_value)
      
      n_sig <- sum(test_df$FDR < fdr_threshold)
      cat(sprintf(" %d significant (FDR < %.2f)\n", n_sig, fdr_threshold))
      
      # Save per-test file if requested
      if (!is.null(output_dir)) {
        output_file <- file.path(output_dir, paste0(test_name, "_enrichment.txt"))
        
        # Format matching NSCLC reference: pathway, overlap, pval, padj, genes
        output_formatted <- test_df %>%
          select(pathway = Pathway, overlap = Overlap, pval = P_value, 
                padj = FDR, genes = Genes)
        
        fwrite(output_formatted, output_file, sep = "\t")
      }
      
      all_results[[test_name]] <- test_df
    } else {
      cat(" No overlaps found\n")
    }
  }
  
  # Combine all results
  if (length(all_results) > 0) {
    combined_results <- bind_rows(all_results)
    return(combined_results)
  } else {
    return(data.frame())
  }
}

# ==============================================================================
# CLUSTERPROFILER ENRICHMENT FUNCTIONS
# ==============================================================================

#' Load MSigDB Collections via msigdbr
#' 
#' Loads gene sets from MSigDB using the msigdbr package.
#' 
#' @param species Character, species name (default: "Mus musculus")
#' @param collections Character vector of MSigDB collection names
#'   (e.g., c("H", "C7") for Hallmark and Immunologic Signatures)
#' @param subcategories Character vector of subcategories to filter (optional)
#' 
#' @return data.frame in msigdbr format (gs_name, gene_symbol, etc.)
#' 
#' @details
#'   Requires msigdbr package. Supported collections:
#'   - H: Hallmark gene sets
#'   - C2: Curated gene sets (CP:REACTOME, CP:KEGG, etc.)
#'   - C5: GO gene sets
#'   - C7: Immunologic signatures
#'   
#'   For Reactome-specific, use collections = "C2", subcategories = "CP:REACTOME"
#' 
#' @export
load_msigdb_collections <- function(species = "Mus musculus",
                                   collections = c("H", "C7"),
                                   subcategories = NULL) {
  
  if (!requireNamespace("msigdbr", quietly = TRUE)) {
    stop("msigdbr package not installed. Install via: install.packages('msigdbr')")
  }
  
  gene_sets_list <- list()
  
  for (collection in collections) {
    gene_sets <- msigdbr::msigdbr(species = species, category = collection)
    
    # Filter by subcategory if specified
    if (!is.null(subcategories) && "gs_subcat" %in% colnames(gene_sets)) {
      gene_sets <- gene_sets %>% filter(gs_subcat %in% subcategories)
    }
    
    gene_sets_list[[collection]] <- gene_sets
  }
  
  combined_gene_sets <- bind_rows(gene_sets_list)
  return(combined_gene_sets)
}

#' Prepare Gene Lists for Enrichment Analysis
#' 
#' Extracts gene lists from SVD results and converts IDs for enrichment.
#' 
#' @param top_genes_df data.frame with columns: SV, Direction, Gene, Symbol, Loading
#'   (output from iSG SVD analysis with gene annotation)
#' @param n_top_svs Integer, number of top SVs to analyze (default: 10)
#' @param n_genes_per_direction Integer, genes per SV direction (default: 100)
#' @param id_type Character, gene ID type to return: "symbol" or "entrez" (default: "symbol")
#' @param organism_db Annotation database for Entrez conversion (required if id_type="entrez")
#' 
#' @return List with elements:
#'   - gene_lists: Named list of gene vectors per SV-direction
#'   - universe: Character vector of all genes in analysis
#' 
#' @export
prepare_gene_lists_for_enrichment <- function(top_genes_df,
                                              n_top_svs = 10,
                                              n_genes_per_direction = 100,
                                              id_type = "symbol",
                                              organism_db = NULL) {
  
  # Get top SVs
  sv_numbers <- unique(as.integer(gsub("SV", "", top_genes_df$SV)))
  top_sv_ids <- paste0("SV", sort(sv_numbers)[1:min(n_top_svs, length(sv_numbers))])
  
  # Filter data
  top_genes_subset <- top_genes_df %>%
    filter(SV %in% top_sv_ids) %>%
    group_by(SV, Direction) %>%
    arrange(desc(abs(Loading))) %>%
    slice_head(n = n_genes_per_direction) %>%
    ungroup()
  
  # Get universe
  if ("Symbol" %in% colnames(top_genes_df)) {
    universe_genes <- unique(top_genes_df$Symbol)
  } else {
    universe_genes <- unique(top_genes_df$Gene)
  }
  
  # Convert to requested ID type
  if (id_type == "entrez" && !is.null(organism_db)) {
    if (!requireNamespace("AnnotationDbi", quietly = TRUE)) {
      stop("AnnotationDbi required for Entrez conversion")
    }
    
    # Convert symbols to Entrez
    if ("Symbol" %in% colnames(top_genes_subset)) {
      entrez_ids <- AnnotationDbi::mapIds(organism_db, 
                                          keys = top_genes_subset$Symbol,
                                          column = "ENTREZID",
                                          keytype = "SYMBOL",
                                          multiVals = "first")
      top_genes_subset$EntrezID <- as.character(entrez_ids)
      top_genes_subset <- top_genes_subset %>% filter(!is.na(EntrezID))
      gene_col <- "EntrezID"
    } else {
      stop("Symbol column required for Entrez conversion")
    }
    
    # Convert universe
    universe_entrez <- AnnotationDbi::mapIds(organism_db,
                                             keys = universe_genes,
                                             column = "ENTREZID",
                                             keytype = "SYMBOL",
                                             multiVals = "first")
    universe_genes <- as.character(universe_entrez[!is.na(universe_entrez)])
    
  } else {
    gene_col <- if ("Symbol" %in% colnames(top_genes_subset)) "Symbol" else "Gene"
  }
  
  # Create gene lists
  gene_lists <- top_genes_subset %>%
    mutate(List_Name = paste(SV, Direction, sep = "_")) %>%
    group_by(List_Name) %>%
    summarize(Genes = list(unique(get(gene_col))), .groups = "drop") %>%
    {setNames(.$Genes, .$List_Name)}
  
  return(list(
    gene_lists = gene_lists,
    universe = universe_genes
  ))
}

#' Run clusterProfiler Enrichment Analysis
#' 
#' Performs enrichment using clusterProfiler::enricher() on multiple gene lists.
#' 
#' @param gene_lists Named list of gene vectors (from prepare_gene_lists_for_enrichment)
#' @param gene_sets data.frame from load_msigdb_collections() with gs_name, gene_symbol columns
#' @param universe Character vector of background genes
#' @param p_cutoff Numeric, p-value cutoff (default: 0.05)
#' @param q_cutoff Numeric, FDR cutoff (default: 0.1)
#' 
#' @return Named list of enrichResult objects (one per gene list)
#' 
#' @details
#'   Requires clusterProfiler package.
#'   Uses enricher() for over-representation analysis.
#' 
#' @export
run_clusterprofiler_enrichment <- function(gene_lists,
                                          gene_sets,
                                          universe,
                                          p_cutoff = 0.05,
                                          q_cutoff = 0.1) {
  
  if (!requireNamespace("clusterProfiler", quietly = TRUE)) {
    stop("clusterProfiler package not installed. Install via: BiocManager::install('clusterProfiler')")
  }
  
  # Convert gene sets to TERM2GENE format
  term2gene <- gene_sets %>%
    select(gs_name, gene_symbol) %>%
    distinct()
  
  # Run enrichment for each list
  enrichment_results <- list()
  
  for (list_name in names(gene_lists)) {
    genes <- gene_lists[[list_name]]
    
    enrich_result <- clusterProfiler::enricher(
      gene = genes,
      TERM2GENE = term2gene,
      universe = universe,
      pvalueCutoff = p_cutoff,
      qvalueCutoff = q_cutoff,
      pAdjustMethod = "BH"
    )
    
    enrichment_results[[list_name]] <- enrich_result
  }
  
  return(enrichment_results)
}

#' Score Immune Enrichment from Pathway Results
#' 
#' Identifies immune-related SVs based on pathway enrichment results.
#' 
#' @param enrichment_df data.frame from run_hypergeometric_enrichment()
#' @param immune_keywords Character vector of keywords to identify immune pathways
#'   (default: c("IMMUNE", "INTERFERON", "CYTOKINE", "INTERLEUKIN", "T_CELL", "B_CELL"))
#' @param fdr_threshold Numeric, FDR cutoff for significance (default: 0.1)
#' 
#' @return data.frame with immune enrichment scores per test:
#'   - Test: Test identifier
#'   - N_Pathways: Total significant pathways
#'   - N_Immune: Number of immune-related pathways
#'   - Immune_Fraction: N_Immune / N_Pathways
#'   - Top_Pathway: Most significant pathway name
#'   - Min_FDR: Minimum FDR value
#' 
#' @export
score_immune_enrichment <- function(enrichment_df,
                                   immune_keywords = c("IMMUNE", "INTERFERON", "CYTOKINE",
                                                       "INTERLEUKIN", "T_CELL", "B_CELL",
                                                       "MHC", "ANTIGEN", "INFLAMMATION"),
                                   fdr_threshold = 0.1) {
  
  # Filter significant results
  sig_results <- enrichment_df %>% filter(FDR < fdr_threshold)
  
  if (nrow(sig_results) == 0) {
    return(data.frame())
  }
  
  # Identify immune pathways
  sig_results$IsImmune <- grepl(paste(immune_keywords, collapse = "|"), 
                               sig_results$Pathway, 
                               ignore.case = TRUE)
  
  # Score by test
  immune_scores <- sig_results %>%
    group_by(Test) %>%
    summarize(
      N_Pathways = n(),
      N_Immune = sum(IsImmune),
      Immune_Fraction = N_Immune / n(),
      Top_Pathway = first(Pathway),
      Min_FDR = min(FDR),
      .groups = "drop"
    ) %>%
    arrange(desc(Immune_Fraction))
  
  return(as.data.frame(immune_scores))
}
