#!/usr/bin/env Rscript
# Thin, non-interactive wrapper around maaslin3() for the toolkit's tertiary STATS engine.
#
# Invoked by src/compute/rstats.py with the renv project (envs/r-stats) as the working
# directory, so renv's .Rprofile puts maaslin3 (and its deps) on the library path. Every
# input is a pre-validated, pre-aligned TSV the Python caller wrote (sample_id rownames on
# both tables, abundances zero-filled, NA-covariate samples already dropped) — this script
# does NO data wrangling, it just maps CLI args onto maaslin3()'s arguments and runs.

suppressWarnings(suppressMessages({
  library(optparse)
  library(maaslin3)
}))

opt <- parse_args(OptionParser(option_list = list(
  make_option("--data",          type = "character"),                    # samples x features TSV
  make_option("--metadata",      type = "character"),                    # samples x variables TSV
  make_option("--output",        type = "character"),                    # maaslin output dir
  make_option("--fixed",         type = "character"),                    # "a,b,c"
  make_option("--random",        type = "character", default = ""),      # "subject_id" | ""
  make_option("--reference",     type = "character", default = ""),      # "var,level;var2,lvl" | ""
  make_option("--normalization", type = "character", default = "TSS"),   # TSS | CLR | NONE
  make_option("--transform",     type = "character", default = "LOG"),   # LOG | PLOG | NONE
  make_option("--min_prevalence",type = "double",    default = 0.1),
  make_option("--min_abundance", type = "double",    default = 0.0),
  make_option("--max_significance", type = "double", default = 0.1),     # q-value cutoff
  make_option("--cores",         type = "integer",   default = 1),
  make_option("--plots",         type = "character", default = "TRUE")   # summary plot only
)))

splitc <- function(s) if (nchar(s)) trimws(strsplit(s, ",", fixed = TRUE)[[1]]) else NULL

data     <- read.delim(opt$data,     row.names = 1, check.names = FALSE, sep = "\t")
metadata <- read.delim(opt$metadata, row.names = 1, check.names = FALSE, sep = "\t")

fit <- maaslin3(
  input_data        = data,
  input_metadata    = metadata,
  output            = opt$output,
  fixed_effects     = splitc(opt$fixed),
  random_effects    = splitc(opt$random),
  reference         = if (nchar(opt$reference)) opt$reference else NULL,
  normalization     = opt$normalization,
  transform         = opt$transform,
  min_prevalence    = opt$min_prevalence,
  min_abundance     = opt$min_abundance,
  max_significance  = opt$max_significance,
  cores             = opt$cores,
  plot_summary_plot = as.logical(opt$plots),
  plot_associations = FALSE,   # per-association PNGs are many files; the summary plot is the keeper
  save_models       = FALSE,
  verbosity         = "WARN"
)

cat("MAASLIN3_OK\n")
