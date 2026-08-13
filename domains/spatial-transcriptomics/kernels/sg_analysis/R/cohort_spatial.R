#!/usr/bin/env Rscript
#
# TumorSPACE: Cohort SGP Spot Labeling
#
# Maps candidate SGP programs from the K-sweep (cohort_ksweep.R) back to
# individual barcodes via the SmallerNodeLabel join, producing a flat
# per-spot classification table for visualization.
#
# Adapts KL_KSweepSpatial_v1.R (HGSOC_SpatialTranscriptomics_Odunsi).
#
# Classification logic:
#   Uses the pre-computed U matrix (svd_u.tsv) — no re-projection required.
#   For candidate programs in ascending order of peak_K, assign sg_label via
#   argmax(|U|) restricted to batch-clean SVs 1..K. Higher-K passes overwrite
#   lower-K (higher-K programs take priority).
#
#   SG → Barcode mapping (mirrors KL_KSweepSpatial_v1.R sections 2e–2g):
#     1. Load OptimalTree_pruned_node_info.txt; self-join to get leaf counts
#        for both Node and Sibling.
#     2. SmallerNodeLabel = Node if Node_Leafs < Sibling_Leafs, else Sibling.
#     3. Join allnodes_leaves.tsv on Node = SmallerNodeLabel → barcodes + coords.
#
# Inputs (from out_dir, produced by cohort_ksweep.R):
#   da_cast_meta.tsv               — SampleID, Node, Sibling row order
#   svd_u.tsv                      — U matrix (header: U1..UN)
#   sv_ksweep_all_svs.tsv          — K-sweep results
#   sv_depth_independent_test.tsv  — to re-identify site-associated SVs
#
# Per-sample TumorSPACE outputs (read from base_dir/{canonical_dir}/optimal/):
#   OptimalTree_pruned_node_info.txt — Node, N_Leafs, Parent, Sibling, Num_Siblings
#   allnodes_leaves.tsv              — Node, Leaf, barcode, array_row, array_col,
#                                      pxl_row_in_mm, pxl_col_in_mm
#
# Output:
#   out_dir/spot_sv_labels.tsv — SampleID, group, barcode, array_row, array_col,
#                                 pxl_row_in_mm, pxl_col_in_mm, sv_label
#
# Dependencies: data.table only.
#
# Source this file to load all functions; call run_cohort_spatial() to execute.

suppressPackageStartupMessages(library(data.table))

# ---------------------------------------------------------------------------
# 1. Identify candidate programs and their peak Ks
# ---------------------------------------------------------------------------

identify_candidates <- function(out_dir,
                                p_group_candidate = 0.10,
                                p_site_threshold  = 0.10) {
  all_svs  <- fread(file.path(out_dir, "sv_ksweep_all_svs.tsv"))
  sv_test  <- fread(file.path(out_dir, "sv_depth_independent_test.tsv"))

  site_svs <- sv_test[!is.na(P_site) & P_site < p_site_threshold, SV]
  message(sprintf("Site-associated SVs (P_site < %.2f): {%s}",
                  p_site_threshold,
                  if (length(site_svs)) paste(sort(site_svs), collapse = ",")
                  else "none"))

  # Best (minimum P_group) peak K for each SV_Signed
  peak_dt  <- all_svs[, .SD[which.min(P_group)], by = SV_Signed]
  # Among non-site SVs: best SV_Signed per SV number
  sv_best  <- peak_dt[!(SV %in% site_svs), .SD[which.min(P_group)], by = SV]
  cands    <- sv_best[P_group < p_group_candidate,
                      .(SV_Signed, SV, peak_K = K, P_group)]
  setorder(cands, peak_K, SV_Signed)

  if (nrow(cands) == 0) {
    message("No candidate programs found.")
  } else {
    message(sprintf("%d candidate program(s):", nrow(cands)))
    for (i in seq_len(nrow(cands)))
      message(sprintf("  %-12s  peak_K=%d  P_group=%.4f",
                      cands$SV_Signed[i], cands$peak_K[i], cands$P_group[i]))
  }

  list(cands = cands, site_svs = site_svs)
}

# ---------------------------------------------------------------------------
# 2. Classify SG pairs: ascending-K overwrite (KL_KSweepSpatial_v1.R §3)
# ---------------------------------------------------------------------------

