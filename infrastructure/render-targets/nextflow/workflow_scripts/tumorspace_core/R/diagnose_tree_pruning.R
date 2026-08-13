#!/usr/bin/env Rscript
#
# Tree Pruning Diagnostic Script
# 
# Analyzes tree pruning behavior to detect potential bugs by comparing:
# - Pre-pruning tree with support values
# - Post-pruning tree
# - Expected vs actual pruning outcomes
# - Optimal hyperparameters and node characteristics
#
# Usage:
#   Rscript diagnose_tree_pruning.R <output_dir> [support_threshold]
#
# Example:
#   Rscript diagnose_tree_pruning.R benchmarks/GSE213688_GSM6592057/container_test_20260118_142617/optimal 0.5
#

library(ape)

# Parse command line arguments
args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 1) {
  cat("Usage: Rscript diagnose_tree_pruning.R <output_dir> [support_threshold]\n")
  cat("\n")
  cat("Arguments:\n")
  cat("  output_dir          Directory containing tree files (OptimalTree_*.nw)\n")
  cat("  support_threshold   Bootstrap support threshold (default: 0.5)\n")
  cat("\n")
  quit(status = 1)
}

output_dir <- args[1]
support_threshold <- ifelse(length(args) >= 2, as.numeric(args[2]), 0.5)

cat("================================================================================\n")
cat("TREE PRUNING DIAGNOSTIC ANALYSIS\n")
cat("================================================================================\n")
cat("Output directory:    ", output_dir, "\n")
cat("Support threshold:   ", support_threshold, "\n")
cat("Analysis date:       ", as.character(Sys.time()), "\n")
cat("\n")

# =============================================================================
# STEP 1: Load Tree Files
# =============================================================================
cat("[Step 1] Loading tree files...\n")

preprune_file <- file.path(output_dir, "OptimalTree_preprune.nw")
postprune_file <- file.path(output_dir, "OptimalTree.nw")
relabeled_file <- file.path(output_dir, "OptimalTree_pruned.nw")

if (!file.exists(preprune_file)) {
  stop("ERROR: Pre-pruning tree not found: ", preprune_file)
}
if (!file.exists(postprune_file)) {
  stop("ERROR: Post-pruning tree not found: ", postprune_file)
}

# Load trees
tree_pre <- read.tree(preprune_file)
tree_post <- read.tree(postprune_file)

cat("  Pre-pruning tree:  ", length(tree_pre$tip.label), "tips,", 
    tree_pre$Nnode, "internal nodes\n")
cat("  Post-pruning tree: ", length(tree_post$tip.label), "tips,", 
    tree_post$Nnode, "internal nodes\n")

if (file.exists(relabeled_file)) {
  tree_relabeled <- read.tree(relabeled_file)
  cat("  Re-labeled tree:   ", length(tree_relabeled$tip.label), "tips,", 
      tree_relabeled$Nnode, "internal nodes\n")
} else {
  tree_relabeled <- NULL
  cat("  Re-labeled tree:   NOT FOUND (optional)\n")
}

cat("\n")

# =============================================================================
# STEP 2: Extract Node Support Values
# =============================================================================
cat("[Step 2] Extracting node support values...\n")

# Pre-pruning tree should have support values as node labels
if (is.null(tree_pre$node.label) || length(tree_pre$node.label) == 0) {
  cat("  WARNING: Pre-pruning tree has no node labels!\n")
  cat("           Cannot analyze support values.\n")
  support_pre <- NULL
} else {
  # Parse node labels as numeric support values
  support_pre <- suppressWarnings(as.numeric(tree_pre$node.label))
  
  # Count valid support values
  valid_support <- sum(!is.na(support_pre))
  cat("  Pre-pruning:  ", valid_support, "/", length(tree_pre$node.label), 
      "nodes have numeric support values\n")
  
  if (valid_support > 0) {
    cat("    Range:      [", min(support_pre, na.rm = TRUE), ",", 
        max(support_pre, na.rm = TRUE), "]\n")
    cat("    Mean:       ", round(mean(support_pre, na.rm = TRUE), 3), "\n")
    cat("    Median:     ", round(median(support_pre, na.rm = TRUE), 3), "\n")
  }
}

