#!/usr/bin/env Rscript
# Thin, non-interactive wrapper around lefser() — the R port of LEfSe (biomarker discovery
# by Kruskal-Wallis + Wilcoxon + Linear Discriminant Analysis effect size).
#
# Invoked by src/compute/tertiary/lefser.py with the renv project (envs/r-stats) as the
# working directory. Every input is a pre-validated, pre-aligned TSV the Python caller
# wrote; this script only reshapes into the SummarizedExperiment lefser wants, runs it, and
# writes the result out.
#
# Two shape facts that make this wrapper necessary:
#   * lefser takes features-as-ROWS (the transpose of how we store tables), inside a
#     SummarizedExperiment whose colData carries the class column;
#   * it wants relative abundances scaled to sum to 100 per sample, which relativeAb() does.

suppressWarnings(suppressMessages({
  library(optparse)
  library(lefser)
  library(SummarizedExperiment)
}))

opt <- parse_args(OptionParser(option_list = list(
  make_option("--data",      type = "character"),                  # samples x features TSV
  make_option("--metadata",  type = "character"),                  # samples x variables TSV
  make_option("--output",    type = "character"),                  # output dir
  make_option("--class_col", type = "character"),                  # 2-level grouping column
  make_option("--subclass_col", type = "character", default = ""), # optional blocking column
  make_option("--kruskal",   type = "double",  default = 0.05),
  make_option("--wilcox",    type = "double",  default = 0.05),
  make_option("--lda",       type = "double",  default = 2.0),
  make_option("--method",    type = "character", default = "none"),  # multiple-testing method
  make_option("--trim_names", type = "character", default = "TRUE"),
  make_option("--terminal_nodes", type = "character", default = "FALSE"),
  make_option("--plot",      type = "character", default = "TRUE")
)))

dir.create(opt$output, recursive = TRUE, showWarnings = FALSE)

data <- read.delim(opt$data,     row.names = 1, check.names = FALSE, sep = "\t")
meta <- read.delim(opt$metadata, row.names = 1, check.names = FALSE, sep = "\t")
meta <- meta[rownames(data), , drop = FALSE]          # align to the abundance rows

# features as rows, samples as columns
counts <- t(as.matrix(data))
se <- SummarizedExperiment(assays = SimpleList(abundance = counts),
                           colData = DataFrame(meta, row.names = rownames(meta)))
# scale to per-sample percentages; lefser warns (and its LDA is off) otherwise
se <- relativeAb(se)

# Collinear features (a taxonomy where a parent is the sum of its children) break the LDA;
# restricting to terminal nodes is lefser's own remedy. Opt-in, since it only applies to
# hierarchical feature names.
if (toupper(opt$terminal_nodes) == "TRUE") {
  keep <- get_terminal_nodes(rownames(se))
  if (length(keep)) se <- se[keep, ]
}

subclass <- if (nchar(opt$subclass_col)) opt$subclass_col else NULL

# lefser reports its reference category on stderr/message; capture it so the caller can
# tell the user which direction a positive score means.
msgs <- character()
res <- withCallingHandlers(
  lefser(se,
         classCol          = opt$class_col,
         subclassCol       = subclass,
         kruskal.threshold = opt$kruskal,
         wilcox.threshold  = opt$wilcox,
         lda.threshold     = opt$lda,
         method            = opt$method,
         trim.names        = toupper(opt$trim_names) == "TRUE"),
  message = function(m) { msgs <<- c(msgs, conditionMessage(m)); invokeRestart("muffleMessage") },
  warning = function(w) { msgs <<- c(msgs, conditionMessage(w)); invokeRestart("muffleWarning") }
)

write.table(res, file.path(opt$output, "lefser_results.tsv"),
            sep = "\t", quote = FALSE, row.names = FALSE)
writeLines(msgs, file.path(opt$output, "lefser_messages.txt"))
cat("N_FEATURES_KEPT:", nrow(se), "\n")
cat("N_SIGNIFICANT:", nrow(res), "\n")

if (toupper(opt$plot) == "TRUE" && nrow(res) > 0) {
  # One bar per feature: with hundreds of hits the figure is both unreadable and taller
  # than ggsave will accept (it caps at 50in), so plot the strongest effects by |score|.
  top <- res[order(-abs(res$scores)), , drop = FALSE]
  n_plot <- min(nrow(top), 60L)
  ok <- try({
    p <- lefserPlot(top[seq_len(n_plot), , drop = FALSE])
    ggplot2::ggsave(file.path(opt$output, "lefser_plot.png"), p,
                    width = 9, height = min(24, max(3, 0.22 * n_plot + 1.5)),
                    dpi = 150, limitsize = FALSE)
  }, silent = TRUE)
  if (inherits(ok, "try-error")) cat("PLOT_FAILED\n") else cat("N_PLOTTED:", n_plot, "\n")
}

cat("LEFSER_OK\n")