classify_sgs <- function(out_dir, cands, site_svs, n_load = 30L) {
  cast_meta <- fread(file.path(out_dir, "da_cast_meta.tsv"))

  u_mat <- as.matrix(
    fread(file.path(out_dir, "svd_u.tsv"),
          select = seq_len(n_load), header = TRUE)
  )

  sg_dt <- copy(cast_meta)
  sg_dt[, sg_label := "Other"]

  unique_Ks <- sort(unique(cands$peak_K))
  message(sprintf("Classifying SGs across peak Ks: %s",
                  paste(unique_Ks, collapse = ", ")))

  for (K_val in unique_Ks) {
    clean_svs_k <- setdiff(seq_len(K_val), site_svs)
    mat_k       <- u_mat[, clean_svs_k, drop = FALSE]
    best_pos    <- max.col(abs(mat_k), ties.method = "first")
    best_sv     <- clean_svs_k[best_pos]
    best_val    <- mat_k[cbind(seq_len(nrow(mat_k)), best_pos)]
    best_signed <- paste0(best_sv, ifelse(best_val > 0, "_Pos", "_Neg"))

    cands_at_K <- cands[peak_K == K_val, SV_Signed]
    hit        <- best_signed %in% cands_at_K
    sg_dt[hit, sg_label := best_signed[hit]]

    message(sprintf("  K=%2d: %4d SGs labeled -> {%s}",
                    K_val, sum(hit), paste(cands_at_K, collapse = ", ")))
  }

  n_lab <- sum(sg_dt$sg_label != "Other")
  message(sprintf("%d / %d SGs labeled (%.1f%%)",
                  n_lab, nrow(sg_dt), 100 * n_lab / nrow(sg_dt)))
  sg_dt
}

# ---------------------------------------------------------------------------
# 3. Per-sample: SG labels → barcodes → spot coordinates
#    Mirrors KL_KSweepSpatial_v1.R sections 2e–2g
# ---------------------------------------------------------------------------

map_sgs_to_spots <- function(sg_dt, manifest, base_dir) {
  results_list <- vector("list", nrow(manifest))

  for (i in seq_len(nrow(manifest))) {
    sid     <- manifest$sample_id[i]
    cdir    <- manifest$canonical_dir[i]
    grp     <- manifest$group[i]
    opt_dir <- file.path(base_dir, cdir, "optimal")

    message(sprintf("\n  [%d/%d] %s ...", i, nrow(manifest), sid))

    node_path   <- file.path(opt_dir, "OptimalTree_pruned_node_info.txt")
    leaves_path <- file.path(opt_dir, "allnodes_leaves.tsv")

    if (!file.exists(node_path) || !file.exists(leaves_path)) {
      warning(sprintf("    Missing tree files for %s in %s — skipping", sid, opt_dir))
      next
    }

    # Node info: self-join to get leaf counts for both Node and Sibling
    node_info <- fread(node_path,
                       select = c("Node", "N_Leafs", "Sibling"),
                       showProgress = FALSE)
    # Ensure character keys for robust joining
    node_info[, Node    := as.character(Node)]
    node_info[, Sibling := as.character(Sibling)]

    sg_list <- merge(
      node_info[, .(Node, Node_Leafs = N_Leafs, Sibling)],
      node_info[, .(Sibling = Node, Sibling_Leafs = N_Leafs)],
      by = "Sibling"
    )
    # SmallerNodeLabel = Node if Node_Leafs < Sibling_Leafs, else Sibling
    sg_list[, SmallerNodeLabel := fifelse(
      !is.na(Node_Leafs) & Node_Leafs < Sibling_Leafs,
      Node, Sibling
    )]

    # allnodes_leaves: Node here is the internal comparison node
    sg_leaves <- fread(leaves_path,
                       select = c("Node", "barcode",
                                  "array_row", "array_col",
                                  "pxl_row_in_mm", "pxl_col_in_mm"),
                       showProgress = FALSE)
    sg_leaves[, Node := as.character(Node)]

    # SG labels for this sample
    sg_sample <- sg_dt[SampleID == sid, .(Node, Sibling, sg_label)]
    if (nrow(sg_sample) == 0) {
      warning(sprintf("    No SG entries in U matrix for %s — skipping", sid))
      next
    }
    # Ensure character keys match
    sg_sample[, Node    := as.character(Node)]
    sg_sample[, Sibling := as.character(Sibling)]

    # Join: (Node, Sibling) → SmallerNodeLabel
    sg_meta <- merge(sg_sample,
                     sg_list[, .(Node, Sibling, SmallerNodeLabel)],
                     by = c("Node", "Sibling"), all.x = TRUE)

    # Join: SmallerNodeLabel → barcodes
    sg_bc <- merge(
      sg_meta[, .(SmallerNodeLabel, sg_label)],
      sg_leaves[, .(SmallerNodeLabel = Node,
                    barcode, array_row, array_col,
                    pxl_row_in_mm, pxl_col_in_mm)],
      by = "SmallerNodeLabel", all.x = TRUE, allow.cartesian = TRUE
    )
    sg_bc <- sg_bc[!is.na(barcode)]

    # One label per barcode — first-assignment wins for any duplicates
    bc_unique <- unique(sg_bc[, .(barcode, sg_label,
                                   array_row, array_col,
                                   pxl_row_in_mm, pxl_col_in_mm)],
                        by = "barcode")

    n_cls    <- sum(bc_unique$sg_label != "Other")
    n_total  <- nrow(bc_unique)
    message(sprintf("    %d / %d barcodes classified (%.1f%%)",
                    n_cls, n_total,
                    100 * n_cls / max(n_total, 1L)))

    # Per candidate count
    cand_tab <- bc_unique[sg_label != "Other", .N, by = sg_label][order(-N)]
    if (nrow(cand_tab) > 0)
      message(sprintf("    Distribution: %s",
                      paste(paste0(cand_tab$sg_label, "=", cand_tab$N),
                            collapse = ", ")))

    bc_unique[, SampleID := sid]
    bc_unique[, group    := grp]
    results_list[[i]] <- bc_unique
  }

  out <- rbindlist(Filter(Negate(is.null), results_list), use.names = TRUE)
  setnames(out, "sg_label", "sv_label")
  setcolorder(out, c("SampleID", "group", "barcode",
                     "array_row", "array_col",
                     "pxl_row_in_mm", "pxl_col_in_mm", "sv_label"))
  out
}