# Post-pruning tree support values
if (is.null(tree_post$node.label) || length(tree_post$node.label) == 0) {
  cat("  Post-pruning: No node labels\n")
  support_post <- NULL
} else {
  support_post <- suppressWarnings(as.numeric(tree_post$node.label))
  valid_support_post <- sum(!is.na(support_post))
  cat("  Post-pruning: ", valid_support_post, "/", length(tree_post$node.label), 
      "nodes have numeric support values\n")
  
  if (valid_support_post > 0) {
    cat("    Range:      [", min(support_post, na.rm = TRUE), ",", 
        max(support_post, na.rm = TRUE), "]\n")
    cat("    Mean:       ", round(mean(support_post, na.rm = TRUE), 3), "\n")
    cat("    Median:     ", round(median(support_post, na.rm = TRUE), 3), "\n")
  }
}

cat("\n")

# =============================================================================
# STEP 3: Analyze Node Characteristics
# =============================================================================
cat("[Step 3] Analyzing node characteristics...\n")

if (!is.null(support_pre)) {
  # Count nodes below threshold
  nodes_below_threshold <- sum(support_pre < support_threshold, na.rm = TRUE)
  pct_below <- round(100 * nodes_below_threshold / length(support_pre), 1)
  
  cat("  Nodes with support < ", support_threshold, ": ", nodes_below_threshold, 
      " (", pct_below, "%)\n", sep = "")
  
  # Distribution of low-support nodes
  if (nodes_below_threshold > 0) {
    low_support_vals <- support_pre[!is.na(support_pre) & support_pre < support_threshold]
    cat("    Low support range:  [", min(low_support_vals), ",", 
        max(low_support_vals), "]\n")
    cat("    Nodes with support = 0: ", sum(low_support_vals == 0), "\n")
  }
  
  # Nodes at or above threshold
  nodes_above_threshold <- sum(support_pre >= support_threshold, na.rm = TRUE)
  cat("  Nodes with support >= ", support_threshold, ": ", nodes_above_threshold, "\n", sep = "")
  
} else {
  cat("  Cannot analyze - no support values in pre-pruning tree\n")
  nodes_below_threshold <- NA
}

cat("\n")

# =============================================================================
# STEP 4: Count Polytomies (Multi-way Splits)
# =============================================================================
cat("[Step 4] Counting polytomies (nodes with >2 children)...\n")

count_polytomies <- function(tree) {
  # Count children per parent node
  edge_table <- table(tree$edge[,1])
  # Polytomies are nodes with >2 children
  return(sum(edge_table > 2))
}

polytomies_pre <- count_polytomies(tree_pre)
polytomies_post <- count_polytomies(tree_post)

cat("  Pre-pruning:  ", polytomies_pre, " polytomies\n")
cat("  Post-pruning: ", polytomies_post, " polytomies\n")
cat("  Change:       ", polytomies_post - polytomies_pre, 
    ifelse(polytomies_post > polytomies_pre, " (INCREASED)", 
           ifelse(polytomies_post < polytomies_pre, " (DECREASED)", " (NO CHANGE)")), 
    "\n")

cat("\n")

# =============================================================================
# STEP 5: Topology Comparison
# =============================================================================
cat("[Step 5] Comparing tree topologies...\n")

# Compare tree structures using all.equal
topology_comparison <- all.equal.phylo(tree_pre, tree_post, 
                                       use.edge.length = FALSE,
                                       use.tip.label = TRUE)

if (isTRUE(topology_comparison)) {
  cat("  RESULT: Trees are TOPOLOGICALLY IDENTICAL\n")
  cat("          No structural changes detected\n")
} else {
  cat("  RESULT: Trees differ in topology\n")
  cat("  Differences:\n")
  for (diff in topology_comparison) {
    cat("    - ", diff, "\n")
  }
}

# Check if trees are byte-for-byte identical
tree_pre_newick <- write.tree(tree_pre)
tree_post_newick <- write.tree(tree_post)

if (identical(tree_pre_newick, tree_post_newick)) {
  cat("  Newick strings: IDENTICAL (byte-for-byte match)\n")
} else {
  cat("  Newick strings: DIFFERENT\n")
  
  # Find where they differ
  n_chars <- min(nchar(tree_pre_newick), nchar(tree_post_newick))
  first_diff <- which(strsplit(tree_pre_newick, "")[[1]][1:n_chars] != 
                      strsplit(tree_post_newick, "")[[1]][1:n_chars])[1]
  
  if (!is.na(first_diff) && first_diff <= 100) {
    cat("    First difference at character ", first_diff, ":\n")
    cat("      Pre:  ...", substr(tree_pre_newick, max(1, first_diff-20), first_diff+20), "...\n")
    cat("      Post: ...", substr(tree_post_newick, max(1, first_diff-20), first_diff+20), "...\n")
  }
}

