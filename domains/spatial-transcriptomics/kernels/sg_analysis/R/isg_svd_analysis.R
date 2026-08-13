#!/usr/bin/env Rscript
#
# DEPRECATED — retained for backwards compatibility only.
# DO NOT USE FOR NEW ANALYSES.
#
# This file has been superseded by the batch-unbiased K-sweep pipeline:
#   cohort_ksweep.R   — Phase 1 SV depth test + Phase 2 K-sweep (replaces all
#                        functions below)
#   cohort_spatial.R  — Phase 3 spot labeling
#
# The two-phase K-sweep correctly accounts for site/batch-associated SVs
# (analogous to KL_SVDepth_v1.R + KL_KSweep_v2.R in the HGSOC reference
# implementation) and is the active analysis path.
#
# Functions in this file (prepare_sg_binary_matrix, compute_svd_signatures,
# classify_sg_to_sv, compute_sample_sv_profiles, run_isg_analysis) remain
# loadable but should not be called by any active pipeline step.
#
# TumorSPACE: iSG SVD-based Spatial Group Clustering
#
# Discovers latent biological signatures (Singular Vectors/SVs) from differential
# gene patterns across spatial subgroups (SGs). Uses SVD decomposition to identify
# recurring patterns of differential expression, then classifies each SG pair to its
# dominant signature and profiles sample-level SV composition.
#
# Algorithm Overview:
#   1. Binary matrix construction: SG pairs × genes (1 if DA Q<0.05, 0 otherwise)
#   2. SVD decomposition: M = U × D × V^T
#      - U matrix: SG loadings on each SV (how strongly each SG represents signature)
#      - D values: Singular values (variance explained by each SV)
#      - V matrix: Gene loadings on each SV (biological interpretation)
#   3. Top gene extraction: Identify genes with highest |loadings| per SV
#   4. SG classification: Assign each SG to dominant SV (max |U loading|)
#   5. Sample profiling: Compute fraction of SGs in each SV category per sample
#
# iSG Classification:
#   - Each SV has positive and negative directions (SV1_Pos, SV1_Neg)
#   - Direction matters: opposite gene loadings = opposite biology
#   - "invariant Spatial Groups" = SGs classified by shared signature patterns
#
# Ported from: SG-TreeVAE/scripts/isg_svd_analysis/
#   - 01_prepare_data.R: Binary matrix construction
#   - 02_svd_decomposition.R: SVD execution
#   - 03_identify_isg.R: SG classification and profiling
#   - 06_pathway_analysis.R: Gene enrichment (separate module)
#
# Dependencies: data.table, dplyr, tidyr

library(data.table)
library(dplyr)
library(tidyr)

