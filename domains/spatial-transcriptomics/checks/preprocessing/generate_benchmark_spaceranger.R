#!/usr/bin/env Rscript
# generate_benchmark_spaceranger.R
#
# Convert the pre-existing harmonized benchmark input_data/ back into
# synthetic SpaceRanger format so test_harmonize.sh can use it as input.
#
# Writes to: benchmarks/GSE213688_GSM6592057/spaceranger_input/
#
# Called automatically by tests/preprocessing/test_harmonize.sh when
# spaceranger_input/ does not exist.

suppressPackageStartupMessages({
  library(data.table)
  library(Matrix)
  library(jsonlite)
})

SCRIPT_DIR <- normalizePath(
  file.path(dirname(sub("--file=", "",
    commandArgs(FALSE)[grep("--file=", commandArgs(FALSE))])), "../.."),
  mustWork = FALSE
)
# Fallback: assume CWD is repo root
if (!dir.exists(file.path(SCRIPT_DIR, "benchmarks")))
  SCRIPT_DIR <- getwd()

BENCH <- file.path(SCRIPT_DIR, "benchmarks", "GSE213688_GSM6592057")
IN    <- file.path(BENCH, "input_data")
OUT   <- file.path(BENCH, "spaceranger_input")
FCB   <- file.path(OUT,   "filtered_feature_bc_matrix")
SPT   <- file.path(OUT,   "spatial")

cat("Generating synthetic SpaceRanger input from benchmark input_data/\n")
cat(sprintf("  Source: %s\n", IN))
cat(sprintf("  Target: %s\n", OUT))

for (d in c(FCB, SPT)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# Read harmonized inputs
M        <- as.matrix(fread(file.path(IN, "M.txt"),       header = FALSE))
barcodes <- fread(file.path(IN, "barcodes.txt"))$barcode
features <- fread(file.path(IN, "features.txt"))$ensembl_gene_id
pos      <- fread(file.path(IN, "barcodes_positions.txt"))

cat(sprintf("  Spots: %d  Genes: %d\n", nrow(M), ncol(M)))

# SpaceRanger writes genes x spots (transpose back)
mtx_sr <- Matrix(t(M), sparse = TRUE)
# writeMM requires a text-mode file; write uncompressed then gzip
mtx_tmp <- tempfile(fileext = ".mtx")
writeMM(mtx_sr, mtx_tmp)
system2("gzip", c("-c", shQuote(mtx_tmp)),
        stdout = file.path(FCB, "matrix.mtx.gz"))
unlink(mtx_tmp)

con <- gzfile(file.path(FCB, "barcodes.tsv.gz"), "wb"); writeLines(barcodes, con); close(con)

feat_df <- data.frame(V1 = features, V2 = features, V3 = "Gene Expression")
con <- gzfile(file.path(FCB, "features.tsv.gz"), "wb")
write.table(feat_df, con, sep = "\t", quote = FALSE, row.names = FALSE, col.names = FALSE)
close(con)

# Standard Visium spot diameter
spot_diam_px <- 177.5
mm_conv      <- 55 / spot_diam_px / 1000

pos_sr <- data.frame(
  barcode            = pos$barcode,
  in_tissue          = 1L,
  array_row          = if ("array_row" %in% names(pos)) pos$array_row else seq_len(nrow(pos)),
  array_col          = if ("array_col" %in% names(pos)) pos$array_col else seq_len(nrow(pos)),
  pxl_row_in_fullres = round(pos$pxl_row_in_mm / mm_conv),
  pxl_col_in_fullres = round(pos$pxl_col_in_mm / mm_conv)
)
write.csv(pos_sr, file.path(SPT, "tissue_positions.csv"), row.names = FALSE, quote = FALSE)

sf <- list(
  spot_diameter_fullres     = spot_diam_px,
  tissue_hires_scalef       = 0.05,
  tissue_lowres_scalef      = 0.013,
  fiducial_diameter_fullres = 304.0
)
writeLines(toJSON(sf, auto_unbox = TRUE, pretty = TRUE),
           file.path(SPT, "scalefactors_json.json"))

cat("Done.\n")
