#!/usr/bin/env Rscript
#
# Enhanced Pruning Diagnostic - Hyperparameter & Node Characteristic Analysis
# 
# Analyzes raw node characteristics (Support, RipleySum) against optimal hyperparameters
# (Prune threshold, Spatial quantile) to validate that ParentPass labels correctly
# identify nodes for keeping/pruning.
#
# Usage:
#   Rscript diagnose_pruning_hyperparameters.R <output_dir>

library(ape)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) {
  stop("Usage: Rscript diagnose_pruning_hyperparameters.R <output_dir>")
}

output_dir <- args[1]

cat("================================================================================\n")
cat("PRUNING DIAGNOSTIC: HYPERPARAMETER & NODE CHARACTERISTIC ANALYSIS\n")
cat("================================================================================\n")
cat("Output directory:    ", output_dir, "\n")
cat("Analysis date:       ", as.character(Sys.time()), "\n\n")

# =============================================================================
# STEP 1: Load Optimal Hyperparameters
# =============================================================================
cat("[Step 1] Loading optimal hyperparameters from cor_dat_all.tsv...\n")
cor_dat <- read.table(file.path(output_dir, "cor_dat_all.tsv"), header = TRUE, sep = "\t")

optimal_prune <- cor_dat$Prune[1]
optimal_spatial <- cor_dat$Spatial[1]
optimal_knn <- cor_dat$KNN[1]
optimal_cor <- cor_dat$NodeCor[1]

cat("  Prune (Support threshold):    ", optimal_prune, "\n")
cat("  Spatial (Ripley quantile):    ", optimal_spatial, "\n")
cat("  KNN:                           ", optimal_knn, "\n")
cat("  Node Correlation:              ", optimal_cor, "\n\n")

# =============================================================================
# STEP 2: Load Raw Node Characteristics
# =============================================================================
cat("[Step 2] Loading raw node characteristics...\n")
allnodes <- read.table(file.path(output_dir, "allnodes_leaves_passingNodes.tsv"), 
                       header = TRUE, sep = "\t", stringsAsFactors = FALSE)

nodes_unique <- allnodes[!duplicated(allnodes$Node), ]
cat("  Total rows in allnodes_leaves_passingNodes: ", nrow(allnodes), "\n")
cat("  Unique nodes: ", nrow(nodes_unique), "\n")
cat("  RipPass:      ", sum(nodes_unique$RipPass), " / ", nrow(nodes_unique), "\n")
cat("  SupportPass:  ", sum(nodes_unique$SupportPass), " / ", nrow(nodes_unique), "\n")
cat("  BothPass:     ", sum(nodes_unique$BothPass), " / ", nrow(nodes_unique), "\n")
cat("  ParentPass:   ", sum(nodes_unique$ParentPass), " / ", nrow(nodes_unique), "\n\n")

# =============================================================================
# STEP 3: Investigate Missing Support Values
# =============================================================================
cat("[Step 3] Investigating missing Support values...\n")

# Check for empty strings
nodes_unique$Support_IsEmpty <- nodes_unique$Support == ""
nodes_unique$Support_IsNA <- is.na(nodes_unique$Support)

empty_count <- sum(nodes_unique$Support_IsEmpty)
na_count <- sum(nodes_unique$Support_IsNA)
valid_count <- sum(!nodes_unique$Support_IsEmpty & !nodes_unique$Support_IsNA)

cat("  Missing Support (empty string): ", empty_count, "\n")
cat("  Missing Support (NA):           ", na_count, "\n")
cat("  Valid Support values:           ", valid_count, "\n")

