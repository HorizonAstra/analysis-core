#!/usr/bin/env Rscript
#
# TumorSPACE: Cohort SGP K-Sweep — batch-unbiased spatial program discovery
#
# Adapts KL_SVDepth_v1.R + KL_KSweep_v2.R (HGSOC_SpatialTranscriptomics_Odunsi)
# to multi-group cohorts with an arbitrary batch/site covariate.
#
# Two-phase design (mirrors the HGSOC implementation):
#
#   Phase 1 — Independent SV depth test (KL_SVDepth_v1.R analog):
#     For each SV k=1..N_LOAD, compute per-sample mean U_k loading, then test:
#       - Site/batch association: Wilcoxon(site_A vs site_B)
#       - Group association: KW(groups) + all pairwise Wilcoxon
#     Output: sv_depth_independent_test.tsv
#
#   Phase 2 — Batch-unbiased K-sweep (KL_KSweep_v2.R analog):
#     For K = k_min..k_max: mask site-associated SVs (P_site < threshold),
#     classify each SG pair to its dominant clean SV via argmax(|U|),
#     compute per-sample fractions, then test KW(groups) + pairwise Wilcoxon.
#     Output: sv_ksweep_all_svs.tsv, sv_ksweep_top_group.tsv, sv_ksweep_persample.tsv
#
# Inputs (via manifest data.table):
#   manifest: required cols: sample_id, canonical_dir, site, group
#   base_dir: base path containing {canonical_dir}/optimal/gene/DA_significant.txt
#
# Outputs (written to out_dir/):
#   da_cast_meta.tsv               — SampleID, Node, Sibling row order for U matrix
#   gene_names.tsv                 — gene column names for binary matrix
#   svd_u.tsv                      — first N_LOAD cols of U matrix (header: U1..UN)
#   svd_v.tsv                      — first N_LOAD cols of V matrix (header: V1..VN)
#   svd_d.tsv                      — full singular value vector
#   sv_depth_independent_test.tsv  — per-SV Phase 1 test results
#   sv_ksweep_all_svs.tsv          — all K-sweep SV_Signed program results
#   sv_ksweep_top_group.tsv        — best P_group program per K
#   sv_ksweep_persample.tsv        — per-sample fractions for candidate programs
#
# Dependencies: data.table only (no other packages required)
#
# Source this file to load all functions; call run_cohort_ksweep() to execute.

suppressPackageStartupMessages(library(data.table))

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

.wilcox_auroc <- function(a, b) {
  if (length(a) < 2 || length(b) < 2)
    return(list(n_A  = length(a), n_B  = length(b),
                med_A = if (length(a) > 0) median(a) else NA_real_,
                med_B = if (length(b) > 0) median(b) else NA_real_,
                W = NA_real_, P = NA_real_, AUROC = NA_real_))
  wt <- wilcox.test(a, b, exact = FALSE)
  list(n_A   = length(a),
       n_B   = length(b),
       med_A = median(a),
       med_B = median(b),
       W     = as.numeric(wt$statistic),
       P     = wt$p.value,
       AUROC = as.numeric(wt$statistic) / (length(a) * length(b)))
}

.kruskal_p <- function(values, groups) {
  grp <- factor(groups)
  if (nlevels(grp) < 2) return(NA_real_)
  tryCatch(kruskal.test(values ~ grp)$p.value, error = function(e) NA_real_)
}

# Compute all unique pairwise Wilcoxon tests; returns a flat named list
# suitable for cbinding into a data.table row.
.pairwise_tests <- function(values, groups, group_levels) {
  pairs  <- combn(group_levels, 2, simplify = FALSE)
  result <- list()
  for (p in pairs) {
    tag  <- paste0(p[1], "_vs_", p[2])
    a    <- values[groups == p[1]]
    b    <- values[groups == p[2]]
    w    <- .wilcox_auroc(a, b)
    result[[paste0("P_",     tag)]] <- w$P
    result[[paste0("AUROC_", tag)]] <- round(w$AUROC, 4)
    result[[paste0("med_",   p[1], "_", tag)]] <- round(w$med_A, 5)
    result[[paste0("med_",   p[2], "_", tag)]] <- round(w$med_B, 5)
  }
  result
}

