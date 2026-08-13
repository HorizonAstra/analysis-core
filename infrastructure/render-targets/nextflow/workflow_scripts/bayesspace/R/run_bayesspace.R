#!/usr/bin/env Rscript

# BayesSpace Analysis Pipeline (Bioconductor 3.20 / BayesSpace 1.19+)
# Purpose: Run BayesSpace spatial clustering on Visium data.
# Supports both standard 10x Visium outputs and reformatted data.
# This version uses BayesSpace's native readVisium which handles Space Ranger V1 and V2+.
# Updated to enable joint clustering for multiple samples. This mode is automatically detected if datapath is a list with more than one path.

# -- Parse Command Line Arguments --
# Accept datapath, nPCs, q, and output directory from the command line

library(optparse)

option_list = list(
  make_option("--datapath", type = "character", default = NULL,
              help = "Path to input data directory (required)"),
  make_option("--nPCs", type = "integer", default = 15,
              help = "Number of principal components [default %default]"),
  make_option("--q", type = "integer", default = 8,
              help = "Number of spatial clusters [default %default]"),
  make_option("--theta", type = "integer", default = 2,
              help = "clustering penalty parameter for Harmony (ignored for single clustering) [default %default]"),
  
  make_option("--outdir", type = "character", default = ".",
              help = "Output directory [default %default]"),
  make_option("--test", action = "store_true", default = FALSE,
              help = "Run in test mode with fixed seeds and md5sum validation")
)

parser = OptionParser(option_list = option_list)
args = parse_args(parser)

if (is.null(args$datapath)) {
  print_help(parser)
  stop("--datapath is required")
}

datapath = args$datapath
nPCs = args$nPCs
q = args$q
outdir = args$outdir
test_mode = args$test
theta = args$theta   # MISSING THETA?

#Split datapath on any commas and clean whitespace
datapath = gsub("\\s+", "", unlist(strsplit(datapath, ",")))

# Choose cluster mode based on length of datapath
if(length(datapath) == 1){
  clustmode = 'single'
} else {
  clustmode = 'joint'
}


if (!dir.exists(outdir)) {
  dir.create(outdir, recursive = TRUE)
}

# -- Load Libraries --
# Load packages required for BayesSpace analysis
library(SingleCellExperiment)
library(ggplot2)
library(harmony)
library(BayesSpace)
library(scater)

# -- Define readVisium_custom --
# Reads reformatted Visium data from a directory containing M.txt, features.txt,
# barcodes.txt, and barcodes_positions_imageScaling.txt
readVisium_custom <- function(dirname) {
  rowData = read.table(file.path(dirname, "features.txt"),
                       header = TRUE)
  colnames(rowData) = "gene_id"
  counts = data.table::fread(file.path(dirname, "M.txt"), header = FALSE, sep = "\t")
  counts = t(as.matrix(counts))
  barcodes = read.table(file.path(dirname, "barcodes.txt"), header = TRUE)
  colnames(counts) = barcodes$barcode
  rownames(counts) = rowData$gene_id

  # Accept both filename variants:
  #   barcodes_positions_imageScaling.txt  (original reformatted format)
  #   barcodes_positions.txt               (TumorSPACE_AWS benchmark format)
  pos_candidates = c(
    file.path(dirname, "barcodes_positions_imageScaling.txt"),
    file.path(dirname, "barcodes_positions.txt")
  )
  pos_file = pos_candidates[file.exists(pos_candidates)][1]
  if (is.na(pos_file))
    stop("Cannot find barcodes_positions_imageScaling.txt or barcodes_positions.txt in ", dirname)
  message("  Reading barcode positions from: ", basename(pos_file))

  colData = read.table(pos_file, header = TRUE, sep = "\t")
  rownames(colData) = colData$barcode
  maxdim = max(colData$pxl_row_in_fullres, colData$pxl_col_in_fullres)

  # spot_diameter_scaled is present in imageScaling variant but not in the
  # standard barcodes_positions.txt; used only for cluster plot visualization.
  if ("spot_diameter_scaled" %in% colnames(colData)) {
    spot_diam_fullres = colData$spot_diameter_scaled[1] / (2000 / maxdim)
  } else {
    spot_diam_fullres = NA  # visualization only; does not affect clustering
  }

  scalef = list(regist_target_img_scalef = NA,
                tissue_hires_scalef = 2000 / maxdim,
                tissue_lowres_scalef = 600 / maxdim,
                fiducial_diameter_fullres = NA,
                spot_diameter_fullres = spot_diam_fullres)

  sce = SingleCellExperiment(assays = list(counts = counts),
                             rowData = rowData, colData = colData)
  sce = sce[, Matrix::colSums(counts(sce)) > 0]
  metadata(sce)$BayesSpace.data = list()
  metadata(sce)$BayesSpace.data$platform = "Visium"
  metadata(sce)$BayesSpace.data$is.enhanced = FALSE
  metadata(sce)$BayesSpace.data$scalef = scalef

  return(sce)
}