# ---------------------------------------------------------------------------
# Master function
# ---------------------------------------------------------------------------

#' Run cohort-level spot labeling from SGP K-sweep results
#'
#' Must be called after run_cohort_ksweep() has written results to out_dir.
#'
#' @param manifest          data.table with cols: sample_id, canonical_dir, site, group
#' @param base_dir          base path containing {canonical_dir}/optimal/
#' @param out_dir           same out_dir used by run_cohort_ksweep()
#' @param n_load            number of SVs loaded from svd_u.tsv (must match ksweep run)
#' @param p_group_candidate P_group threshold for candidate programs
#' @param p_site_threshold  P_site threshold for site-associated SV exclusion
run_cohort_spatial <- function(manifest, base_dir, out_dir,
                                n_load            = 30L,
                                p_group_candidate = 0.10,
                                p_site_threshold  = 0.10) {
  stopifnot(all(c("sample_id", "canonical_dir", "group") %in% names(manifest)))
  required_inputs <- c("da_cast_meta.tsv", "svd_u.tsv",
                        "sv_ksweep_all_svs.tsv",
                        "sv_depth_independent_test.tsv")
  missing <- required_inputs[!file.exists(file.path(out_dir, required_inputs))]
  if (length(missing) > 0)
    stop(sprintf("run_cohort_ksweep() outputs not found in %s: %s",
                 out_dir, paste(missing, collapse = ", ")))

  message("\n=== run_cohort_spatial ===")

  message("\n--- Step 5: Identify candidate programs ---")
  res <- identify_candidates(out_dir, p_group_candidate, p_site_threshold)

  if (nrow(res$cands) == 0) {
    message("No candidates — spot_sv_labels.tsv will not be written.")
    return(invisible(NULL))
  }

  message("\n--- Step 6: Classify SG pairs (ascending-K overwrite) ---")
  sg_dt <- classify_sgs(out_dir, res$cands, res$site_svs, n_load)

  message("\n--- Step 7: Map SG labels to spot barcodes ---")
  spots <- map_sgs_to_spots(sg_dt, manifest, base_dir)

  out_path <- file.path(out_dir, "spot_sv_labels.tsv")
  fwrite(spots, out_path, sep = "\t", quote = FALSE)
  message(sprintf("\nOutput: %s  (%d rows)", out_path, nrow(spots)))

  tab <- spots[, .N, by = sv_label][order(-N)]
  message("Label distribution:")
  for (j in seq_len(nrow(tab)))
    message(sprintf("  %-15s %6d  (%.2f%%)",
                    tab$sv_label[j], tab$N[j],
                    100 * tab$N[j] / nrow(spots)))

  message("\n=== run_cohort_spatial complete ===")
  invisible(spots)
}
