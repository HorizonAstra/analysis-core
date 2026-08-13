#!/usr/bin/env Rscript

# Spatial Differential Expression Analysis
# Runs Seurat FindAllMarkers on pre-clustered spatial data (SingleCellExperiment).
# Optionally runs DESpace spatially-variable gene detection (--despace flag).
#
# When run with multiple samples, clusters are assumed to be jointly determined
# and interpretable as the same IDs across samples.
# Input: path(s)s to original Visium data file, and path to the associated metadata file with sample IDs and cluster information.
# Future update: consider a SingleCellExperiment RDS object that already has all of this information stored.
# assignments already present in colData (e.g. from run_bayesspace.R).

library(optparse)

option_list = list(
  make_option("--datapath", type = "character", default = NULL,
              help = "Path to input data directory [required]"),
  make_option("--outdir", type = "character", default = NULL,
              help = "Output directory [required]"),
  make_option("--metapath", type = "character", default = NULL,
              help = "Path to metadata file containing IDs and cluster data [required]"),
  make_option("--idcol", type = "character", default = "sample",
              help = "colData column containing sample IDs [default %default]"),
  make_option("--clustercol", type = "character", default = "spatial.cluster",
              help = "colData column containing cluster IDs [default %default]"),
  make_option("--despace", action = "store_true", default = FALSE,
              help = "Also run DESpace spatially-variable gene detection [default %default]"),
  make_option("--test", action = "store_true", default = FALSE,
              help = "Test mode (reserved for future fixed-seed validation)")
)

parser = OptionParser(option_list = option_list)
args   = parse_args(parser)

if (is.null(args$datapath)) {
  print_help(parser)
  stop("--datapath is required")
}
if (is.null(args$outdir)) {
  print_help(parser)
  stop("--outdir is required")
}
if (is.null(args$metapath)) {
  print_help(parser)
  stop("--metapath is required")
}
if (!file.exists(args$metapath)) {
  stop("metapath not found: ", args$metapath)
}

datapath   = args$datapath   #Note: could be one file or a comma-separated list.
outdir     = args$outdir
metapath   = args$metapath   #Note: will always be one file.
clustercol = args$clustercol
idcol      = args$idcol
run_despace = args$despace

#Split datapath on any commas and clean whitespace
datapath = gsub("\\s+", "", unlist(strsplit(datapath, ",")))

for(i in 1:length(datapath)){
  if (!dir.exists(datapath[i])) {
    stop("datapath not found: ", datapath[i])
  }
  
}
# Choose cluster mode based on length of datapath
if(length(datapath) == 1){
  clustmode = 'single'
} else {
  clustmode = 'joint'
}
if (!dir.exists(outdir)) {
  dir.create(outdir, recursive = TRUE)
}

message("Starting DE analysis")
message("  datapath:     ", datapath)
message("  outdir:     ", outdir)
message("  metapath:     ", metapath)
message("  clustercol: ", clustercol)
message("  idcol:      ", idcol)
message("  despace:    ", run_despace)

# -- Load Libraries --
library(Seurat)
library(SingleCellExperiment)
library(scater)
library(ggplot2)
library(stringr)
library(dplyr)
if (run_despace) library(DESpace)

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

# -- Load Data --
message("Loading data from ", datapath)
samplelist = paste0('sample', c(1:length(datapath)))  #Note: this needs to be updated to derive values directly from datapath.
                                                      #This would require consistent naming conventions, which are currently unknown.
                                                      #The current version requires that samples are always provided in the exact same order
                                                      #and steps can break otherwise. Should be ok for now as long as the same datapath list is used
                                                      #when doing joint clustering or running DE analysis.
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
  message("Multiple samples in datapath. Loading remaining samples.")
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
  message("Updating barcodes to avoid overlaps between samples")
  colData(data)$newbarcode = paste0(colnames(data), '_', colData(data)$sample)
  colnames(data) = colData(data)$newbarcode
  
  # Adjust positions for each sample in succession to be nudged away from the prior sample's maximum dimensions to prevent overlaps
  # when joint clustering
  message("Updating coordinates to avoid overlaps between samples")
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

message("Loading metadata from ", metapath)
message("Adding previous metadata to SCE object")

#Before adding the metadata, confirm that the rows exactly match
oldmeta = read.csv(metapath)
#Set rownames using "newbarcode" if it exists and using "barcode" otherwise. "newbarcode" is added when data were joint clustered.
if ("newbarcode" %in% colnames(oldmeta)){
  rownames(oldmeta) = oldmeta$newbarcode
} else if ("barcode" %in% colnames(oldmeta)){
  rownames(oldmeta) = oldmeta$barcode
} else{
  stop("barcodes not present in metadata. Cannot proceed with analysis.")
}