if (empty_count > 0 || na_count > 0) {
  cat("\n  MISSING SUPPORT VALUES DETECTED:\n")
  missing_nodes <- nodes_unique[nodes_unique$Support_IsEmpty | nodes_unique$Support_IsNA, 
                                 c("Node", "Support", "NodeSize", "RipleySum", "SupportPass")]
  cat("  First 20 nodes with missing Support:\n")
  print(head(missing_nodes, 20))
  
  if (nrow(missing_nodes) > 20) {
    cat("  ... (", nrow(missing_nodes) - 20, " more nodes not shown)\n")
  }
  
  # Analyze characteristics of missing nodes
  cat("\n  CHARACTERISTICS OF MISSING SUPPORT NODES:\n")
  cat("    NodeSize range:    [", min(missing_nodes$NodeSize), ", ", max(missing_nodes$NodeSize), "]\n")
  cat("    RipleySum range:   [", min(missing_nodes$RipleySum), ", ", max(missing_nodes$RipleySum), "]\n")
  cat("    SupportPass = 1:   ", sum(missing_nodes$SupportPass), " / ", nrow(missing_nodes), "\n")
  
  # Check if these are root or special nodes
  cat("\n  INVESTIGATION - Why are these Support values missing?\n")
  cat("  Hypothesis 1: Root node (Node=-2 is typically root)\n")
  cat("    Root node in missing: ", any(missing_nodes$Node == -2), "\n")
  
  cat("  Hypothesis 2: Large nodes (close to total tip count)\n")
  total_tips <- max(allnodes$Leaf)
  large_nodes <- missing_nodes$NodeSize > total_tips * 0.9
  cat("    Nodes with >90% of tips: ", sum(large_nodes), "\n")
  
  cat("  Hypothesis 3: Nodes with no bootstrap value in tree\n")
  cat("    (These would get default Support=1.0 in Julia code)\n")
}

cat("\n")

# =============================================================================
# STEP 4: Parse Support Values and Handle Missing
# =============================================================================
cat("[Step 4] Parsing Support values...\n")

# Convert Support to numeric, handling missing values
nodes_unique$Support_Numeric <- suppressWarnings(as.numeric(nodes_unique$Support))

# For empty/NA Support, assign 1.0 (matches Julia behavior)
nodes_unique$Support_Numeric[nodes_unique$Support_IsEmpty | nodes_unique$Support_IsNA] <- 1.0

cat("  Support values after parsing:\n")
cat("    Min:    ", min(nodes_unique$Support_Numeric, na.rm = TRUE), "\n")
cat("    Max:    ", max(nodes_unique$Support_Numeric, na.rm = TRUE), "\n")
cat("    Mean:   ", round(mean(nodes_unique$Support_Numeric, na.rm = TRUE), 3), "\n")
cat("    Median: ", round(median(nodes_unique$Support_Numeric, na.rm = TRUE), 3), "\n")
cat("\n")

# =============================================================================
# STEP 5: Analyze Support Threshold Filtering
# =============================================================================
cat("[Step 5] Analyzing Support (Prune) threshold...\n")
cat("  Threshold: Support >= ", optimal_prune, "\n")

nodes_unique$Expected_SupportPass <- ifelse(nodes_unique$Support_Numeric >= optimal_prune, 1, 0)

support_match <- sum(nodes_unique$Expected_SupportPass == nodes_unique$SupportPass)
support_mismatch <- sum(nodes_unique$Expected_SupportPass != nodes_unique$SupportPass)

cat("  Nodes with Support >= ", optimal_prune, ": ", sum(nodes_unique$Expected_SupportPass), "\n")
cat("  Nodes with Support <  ", optimal_prune, ": ", nrow(nodes_unique) - sum(nodes_unique$Expected_SupportPass), "\n")
cat("\n")
cat("  SupportPass label accuracy:\n")
cat("    Matches expected:   ", support_match, " (", 
    round(100 * support_match / nrow(nodes_unique), 1), "%)\n")
cat("    Mismatches:         ", support_mismatch, "\n")

if (support_mismatch > 0) {
  cat("\n  MISMATCHES DETECTED:\n")
  mm <- nodes_unique[nodes_unique$Expected_SupportPass != nodes_unique$SupportPass, 
                     c("Node", "Support", "Support_Numeric", "Expected_SupportPass", "SupportPass")]
  print(head(mm, 20))
  
  if (nrow(mm) > 20) {
    cat("  ... (", nrow(mm) - 20, " more mismatches not shown)\n")
  }
}
cat("\n")

# =============================================================================
# STEP 6: Analyze Ripley's K Quantile Filtering
# =============================================================================
cat("[Step 6] Analyzing Ripley's K (Spatial) quantile...\n")
ripley_threshold <- quantile(nodes_unique$RipleySum, optimal_spatial, na.rm = TRUE)
cat("  Quantile threshold (", optimal_spatial, "): ", ripley_threshold, "\n")

nodes_unique$Expected_RipPass <- ifelse(nodes_unique$RipleySum >= ripley_threshold, 1, 0)

rip_match <- sum(nodes_unique$Expected_RipPass == nodes_unique$RipPass)
rip_mismatch <- sum(nodes_unique$Expected_RipPass != nodes_unique$RipPass)