cat("\n")

# =============================================================================
# STEP 6: Expected vs Actual Pruning
# =============================================================================
cat("[Step 6] Expected vs actual pruning outcomes...\n")

if (!is.null(support_pre) && !is.na(nodes_below_threshold)) {
  cat("  EXPECTED: ", nodes_below_threshold, " nodes should be collapsed (support < ", 
      support_threshold, ")\n", sep = "")
  cat("  EXPECTED: ", nodes_below_threshold, " new polytomies created\n")
  cat("  EXPECTED: Internal node count should decrease by ~", nodes_below_threshold, "\n")
  cat("\n")
  
  cat("  ACTUAL:   ", polytomies_post - polytomies_pre, " new polytomies\n")
  cat("  ACTUAL:   Internal node count changed by ", tree_post$Nnode - tree_pre$Nnode, "\n")
  cat("\n")
  
  # Diagnosis
  if (polytomies_post == polytomies_pre && nodes_below_threshold > 0) {
    cat("  *** POTENTIAL BUG DETECTED ***\n")
    cat("  Expected ", nodes_below_threshold, " nodes to be pruned, but no polytomies created!\n")
    cat("  This suggests the pruning function did NOT execute correctly.\n")
  } else if (polytomies_post - polytomies_pre < nodes_below_threshold * 0.5) {
    cat("  *** POTENTIAL ISSUE ***\n")
    cat("  Fewer polytomies created than expected.\n")
    cat("  Expected ~", nodes_below_threshold, ", got ", polytomies_post - polytomies_pre, "\n")
  } else if (nodes_below_threshold == 0 && polytomies_post == polytomies_pre) {
    cat("  ✓ PRUNING NOT NEEDED\n")
    cat("  All nodes have support >= ", support_threshold, " - no pruning required.\n")
  } else {
    cat("  ✓ PRUNING APPEARS CORRECT\n")
    cat("  Polytomy increase (", polytomies_post - polytomies_pre, 
        ") is consistent with low-support nodes (", nodes_below_threshold, ")\n")
  }
} else {
  cat("  Cannot evaluate - missing support values\n")
}

cat("\n")

# =============================================================================
# STEP 7: Detailed Node-by-Node Analysis
# =============================================================================
cat("[Step 7] Detailed node-by-node analysis...\n")

if (!is.null(support_pre)) {
  # Create node analysis table
  node_analysis <- data.frame(
    Node_ID = seq_along(support_pre),
    Support_Pre = support_pre,
    Below_Threshold = support_pre < support_threshold,
    stringsAsFactors = FALSE
  )
  
  # Add post-pruning support if available
  if (!is.null(support_post) && length(support_post) == length(support_pre)) {
    node_analysis$Support_Post <- support_post
    node_analysis$Support_Changed <- abs(support_pre - support_post) > 0.001
  }
  
  # Show low-support nodes
  low_support_nodes <- node_analysis[which(node_analysis$Below_Threshold), ]
  
  if (nrow(low_support_nodes) > 0) {
    cat("  Low-support nodes (should be pruned):\n")
    cat("\n")
    print(head(low_support_nodes, 20), row.names = FALSE)
    
    if (nrow(low_support_nodes) > 20) {
      cat("  ... (", nrow(low_support_nodes) - 20, " more nodes not shown)\n")
    }
  } else {
    cat("  No nodes below threshold - all nodes have sufficient support\n")
  }
  
  # Save full analysis to file
  output_file <- file.path(output_dir, "pruning_diagnostic_nodes.tsv")
  write.table(node_analysis, output_file, sep = "\t", row.names = FALSE, quote = FALSE)
  cat("\n")
  cat("  Full node analysis saved to: ", output_file, "\n")
} else {
  cat("  Cannot perform node-by-node analysis - no support values\n")
}

cat("\n")

# =============================================================================
# STEP 8: Check for Optimal Hyperparameters
# =============================================================================
cat("[Step 8] Checking for optimal hyperparameters...\n")

# Look for cor_dat_all.tsv which may contain optimal threshold
cor_dat_file <- file.path(output_dir, "cor_dat_all.tsv")

