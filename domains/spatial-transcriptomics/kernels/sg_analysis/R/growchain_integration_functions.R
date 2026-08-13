#!/usr/bin/env Rscript
#
# GrowChain Integration Function Library
#
# Integrates spatial group (SG) SVD signatures with GrowChain depth metrics
# to analyze hierarchical spatial organization patterns. Tests hypotheses
# about whether specific biological signatures (e.g., immune-related SVs)
# correlate with deeper or shallower spatial nesting structures.
#
# GrowChain depth represents hierarchical spatial organization - higher depth
# indicates more nested spatial domains, while depth=0 indicates non-nested regions.
#
# Dependencies: data.table, dplyr, tidyr

library(data.table)
library(dplyr)
library(tidyr)

#' Load GrowChain Depth Data from Multiple Samples
#' 
#' Reads GrowChain depth files from TumorSPACE outputs and combines into
#' a single data table with sample identifiers.
#' 
#' @param sample_info_df data.frame with columns:
#'   - sample_id: Character, sample identifier
#'   - sample_dir: Character, path to TumorSPACE output directory containing optimal/
#' @param gc_filename Character, name of GrowChain depth file (default: "SG_GrowChain_depths.txt")
#' 
#' @return data.table with columns:
#'   - SampleID: Sample identifier
#'   - Node: SG node ID
#'   - GrowChain: Depth value (0 = non-nested, higher = deeper nesting)
#' 
#' @details
#'   Expected file location: <sample_dir>/optimal/<gc_filename>
#'   Missing files generate warnings but don't stop execution.
#' 
#' @export
load_growchain_data <- function(sample_info_df, gc_filename = "SG_GrowChain_depths.txt") {
  
  if (!"sample_id" %in% colnames(sample_info_df) || !"sample_dir" %in% colnames(sample_info_df)) {
    stop("sample_info_df must have columns: sample_id, sample_dir")
  }
  
  growchain_data_list <- list()
  
  for (i in 1:nrow(sample_info_df)) {
    sample_id <- sample_info_df$sample_id[i]
    growchain_file <- file.path(sample_info_df$sample_dir[i], "optimal", gc_filename)
    
    if (!file.exists(growchain_file)) {
      warning(sprintf("GrowChain file not found for %s: %s", sample_id, growchain_file))
      next
    }
    
    gc_data <- fread(growchain_file, header = TRUE)
    gc_data$SampleID <- sample_id
    growchain_data_list[[sample_id]] <- gc_data
  }
  
  if (length(growchain_data_list) == 0) {
    stop("No GrowChain data files found. Check sample_info_df paths.")
  }
  
  growchain_data <- rbindlist(growchain_data_list, fill = TRUE)
  return(growchain_data)
}

#' Compute GrowChain Metrics per Sample
#' 
#' Calculates summary statistics of GrowChain depth distribution for each sample.
#' 
#' @param growchain_data data.table with columns SampleID, Node, GrowChain
#' 
#' @return data.frame with per-sample metrics:
#'   - SampleID: Sample identifier
#'   - Total_SG: Number of SG nodes
#'   - Median_Depth: Median GrowChain depth
#'   - Mean_Depth: Mean GrowChain depth
#'   - Max_Depth: Maximum depth observed
#'   - Min_Depth: Minimum depth (usually 0)
#'   - SD_Depth: Standard deviation of depth
#'   - Frac_NonNested: Fraction of nodes with depth=0
#'   - Frac_DeepNested: Fraction of nodes with depth>=3
#' 
#' @export
compute_growchain_metrics <- function(growchain_data) {
  
  metrics <- growchain_data %>%
    group_by(SampleID) %>%
    summarize(
      Total_SG = n(),
      Median_Depth = median(GrowChain, na.rm = TRUE),
      Mean_Depth = mean(GrowChain, na.rm = TRUE),
      Max_Depth = max(GrowChain, na.rm = TRUE),
      Min_Depth = min(GrowChain, na.rm = TRUE),
      SD_Depth = sd(GrowChain, na.rm = TRUE),
      Frac_NonNested = sum(GrowChain == 0, na.rm = TRUE) / n(),
      Frac_DeepNested = sum(GrowChain >= 3, na.rm = TRUE) / n(),
      .groups = "drop"
    )
  
  return(as.data.frame(metrics))
}

