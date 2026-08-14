#!/usr/bin/env bash
# RESTORE the R stats environment exactly as renv.lock records it. This is what the image runs.
#
# renv::restore() resolves nothing — it installs the exact package versions, from the exact
# repositories, that the lock names. install.R is the AUTHOR path (resolve + relock) and is
# never run by a build; keeping them apart is what makes "works on my laptop" and "works in
# the image" the same claim.
#
#   bash envs/r-stats/restore.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

Rscript -e '
  options(repos = c(CRAN = "https://cloud.r-project.org"))
  if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv")
  # renv.lock records the R version it was authored against; restore warns (not fails) on a
  # different one, which is why the image base image is chosen to match it.
  lock <- jsonlite::fromJSON("renv.lock")
  cat("lock authored against R", lock$R$Version, "| running R", as.character(getRversion()), "\n")
  renv::restore(prompt = FALSE)
'
bash "$HERE/verify.sh"
