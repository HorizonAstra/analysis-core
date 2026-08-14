#!/usr/bin/env Rscript
# AUTHOR the tertiary bioBakery STATS env — system R + renv (no conda).
#
# This is the path that RESOLVES current versions and rewrites renv.lock. Run it by hand when
# you want to move versions, then commit the lock. A build never runs this: it runs
# restore.sh, which installs exactly what the lock records. Two paths so that "works on my
# laptop" and "works in the image" are the same claim rather than two.
#
# renv is R's lockfile-based, project-local env manager (the `uv`/`venv` of R): it keeps
# these packages in a library under this dir, isolated from the global R install, and pins
# exact versions in renv.lock. That one lockfile is the whole reproducibility contract — it
# rebuilds the identical library on another Mac, or in a Linux/Docker image, via:
#     cd envs/r-stats && Rscript -e 'renv::restore()'   (needs an r-base, e.g. a rocker image)
#
# On this Mac (CRAN R), Bioconductor ships precompiled arm64 binaries, so this DOWNLOADS the
# packages rather than compiling them. To build/refresh from anywhere:
#     Rscript path/to/envs/r-stats/install.R
#
# Grow the package list below as each tool is wired up — install what we actually use.

# Run from this script's own directory so renv treats it as the project root.
.file <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
if (length(.file)) setwd(dirname(normalizePath(.file)))

options(repos = c(CRAN = "https://cloud.r-project.org"))
if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv")

# First run stands up the renv project (empty lock + infra); later runs just activate it.
if (!file.exists("renv.lock")) renv::init(bare = TRUE, restart = FALSE) else renv::load(".")

# Curated env: lock exactly what we install, rather than scanning code for library() calls
# (our wrapper scripts live elsewhere in the repo, so a code-scan snapshot would miss them).
renv::settings$snapshot.type("all")

# bioBakery tertiary STATS packages. `bioc::` = Bioconductor (macOS binaries on CRAN R).
#   maaslin3 — multivariable association / differential abundance (the workhorse; tool #1)
#   lefser   — LEfSe (R port): biomarker discovery, Kruskal-Wallis + LDA effect size
#   MMUPHin  — meta-analysis + batch/covariate correction across studies
#   ccrepe   — compositionality-corrected correlation / co-occurrence
#   banocc   — Bayesian compositional correlation networks (Stan-backed, slower)
# Still deferred: github::biobakery/anpan — the one source-only package (compiles, and
# pulls a heavier dependency set); add it when its tool is built.
renv::install(c(
  "bioc::maaslin3",
  "bioc::lefser",
  "bioc::MMUPHin",
  "bioc::ccrepe",
  "bioc::banocc"
))

renv::snapshot()
cat("\nr-stats AUTHORED. lockfile:", normalizePath("renv.lock"), "— commit it.\n")
# Same check restore.sh and the image build run, so authoring cannot leave a broken env behind.
quit(status = system2("bash", c(shQuote("verify.sh"))))
