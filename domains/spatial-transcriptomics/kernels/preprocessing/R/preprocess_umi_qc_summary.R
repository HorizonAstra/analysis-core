#!/usr/bin/env Rscript
#
# preprocess_umi_qc_summary.R
#
# Aggregate per-sample UMI QC statistics and generate a multi-page summary PDF
# with one page per sample (density + spatial QC figure).
#
# Input:  per-sample umi_stats.tsv and umi_qc_plot.png files produced by
#         preprocess_umi_qc.R, found under --qc-dir/<sample_id>/
#
# Output: <qc-dir>/umi_qc_summary.pdf   — one page per sample
#         <qc-dir>/umi_stats_all.tsv    — combined stats table
#
# Usage:
#   Rscript preprocess_umi_qc_summary.R \
#       --qc-dir <path>           Root directory containing per-sample subdirs
#       [--samples s1,s2,...]     Comma-separated sample IDs to include
#                                 (default: all subdirs containing umi_stats.tsv)

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(grid)
  library(gridExtra)
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
  cat("Usage: Rscript preprocess_umi_qc_summary.R --qc-dir <path> [--samples s1,s2,...]\n")
  quit(status = 0)
}

QC_DIR      <- .require_arg(argv, "--qc-dir")
SAMPLES_ARG <- .optional_arg(argv, "--samples")

cat(strrep("=", 70), "\n", sep = "")
cat("preprocess_umi_qc_summary\n")
cat(strrep("=", 70), "\n", sep = "")
cat(sprintf("  QC dir : %s\n\n", QC_DIR))

if (!dir.exists(QC_DIR))
  stop(sprintf("QC directory not found: %s", QC_DIR))

# ── Discover samples ──────────────────────────────────────────────────────────
if (!is.na(SAMPLES_ARG)) {
  sids <- trimws(strsplit(SAMPLES_ARG, ",")[[1]])
} else {
  sids <- sort(basename(
    Filter(function(d) file.exists(file.path(d, "umi_stats.tsv")),
           list.dirs(QC_DIR, recursive = FALSE))
  ))
}

if (length(sids) == 0)
  stop(sprintf("No samples with umi_stats.tsv found under %s", QC_DIR))

cat(sprintf("  Found %d samples\n\n", length(sids)))

# ── Read all stats ────────────────────────────────────────────────────────────
stats_list <- lapply(sids, function(sid) {
  f <- file.path(QC_DIR, sid, "umi_stats.tsv")
  if (!file.exists(f)) { warning(sprintf("  SKIP %s — no umi_stats.tsv", sid)); return(NULL) }
  fread(f)
})
stats_all <- rbindlist(Filter(Negate(is.null), stats_list))
fwrite(stats_all, file.path(QC_DIR, "umi_stats_all.tsv"), sep = "\t")

# ── Print summary table ───────────────────────────────────────────────────────
cat("=== UMI QC Filter Summary ===\n")
print(stats_all[order(-pct_removed),
                .(sample_id, n_total, n_pass, n_fail, pct_removed,
                  filter_applied, cutoff_umi, mu_bg, mu_tissue)])
cat(sprintf("\nSamples with filter applied: %d / %d\n",
            sum(stats_all$filter_applied), nrow(stats_all)))
pct_med <- stats_all[filter_applied == TRUE, median(pct_removed)]
if (!is.na(pct_med)) cat(sprintf("Median pct removed: %.1f%%\n", pct_med))

# ── Build PDF ─────────────────────────────────────────────────────────────────
out_pdf <- file.path(QC_DIR, "umi_qc_summary.pdf")
cat(sprintf("\nBuilding PDF: %s\n", out_pdf))

pdf(out_pdf, width = 11, height = 5)
for (sid in sids) {
  cat(sprintf("  %s ...\n", sid))
  img_f <- file.path(QC_DIR, sid, "umi_qc_plot.png")
  if (!file.exists(img_f)) {
    grid.newpage()
    grid.text(sprintf("%s\n(umi_qc_plot.png not found)", sid), gp = gpar(fontsize = 14))
    next
  }
  img <- tryCatch(png::readPNG(img_f), error = function(e) NULL)
  if (is.null(img)) {
    grid.newpage()
    grid.text(sprintf("%s\n(could not read PNG: %s)", sid, conditionMessage(e)),
              gp = gpar(fontsize = 12))
    next
  }
  grid.newpage()
  grid.raster(img)
}
dev.off()
cat(sprintf("Done — %d pages written to %s\n", length(sids), out_pdf))
