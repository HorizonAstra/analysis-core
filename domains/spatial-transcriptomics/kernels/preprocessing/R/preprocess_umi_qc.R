#!/usr/bin/env Rscript
#
# preprocess_umi_qc.R
#
# Per-sample UMI QC filter using a 2-component Gaussian Mixture Model on
# log10(total UMI per spot).  Spots in the lower component (debris/background)
# are excluded; the cutoff is set at P(debris | x) = 0.5.
#
# A G=3 retry is triggered when the G=2 fit is suspicious (debris component
# mean too high, or cutoff too high), allowing the model to separate a genuine
# low-UMI debris cluster from tissue when three populations are present.
#
# Thresholds used (biologically grounded):
#   MU_BG_MAX     = 2.70  log10 (~500 UMI)  — real debris rarely exceeds this
#   CUTOFF_MAX    = 3.30  log10 (~2000 UMI) — implausibly high debris/tissue boundary
#   MU_DEBRIS_MAX = 2.50  log10 (~316 UMI)  — G=3 debris component must be below this
#   MAX_DEBRIS_FRAC = 0.40                  — debris must be a minority of spots
#
# Outputs (written to --output-dir/):
#   passing_barcodes.txt   barcodes passing the UMI QC filter
#   umi_stats.tsv          per-sample statistics (cutoff, component parameters, etc.)
#   umi_qc_plot.png        density + spatial QC figure
#
# Usage:
#   Rscript preprocess_umi_qc.R \
#       --spaceranger-dir  <path>   SpaceRanger outs/ directory for this sample
#       --output-dir       <path>   Directory to write outputs
#       [--sample-id       <str>]   Label for log messages (default: basename of output-dir)

suppressPackageStartupMessages({
  library(data.table)
  library(Matrix)
  library(ggplot2)
  library(jsonlite)
})

# ── Argument parsing ──────────────────────────────────────────────────────────
argv <- commandArgs(trailingOnly = TRUE)

.require_arg <- function(argv, flag) {
  i <- which(argv == flag)
  if (length(i) == 0 || i[1] >= length(argv))
    stop(sprintf("Required argument %s not provided", flag))
  argv[i[1] + 1L]
}
.optional_arg <- function(argv, flag, default = NA_character_) {
  i <- which(argv == flag)
  if (length(i) > 0 && i[1] < length(argv)) argv[i[1] + 1L] else default
}

if ("--help" %in% argv || "-h" %in% argv || length(argv) == 0) {
  cat("Usage: Rscript preprocess_umi_qc.R --spaceranger-dir <path> --output-dir <path>",
      "[--sample-id <str>]\n")
  quit(status = 0)
}

SPACERANGER_DIR <- .require_arg(argv, "--spaceranger-dir")
OUTPUT_DIR      <- .require_arg(argv, "--output-dir")
SAMPLE_ID       <- .optional_arg(argv, "--sample-id", basename(OUTPUT_DIR))

cat(strrep("=", 70), "\n", sep = "")
cat(sprintf("preprocess_umi_qc | %s\n", SAMPLE_ID))
cat(strrep("=", 70), "\n", sep = "")

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

filt_dir    <- file.path(SPACERANGER_DIR, "filtered_feature_bc_matrix")
spatial_dir <- file.path(SPACERANGER_DIR, "spatial")

if (!dir.exists(filt_dir))
  stop(sprintf("filtered_feature_bc_matrix not found: %s", filt_dir))

# ── GMM helpers ───────────────────────────────────────────────────────────────
simple_em_kgauss <- function(x, k = 2, max_iter = 300, tol = 1e-7) {
  set.seed(42L)
  km     <- kmeans(x, k, nstart = 5)
  mu     <- as.numeric(km$centers)
  sigma  <- vapply(seq_len(k), function(i) {
    s <- sd(x[km$cluster == i]); if (is.na(s) || s < 1e-4) 1e-4 else s
  }, numeric(1))
  lambda <- as.numeric(table(km$cluster)) / length(x)
  log_lik_prev <- -Inf
  for (iter in seq_len(max_iter)) {
    dens  <- vapply(seq_len(k),
                    function(i) lambda[i] * dnorm(x, mu[i], sigma[i]),
                    numeric(length(x)))
    denom <- rowSums(dens); denom[denom < 1e-300] <- 1e-300
    r     <- sweep(dens, 1, denom, "/")
    nk    <- colSums(r)
    mu    <- colSums(r * x) / nk
    sigma <- sqrt(colSums(r * outer(x, mu, `-`)^2) / nk)
    sigma[sigma < 1e-4] <- 1e-4
    lambda <- nk / length(x)
    log_lik <- sum(log(denom))
    if (abs(log_lik - log_lik_prev) < tol) break
    log_lik_prev <- log_lik
  }
  list(mu = mu, sigma = sigma, lambda = lambda,
       ok = !any(is.nan(c(mu, sigma, lambda))))
}