#' Prepare Binary SG × Gene Matrix from TumorSPACE Outputs
#' 
#' Reads differential gene analysis files (DA_significant.txt) from multiple
#' TumorSPACE sample outputs, filters by significance threshold, and constructs
#' a binary matrix where rows = SG pairs, columns = genes, values = 1 if gene
#' is significantly differentially expressed in that SG pair, 0 otherwise.
#' 
#' @param sample_dirs Character vector of paths to TumorSPACE output directories
#'   (should contain optimal/DA_significant.txt files)
#' @param sample_ids Character vector of sample identifiers (same length as sample_dirs)
#' @param q_threshold Numeric, significance threshold for Q-value filtering (default: 0.05)
#' @param da_file_name Character, name of differential abundance file (default: "DA_significant.txt")
#' 
#' @return List with three elements:
#'   - binary_matrix: Matrix (SG pairs × genes) with 0/1 values
#'   - sg_metadata: data.table with SG_Pair, SampleID, Node, Sibling columns
#'   - stats: Summary statistics (n_samples, n_sg_pairs, n_genes, sparsity)
#' 
#' @details
#'   SG_Pair identifier format: "Node_Sibling" (e.g., "134_135")
#'   Filters genes with Q < q_threshold across all samples
#'   Combines all samples into single matrix for cross-sample SVD analysis
#' 
#' @export
prepare_sg_binary_matrix <- function(sample_dirs, 
                                     sample_ids, 
                                     q_threshold = 0.05,
                                     da_file_name = "DA_significant.txt") {
  
  # Validate inputs
  if (length(sample_dirs) != length(sample_ids)) {
    stop("sample_dirs and sample_ids must have same length")
  }
  
  if (length(sample_dirs) == 0) {
    stop("Must provide at least one sample directory")
  }
  
  cat(sprintf("Reading differential gene data from %d samples...\n", length(sample_dirs)))
  
  # Read and combine all DA files
  da_list <- list()
  for (i in seq_along(sample_dirs)) {
    da_path <- file.path(sample_dirs[i], "optimal", da_file_name)
    
    if (!file.exists(da_path)) {
      warning(sprintf("DA file not found: %s", da_path))
      next
    }
    
    da_data <- fread(da_path, header = TRUE)
    da_data$SampleID <- sample_ids[i]
    da_list[[i]] <- da_data
    
    cat(sprintf("  Sample %s: %d DA results\n", sample_ids[i], nrow(da_data)))
  }
  
  if (length(da_list) == 0) {
    stop("No valid DA files found in provided directories")
  }
  
  # Combine all samples
  da_combined <- rbindlist(da_list, fill = TRUE)
  
  cat(sprintf("Combined: %d total DA results across samples\n", nrow(da_combined)))
  
  # Filter by significance threshold
  # Handle both Q column formats: "< 0.05" string or numeric
  if (is.character(da_combined$Q)) {
    # Check if Q column contains strings like "< 0.05"
    # If DA_significant.txt file, all entries are already Q < 0.05
    if (all(grepl("^<", da_combined$Q, ignore.case = TRUE))) {
      cat("Q column contains '< 0.05' strings - all entries already significant\n")
      da_sig <- da_combined
    } else {
      # Try to extract numeric values
      da_combined[, Q_numeric := as.numeric(gsub("[^0-9.]", "", Q))]
      da_sig <- da_combined[Q_numeric < q_threshold, ]
    }
  } else {
    da_sig <- da_combined[Q < q_threshold, ]
  }
  
  cat(sprintf("After Q < %.3f filter: %d significant DA results\n", 
              q_threshold, nrow(da_sig)))
  
  if (nrow(da_sig) == 0) {
    stop("No significant DA results remain after filtering")
  }
  
  # Create SG_Pair identifier: "Node_Sibling"
  da_sig[, SG_Pair := paste(Node, Sibling, sep = "_")]
  
  # Mark presence (for binary matrix)
  da_sig[, DA_Present := 1]
  
  # Rename DA_Object to Gene for consistency (if needed)
  if ("DA_Object" %in% colnames(da_sig) && !"Gene" %in% colnames(da_sig)) {
    setnames(da_sig, "DA_Object", "Gene")
  }
  
  # Cast to binary matrix: rows = SG_Pair, columns = Gene
  cat("Constructing binary matrix (SG pairs × genes)...\n")
  
  binary_matrix_dt <- dcast.data.table(
    da_sig,
    SG_Pair ~ Gene,
    value.var = "DA_Present",
    fill = 0,
    fun.aggregate = max  # In case of duplicates, take max (1 if any presence)
  )
  
  # Extract SG_Pair column for rownames
  sg_pairs <- binary_matrix_dt$SG_Pair
  binary_matrix_dt[, SG_Pair := NULL]
  
  # Convert to matrix
  binary_matrix <- as.matrix(binary_matrix_dt)
  rownames(binary_matrix) <- sg_pairs
  
  # Create metadata table linking SG_Pair to sample/node info
  sg_metadata <- da_sig[, .(SampleID = first(SampleID),
                            Node = first(Node),
                            Sibling = first(Sibling)),
                        by = SG_Pair]
  
  # Summary statistics
  n_sg_pairs <- nrow(binary_matrix)
  n_genes <- ncol(binary_matrix)
  sparsity <- 1 - (sum(binary_matrix) / (n_sg_pairs * n_genes))
  
  stats <- list(
    n_samples = length(unique(da_sig$SampleID)),
    n_sg_pairs = n_sg_pairs,
    n_genes = n_genes,
    sparsity = sparsity,
    sg_pairs_per_sample = table(sg_metadata$SampleID)
  )
  
  cat(sprintf("\nBinary matrix constructed:\n"))
  cat(sprintf("  Dimensions: %d SG pairs × %d genes\n", n_sg_pairs, n_genes))
  cat(sprintf("  Sparsity: %.2f%% zeros\n", sparsity * 100))
  cat(sprintf("  SG pairs per sample:\n"))
  print(stats$sg_pairs_per_sample)
  
  return(list(
    binary_matrix = binary_matrix,
    sg_metadata = sg_metadata,
    stats = stats
  ))
}