# ---------------------------------------------------------------------------
# 1. Build SG binary matrix
# ---------------------------------------------------------------------------

build_sg_binary_matrix <- function(manifest, base_dir,
                                   da_file   = "gene/DA_significant.txt",
                                   q_string  = "< 0.05") {
  message(sprintf("Loading DA files for %d samples ...", nrow(manifest)))

  all_da <- rbindlist(lapply(seq_len(nrow(manifest)), function(i) {
    sid  <- manifest$sample_id[i]
    cdir <- manifest$canonical_dir[i]
    path <- file.path(base_dir, cdir, "optimal", da_file)
    if (!file.exists(path)) {
      warning(sprintf("  [%s] DA file not found: %s", sid, path))
      return(NULL)
    }
    dt <- fread(path, showProgress = FALSE)
    dt <- dt[Q == q_string]
    if (nrow(dt) == 0) {
      warning(sprintf("  [%s] No DA genes at Q == '%s'", sid, q_string))
      return(NULL)
    }
    dt[, SampleID := sid]
    dt[, .(SampleID, Node = as.character(Node),
           Sibling  = as.character(Sibling),
           DA_Object)]
  }), use.names = TRUE)

  if (is.null(all_da) || nrow(all_da) == 0)
    stop("No DA genes found across any sample — cannot build binary matrix.")

  n_samp <- uniqueN(all_da$SampleID)
  message(sprintf("  %d DA gene-SG entries from %d / %d samples",
                  nrow(all_da), n_samp, nrow(manifest)))

  # Presence/absence cast: rows = (SampleID, Node, Sibling), cols = genes
  all_da[, value := 1L]
  cast_dt <- dcast(all_da, SampleID + Node + Sibling ~ DA_Object,
                   value.var = "value", fill = 0L)

  meta_dt   <- cast_dt[, .(SampleID, Node, Sibling)]
  gene_cols <- setdiff(names(cast_dt), c("SampleID", "Node", "Sibling"))
  bin_mat   <- as.matrix(cast_dt[, ..gene_cols])

  sparsity <- 100 * mean(bin_mat == 0)
  message(sprintf("  Binary matrix: %d SG pairs x %d genes (sparsity %.1f%%)",
                  nrow(bin_mat), ncol(bin_mat), sparsity))

  list(binary_matrix = bin_mat, cast_meta = meta_dt, gene_names = gene_cols)
}

# ---------------------------------------------------------------------------
# 2. SVD + save
# ---------------------------------------------------------------------------

run_svd <- function(binary_matrix, out_dir, n_load = 30L) {
  message(sprintf("Running SVD on %d x %d matrix ...",
                  nrow(binary_matrix), ncol(binary_matrix)))
  sv     <- svd(binary_matrix)
  n_save <- min(n_load, length(sv$d))
  message(sprintf("  SVD complete. Saving first %d components.", n_save))

  u_dt <- as.data.table(sv$u[, seq_len(n_save)])
  setnames(u_dt, paste0("U", seq_len(n_save)))
  v_dt <- as.data.table(sv$v[, seq_len(n_save)])
  setnames(v_dt, paste0("V", seq_len(n_save)))

  fwrite(u_dt, file.path(out_dir, "svd_u.tsv"), sep = "\t", quote = FALSE)
  fwrite(v_dt, file.path(out_dir, "svd_v.tsv"), sep = "\t", quote = FALSE)
  fwrite(data.table(d = sv$d),
         file.path(out_dir, "svd_d.tsv"), sep = "\t", quote = FALSE)

  list(u = sv$u, v = sv$v, d = sv$d, n_save = n_save)
}

# ---------------------------------------------------------------------------
# 3. Phase 1 — independent per-SV depth test (KL_SVDepth_v1.R analog)
# ---------------------------------------------------------------------------