run_gmm <- function(log10_umi, k) {
  fit <- tryCatch({
    if (!requireNamespace("mclust", quietly = TRUE)) stop("no mclust")
    m <- mclust::Mclust(log10_umi, G = k, modelNames = "V", verbose = FALSE)
    if (is.null(m)) stop("mclust returned NULL")
    list(mu = m$parameters$mean, sigma = sqrt(m$parameters$variance$sigmasq),
         lambda = m$parameters$pro, ok = TRUE)
  }, error = function(e) {
    if (k == 2) message("  mclust unavailable; using built-in EM fallback")
    simple_em_kgauss(log10_umi, k = k)
  })
  if (!isTRUE(fit$ok)) return(NULL)
  ord <- order(fit$mu)
  list(mu = fit$mu[ord], sigma = fit$sigma[ord], lambda = fit$lambda[ord])
}

find_cutoff <- function(mu, sigma, lambda) {
  post_debris <- function(x) {
    d <- vapply(seq_along(mu),
                function(i) lambda[i] * dnorm(x, mu[i], sigma[i]), numeric(1))
    d[1] / sum(d)
  }
  tryCatch(
    uniroot(function(x) post_debris(x) - 0.5,
            interval = c(mu[1], mu[length(mu)]))$root,
    error = function(e) (mu[1] + mu[2]) / 2
  )
}

fit_gmm <- function(log10_umi) {
  MIN_GAP         <- 0.30
  MIN_BG_FRAC     <- 0.03
  MU_BG_MAX       <- 2.70
  CUTOFF_MAX      <- 3.30
  MU_DEBRIS_MAX   <- 2.50
  MAX_DEBRIS_FRAC <- 0.40

  skip <- function(reason, fit = NULL) {
    mu     <- if (!is.null(fit)) fit$mu     else rep(NA_real_, 2)
    sigma  <- if (!is.null(fit)) fit$sigma  else rep(NA_real_, 2)
    lambda <- if (!is.null(fit)) fit$lambda else rep(NA_real_, 2)
    list(cutoff_log10 = NA_real_, cutoff_umi = NA_real_,
         mu = mu, sigma = sigma, lambda = lambda,
         filter_applied = FALSE, skip_reason = reason,
         n_components = length(mu))
  }

  g2 <- run_gmm(log10_umi, k = 2)
  if (is.null(g2)) return(skip("G=2 EM did not converge"))

  gap2 <- g2$mu[2] - g2$mu[1]
  if (gap2 < MIN_GAP)
    return(skip(sprintf("G=2 gap=%.2f < %.2f (no bimodality)", gap2, MIN_GAP), g2))
  if (g2$lambda[1] < MIN_BG_FRAC)
    return(skip(sprintf("G=2 bg_frac=%.1f%% < %.0f%% (negligible debris)",
                        g2$lambda[1]*100, MIN_BG_FRAC*100), g2))

  cut2 <- find_cutoff(g2$mu, g2$sigma, g2$lambda)

  if (g2$mu[1] > MU_BG_MAX || cut2 > CUTOFF_MAX) {
    why <- if (g2$mu[1] > MU_BG_MAX)
      sprintf("G=2 mu_bg=%.2f > %.2f", g2$mu[1], MU_BG_MAX)
    else
      sprintf("G=2 cutoff=%.2f > %.2f", cut2, CUTOFF_MAX)
    message(sprintf("  G=2 suspicious (%s) — retrying G=3", why))

    g3 <- run_gmm(log10_umi, k = 3)
    if (is.null(g3)) return(skip(paste0("G=3 EM failed after: ", why), g2))

    if (g3$mu[1] >= MU_DEBRIS_MAX || g3$lambda[1] >= MAX_DEBRIS_FRAC)
      return(skip(
        sprintf("G=3 lowest component mu=%.2f lam=%.1f%% — no debris distribution",
                g3$mu[1], g3$lambda[1]*100), g3))

    if ((g3$mu[2] - g3$mu[1]) < MIN_GAP)
      return(skip(sprintf("G=3 gap(1,2)=%.2f < %.2f", g3$mu[2]-g3$mu[1], MIN_GAP), g3))

    cut3 <- find_cutoff(g3$mu, g3$sigma, g3$lambda)
    message(sprintf("  G=3 debris: mu=%.2f lam=%.1f%%  cutoff=%.2f (%.0f UMI)",
                    g3$mu[1], g3$lambda[1]*100, cut3, 10^cut3))
    return(list(cutoff_log10 = cut3, cutoff_umi = 10^cut3,
                mu = g3$mu, sigma = g3$sigma, lambda = g3$lambda,
                filter_applied = TRUE, skip_reason = NA_character_,
                n_components = 3L))
  }

  list(cutoff_log10 = cut2, cutoff_umi = 10^cut2,
       mu = g2$mu, sigma = g2$sigma, lambda = g2$lambda,
       filter_applied = TRUE, skip_reason = NA_character_,
       n_components = 2L)
}