#' Merge iSG SV Assignments with GrowChain Depths
#' 
#' Joins SG-level SV classifications with GrowChain depth data.
#' 
#' @param sg_assignments data.table from iSG analysis with columns:
#'   - SG_Pair: Formatted as "Node_Sibling"
#'   - SampleID: Sample identifier
#'   - SV_Signed: SV category (e.g., "SV1_Pos")
#' @param growchain_data data.table with columns: SampleID, Node, GrowChain
#' 
#' @return data.table with merged SG-level data:
#'   - SG_Pair: Original identifier
#'   - Node: Extracted node ID
#'   - Sibling: Extracted sibling ID
#'   - SampleID: Sample identifier
#'   - SV_Signed: SV category
#'   - GrowChain: Depth value (NA if not matched)
#' 
#' @details
#'   Extracts Node ID from SG_Pair format "Node_Sibling" and joins with
#'   GrowChain data by SampleID and Node.
#' 
#' @export
merge_isg_growchain <- function(sg_assignments, growchain_data) {
  
  sg_with_depth <- sg_assignments %>%
    separate(SG_Pair, into = c("Node", "Sibling"), sep = "_", remove = FALSE) %>%
    mutate(Node = as.integer(Node)) %>%
    left_join(
      growchain_data %>% select(SampleID, Node, GrowChain),
      by = c("SampleID", "Node")
    )
  
  return(sg_with_depth)
}

#' Compute SV-Level GrowChain Statistics
#' 
#' Aggregates GrowChain depth metrics per SV category.
#' 
#' @param sg_with_depth data.table from merge_isg_growchain() with GrowChain column
#' 
#' @return data.frame with per-SV statistics:
#'   - SV_Signed: SV category
#'   - N_SG: Number of SG pairs
#'   - Mean_Depth: Mean GrowChain depth
#'   - Median_Depth: Median depth
#'   - SD_Depth: Standard deviation
#'   - Frac_NonNested: Fraction with depth=0
#'   - Frac_DeepNested: Fraction with depth>=3
#' 
#' @export
compute_sv_growchain_stats <- function(sg_with_depth) {
  
  sv_depth_stats <- sg_with_depth %>%
    filter(!is.na(GrowChain)) %>%
    group_by(SV_Signed) %>%
    summarize(
      N_SG = n(),
      Mean_Depth = mean(GrowChain),
      Median_Depth = median(GrowChain),
      SD_Depth = sd(GrowChain),
      Frac_NonNested = sum(GrowChain == 0) / n(),
      Frac_DeepNested = sum(GrowChain >= 3) / n(),
      .groups = "drop"
    ) %>%
    arrange(desc(Mean_Depth))
  
  return(as.data.frame(sv_depth_stats))
}

#' Correlate SV Fractions with GrowChain Metrics
#' 
#' Computes Pearson correlations between sample-level SV fractions and
#' GrowChain depth metrics. Useful for identifying which SV signatures
#' are associated with deeper or shallower spatial organization.
#' 
#' @param sv_fractions data.table with columns: SampleID, SV_Signed, Fraction
#' @param growchain_metrics data.frame from compute_growchain_metrics()
#' @param min_samples Integer, minimum number of samples where SV must be
#'   present (Fraction > 0) to compute correlation (default: 3)
#' 
#' @return data.frame with correlations:
#'   - SV: SV category
#'   - Metric: GrowChain metric name
#'   - Correlation: Pearson r value
#'   - PValue: P-value from cor.test
#' 
#' @details
#'   Only SVs present in >= min_samples are analyzed to ensure statistical validity.
#'   With small sample sizes (N<10), p-values have limited power.
#' 
#' @export
correlate_sv_depth <- function(sv_fractions, growchain_metrics, min_samples = 3) {
  
  # Pivot SV fractions to wide format
  sv_fractions_wide <- sv_fractions %>%
    select(SampleID, SV_Signed, Fraction) %>%
    pivot_wider(names_from = SV_Signed, values_from = Fraction, values_fill = 0)
  
  # Merge with GrowChain metrics
  correlation_data <- growchain_metrics %>%
    left_join(sv_fractions_wide, by = "SampleID")
  
  # Get SV columns
  sv_columns <- setdiff(colnames(correlation_data), 
                       c("SampleID", colnames(growchain_metrics)))
  
  if (length(sv_columns) == 0) {
    warning("No SV columns found for correlation")
    return(data.frame())
  }
  
  # Filter to common SVs (present in >= min_samples)
  sv_presence <- colSums(correlation_data[, sv_columns, drop = FALSE] > 0)
  common_svs <- names(sv_presence[sv_presence >= min_samples])
  
  if (length(common_svs) == 0) {
    warning(sprintf("No SVs present in >= %d samples", min_samples))
    return(data.frame())
  }
  
  # Compute correlations
  correlation_results <- list()
  
  for (sv in common_svs) {
    for (metric in c("Median_Depth", "Mean_Depth", "Max_Depth", 
                    "Frac_NonNested", "Frac_DeepNested")) {
      if (metric %in% colnames(correlation_data)) {
        cor_test <- cor.test(correlation_data[[sv]], 
                            correlation_data[[metric]],
                            method = "pearson")
        
        correlation_results[[length(correlation_results) + 1]] <- data.frame(
          SV = sv,
          Metric = metric,
          Correlation = as.numeric(cor_test$estimate),
          PValue = cor_test$p.value,
          stringsAsFactors = FALSE
        )
      }
    }
  }
  
  if (length(correlation_results) == 0) {
    return(data.frame())
  }
  
  correlation_df <- bind_rows(correlation_results) %>%
    arrange(desc(abs(Correlation)))
  
  return(as.data.frame(correlation_df))
}