sv_depth_test <- function(u_full, cast_meta, manifest, n_load, out_dir) {
  message(sprintf("Phase 1: independent per-SV tests (N_LOAD=%d) ...", n_load))

  d_vec    <- fread(file.path(out_dir, "svd_d.tsv"))[[1]]
  var_expl <- (d_vec^2 / sum(d_vec^2)) * 100

  n_sv <- min(n_load, ncol(u_full))

  # Per-sample mean U_k loading for each SV
  u_dt <- as.data.table(u_full[, seq_len(n_sv)])
  setnames(u_dt, paste0("U", seq_len(n_sv)))
  u_dt[, SampleID := cast_meta$SampleID]
  u_means <- u_dt[, lapply(.SD, mean), by = SampleID, .SDcols = paste0("U", seq_len(n_sv))]
  u_means <- merge(u_means,
                   manifest[, .(SampleID = sample_id, site, group)],
                   by = "SampleID", all.x = TRUE)

  group_levels <- sort(unique(u_means$group))
  site_levels  <- sort(unique(u_means$site))

  sv_tests <- rbindlist(lapply(seq_len(n_sv), function(k) {
    col    <- paste0("U", k)
    vals   <- u_means[[col]]
    grps   <- u_means$group
    sts    <- u_means$site

    p_group <- .kruskal_p(vals, grps)
    pw      <- .pairwise_tests(vals, grps, group_levels)

    s1      <- vals[sts == site_levels[1]]
    s2      <- vals[sts == site_levels[2]]
    stest   <- .wilcox_auroc(s1, s2)

    row <- data.table(
      SV          = k,
      VarExpl_Pct = round(var_expl[k], 3),
      P_group     = p_group,
      P_site      = stest$P,
      AUROC_site  = round(stest$AUROC, 4)
    )
    cbind(row, as.data.table(pw))
  }))
  setorder(sv_tests, P_group)

  fwrite(sv_tests, file.path(out_dir, "sv_depth_independent_test.tsv"),
         sep = "\t", quote = FALSE)

  site_svs <- sv_tests[!is.na(P_site) & P_site < 0.10, SV]
  message(sprintf("  -> sv_depth_independent_test.tsv (%d SVs)", nrow(sv_tests)))
  message(sprintf("  Site-associated SVs (P_site < 0.10): {%s}",
                  if (length(site_svs)) paste(sort(site_svs), collapse = ",")
                  else "none"))

  sv_tests
}

# ---------------------------------------------------------------------------
# 4. Phase 2 — batch-unbiased K-sweep (KL_KSweep_v2.R analog)
# ---------------------------------------------------------------------------