if (length(intersect(rownames(oldmeta), colnames(data))) == ncol(data)){
  message("metadata matches samples. Can proceed with analysis")
  colData(data)[[clustercol]] = oldmeta[colnames(data), clustercol]
  colData(data)[[idcol]] = oldmeta[colnames(data), idcol]
} else{
  stop(paste0("Barcodes do not match between the metadata at ", metapath, " and the data from ", datapath, "."))
}

# Validate required colData columns
if (!clustercol %in% colnames(colData(data))) {
  stop("Cluster column '", clustercol, "' not found in colData. ",
       "Available columns: ", paste(colnames(colData(data)), collapse = ", "))
}
if (!idcol %in% colnames(colData(data))) {
  stop("Sample ID column '", idcol, "' not found in colData. ",
       "Available columns: ", paste(colnames(colData(data)), collapse = ", "))
}

# Ensure unique column names (required when merging multiple samples). 
# Note: this should not be possible since this is necessary to generate the metadata file at metapath.
# if (any(duplicated(colnames(data)))) {
#   colData(data)$newbarcode = paste0(colnames(data), '_', colData(data)[[idcol]])
#   colnames(data) = colData(data)$newbarcode
# }

# -- Seurat FindAllMarkers --
# Convert to Seurat object using raw counts.
# Coordinates and image information are preserved in metadata but not used here.
# Note: these steps only depend on the number of samples for the purpose of setting identities and resource demands.
message("Converting to Seurat object...")
sobj = CreateSeuratObject(
  counts    = counts(data),
  meta.data = as.data.frame(colData(data))
)

Idents(sobj) = idcol
sobj = NormalizeData(sobj)
sobj = FindVariableFeatures(sobj)
sobj = ScaleData(sobj, split.by=idcol)   #Note: this scales data for each sample separately if more than one sample present

message("Running FindAllMarkers (cluster column: ", clustercol, ")...")
Idents(sobj) = clustercol
seurat.markers = FindAllMarkers(sobj)

clusterlist = sort(unique(colData(data)[[clustercol]]))

top50 = arrange(subset(seurat.markers, cluster == clusterlist[1]), desc(avg_log2FC))[1:50, ]
for (i in seq(2, length(clusterlist))) {
  top50 = rbind(top50,
                 arrange(subset(seurat.markers, cluster == clusterlist[i]), desc(avg_log2FC))[1:50, ])
}

seurat.markers$cluster = as.numeric(as.character(seurat.markers$cluster))
seurat.markers = arrange(seurat.markers, cluster, desc(avg_log2FC))

out_all  = file.path(outdir, "seurat_cluster_markers_all.csv")
out_top  = file.path(outdir, "seurat_cluster_markers_top50.csv")
write.csv(seurat.markers, out_all, row.names = FALSE, quote = FALSE)
write.csv(top50,          out_top, row.names = FALSE, quote = FALSE)
message("Seurat results written:")
message("  ", out_all)
message("  ", out_top)

# -- DESpace (optional) --
if (run_despace) {
  message("Checking cluster representation across samples for DESpace...")
  clustercheck = table(
    distinct(as.data.frame(colData(data))[, c(idcol, clustercol)])[[idcol]]
  )
  n_missing_samples = length(which(clustercheck != length(clusterlist)))

  if (n_missing_samples > 0) {
    message("WARNING: ", n_missing_samples, " sample(s) do not contain all clusters. ",
            "Skipping DESpace.")
  } else {
    message("All samples contain all clusters. Running DESpace...")
    if (clustmode == 'single'){
      despace_results = svg_test(
        spe        = data,
        cluster_col = clustercol,
        sample_col  = idcol,
        replicates  = FALSE
      )
      cluster_results = individual_svg(
        data,
        edgeR_y    = despace_results$estimated_y,
        replicates  = FALSE,
        cluster_col = clustercol,
        sample_col  = idcol
      )
    } else {
      despace_results = svg_test(
        spe        = data,
        cluster_col = clustercol,
        sample_col  = idcol,
        replicates  = TRUE
      )
      cluster_results = individual_svg(
        data,
        edgeR_y    = despace_results$estimated_y,
        replicates  = TRUE,
        cluster_col = clustercol,
        sample_col  = idcol
      )
    }
    out_de_all     = file.path(outdir, "despace_results_all.csv")
    out_de_cluster = file.path(outdir, "despace_results_byCluster.csv")
    write.csv(despace_results,  out_de_all,     row.names = FALSE, quote = FALSE)
    write.csv(cluster_results,  out_de_cluster, row.names = FALSE, quote = FALSE)
    message("DESpace results written:")
    message("  ", out_de_all)
    message("  ", out_de_cluster)
  }
}

message("DE analysis complete.")
