#!/usr/bin/env Rscript
# Check if msigdbr is installed, install if needed

cat("Checking for msigdbr package...\n")

if (!requireNamespace("msigdbr", quietly = TRUE)) {
  cat("msigdbr not found. Installing from CRAN...\n")
  install.packages("msigdbr", repos = "https://cloud.r-project.org/")
  cat("Installation complete!\n")
} else {
  cat("msigdbr is already installed.\n")
  cat("Version:", as.character(packageVersion("msigdbr")), "\n")
}

# Test that it works
library(msigdbr)
cat("\nTesting msigdbr...\n")
cat("Available species:\n")
species <- msigdbr_species()
print(species[species$species_name %in% c("Homo sapiens", "Mus musculus"), ])

cat("\nmsigdbr is ready to use!\n")