# ── Read SpaceRanger filtered matrix ─────────────────────────────────────────
mtx_f  <- list.files(filt_dir, "matrix\\.mtx",   full.names = TRUE)
barc_f <- list.files(filt_dir, "barcodes\\.tsv",  full.names = TRUE)

if (length(mtx_f)  == 0) stop(sprintf("matrix.mtx not found in %s",  filt_dir))
if (length(barc_f) == 0) stop(sprintf("barcodes.tsv not found in %s", filt_dir))

mtx      <- Matrix::readMM(gzfile(mtx_f))   # genes × spots (keep sparse)
barcodes <- fread(barc_f, header = FALSE)$V1

total_umi <- Matrix::colSums(mtx)
names(total_umi) <- barcodes
n_total   <- length(total_umi)
log10_umi <- log10(pmax(total_umi, 1))

cat(sprintf("  spots=%d  median_umi=%.0f  range=[%.0f, %.0f]\n",
            n_total, median(total_umi), min(total_umi), max(total_umi)))

# ── Fit GMM ───────────────────────────────────────────────────────────────────
gmm <- fit_gmm(log10_umi)

if (gmm$filter_applied) {
  pass_mask <- log10_umi >= gmm$cutoff_log10
  cat(sprintf("  cutoff=%.1f UMI (log10=%.3f)  pass=%d  fail=%d (%.1f%%)\n",
              gmm$cutoff_umi, gmm$cutoff_log10,
              sum(pass_mask), sum(!pass_mask), 100 * mean(!pass_mask)))
} else {
  pass_mask <- rep(TRUE, n_total)
  cat(sprintf("  filter NOT applied: %s\n", gmm$skip_reason))
}

passing_barcodes <- barcodes[pass_mask]
writeLines(passing_barcodes, file.path(OUTPUT_DIR, "passing_barcodes.txt"))

# ── Write stats ───────────────────────────────────────────────────────────────
nc    <- as.integer(gmm$n_components)
stats <- data.table(
  sample_id      = SAMPLE_ID,
  n_total        = n_total,
  n_pass         = sum(pass_mask),
  n_fail         = sum(!pass_mask),
  pct_removed    = round(100 * mean(!pass_mask), 2),
  filter_applied = gmm$filter_applied,
  n_components   = nc,
  skip_reason    = if (is.na(gmm$skip_reason)) "" else gmm$skip_reason,
  cutoff_umi     = if (gmm$filter_applied) round(gmm$cutoff_umi,   1)  else NA_real_,
  cutoff_log10   = if (gmm$filter_applied) round(gmm$cutoff_log10, 4)  else NA_real_,
  mu_bg          = round(gmm$mu[1],           4),
  mu_tissue      = round(gmm$mu[length(gmm$mu)], 4),
  sigma_bg       = round(gmm$sigma[1],        4),
  sigma_tissue   = round(gmm$sigma[length(gmm$sigma)], 4),
  lambda_bg      = round(gmm$lambda[1],       4),
  lambda_tissue  = round(gmm$lambda[length(gmm$lambda)], 4)
)
fwrite(stats, file.path(OUTPUT_DIR, "umi_stats.tsv"), sep = "\t")

# ── QC plot ───────────────────────────────────────────────────────────────────
df_dens <- data.table(log10_umi = log10_umi,
                      status    = ifelse(pass_mask, "pass", "fail"))

x_seq    <- seq(min(log10_umi) - 0.2, max(log10_umi) + 0.2, length.out = 400)
comp_col <- c("#d73027", "#4dac26", "#2166ac")

comp_mat <- vapply(seq_len(nc),
                   function(i) gmm$lambda[i] * dnorm(x_seq, gmm$mu[i], gmm$sigma[i]),
                   numeric(length(x_seq)))
df_gmm         <- as.data.table(if (is.matrix(comp_mat)) comp_mat else matrix(comp_mat, ncol = 1))
setnames(df_gmm, paste0("c", seq_len(nc)))
df_gmm[, x     := x_seq]
df_gmm[, total := rowSums(.SD), .SDcols = paste0("c", seq_len(nc))]