#' Compute SVD Signatures from Binary Matrix
#' 
#' Performs Singular Value Decomposition on the SG × gene binary matrix to
#' discover latent biological signatures (Singular Vectors). Returns U, D, V
#' matrices for downstream analysis and interpretation.
#' 
#' @param binary_matrix Numeric matrix (SG pairs × genes) with 0/1 values
#' @param n_svs Integer, number of singular vectors to retain (default: NULL = all)
#' @param scale_genes Logical, whether to scale genes to unit variance (default: FALSE)
#' 
#' @return List with elements:
#'   - u_matrix: data.frame with columns SG_Pair, SV, Loading (SG loadings on SVs)
#'   - d_values: data.frame with columns SV, SingularValue, VarianceExplained, CumVariance
#'   - v_matrix: data.frame with columns Gene, SV, Loading (gene loadings on SVs)
#'   - raw_svd: Raw svd() output object for advanced users
#' 
#' @details
#'   Uses base R svd() function (fast, stable for small-medium matrices)
#'   U matrix: How strongly each SG represents each signature
#'   D values: Variance explained by each signature (check scree plot)
#'   V matrix: Gene contributions to each signature (biological interpretation)
#' 
#' @export
compute_svd_signatures <- function(binary_matrix, 
                                   n_svs = NULL, 
                                   scale_genes = FALSE) {
  
  cat("Performing SVD decomposition...\n")
  cat(sprintf("  Input matrix: %d SG pairs × %d genes\n", 
              nrow(binary_matrix), ncol(binary_matrix)))
  
  # Optional gene scaling (typically not needed for binary matrix)
  if (scale_genes) {
    cat("  Scaling genes to unit variance...\n")
    gene_matrix <- scale(binary_matrix, center = TRUE, scale = TRUE)
  } else {
    gene_matrix <- binary_matrix
  }
  
  # Perform SVD: M = U × D × V^T
  svd_result <- svd(gene_matrix)
  
  # Determine number of SVs to retain
  max_svs <- min(nrow(gene_matrix), ncol(gene_matrix))
  if (is.null(n_svs)) {
    n_svs <- max_svs
  } else if (n_svs > max_svs) {
    warning(sprintf("n_svs (%d) exceeds matrix rank (%d), using %d", 
                    n_svs, max_svs, max_svs))
    n_svs <- max_svs
  }
  
  cat(sprintf("  Retaining %d singular vectors\n", n_svs))
  
  # Extract and format U matrix (SG loadings)
  u_matrix_raw <- svd_result$u[, 1:n_svs, drop = FALSE]
  rownames(u_matrix_raw) <- rownames(binary_matrix)
  colnames(u_matrix_raw) <- paste0("SV", 1:n_svs)
  
  u_matrix_long <- u_matrix_raw %>%
    as.data.frame() %>%
    tibble::rownames_to_column("SG_Pair") %>%
    pivot_longer(cols = starts_with("SV"),
                 names_to = "SV",
                 values_to = "Loading")
  
  # Extract and format D values (singular values)
  d_values <- data.frame(
    SV = paste0("SV", 1:n_svs),
    SingularValue = svd_result$d[1:n_svs],
    stringsAsFactors = FALSE
  )
  
  # Compute variance explained
  total_var <- sum(svd_result$d^2)
  d_values$VarianceExplained <- (d_values$SingularValue^2) / total_var
  d_values$CumVariance <- cumsum(d_values$VarianceExplained)
  
  # Extract and format V matrix (gene loadings)
  v_matrix_raw <- svd_result$v[, 1:n_svs, drop = FALSE]
  rownames(v_matrix_raw) <- colnames(binary_matrix)
  colnames(v_matrix_raw) <- paste0("SV", 1:n_svs)
  
  v_matrix_long <- v_matrix_raw %>%
    as.data.frame() %>%
    tibble::rownames_to_column("Gene") %>%
    pivot_longer(cols = starts_with("SV"),
                 names_to = "SV",
                 values_to = "Loading")
  
  # Summary output
  cat(sprintf("\nSVD decomposition complete:\n"))
  cat(sprintf("  First 5 SVs explain %.1f%% variance\n", 
              d_values$CumVariance[min(5, n_svs)] * 100))
  cat(sprintf("  First 10 SVs explain %.1f%% variance\n", 
              d_values$CumVariance[min(10, n_svs)] * 100))
  
  return(list(
    u_matrix = u_matrix_long,
    d_values = d_values,
    v_matrix = v_matrix_long,
    raw_svd = svd_result
  ))
}