# -- Define run_BayesSpace --
# Main wrapper function: auto-detects input format, preprocesses, and clusters.
# Uses BayesSpace's native readVisium for standard data (supports V1 and V2+).

run_BayesSpace <- function(datapath, mode = clustmode, nPCs = 15, q = 8, theta = 2, fixed_seeds = NULL) {
  samplelist = paste0('sample', c(1:length(datapath)))   #Note: would be better to define explicitly from values in datapath. This version could create ambiguities in metadata files later.
  # Auto-detect input format
  # Check for standard Visium output (filtered_feature_bc_matrix directory)
  # or reformatted data (M.txt file)
  
  if (dir.exists(file.path(datapath[1], "filtered_feature_bc_matrix"))) {
    message("Detected standard Visium output. Using readVisium().")
    data = readVisium(datapath[1])
    colData(data)$sample = samplelist[1]
  } else if (file.exists(file.path(datapath[1], "M.txt"))) {
    message("Detected reformatted Visium data. Using readVisium_custom().")
    data = readVisium_custom(datapath[1])
    colData(data)$sample = samplelist[1]
  } else {
    stop("Cannot detect data format: expected 'filtered_feature_bc_matrix/' directory ",
         "or 'M.txt' file in ", datapath[1])
  }
  if (clustmode == 'joint'){
    for(i in 2:length(datapath)){
      if (dir.exists(file.path(datapath[i], "filtered_feature_bc_matrix"))) {
        message("Detected standard Visium output. Using readVisium().")
        temp = readVisium(datapath[i])
        colData(temp)$sample = samplelist[i]
        data = cbind(data, temp)
      } else if (file.exists(file.path(datapath[i], "M.txt"))) {
        message("Detected reformatted Visium data. Using readVisium_custom().")
        temp = readVisium_custom(datapath[i])
        colData(temp)$sample = samplelist[i]
        data = cbind(data, temp)
      } else {
        stop("Cannot detect data format: expected 'filtered_feature_bc_matrix/' directory ",
             "or 'M.txt' file in ", datapath[i])
      }
    }
    # Update barcodes to ensure unique IDs after merging samples
    colData(data)$newbarcode = paste0(colnames(data), '_', colData(data)$sample)
    colnames(data) = colData(data)$newbarcode
    
    # Adjust positions for each sample in succession to be nudged away from the prior sample's maximum dimensions to prevent overlaps
    # when joint clustering
    data$newrow = data$newcol = rep(0, ncol(data))
    for(i in 1:length(samplelist)){
      temp = which(data$sample == samplelist[i])
      maxrow = max(data$newrow)
      maxcol = max(data$newcol)
      data$newrow[temp] = data$array_row[temp] + maxrow + 50
      data$newcol[temp] = data$array_col[temp] + maxcol + 50
    }
    
    data$oldrow = data$array_row
    data$oldcol = data$array_col
    data$array_row = data$newrow
    data$array_col = data$newcol
  }

  # Generate or use fixed seeds
  if (!is.null(fixed_seeds)) {
    seed1 = fixed_seeds[1]
    seed2 = fixed_seeds[2]
  } else {
    seed1 = sample(10000000, 1)
    seed2 = sample(10000000, 1)
  }

  # Preprocessing
  # Run spatialPreprocess with specified number of PCs and HVGs
  set.seed(seed1)
  message("Preprocessing data (n.PCs = ", nPCs, ")")
  data = spatialPreprocess(data, platform = "Visium",
                           n.PCs = nPCs, n.HVGs = 2000, log.normalize = TRUE)
  if (clustmode == 'joint'){
    # Prepare the data and run Harmony to integrate values before clustering
    data = runUMAP(data, dimred = "PCA")
    colnames(reducedDim(data, "UMAP")) = c("UMAP1", "UMAP2")
    data = RunHarmony(data, "sample", verbose = F, theta = theta) 
    data = runUMAP(data, dimred = "HARMONY", name = "UMAP.HARMONY")
    colnames(reducedDim(data, "UMAP.HARMONY")) = c("UMAP1", "UMAP2")
  }
  
  # Spatial clustering
  # Run spatialCluster with d matching nPCs for consistency
  # If joint clustering, adds the use.dimred option to choose the HARMONY reduction instead of the original PCA.
  
  set.seed(seed2)
  message("Running BayesSpace clustering (q = ", q, ", d = ", nPCs, ")")
  if (clustmode == 'single'){
    data = spatialCluster(data, q = q, platform = "Visium", d = nPCs,
                          init.method = "mclust", model = "t", gamma = 2,
                          nrep = 2000, burn.in = 100,
                          save.chain = FALSE)
  } else {
    data = spatialCluster(data, q = q, platform = "Visium", use.dimred = "HARMONY", d = nPCs,
                          init.method = "mclust", model = "t", gamma = 2,
                          nrep = 2000, burn.in = 100,
                          save.chain = FALSE)
  }
  result = list(sce = data, seed1 = seed1, seed2 = seed2)
  return(result)
}