ksweep <- function(u_full, cast_meta, manifest, sv_tests,
                   k_min, k_max, p_site_threshold, p_group_candidate, n_load,
                   out_dir) {
  message(sprintf("Phase 2: K-sweep K=%d..%d (P_site threshold=%.2f) ...",
                  k_min, k_max, p_site_threshold))

  d_vec    <- fread(file.path(out_dir, "svd_d.tsv"))[[1]]
  var_expl <- (d_vec^2 / sum(d_vec^2)) * 100

  n_sv  <- min(n_load, ncol(u_full))
  abs_u <- abs(u_full[, seq_len(n_sv)])

  meta <- merge(data.table(SampleID = cast_meta$SampleID),
                manifest[, .(SampleID = sample_id, site, group)],
                by = "SampleID", all.x = TRUE)

  group_levels <- sort(unique(meta$group))
  site_levels  <- sort(unique(meta$site))

  site_svs_all <- sv_tests[!is.na(P_site) & P_site < p_site_threshold, SV]
  message(sprintf("  Site SVs excluded at any K: {%s}",
                  if (length(site_svs_all)) paste(sort(site_svs_all), collapse = ",")
                  else "none"))

  all_k_results <- vector("list", k_max - k_min + 1L)
  all_freq_list  <- vector("list", k_max - k_min + 1L)

  for (K in seq(k_min, k_max)) {
    site_svs_k  <- sv_tests[SV %in% seq_len(K) & !is.na(P_site) &
                              P_site < p_site_threshold, SV]
    clean_svs_k <- setdiff(seq_len(K), site_svs_k)

    if (length(clean_svs_k) == 0) {
      message(sprintf("  K=%2d | WARNING: all %d SVs are site-associated — skipping", K, K))
      next
    }

    # Mask site SVs with -Inf so argmax never selects them
    abs_u_k <- abs_u[, seq_len(K), drop = FALSE]
    if (length(site_svs_k) > 0) abs_u_k[, site_svs_k] <- -Inf

    best_k      <- max.col(abs_u_k, ties.method = "first")
    best_v      <- u_full[cbind(seq_len(nrow(u_full)), best_k)]
    sg_class    <- data.table(
      SampleID  = cast_meta$SampleID,
      SV_Signed = paste0(best_k, "_", fifelse(best_v > 0, "Pos", "Neg"))
    )

    # Verify no SG classified into a site SV
    stopifnot(!any(sg_class$SV_Signed %in%
                   paste0(rep(site_svs_k, each = 2L), "_", c("Pos", "Neg"))))

    # Per-sample fractions (zero-fill absent SV_Signed per sample)
    freq <- sg_class[, .N, by = .(SampleID, SV_Signed)]
    freq <- merge(freq, freq[, .(Total = sum(N)), by = SampleID], by = "SampleID")
    freq[, Frac := N / Total]
    freq_save      <- copy(freq); freq_save[, K := K]
    all_freq_list[[K - k_min + 1L]] <- freq_save

    sv_levels <- freq[, .(n_SGs = sum(N)), by = SV_Signed][order(-n_SGs), SV_Signed]

    k_tests <- rbindlist(lapply(sv_levels, function(sg) {
      ps <- merge(meta[, .(SampleID, site, group)],
                  freq[SV_Signed == sg, .(SampleID, Frac)],
                  by = "SampleID", all.x = TRUE)
      ps[is.na(Frac), Frac := 0]

      p_group <- .kruskal_p(ps$Frac, ps$group)
      pw      <- .pairwise_tests(ps$Frac, ps$group, group_levels)

      s1      <- ps[site == site_levels[1], Frac]
      s2      <- ps[site == site_levels[2], Frac]
      stest   <- .wilcox_auroc(s1, s2)

      row <- data.table(
        K               = K,
        SV_Signed       = sg,
        SV              = as.integer(sub("_.*", "", sg)),
        n_SGs           = freq[SV_Signed == sg, sum(N)],
        n_site_excluded = length(site_svs_k),
        clean_svs       = paste(sort(clean_svs_k), collapse = ","),
        VarExpl_Pct     = round(var_expl[as.integer(sub("_.*", "", sg))], 3),
        P_group         = p_group,
        P_site          = stest$P,
        AUROC_site      = round(stest$AUROC, 4)
      )
      cbind(row, as.data.table(pw))
    }))

    setorder(k_tests, P_group)
    all_k_results[[K - k_min + 1L]] <- k_tests

    message(sprintf("  K=%2d | excl={%s} | best: %-10s  P_group=%.4f  P_site=%.4f  n_SGs=%d",
                    K,
                    paste(sort(site_svs_k), collapse = ","),
                    k_tests$SV_Signed[1], k_tests$P_group[1],
                    k_tests$P_site[1],    k_tests$n_SGs[1]))
  }

  all_k_dt   <- rbindlist(Filter(Negate(is.null), all_k_results), fill = TRUE)
  all_freq_dt <- rbindlist(Filter(Negate(is.null), all_freq_list))

  fwrite(all_k_dt,   file.path(out_dir, "sv_ksweep_all_svs.tsv"),
         sep = "\t", quote = FALSE)

  top_group <- all_k_dt[, .SD[which.min(P_group)], by = K]
  fwrite(top_group, file.path(out_dir, "sv_ksweep_top_group.tsv"),
         sep = "\t", quote = FALSE)

  # Candidates: best peak P_group per SV_Signed, not site-associated, below threshold
  cand_peak <- all_k_dt[, .SD[which.min(P_group)], by = SV_Signed][
    P_group < p_group_candidate & !(SV %in% site_svs_all)]

  persample_out <- rbindlist(lapply(seq_len(nrow(cand_peak)), function(i) {
    sv_signed <- cand_peak$SV_Signed[i]
    peak_k    <- cand_peak$K[i]
    rows      <- all_freq_dt[K == peak_k & SV_Signed == sv_signed,
                              .(SampleID, Frac)]
    ps <- merge(manifest[, .(SampleID = sample_id, site, group)], rows,
                by = "SampleID", all.x = TRUE)
    ps[is.na(Frac), Frac := 0]
    ps[, SV_Signed := sv_signed]
    ps[, K         := peak_k]
    ps[, .(SampleID, site, group, SV_Signed, K, Frac)]
  }))
  fwrite(persample_out, file.path(out_dir, "sv_ksweep_persample.tsv"),
         sep = "\t", quote = FALSE)

  message(sprintf("\nCandidates (P_group < %.2f, not site-associated): {%s}",
                  p_group_candidate,
                  if (nrow(cand_peak)) paste(cand_peak$SV_Signed, collapse = ", ")
                  else "none"))
  message(sprintf("K-sweep top programs written to: sv_ksweep_top_group.tsv"))

  list(all_k = all_k_dt, top_group = top_group,
       candidates = cand_peak, freq = all_freq_dt)
}