#' Extract Top Genes per Singular Vector
#' 
#' Identifies genes with highest (positive direction) and lowest (negative direction)
#' loadings for each SV. These top genes define the biological signature and are
#' used for pathway enrichment and interpretation.
#' 
#' @param v_matrix data.frame with columns Gene, SV, Loading (from compute_svd_signatures)
#' @param n_genes Integer, number of top genes to extract per direction (default: 100)
#' 
#' @return data.frame with columns:
#'   - SV: Singular vector identifier (SV1, SV2, ...)
#'   - Direction: "Pos" or "Neg"
#'   - Gene: Gene symbol
#'   - Loading: Gene loading on that SV
#'   - Rank: Rank within direction (1 = highest |loading|)
#' 
#' @details
#'   For each SV:
#'     - Positive direction: Genes with highest loadings (most upregulated)
#'     - Negative direction: Genes with lowest loadings (most downregulated)
#'   Direction matters: SV1_Pos and SV1_Neg have opposite biological meanings
#' 
#' @export
extract_top_genes_per_sv <- function(v_matrix, n_genes = 100) {
  
  cat(sprintf("Extracting top %d genes per SV (both directions)...\n", n_genes))
  
  top_genes_list <- list()
  
  svs <- unique(v_matrix$SV)
  
  for (sv in svs) {
    v_sv <- v_matrix %>% filter(SV == !!sv)
    
    # Top positive loadings
    top_pos <- v_sv %>%
      arrange(desc(Loading)) %>%
      head(n_genes) %>%
      mutate(Direction = "Pos",
             Rank = row_number())
    
    # Top negative loadings
    top_neg <- v_sv %>%
      arrange(Loading) %>%
      head(n_genes) %>%
      mutate(Direction = "Neg",
             Rank = row_number())
    
    top_genes_list[[paste0(sv, "_Pos")]] <- top_pos
    top_genes_list[[paste0(sv, "_Neg")]] <- top_neg
    
    cat(sprintf("  %s: Top pos gene = %s (%.4f), Top neg gene = %s (%.4f)\n",
                sv,
                top_pos$Gene[1], top_pos$Loading[1],
                top_neg$Gene[1], top_neg$Loading[1]))
  }
  
  top_genes <- bind_rows(top_genes_list)
  
  cat(sprintf("\nExtracted %d total gene-SV associations\n", nrow(top_genes)))
  
  return(top_genes)
}