if (file.exists(cor_dat_file)) {
  cor_dat <- tryCatch({
    read.table(cor_dat_file, header = TRUE, stringsAsFactors = FALSE, sep = "\t")
  }, error = function(e) {
    NULL
  })
  
  if (!is.null(cor_dat) && nrow(cor_dat) > 0) {
    cat("  Found cor_dat_all.tsv with ", nrow(cor_dat), " rows\n")
    cat("  Columns: ", paste(colnames(cor_dat), collapse = ", "), "\n")
    
    # Check if it has support threshold info (typically in column 5)
    if (ncol(cor_dat) >= 5) {
      cat("  First row values (may contain optimal parameters):\n")
      cat("    ", paste(cor_dat[1, 1:min(5, ncol(cor_dat))], collapse = " | "), "\n")
    }
  } else {
    cat("  cor_dat_all.tsv found but could not be parsed\n")
  }
} else {
  cat("  cor_dat_all.tsv not found (not used in this pipeline version)\n")
}

# Check SLURM logs for actual threshold used
log_files <- list.files(file.path(dirname(output_dir), "logs"), 
                        pattern = "step4.*\\.out$", full.names = TRUE)

if (length(log_files) > 0) {
  # Get most recent log
  latest_log <- log_files[which.max(file.info(log_files)$mtime)]
  cat("\n")
  cat("  Checking Step 4 log: ", basename(latest_log), "\n")
  
  log_content <- readLines(latest_log, n = 50)
  threshold_line <- grep("Support threshold", log_content, value = TRUE)
  
  if (length(threshold_line) > 0) {
    cat("  ", threshold_line[1], "\n")
  }
} else {
  cat("\n")
  cat("  Step 4 logs not found - cannot verify threshold from logs\n")
}

cat("\n")

# =============================================================================
# STEP 9: Summary and Recommendations
# =============================================================================
cat("================================================================================\n")
cat("SUMMARY AND RECOMMENDATIONS\n")
cat("================================================================================\n")

cat("\n")
cat("KEY FINDINGS:\n")
cat("-------------\n")
cat("1. Support threshold:        ", support_threshold, "\n")
cat("2. Nodes below threshold:    ", ifelse(is.na(nodes_below_threshold), "N/A", nodes_below_threshold), "\n")
cat("3. Polytomies created:       ", polytomies_post - polytomies_pre, "\n")
cat("4. Topology identical:       ", isTRUE(topology_comparison), "\n")
cat("5. Internal node count:      ", tree_pre$Nnode, " -> ", tree_post$Nnode, 
    " (", ifelse(tree_post$Nnode == tree_pre$Nnode, "NO CHANGE", 
                paste(tree_post$Nnode - tree_pre$Nnode, "change")), ")\n")

cat("\n")
cat("INTERPRETATION:\n")
cat("---------------\n")

if (!is.null(support_pre) && !is.na(nodes_below_threshold)) {
  if (nodes_below_threshold == 0) {
    cat("✓ All nodes have support >= ", support_threshold, "\n")
    cat("✓ No pruning required - tree is already well-supported\n")
    cat("✓ Pre and post-pruning trees should be identical or nearly identical\n")
  } else if (polytomies_post == polytomies_pre) {
    cat("✗ PRUNING FAILURE DETECTED\n")
    cat("  - ", nodes_below_threshold, " nodes should have been pruned\n")
    cat("  - No polytomies were created\n")
    cat("  - Possible causes:\n")
    cat("    1. as_polytomy! function not executed\n")
    cat("    2. Function parameters incorrect\n")
    cat("    3. Tree format incompatibility\n")
    cat("  - Recommendation: Check Step 4 Julia pruning logs for errors\n")
  } else if (abs((polytomies_post - polytomies_pre) - nodes_below_threshold) <= 2) {
    cat("✓ Pruning appears to have worked correctly\n")
    cat("  - ", polytomies_post - polytomies_pre, " polytomies created (expected ~", 
        nodes_below_threshold, ")\n")
    cat("  - Low-support nodes were collapsed as expected\n")
  } else {
    cat("? Pruning results unclear\n")
    cat("  - Expected ~", nodes_below_threshold, " polytomies\n")
    cat("  - Got ", polytomies_post - polytomies_pre, " polytomies\n")
    cat("  - May indicate complex pruning pattern (e.g., nested low-support nodes)\n")
  }
} else {
  cat("Cannot interpret - missing support values in tree files\n")
}

cat("\n")
cat("Note: Internal node count differences between pre/post trees may be artifacts\n")
cat("      of different label formats (support values vs integer IDs). Focus on\n")
cat("      polytomy count as the primary metric for successful pruning.\n")

cat("\n")
cat("================================================================================\n")
cat("DIAGNOSTIC COMPLETE\n")
cat("================================================================================\n")