#' Analyze Immune vs Non-Immune SV Depth Associations
#' 
#' Compares GrowChain depth distributions between immune-related and
#' non-immune SVs using Wilcoxon rank-sum test.
#' 
#' @param sg_with_depth data.table from merge_isg_growchain()
#' @param immune_sv_ids Character vector of immune-related SV base IDs (e.g., c("SV1", "SV2"))
#'   Should NOT include _Pos/_Neg suffix
#' 
#' @return List with elements:
#'   - comparison_stats: data.frame with mean/median depth by immune status
#'   - wilcox_test: Wilcoxon test result (if sufficient data)
#' 
#' @details
#'   Requires at least 5 SG pairs per group for statistical testing.
#'   Extracts base SV ID (removes _Pos/_Neg suffix) for classification.
#' 
#' @export
analyze_immune_depth_association <- function(sg_with_depth, immune_sv_ids) {
  
  # Extract base SV (remove _Pos/_Neg suffix)
  sg_with_depth <- sg_with_depth %>%
    mutate(
      SV_Base = gsub("_Pos|_Neg", "", SV_Signed),
      IsImmuneRelated = SV_Base %in% immune_sv_ids
    )
  
  # Compute comparison stats
  comparison_stats <- sg_with_depth %>%
    filter(!is.na(GrowChain)) %>%
    group_by(IsImmuneRelated) %>%
    summarize(
      N_SG = n(),
      Mean_Depth = mean(GrowChain),
      Median_Depth = median(GrowChain),
      SD_Depth = sd(GrowChain),
      Frac_NonNested = sum(GrowChain == 0) / n(),
      Frac_DeepNested = sum(GrowChain >= 3) / n(),
      .groups = "drop"
    )
  
  # Statistical test (if enough data)
  wilcox_result <- NULL
  
  immune_depths <- sg_with_depth %>% 
    filter(IsImmuneRelated == TRUE, !is.na(GrowChain)) %>% 
    pull(GrowChain)
  
  nonimmune_depths <- sg_with_depth %>%
    filter(IsImmuneRelated == FALSE, !is.na(GrowChain)) %>%
    pull(GrowChain)
  
  if (length(immune_depths) >= 5 && length(nonimmune_depths) >= 5) {
    wilcox_result <- wilcox.test(immune_depths, nonimmune_depths)
  } else {
    warning("Insufficient data for Wilcoxon test (need >=5 per group)")
  }
  
  return(list(
    comparison_stats = as.data.frame(comparison_stats),
    wilcox_test = wilcox_result
  ))
}