#' Classify Spatial Groups to Dominant Singular Vector
#' 
#' Assigns each SG pair to its dominant SV signature based on maximum absolute
#' loading in the U matrix. Creates signed SV labels (e.g., SV4_Pos, SV4_Neg)
#' based on loading direction.
#' 
#' @param u_matrix data.frame with columns SG_Pair, SV, Loading (from compute_svd_signatures)
#' @param sg_metadata data.frame with columns SG_Pair, SampleID, Node, Sibling
#' 
#' @return data.frame with columns:
#'   - SG_Pair: Spatial group pair identifier
#'   - SampleID: Sample identifier
#'   - Node: Parent node
#'   - Sibling: Sibling node
#'   - SV: Dominant singular vector (SV1, SV2, ...)
#'   - Loading: U matrix loading on dominant SV
#'   - SV_Signed: Signed SV label (SV1_Pos, SV1_Neg, ...)
#' 
#' @details
#'   Classification rule: For each SG pair, find SV with max(|Loading|)
#'   Direction determined by sign of loading:
#'     - Loading > 0 → SV_Pos (upregulated genes dominate)
#'     - Loading < 0 → SV_Neg (downregulated genes dominate)
#' 
#' @export
classify_sg_to_sv <- function(u_matrix, sg_metadata) {
  
  cat("Classifying SG pairs to dominant SV...\n")
  
  # Join metadata
  u_matrix_full <- u_matrix %>%
    left_join(sg_metadata, by = "SG_Pair")
  
  # For each SG pair, find SV with maximum absolute loading
  sg_assignments <- u_matrix_full %>%
    group_by(SG_Pair) %>%
    slice_max(abs(Loading), n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    mutate(SV_Signed = paste0(SV, "_", ifelse(Loading > 0, "Pos", "Neg")))
  
  # Summary statistics
  cat(sprintf("\nClassification complete: %d SG pairs assigned\n", 
              nrow(sg_assignments)))
  cat("\nSG pairs per SV_Signed category:\n")
  print(table(sg_assignments$SV_Signed))
  
  cat("\nSG pairs per Sample:\n")
  print(table(sg_assignments$SampleID))
  
  return(sg_assignments)
}


#' Compute Per-Sample SV Fraction Profiles
#' 
#' Calculates the fraction of SG pairs in each SV_Signed category for each sample.
#' This creates sample-level profiles that can be used to compare spatial immune
#' architecture across samples or correlate with clinical outcomes.
#' 
#' @param sg_assignments data.frame from classify_sg_to_sv() with SampleID and SV_Signed columns
#' 
#' @return data.frame with columns:
#'   - SampleID: Sample identifier
#'   - SV_Signed: Signed SV category (SV1_Pos, SV1_Neg, ...)
#'   - N_SG: Number of SG pairs in this category
#'   - Total_SG: Total SG pairs in sample
#'   - Fraction: N_SG / Total_SG (sums to 1.0 per sample)
#' 
#' @details
#'   Produces a sample × SV_Signed matrix of fractions
#'   Can be used for:
#'     - Comparing samples (heterogeneous vs homogeneous profiles)
#'     - Clinical correlations (e.g., survival, response)
#'     - Cross-cohort comparisons (mouse vs human)
#' 
#' @export
compute_sample_sv_profiles <- function(sg_assignments) {
  
  cat("Computing per-sample SV fraction profiles...\n")
  
  sample_profiles <- sg_assignments %>%
    group_by(SampleID, SV_Signed) %>%
    summarize(N_SG = n(), .groups = "drop_last") %>%
    mutate(Total_SG = sum(N_SG),
           Fraction = N_SG / Total_SG) %>%
    ungroup()
  
  cat(sprintf("\nSample profiles computed: %d samples × %d SV categories\n",
              length(unique(sample_profiles$SampleID)),
              length(unique(sample_profiles$SV_Signed))))
  
  # Show top SV per sample
  cat("\nDominant SV per sample:\n")
  top_sv_per_sample <- sample_profiles %>%
    group_by(SampleID) %>%
    slice_max(Fraction, n = 1) %>%
    select(SampleID, SV_Signed, Fraction)
  print(top_sv_per_sample)
  
  return(sample_profiles)
}


#' Run Complete iSG SVD Analysis
#' 
#' Master orchestrator function that executes the full iSG analysis pipeline:
#' binary matrix construction → SVD decomposition → top gene extraction →
#' SG classification → sample profiling. Saves all intermediate and final
#' results to output directory.
#' 
#' @param sample_dirs Character vector of paths to TumorSPACE output directories
#' @param sample_ids Character vector of sample identifiers (same length as sample_dirs)
#' @param output_dir Character, path to output directory (will be created if doesn't exist)
#' @param q_threshold Numeric, significance threshold for Q-value filtering (default: 0.05)
#' @param n_svs Integer, number of SVs to retain (default: NULL = all)
#' @param n_top_genes Integer, number of top genes to extract per SV direction (default: 100)
#' @param da_file_name Character, name of DA file (default: "DA_significant.txt")
#' 
#' @return List with all analysis results:
#'   - binary_matrix_data: Output from prepare_sg_binary_matrix()
#'   - svd_data: Output from compute_svd_signatures()
#'   - top_genes: Output from extract_top_genes_per_sv()
#'   - sg_assignments: Output from classify_sg_to_sv()
#'   - sample_profiles: Output from compute_sample_sv_profiles()
#' 
#' @details
#'   Saves the following files to output_dir:
#'     - da_gene_sig_binary.txt: Binary SG × gene matrix
#'     - sg_pair_metadata.txt: SG pair to sample mapping
#'     - svd_u_matrix.txt: U matrix (SG loadings)
#'     - svd_d_values.txt: D values (variance explained)
#'     - svd_v_matrix.txt: V matrix (gene loadings)
#'     - top_genes_per_sv.txt: Top genes for each SV direction
#'     - sg_sv_assignments.txt: SG pair classifications
#'     - sample_sv_fractions.txt: Per-sample SV profiles
#'     - analysis_summary.txt: Summary statistics and parameters
#' 
#' @examples
#' \dontrun{
#' results <- run_isg_analysis(
#'   sample_dirs = c("local/outputs/sample1", "local/outputs/sample2"),
#'   sample_ids = c("KP_1", "KP_2"),
#'   output_dir = "local/outputs/cohort_isg_analysis",
#'   q_threshold = 0.05,
#'   n_svs = 10,
#'   n_top_genes = 100
#' )
#' }
#' 
#' @export
run_isg_analysis <- function(sample_dirs,
                             sample_ids,
                             output_dir,
                             q_threshold = 0.05,
                             n_svs = NULL,
                             n_top_genes = 100,
                             da_file_name = "DA_significant.txt") {
  
  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
    cat(sprintf("Created output directory: %s\n", output_dir))
  }
  
  cat("\n=== TumorSPACE iSG SVD Analysis ===\n")
  cat(sprintf("Samples: %d\n", length(sample_ids)))
  cat(sprintf("Q threshold: %.3f\n", q_threshold))
  cat(sprintf("Output directory: %s\n\n", output_dir))
  
  # Step 1: Prepare binary matrix
  cat("STEP 1: Preparing binary SG × gene matrix\n")
  cat("==========================================\n")
  binary_matrix_data <- prepare_sg_binary_matrix(
    sample_dirs = sample_dirs,
    sample_ids = sample_ids,
    q_threshold = q_threshold,
    da_file_name = da_file_name
  )
  
  # Save binary matrix
  write.table(
    cbind(SG_Pair = rownames(binary_matrix_data$binary_matrix),
          as.data.frame(binary_matrix_data$binary_matrix)),
    file = file.path(output_dir, "da_gene_sig_binary.txt"),
    sep = "\t",
    quote = FALSE,
    row.names = FALSE
  )
  
  fwrite(
    binary_matrix_data$sg_metadata,
    file = file.path(output_dir, "sg_pair_metadata.txt"),
    sep = "\t"
  )
  
  cat(sprintf("\nSaved: da_gene_sig_binary.txt, sg_pair_metadata.txt\n"))
  
  # Step 2: SVD decomposition
  cat("\n\nSTEP 2: SVD decomposition\n")
  cat("=========================\n")
  svd_data <- compute_svd_signatures(
    binary_matrix = binary_matrix_data$binary_matrix,
    n_svs = n_svs,
    scale_genes = FALSE
  )
  
  # Save SVD matrices
  fwrite(
    svd_data$u_matrix,
    file = file.path(output_dir, "svd_u_matrix.txt"),
    sep = "\t"
  )
  
  fwrite(
    svd_data$d_values,
    file = file.path(output_dir, "svd_d_values.txt"),
    sep = "\t"
  )
  
  fwrite(
    svd_data$v_matrix,
    file = file.path(output_dir, "svd_v_matrix.txt"),
    sep = "\t"
  )
  
  cat(sprintf("\nSaved: svd_u_matrix.txt, svd_d_values.txt, svd_v_matrix.txt\n"))
  
  # Step 3: Extract top genes
  cat("\n\nSTEP 3: Extracting top genes per SV\n")
  cat("====================================\n")
  top_genes <- extract_top_genes_per_sv(
    v_matrix = svd_data$v_matrix,
    n_genes = n_top_genes
  )
  
  fwrite(
    top_genes,
    file = file.path(output_dir, "top_genes_per_sv.txt"),
    sep = "\t"
  )
  
  cat(sprintf("\nSaved: top_genes_per_sv.txt\n"))
  
  # Step 4: Classify SGs to SVs
  cat("\n\nSTEP 4: Classifying SG pairs to dominant SV\n")
  cat("============================================\n")
  sg_assignments <- classify_sg_to_sv(
    u_matrix = svd_data$u_matrix,
    sg_metadata = binary_matrix_data$sg_metadata
  )
  
  fwrite(
    sg_assignments,
    file = file.path(output_dir, "sg_sv_assignments.txt"),
    sep = "\t"
  )
  
  cat(sprintf("\nSaved: sg_sv_assignments.txt\n"))
  
  # Step 5: Compute sample profiles
  cat("\n\nSTEP 5: Computing per-sample SV fraction profiles\n")
  cat("==================================================\n")
  sample_profiles <- compute_sample_sv_profiles(
    sg_assignments = sg_assignments
  )
  
  fwrite(
    sample_profiles,
    file = file.path(output_dir, "sample_sv_fractions.txt"),
    sep = "\t"
  )
  
  cat(sprintf("\nSaved: sample_sv_fractions.txt\n"))
  
  # Save analysis summary
  summary_text <- sprintf(
    "TumorSPACE iSG SVD Analysis Summary
=====================================

Analysis Date: %s

Input Parameters:
-----------------
Number of samples: %d
Sample IDs: %s
Q threshold: %.3f
Number of SVs retained: %s
Top genes per SV direction: %d

Data Summary:
-------------
Total SG pairs: %d
Total genes: %d
Matrix sparsity: %.2f%%

SG pairs per sample:
%s

Variance Explained:
-------------------
%s

Output Files:
-------------
- da_gene_sig_binary.txt: Binary SG × gene matrix
- sg_pair_metadata.txt: SG pair metadata
- svd_u_matrix.txt: U matrix (SG loadings on SVs)
- svd_d_values.txt: Singular values and variance explained
- svd_v_matrix.txt: V matrix (gene loadings on SVs)
- top_genes_per_sv.txt: Top genes defining each SV signature
- sg_sv_assignments.txt: SG pair classifications to dominant SV
- sample_sv_fractions.txt: Per-sample SV fraction profiles

Next Steps:
-----------
1. Review top_genes_per_sv.txt to interpret biological meaning of each SV
2. Perform pathway enrichment on top genes (MSigDB Hallmark, Immunologic)
3. Compare sample_sv_fractions.txt across samples (homogeneous vs heterogeneous)
4. Integrate with other metrics (GrowChain depth, clinical outcomes, etc.)
5. Visualize: gene loading heatmaps, sample profile bar plots, SV biplots
",
    Sys.time(),
    length(sample_ids),
    paste(sample_ids, collapse = ", "),
    q_threshold,
    ifelse(is.null(n_svs), "all", as.character(n_svs)),
    n_top_genes,
    binary_matrix_data$stats$n_sg_pairs,
    binary_matrix_data$stats$n_genes,
    binary_matrix_data$stats$sparsity * 100,
    paste(capture.output(print(binary_matrix_data$stats$sg_pairs_per_sample)), collapse = "\n"),
    paste(capture.output(print(svd_data$d_values)), collapse = "\n")
  )
  
  writeLines(summary_text, file.path(output_dir, "analysis_summary.txt"))
  cat(sprintf("\nSaved: analysis_summary.txt\n"))
  
  # Final summary
  cat("\n\n=== Analysis Complete ===\n")
  cat(sprintf("All results saved to: %s\n", output_dir))
  cat("\nKey Results:\n")
  cat(sprintf("  - %d SG pairs classified across %d samples\n",
              nrow(sg_assignments), length(sample_ids)))
  cat(sprintf("  - %d singular vectors identified\n", 
              length(unique(svd_data$d_values$SV))))
  cat(sprintf("  - %d unique SV_Signed categories\n",
              length(unique(sg_assignments$SV_Signed))))
  
  return(list(
    binary_matrix_data = binary_matrix_data,
    svd_data = svd_data,
    top_genes = top_genes,
    sg_assignments = sg_assignments,
    sample_profiles = sample_profiles
  ))
}
