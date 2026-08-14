#!/usr/bin/env bash
# Assert every R package a tool needs actually loads. Ends both install.R (author) and
# restore.sh, and runs in the image build, so a broken env fails at build time rather than at
# a user's first request. Add a package here when you add the tool that uses it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
Rscript -e '
  suppressMessages(renv::load("."))
  need <- c("maaslin3", "lefser", "MMUPHin", "ccrepe", "banocc", "optparse", "SummarizedExperiment")
  miss <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
  for (p in setdiff(need, miss)) cat(sprintf("  %-22s %s\n", p, as.character(packageVersion(p))))
  if (length(miss)) { cat("FAIL: missing/unloadable:", paste(miss, collapse=", "), "\n"); quit(status=1) }
  cat("r-stats env OK\n")
'