#' Run Complete GrowChain Integration Analysis
#' 
#' Master orchestrator function that loads data, computes metrics, performs
#' correlations, and generates comprehensive summary outputs.
#' 
#' @param isg_analysis_dir Character, directory containing iSG analysis outputs
#'   (must have sg_sv_assignments.txt, sample_sv_fractions.txt)
#' @param sample_info_df data.frame with columns sample_id, sample_dir
#' @param output_dir Character, directory to save integration results
#' @param gc_filename Character, GrowChain depth filename (default: "SG_GrowChain_depths.txt")
#' @param immune_sv_ids Character vector of immune SV base IDs (optional, for immune analysis)
#' 
#' @return List with analysis results:
#'   - growchain_metrics: Sample-level depth statistics
#'   - sv_depth_stats: SV-level depth statistics
#'   - correlations: SV fraction-depth correlations
#'   - immune_analysis: Immune vs non-immune comparison (if immune_sv_ids provided)
#' 
#' @details
#'   Creates output files:
#'   - sv_growchain_depth_stats.txt: Mean depth per SV
#'   - sv_growchain_correlations.txt: Correlations
#'   - immune_vs_nonimmune_depth_comparison.txt: Immune comparison
#'   - integration_analysis_summary.txt: Text summary report
#' 
#' @export
run_growchain_integration <- function(isg_analysis_dir,
                                     sample_info_df,
                                     output_dir,
                                     gc_filename = "SG_GrowChain_depths.txt",
                                     immune_sv_ids = NULL) {
  
  # Validate inputs
  if (!dir.exists(isg_analysis_dir)) {
    stop(sprintf("iSG analysis directory not found: %s", isg_analysis_dir))
  }
  
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  
  # Load iSG data
  cat("Loading iSG analysis results...\n")
  
  sv_fractions_file <- file.path(isg_analysis_dir, "sample_sv_fractions.txt")
  sg_assignments_file <- file.path(isg_analysis_dir, "sg_sv_assignments.txt")
  
  if (!file.exists(sv_fractions_file) || !file.exists(sg_assignments_file)) {
    stop("Required iSG files not found. Run iSG SVD analysis first.")
  }
  
  sv_fractions <- fread(sv_fractions_file)
  sg_assignments <- fread(sg_assignments_file)
  
  cat(sprintf("  SV fractions: %d rows\n", nrow(sv_fractions)))
  cat(sprintf("  SG assignments: %d SG pairs\n", nrow(sg_assignments)))
  
  # Load GrowChain data
  cat("\nLoading GrowChain depth data...\n")
  growchain_data <- load_growchain_data(sample_info_df, gc_filename)
  cat(sprintf("  Loaded %d SG nodes across %d samples\n", 
              nrow(growchain_data), 
              length(unique(growchain_data$SampleID))))
  
  # Compute metrics
  cat("\nComputing GrowChain metrics...\n")
  growchain_metrics <- compute_growchain_metrics(growchain_data)
  print(growchain_metrics)
  
  # Merge iSG with GrowChain
  cat("\nMerging iSG assignments with GrowChain depths...\n")
  sg_with_depth <- merge_isg_growchain(sg_assignments, growchain_data)
  
  n_matched <- sum(!is.na(sg_with_depth$GrowChain))
  cat(sprintf("  Matched %d / %d SG pairs (%.1f%%)\n",
              n_matched, nrow(sg_with_depth),
              100 * n_matched / nrow(sg_with_depth)))
  
  # SV-level depth stats
  cat("\nComputing SV-level depth statistics...\n")
  sv_depth_stats <- compute_sv_growchain_stats(sg_with_depth)
  cat(sprintf("  Computed stats for %d SV categories\n", nrow(sv_depth_stats)))
  
  # Save SV depth stats
  fwrite(sv_depth_stats,
         file.path(output_dir, "sv_growchain_depth_stats.txt"),
         sep = "\t")
  
  # Correlations
  cat("\nComputing SV-depth correlations...\n")
  correlation_df <- correlate_sv_depth(sv_fractions, growchain_metrics, min_samples = 3)
  
  if (nrow(correlation_df) > 0) {
    cat(sprintf("  Computed %d correlations\n", nrow(correlation_df)))
    fwrite(correlation_df,
           file.path(output_dir, "sv_growchain_correlations.txt"),
           sep = "\t")
  } else {
    cat("  Insufficient data for correlation analysis\n")
  }
  
  # Immune analysis
  immune_analysis <- NULL
  if (!is.null(immune_sv_ids) && length(immune_sv_ids) > 0) {
    cat("\nAnalyzing immune vs non-immune SV depth associations...\n")
    immune_analysis <- analyze_immune_depth_association(sg_with_depth, immune_sv_ids)
    
    cat("  Comparison statistics:\n")
    print(immune_analysis$comparison_stats)
    
    if (!is.null(immune_analysis$wilcox_test)) {
      cat(sprintf("\n  Wilcoxon test: p = %.4f\n", immune_analysis$wilcox_test$p.value))
    }
    
    fwrite(immune_analysis$comparison_stats,
           file.path(output_dir, "immune_vs_nonimmune_depth_comparison.txt"),
           sep = "\t")
  }
  
  cat(sprintf("\nAnalysis complete! Results saved to: %s\n", output_dir))
  
  # Return results
  return(list(
    growchain_metrics = growchain_metrics,
    sv_depth_stats = sv_depth_stats,
    correlations = correlation_df,
    immune_analysis = immune_analysis,
    sg_with_depth = sg_with_depth
  ))
}