cat("  Nodes with RipleySum >= ", ripley_threshold, ": ", sum(nodes_unique$Expected_RipPass), "\n")
cat("  Nodes with RipleySum <  ", ripley_threshold, ": ", nrow(nodes_unique) - sum(nodes_unique$Expected_RipPass), "\n")
cat("\n")
cat("  RipPass label accuracy:\n")
cat("    Matches expected:   ", rip_match, " (", 
    round(100 * rip_match / nrow(nodes_unique), 1), "%)\n")
cat("    Mismatches:         ", rip_mismatch, "\n")

if (rip_mismatch > 0) {
  cat("\n  MISMATCHES DETECTED:\n")
  mm <- nodes_unique[nodes_unique$Expected_RipPass != nodes_unique$RipPass, 
                     c("Node", "RipleySum", "Expected_RipPass", "RipPass")]
  print(head(mm, 20))
  
  if (nrow(mm) > 20) {
    cat("  ... (", nrow(mm) - 20, " more mismatches not shown)\n")
  }
}
cat("\n")

# =============================================================================
# STEP 7: Analyze Combined BothPass Filtering
# =============================================================================
cat("[Step 7] Analyzing combined BothPass...\n")
nodes_unique$Expected_BothPass <- ifelse((nodes_unique$Expected_SupportPass == 1) & 
                                         (nodes_unique$Expected_RipPass == 1), 1, 0)

both_match <- sum(nodes_unique$Expected_BothPass == nodes_unique$BothPass)
both_mismatch <- sum(nodes_unique$Expected_BothPass != nodes_unique$BothPass)

cat("  BothPass label accuracy:\n")
cat("    Matches expected:   ", both_match, " (", 
    round(100 * both_match / nrow(nodes_unique), 1), "%)\n")
cat("    Mismatches:         ", both_mismatch, "\n")

if (both_mismatch > 0) {
  cat("\n  MISMATCHES DETECTED:\n")
  mm <- nodes_unique[nodes_unique$Expected_BothPass != nodes_unique$BothPass, 
                     c("Node", "Support", "RipleySum", "Expected_BothPass", "BothPass")]
  print(head(mm, 20))
}
cat("\n")

# =============================================================================
# STEP 8: Validate ParentPass Selection
# =============================================================================
cat("[Step 8] Validating ParentPass selection...\n")

parents_file <- file.path(output_dir, "allnodes_parents.tsv")
if (file.exists(parents_file)) {
  allnodes_parents <- read.table(parents_file, header = TRUE, sep = "\t", stringsAsFactors = FALSE)
  
  # Get parent nodes of nodes that pass BothPass
  nodes_bothpass <- nodes_unique$Node[nodes_unique$BothPass == 1]
  parent_nodes_expected <- unique(allnodes_parents$ParentNode[allnodes_parents$Node %in% nodes_bothpass])
  
  # Compare to actual ParentPass
  nodes_parentpass <- nodes_unique$Node[nodes_unique$ParentPass == 1]
  
  cat("  Nodes with BothPass = 1:  ", length(nodes_bothpass), "\n")
  cat("  Expected parent nodes:    ", length(parent_nodes_expected), "\n")
  cat("  Actual ParentPass = 1:    ", length(nodes_parentpass), "\n\n")
  
  # Find mismatches
  missing_parents <- setdiff(parent_nodes_expected, nodes_parentpass)
  extra_parents <- setdiff(nodes_parentpass, parent_nodes_expected)
  
  if (length(missing_parents) > 0) {
    cat("  ✗ Parents of BothPass nodes NOT in ParentPass: ", length(missing_parents), "\n")
    cat("    ", paste(head(missing_parents, 10), collapse = ", "), "\n")
  }
  
  if (length(extra_parents) > 0) {
    cat("  ✗ Nodes in ParentPass but NOT parents of BothPass: ", length(extra_parents), "\n")
    cat("    ", paste(head(extra_parents, 10), collapse = ", "), "\n")
  }
  
  if (length(missing_parents) == 0 && length(extra_parents) == 0) {
    cat("  ✓ ParentPass perfectly matches parents of BothPass nodes\n")
  }
} else {
  cat("  allnodes_parents.tsv not found - skipping ParentPass validation\n")
}
cat("\n")

# =============================================================================
# STEP 9: Generate Detailed Node Report
# =============================================================================
cat("[Step 9] Generating detailed report...\n")