# -- Run Analysis --
# Execute the BayesSpace pipeline with the provided parameters
message("Starting BayesSpace analysis")
message("  datapath: ", datapath)
message("  nPCs: ", nPCs)
message("  q: ", q)
message("  outdir: ", outdir)
message("  cluster mode: ", clustmode)
message("  test_mode: ", test_mode)

# Test mode configuration
# Use fixed seeds for reproducibility; expected md5sum is validated after output

TEST_SEED1 = 42
TEST_SEED2 = 123

if (test_mode) {
  result = run_BayesSpace(datapath, nPCs = nPCs, q = q,
                          fixed_seeds = c(TEST_SEED1, TEST_SEED2))
} else {
  result = run_BayesSpace(datapath, nPCs = nPCs, q = q)
}

if (test_mode) {
  # -- Test Mode: Save colData for md5sum validation --
  # PASS/FAIL checked by tests/bayesspace/test_bayesspace.sh against committed baseline.
  if (clustmode == 'single'){
    csv_path = file.path(outdir, "test_coldata_single.csv")
    write.csv(as.data.frame(colData(result$sce)), csv_path, row.names = TRUE)
    message("Saved single test colData to ", csv_path)
    message("md5sum: ", tools::md5sum(csv_path))
  } else{
    csv_path = file.path(outdir, "test_coldata_joint.csv")
    write.csv(as.data.frame(colData(result$sce)), csv_path, row.names = TRUE)
    message("Saved joint test colData to ", csv_path)
    message("md5sum: ", tools::md5sum(csv_path))
  }
  message("Seeds used: seed1=", result$seed1, ", seed2=", result$seed2)
  message("BayesSpace test output complete. Validation handled by test_bayesspace.sh.")
  
} else {
  # -- Normal Mode: Save colData CSV and Parameters --
  csv_path = file.path(outdir, "bayesspace_coldata.csv")
  write.csv(as.data.frame(colData(result$sce)), csv_path, row.names = TRUE)
  message("Saved colData to ", csv_path)

  # -- Save Parameters File --
  params_path = file.path(outdir, "parameters.txt")
  writeLines(c(
    paste("datapath:", datapath),
    paste("n.PCs:", nPCs),
    paste("n.HVGs:", 2000),
    paste("log.normalize:", TRUE),
    paste("q:", q),
    paste("d:", nPCs),
    paste("theta:", theta),
    paste("nrep:", 2000),
    paste("burn.in:", 100),
    paste("gamma:", 2),
    paste("init.method:", "mclust"),
    paste("model:", "t"),
    paste("save.chain:", FALSE),
    paste("seed1:", result$seed1),
    paste("seed2:", result$seed2)
  ), params_path)
  message("Saved parameters to ", params_path)
}

# -- Save UMAPs before and after Harmony, if joint clustering --
if (clustmode == 'joint'){
  png_path = file.path(outdir, "umap_original.png")
  png(png_path, width = 800, height = 800, type = "cairo")
  ggplot(data.frame(reducedDim(result$sce, "UMAP")), 
         aes(x = UMAP1, y = UMAP2, color = factor(result$sce$sample))) +
    geom_point() +
    labs(color = "Sample") +
    theme_bw()
  dev.off()
  message("Saved original UMAP to ", png_path)
  
  png_path = file.path(outdir, "umap_harmony.png")
  png(png_path, width = 800, height = 800, type = "cairo")
  ggplot(data.frame(reducedDim(result$sce, "UMAP.HARMONY")), 
         aes(x = UMAP1, y = UMAP2, color = factor(result$sce$sample))) +
    geom_point() +
    labs(color = "Sample") +
    theme_bw()
  dev.off()
  message("Saved integrated UMAP to ", png_path)
}

# -- Save Cluster Plot (both test and normal mode) --
# If joint clustering, save a separate plot for each sample
if (clustmode == 'single'){
  png_path = file.path(outdir, "cluster_plot.png")
  png(png_path, width = 800, height = 800, type = "cairo")
  print(clusterPlot(result$sce, label = "spatial.cluster"))
  dev.off()
  message("Saved cluster plot to ", png_path)
} else{
  samplelist = unique(result$sce$sample)
  for(i in 1:length(samplelist)){
    temp = which(result$sce$sample == samplelist[i])  
    tempplot = clusterPlot(result$sce[,temp], color = NA) + 
      labs(title = paste0("BayesSpace joint clusters: ", samplelist[i]))
    
    png_path = file.path(outdir, paste0("cluster_plot_",samplelist[i],".png"))
    png(png_path, width = 800, height = 800, type = "cairo")
    print(tempplot)
    dev.off()
    message("Saved cluster plot to ", png_path)
  }
}

message("BayesSpace analysis complete.")