# ---------------------------------------------------------------------------
# Master function
# ---------------------------------------------------------------------------

#' Run cohort-level SGP K-sweep analysis
#'
#' @param manifest  data.table with cols: sample_id, canonical_dir, site, group
#' @param base_dir  base path containing {canonical_dir}/optimal/
#' @param out_dir   output directory (created if absent)
#' @param n_load    number of SVs to load/test (default 30)
#' @param k_min     minimum K for sweep (default 5)
#' @param k_max     maximum K for sweep (default 30)
#' @param p_site_threshold  P_site threshold for excluding site-associated SVs (default 0.10)
#' @param p_group_candidate P_group threshold for candidate programs (default 0.10)
#' @param da_file   relative path from optimal/ to DA file (default "gene/DA_significant.txt")
#' @param q_string  Q-value string indicating significance (default "< 0.05")
run_cohort_ksweep <- function(manifest, base_dir, out_dir,
                               n_load             = 30L,
                               k_min              = 5L,
                               k_max              = 30L,
                               p_site_threshold   = 0.10,
                               p_group_candidate  = 0.10,
                               da_file            = "gene/DA_significant.txt",
                               q_string           = "< 0.05") {
  stopifnot(all(c("sample_id", "canonical_dir", "site", "group") %in% names(manifest)))
  stopifnot(length(unique(manifest$site))  >= 2)
  stopifnot(length(unique(manifest$group)) >= 2)

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  message(sprintf("\n=== run_cohort_ksweep | %d samples | K=%d..%d | N_LOAD=%d ===",
                  nrow(manifest), k_min, k_max, n_load))

  message("\n--- Step 1: Build SG binary matrix ---")
  sg <- build_sg_binary_matrix(manifest, base_dir, da_file, q_string)
  fwrite(sg$cast_meta, file.path(out_dir, "da_cast_meta.tsv"),
         sep = "\t", quote = FALSE)
  fwrite(data.table(gene = sg$gene_names),
         file.path(out_dir, "gene_names.tsv"), sep = "\t", quote = FALSE)

  message("\n--- Step 2: SVD ---")
  sv_res <- run_svd(sg$binary_matrix, out_dir, n_load)

  message("\n--- Step 3: Phase 1 — independent SV depth test ---")
  sv_tests <- sv_depth_test(sv_res$u, sg$cast_meta, manifest, n_load, out_dir)

  message("\n--- Step 4: Phase 2 — batch-unbiased K-sweep ---")
  sweep <- ksweep(sv_res$u, sg$cast_meta, manifest, sv_tests,
                  k_min, k_max, p_site_threshold, p_group_candidate, n_load,
                  out_dir)

  message(sprintf("\n=== run_cohort_ksweep complete — outputs in: %s ===\n", out_dir))
  invisible(list(sg = sg, svd = sv_res, sv_tests = sv_tests, sweep = sweep))
}