node_report <- data.frame(
  Node = nodes_unique$Node,
  Support_Raw = nodes_unique$Support,
  Support = nodes_unique$Support_Numeric,
  RipleySum = nodes_unique$RipleySum,
  NodeSize = nodes_unique$NodeSize,
  Support_Threshold = optimal_prune,
  Ripley_Threshold = ripley_threshold,
  Expected_SupportPass = nodes_unique$Expected_SupportPass,
  Actual_SupportPass = nodes_unique$SupportPass,
  Support_Match = nodes_unique$Expected_SupportPass == nodes_unique$SupportPass,
  Expected_RipPass = nodes_unique$Expected_RipPass,
  Actual_RipPass = nodes_unique$RipPass,
  Ripley_Match = nodes_unique$Expected_RipPass == nodes_unique$RipPass,
  Expected_BothPass = nodes_unique$Expected_BothPass,
  Actual_BothPass = nodes_unique$BothPass,
  BothPass_Match = nodes_unique$Expected_BothPass == nodes_unique$BothPass,
  ParentPass = nodes_unique$ParentPass,
  Prune_Decision = ifelse(nodes_unique$ParentPass == 1, "KEEP", "PRUNE"),
  stringsAsFactors = FALSE
)

output_file <- file.path(output_dir, "pruning_hyperparameter_diagnostic.tsv")
write.table(node_report, output_file, sep = "\t", row.names = FALSE, quote = FALSE)
cat("  Saved: ", output_file, "\n")
cat("  Rows: ", nrow(node_report), "\n\n")

# =============================================================================
# STEP 10: Summary and Recommendations
# =============================================================================
cat("================================================================================\n")
cat("SUMMARY AND RECOMMENDATIONS\n")
cat("================================================================================\n\n")

cat("HYPERPARAMETERS:\n")
cat("  Prune threshold (Support):    ", optimal_prune, "\n")
cat("  Spatial quantile (Ripley):    ", optimal_spatial, " (threshold: ", ripley_threshold, ")\n")
cat("  KNN:                           ", optimal_knn, "\n")
cat("  Correlation achieved:          ", optimal_cor, "\n\n")

cat("NODE CHARACTERISTIC FILTERING:\n")
cat("  Total nodes:                   ", nrow(nodes_unique), "\n")
cat("  Pass Support threshold:        ", sum(nodes_unique$Expected_SupportPass), 
    " (", round(100 * sum(nodes_unique$Expected_SupportPass) / nrow(nodes_unique), 1), "%)\n")
cat("  Pass Ripley threshold:         ", sum(nodes_unique$Expected_RipPass), 
    " (", round(100 * sum(nodes_unique$Expected_RipPass) / nrow(nodes_unique), 1), "%)\n")
cat("  Pass BOTH thresholds:          ", sum(nodes_unique$Expected_BothPass), 
    " (", round(100 * sum(nodes_unique$Expected_BothPass) / nrow(nodes_unique), 1), "%)\n")
cat("  Selected as ParentPass (KEEP): ", sum(nodes_unique$ParentPass), 
    " (", round(100 * sum(nodes_unique$ParentPass) / nrow(nodes_unique), 1), "%)\n\n")

cat("LABEL ACCURACY:\n")
cat("  SupportPass:  ", round(100 * support_match / nrow(nodes_unique), 1), "% match\n")
cat("  RipPass:      ", round(100 * rip_match / nrow(nodes_unique), 1), "% match\n")
cat("  BothPass:     ", round(100 * both_match / nrow(nodes_unique), 1), "% match\n\n")

cat("MISSING SUPPORT VALUES:\n")
cat("  Empty/NA Support: ", empty_count + na_count, " nodes\n")
cat("  Default to 1.0:   ", empty_count + na_count, " (matches Julia code behavior)\n\n")

if (support_mismatch == 0 && rip_mismatch == 0 && both_mismatch == 0) {
  cat("OVERALL STATUS: ✓ EXCELLENT\n")
  cat("  All node characteristic labels match expected values based on thresholds.\n")
  cat("  Pruning decisions are consistent with optimal hyperparameters.\n")
} else {
  cat("OVERALL STATUS: ✗ ISSUES DETECTED\n")
  cat("  Mismatches found between expected and actual pass labels.\n")
  cat("  Review detailed report: ", output_file, "\n")
}

cat("\n================================================================================\n")
cat("DIAGNOSTIC COMPLETE\n")
cat("================================================================================\n")
