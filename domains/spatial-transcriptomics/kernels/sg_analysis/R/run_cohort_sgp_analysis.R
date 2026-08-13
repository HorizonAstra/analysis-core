#!/usr/bin/env Rscript
#
# TumorSPACE: Cohort SGP K-sweep — container entry point
#
# Called by run_cohort_sgp_analysis.sh via:
#   singularity exec tumorspace_r45.sif Rscript /opt/workflows/R/run_cohort_sgp_analysis.R ...
# or directly in native mode.
#
# cohort_ksweep.R and cohort_spatial.R are sourced from the same directory as
# this script (all three are embedded together at container build time).
#
# Arguments:
#   --manifest    TSV: sample_id, canonical_dir, site, group  [required]
#   --base-dir    Base path containing {canonical_dir}/optimal/  [required]
#   --output-dir  Output directory (created if absent)           [required]
#   --n-load      SVs to load/test        [default 30]
#   --k-min       Minimum K for sweep     [default 5]
#   --k-max       Maximum K for sweep     [default 30]
#   --p-site      P_site exclusion threshold  [default 0.10]
#   --p-group     P_group candidate threshold [default 0.10]
#   --skip-spatial  Skip Phase 3 spot labeling (run Phase 1+2 only)

suppressPackageStartupMessages(library(data.table))
suppressPackageStartupMessages(library(optparse))

option_list <- list(
  make_option("--manifest",   type = "character", default = NULL,
              help = "TSV manifest: sample_id, canonical_dir, site, group [required]"),
  make_option("--base-dir",   type = "character", default = NULL,
              help = "Base path containing {canonical_dir}/optimal/ [required]"),
  make_option("--output-dir", type = "character", default = NULL,
              help = "Output directory [required]"),
  make_option("--n-load",     type = "integer",   default = 30L,
              help = "SVs to load/test [default %default]"),
  make_option("--k-min",      type = "integer",   default = 5L,
              help = "Minimum K for sweep [default %default]"),
  make_option("--k-max",      type = "integer",   default = 30L,
              help = "Maximum K for sweep [default %default]"),
  make_option("--p-site",     type = "double",    default = 0.10,
              help = "P_site threshold for site-SV exclusion [default %default]"),
  make_option("--p-group",    type = "double",    default = 0.10,
              help = "P_group threshold for candidate programs [default %default]"),
  make_option("--skip-spatial", action = "store_true", default = FALSE,
              help = "Skip Phase 3 spot labeling; run Phase 1+2 (K-sweep) only")
)

parser <- OptionParser(
  option_list = option_list,
  usage = "Rscript run_cohort_sgp_analysis.R --manifest M.tsv --base-dir DIR --output-dir OUT"
)
args <- parse_args(parser)

for (req in c("manifest", "base-dir", "output-dir")) {
  if (is.null(args[[req]])) {
    print_help(parser)
    stop(sprintf("--%s is required", req), call. = FALSE)
  }
}
if (!file.exists(args[["manifest"]]))
  stop("manifest not found: ", args[["manifest"]], call. = FALSE)

# Source sibling R files from the same directory as this script
script_dir <- normalizePath(dirname(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE)[1])),
                            mustWork = FALSE)
if (is.na(script_dir) || !nzchar(script_dir)) script_dir <- "."
source(file.path(script_dir, "cohort_ksweep.R"))
source(file.path(script_dir, "cohort_spatial.R"))

manifest <- fread(args[["manifest"]])
stopifnot(all(c("sample_id", "canonical_dir", "site", "group") %in% names(manifest)))

message(sprintf("Manifest: %d samples | groups: {%s} | sites: {%s}",
                nrow(manifest),
                paste(sort(unique(manifest$group)), collapse = ", "),
                paste(sort(unique(manifest$site)),  collapse = ", ")))

run_cohort_ksweep(
  manifest          = manifest,
  base_dir          = args[["base-dir"]],
  out_dir           = args[["output-dir"]],
  n_load            = args[["n-load"]],
  k_min             = args[["k-min"]],
  k_max             = args[["k-max"]],
  p_site_threshold  = args[["p-site"]],
  p_group_candidate = args[["p-group"]]
)

if (isTRUE(args[["skip-spatial"]])) {
  message("--skip-spatial set: Phase 3 spot labeling skipped.")
  message("=== Cohort SGP K-sweep complete (Phase 1+2 only) ===")
} else {
  run_cohort_spatial(
    manifest          = manifest,
    base_dir          = args[["base-dir"]],
    out_dir           = args[["output-dir"]],
    n_load            = args[["n-load"]],
    p_group_candidate = args[["p-group"]],
    p_site_threshold  = args[["p-site"]]
  )
  message("=== Cohort SGP analysis complete ===")
}