subtitle_txt <- if (gmm$filter_applied) {
  sprintf("n=%d  pass=%d  fail=%d (%.1f%%)  [G=%d]",
          n_total, sum(pass_mask), sum(!pass_mask), 100*mean(!pass_mask), nc)
} else {
  sprintf("filter not applied [G=%d]: %s", nc, gmm$skip_reason)
}

p_dens <- ggplot(df_dens, aes(x = log10_umi)) +
  geom_histogram(aes(y = after_stat(density), fill = status),
                 bins = 80, alpha = 0.6, colour = NA) +
  scale_fill_manual(values = c(pass = "#2166ac", fail = "#d73027"), name = NULL)
for (i in seq_len(nc)) {
  p_dens <- p_dens +
    geom_line(data = df_gmm, aes(x = x, y = .data[[paste0("c", i)]]),
              colour = comp_col[i], linetype = "dashed", linewidth = 0.65,
              inherit.aes = FALSE)
}
p_dens <- p_dens +
  geom_line(data = df_gmm, aes(x = x, y = total),
            colour = "#333", linewidth = 0.9, inherit.aes = FALSE) +
  (if (gmm$filter_applied) geom_vline(xintercept = gmm$cutoff_log10,
    colour = "black", linetype = "solid", linewidth = 0.8) else NULL) +
  (if (gmm$filter_applied) annotate("text", x = gmm$cutoff_log10 + 0.05,
    y = Inf, vjust = 1.5, hjust = 0, size = 2.8,
    label = sprintf("cutoff\n%.0f UMI", gmm$cutoff_umi)) else NULL) +
  labs(title = SAMPLE_ID, subtitle = subtitle_txt,
       x = "log\u2081\u2080 (total UMI)", y = "Density") +
  theme_bw(base_size = 10) + theme(legend.position = "bottom")

# Spatial panel — if tissue_positions is available
img_f <- file.path(spatial_dir, "tissue_lowres_image.png")
pos_f <- list.files(spatial_dir, "tissue_positions.*csv", full.names = TRUE)
sf_f  <- list.files(spatial_dir, "scalefactors.*json",    full.names = TRUE)

p_spatial <- NULL
if (length(pos_f) > 0 && length(sf_f) > 0) {
  pos <- fread(pos_f)
  if (names(pos)[1] != "barcode")
    setnames(pos, c("barcode","in_tissue","array_row","array_col",
                    "pxl_row_in_fullres","pxl_col_in_fullres"))
  pos <- pos[in_tissue == 1]
  pos[, barcode := gsub("\\.", "-", barcode)]

  sf     <- fromJSON(sf_f)
  scalef <- sf$tissue_lowres_scalef

  img_h <- NA_integer_
  if (file.exists(img_f)) {
    hdr   <- readBin(img_f, "raw", 28L)
    img_h <- sum(as.integer(hdr[21:24]) * c(16777216L, 65536L, 256L, 1L))
  }
  if (is.na(img_h)) img_h <- 600L

  pos[, `:=`(lx = pxl_col_in_fullres * scalef,
             ly = img_h - pxl_row_in_fullres * scalef)]

  umi_dt <- data.table(barcode = barcodes, status = ifelse(pass_mask, "pass", "fail"))
  pos    <- merge(pos, umi_dt, by = "barcode", all.x = TRUE)
  pos[is.na(status), status := "pass"]

  p_spatial <- ggplot(pos[status == "fail"], aes(x = lx, y = ly)) +
    geom_point(data = pos[status == "pass"],
               aes(x = lx, y = ly), colour = "#2166ac", alpha = 0.4, size = 0.5) +
    geom_point(colour = "#d73027", alpha = 0.6, size = 0.6) +
    coord_fixed() + labs(title = "Spatial: fail (red) / pass (blue)") +
    theme_void(base_size = 9)
}

if (!is.null(p_spatial)) {
  p_out <- gridExtra::arrangeGrob(p_dens, p_spatial, ncol = 2)
} else {
  p_out <- p_dens
}
suppressMessages(
  ggplot2::ggsave(file.path(OUTPUT_DIR, "umi_qc_plot.png"),
                  p_out, width = if (!is.null(p_spatial)) 12 else 6,
                  height = 5, dpi = 150)
)
cat(sprintf("  wrote passing_barcodes.txt (%d), umi_stats.tsv, umi_qc_plot.png\n",
            length(passing_barcodes)))
cat("UMI QC complete.\n")
