#!/usr/bin/env Rscript
#
# preprocess_harmonize.R
#
# Convert SpaceRanger filtered output for one sample into the 5-file format
# required by TumorSPACE_AWS:
#   M.txt                    expression matrix (spots × genes), no header
#   barcodes.txt             spot barcodes, one per row, with header
#   features.txt             gene/feature list, with header
#   genes.txt                alias for features.txt (expected by tumorspace_core)
#   barcodes_positions.txt   spatial coordinates in mm, with header
#
# Optionally applies a UMI QC barcode whitelist produced by preprocess_umi_qc.R.
#
# Usage:
#   Rscript preprocess_harmonize.R \
#       --spaceranger-dir  <path>   SpaceRanger outs/ directory for this sample
#       --output-dir       <path>   Where to write the 5-file harmonized output
#       [--umi-qc-dir      <path>]  Directory containing passing_barcodes.txt
#                                   (from preprocess_umi_qc.R); omit to skip QC filtering
#       [--sample-id       <str>]   Sample label for log messages (default: basename of output-dir)
#
# All arguments are required except --umi-qc-dir and --sample-id.
# Run from any working directory.

suppressPackageStartupMessages({
  library(data.table)
  library(Matrix)
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
  cat("Usage: Rscript preprocess_harmonize.R --spaceranger-dir <path> --output-dir <path>",
      "[--umi-qc-dir <path>] [--sample-id <str>]\n")
  quit(status = 0)
}

SPACERANGER_DIR <- .require_arg(argv, "--spaceranger-dir")
OUTPUT_DIR      <- .require_arg(argv, "--output-dir")
UMI_QC_DIR      <- .optional_arg(argv, "--umi-qc-dir")
SAMPLE_ID       <- .optional_arg(argv, "--sample-id", basename(OUTPUT_DIR))

cat(strrep("=", 70), "\n", sep = "")
cat(sprintf("preprocess_harmonize | %s\n", SAMPLE_ID))
cat(strrep("=", 70), "\n", sep = "")
cat(sprintf("  SpaceRanger dir : %s\n", SPACERANGER_DIR))
cat(sprintf("  Output dir      : %s\n", OUTPUT_DIR))
cat(sprintf("  UMI QC dir      : %s\n", if (is.na(UMI_QC_DIR)) "(none)" else UMI_QC_DIR))

if (!dir.exists(SPACERANGER_DIR))
  stop(sprintf("SpaceRanger directory not found: %s", SPACERANGER_DIR))
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

# ── Derived paths ─────────────────────────────────────────────────────────────
filt_dir    <- file.path(SPACERANGER_DIR, "filtered_feature_bc_matrix")
spatial_dir <- file.path(SPACERANGER_DIR, "spatial")

if (!dir.exists(filt_dir))
  stop(sprintf("filtered_feature_bc_matrix not found under: %s", SPACERANGER_DIR))

matrix_loc      <- file.path(OUTPUT_DIR, "M.txt")
barcode_loc     <- file.path(OUTPUT_DIR, "barcodes.txt")
feature_loc     <- file.path(OUTPUT_DIR, "features.txt")
genes_loc       <- file.path(OUTPUT_DIR, "genes.txt")
barcode_pos_loc <- file.path(OUTPUT_DIR, "barcodes_positions.txt")

# ── Expression matrix ─────────────────────────────────────────────────────────
matrix_complete <- file.exists(matrix_loc) && file.exists(barcode_loc) &&
                   (file.exists(genes_loc) || file.exists(feature_loc))

if (!matrix_complete) {
  if (file.exists(matrix_loc))
    cat("  M.txt exists but sibling files missing — regenerating all matrix files\n")

  mtx_f  <- list.files(filt_dir, "matrix\\.mtx",   full.names = TRUE)
  barc_f <- list.files(filt_dir, "barcodes\\.tsv",  full.names = TRUE)
  feat_f <- list.files(filt_dir, "features\\.tsv",  full.names = TRUE)

  if (length(mtx_f)  == 0) stop(sprintf("matrix.mtx not found in %s",   filt_dir))
  if (length(barc_f) == 0) stop(sprintf("barcodes.tsv not found in %s",  filt_dir))
  if (length(feat_f) == 0) stop(sprintf("features.tsv not found in %s",  filt_dir))

  # t(): SpaceRanger writes genes × spots; TumorSPACE expects spots × genes
  mtx      <- t(as.matrix(Matrix::readMM(gzfile(mtx_f))))
  nonzero  <- which(colSums(mtx) != 0)
  mtx      <- mtx[, nonzero]

  barcodes <- data.table(barcode =
    read.table(gzfile(barc_f), header = FALSE, sep = "\t",
               stringsAsFactors = FALSE)$V1)
  features <- data.table(ensembl_gene_id =
    read.table(gzfile(feat_f), header = FALSE, sep = "\t",
               stringsAsFactors = FALSE)$V1)[nonzero]

  write.table(mtx,      matrix_loc,  quote = FALSE, sep = "\t",
              row.names = FALSE, col.names = FALSE)
  write.table(barcodes, barcode_loc, quote = FALSE, sep = "\t",
              row.names = FALSE, col.names = TRUE)
  write.table(features, feature_loc, quote = FALSE, sep = "\t",
              row.names = FALSE, col.names = TRUE)
  write.table(features, genes_loc,   quote = FALSE, sep = "\t",
              row.names = FALSE, col.names = TRUE)
  cat(sprintf("  wrote M.txt (%d spots x %d genes)\n", nrow(barcodes), nrow(features)))
} else {
  cat("  M.txt present — loading barcodes for positions step\n")
  barcodes <- fread(barcode_loc)
}

# ── UMI QC whitelist (optional) ───────────────────────────────────────────────
if (!is.na(UMI_QC_DIR)) {
  qc_file <- file.path(UMI_QC_DIR, "passing_barcodes.txt")
  if (file.exists(qc_file)) {
    passing  <- readLines(qc_file)
    n_before <- nrow(barcodes)
    keep_idx <- which(barcodes$barcode %in% passing)
    n_removed <- n_before - length(keep_idx)
    if (n_removed > 0) {
      cat(sprintf("  UMI QC: retaining %d / %d spots (%d removed)\n",
                  length(keep_idx), n_before, n_removed))
      barcodes <- barcodes[keep_idx, , drop = FALSE]
      # Load mtx from disk if not freshly created this run (H3 re-harmonize path)
      if (!exists("mtx")) {
        cat("  Loading M.txt from disk for QC filtering...\n")
        mtx      <- as.matrix(data.table::fread(matrix_loc, header = FALSE))
        feat_file <- if (file.exists(feature_loc)) feature_loc else genes_loc
        features  <- data.table::fread(feat_file)
        colnames(features)[1] <- "ensembl_gene_id"
      }
      mtx      <- mtx[keep_idx, , drop = FALSE]
      nonzero2 <- which(colSums(mtx) != 0)
      mtx      <- mtx[, nonzero2, drop = FALSE]
      features <- features[nonzero2]
      write.table(mtx,      matrix_loc,  quote = FALSE, sep = "\t",
                  row.names = FALSE, col.names = FALSE)
      write.table(barcodes, barcode_loc, quote = FALSE, sep = "\t",
                  row.names = FALSE, col.names = TRUE)
      write.table(features, feature_loc, quote = FALSE, sep = "\t",
                  row.names = FALSE, col.names = TRUE)
      write.table(features, genes_loc,   quote = FALSE, sep = "\t",
                  row.names = FALSE, col.names = TRUE)
      cat(sprintf("  rewrote M.txt (%d spots x %d genes after UMI QC)\n",
                  nrow(barcodes), nrow(features)))
    } else {
      cat(sprintf("  UMI QC: all %d spots pass\n", n_before))
    }
  } else {
    cat(sprintf("  UMI QC: no passing_barcodes.txt at %s — using all spots\n", UMI_QC_DIR))
  }
} else {
  cat("  UMI QC: skipped (no --umi-qc-dir provided)\n")
}

# ── Spatial positions ─────────────────────────────────────────────────────────
if (!file.exists(barcode_pos_loc)) {
  pos_f <- list.files(spatial_dir, "tissue_positions.*csv", full.names = TRUE)
  sf_f  <- list.files(spatial_dir, "scalefactors.*json",    full.names = TRUE)

  if (length(pos_f) == 0) stop(sprintf("tissue_positions CSV not found in %s", spatial_dir))
  if (length(sf_f)  == 0) stop(sprintf("scalefactors JSON not found in %s",    spatial_dir))

  pos <- fread(pos_f)
  # SpaceRanger v2+ has header; v1 does not
  if (names(pos)[1] != "barcode")
    setnames(pos, c("barcode","in_tissue","array_row","array_col",
                    "pxl_row_in_fullres","pxl_col_in_fullres"))

  pos[, barcode := gsub("\\.", "-", barcode)]
  pos <- pos[in_tissue == 1]

  # Convert pixels → mm using 55 µm physical spot diameter
  sf           <- fromJSON(sf_f)
  spot_diam_px <- sf$spot_diameter_fullres
  mm_conv      <- 55 / spot_diam_px / 1000   # 55 µm / diameter_px → mm/px

  pos[, pxl_row_in_mm := pxl_row_in_fullres * mm_conv]
  pos[, pxl_col_in_mm := pxl_col_in_fullres * mm_conv]

  # Reorder to match barcode order in barcodes.txt
  pos <- pos[match(barcodes$barcode, pos$barcode)]

  write.table(pos, barcode_pos_loc, quote = FALSE, sep = "\t",
              row.names = FALSE, col.names = TRUE)
  cat(sprintf("  wrote barcodes_positions.txt (%d spots)\n", nrow(pos)))
} else {
  cat("  barcodes_positions.txt already present — skipping\n")
}

cat("\nHarmonization complete.\n")
