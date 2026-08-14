#!/usr/bin/env Rscript
# Restore HAllA's private R library, and assert it matches r-requirements.lock.txt.
#
# The PIN is the dated CRAN snapshot in env.conf, not the lock: a frozen date always resolves
# the same versions, transitively, and — unlike remotes::install_version — a plain
# install.packages can use BINARIES. That matters: install_version builds from source, and
# mnormt is a Fortran package, so a source path needs gfortran and fails on a machine without
# it. The lock is therefore a CHECK (fail if the installed set drifts from what was authored)
# rather than an installation instruction.
#
# A separate file rather than an inline `Rscript -e` string because passing regex escapes
# through a shell heredoc into R silently mangles backslashes.
#
#   Rscript restore_r.R <lib_dir> <lock_file> <cran_snapshot_url>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3) stop("usage: restore_r.R <lib_dir> <lock_file> <cran_snapshot_url>")
lib <- args[1]; lock_file <- args[2]; repo <- args[3]

dir.create(lib, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(lib, .libPaths()))

lines <- trimws(readLines(lock_file, warn = FALSE))
lines <- lines[nzchar(lines) & !startsWith(lines, "#")]   # no regex needed
locked <- do.call(rbind, strsplit(lines, "[[:space:]]+"))
want <- setNames(locked[, 2], locked[, 1])

# Top-level packages only; the snapshot resolves their dependencies to the same versions the
# lock recorded, which the check below then confirms.
top <- intersect(names(want), c("XICOR", "eva"))
need <- setdiff(top, rownames(installed.packages(lib.loc = lib)))
if (length(need)) install.packages(need, lib = lib, repos = repo, quiet = TRUE)

have <- installed.packages(lib.loc = lib)[, "Version"]
drift <- character()
for (pkg in names(want)) {
  if (!pkg %in% names(have)) { drift <- c(drift, sprintf("%s: missing (want %s)", pkg, want[[pkg]])); next }
  if (!identical(as.character(have[[pkg]]), want[[pkg]]))
    drift <- c(drift, sprintf("%s: have %s, lock says %s", pkg, have[[pkg]], want[[pkg]]))
  else cat(sprintf("  %-14s %s\n", pkg, want[[pkg]]))
}
if (length(drift)) {
  cat("FAIL: installed R library does not match the lock:\n")
  cat(paste0("  - ", drift, collapse = "\n"), "\n")
  cat("The dated snapshot in env.conf may have moved, or this platform resolves differently.\n")
  cat("Re-run build.sh to re-author the lock if the change is intended.\n")
  quit(status = 1)
}
cat("halla R library restored and matches the lock\n")
