#!/usr/bin/env Rscript

# SpaCET Cell Type Deconvolution (TumorSPACE_AWS)
# Purpose: Run SpaCET cell-type deconvolution on Visium data.
#
# Core logic verbatim from:
#   /project/araman/vivek/TME_SPI/Revisions/scripts_2/Revisions_TumorSPACE_v1.R
#   (spacet task block, lines 237-305)
#
# Adaptations for standalone CLI use:
#   - raw_file_path → --raw-data-dir
#   - tmp_path_job  → --outdir  (used for both cache and final output)
#   - cancer_type$SpaCET_CancerType → --cancer-type (SpaCET string, e.g. "BRCA")
#   - /project/.../Hg38_GeneNames_MultipleFormats.txt → --ref-dir
#   - coreNo=8 → --cores

# -- Parse Command Line Arguments --
library(optparse)

option_list <- list(
  make_option("--raw-data-dir", type = "character", default = NULL,
              help = "Path to input data directory with M.txt, features.txt, barcodes_positions.txt (required)"),
  make_option("--outdir", type = "character", default = NULL,
              help = "Output directory for Spacet_Matrix.txt and intermediate cache files (required)"),
  make_option("--cancer-type", type = "character", default = NULL,
              help = "SpaCET cancer type string, e.g. BRCA, LUAD, COAD (required). See reference_data/spacet/tissue_types_lookup.txt"),
  make_option("--cores", type = "integer", default = 8L,
              help = "Number of parallel cores for SpaCET deconvolution [default %default]"),
  make_option("--ref-dir", type = "character", default = NULL,
              help = "Path to reference_data directory containing Hg38_GeneNames_MultipleFormats.txt (required)")
)

parser <- OptionParser(option_list = option_list)
args   <- parse_args(parser)

# Validate required args
if (is.null(args[["raw-data-dir"]])) { print_help(parser); stop("--raw-data-dir is required") }
if (is.null(args[["outdir"]]))        { print_help(parser); stop("--outdir is required") }
if (is.null(args[["cancer-type"]]))   { print_help(parser); stop("--cancer-type is required") }
if (is.null(args[["ref-dir"]]))       { print_help(parser); stop("--ref-dir is required") }

raw_file_path    <- file.path(args[["raw-data-dir"]], "")   # ensure trailing slash equiv
outdir           <- args[["outdir"]]
cancer_type_str  <- args[["cancer-type"]]
cores            <- args[["cores"]]
ref_dir          <- args[["ref-dir"]]

if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)

# -- Load Libraries --
library(dplyr)
library(data.table)
library(SpaCET)

# ── SpaCET task block (verbatim from Revisions_TumorSPACE_v1.R, lines 237-305) ──

barcode_positions <- fread(paste0(raw_file_path,"barcodes_positions.txt"))
mtx_nodup_loc  <- file.path(outdir, "M_nodup.txt")
feat_nodup_loc <- file.path(outdir, "features_nodup.txt")

if (!(file.exists(mtx_nodup_loc))){
  M <- as.matrix(fread(paste0(raw_file_path,"M.txt"),header=F))
  features <- fread(paste0(raw_file_path,"features.txt"))
  # Explicitly convert any Ensemble gene names into common gene name
  if (!("gene_name" %in% names(features))){
      gene_conv_dt <- fread(file.path(ref_dir, "Hg38_GeneNames_MultipleFormats.txt")) %>%
        select(ensembl_gene_id, gene_name = external_gene_name) %>%
        arrange(desc(gene_name)) %>%
        unique() %>%
        mutate(gene_name = ifelse(gene_name == "ensembl_gene_id", ensembl_gene_id,
                                  ifelse(is.na(gene_name), ensembl_gene_id, gene_name)))
    features <- features %>% left_join(gene_conv_dt)
  }
  # Remove features with an NA gene name
  features_sub <- features %>% mutate(featID = row_number()) %>% filter(!is.na(gene_name), gene_name != "")
  # Collapse duplicate gene names by summing counts (aka had unique Ensemble ID but the same common ID)
  features_sub_unique <- features_sub %>% semi_join(features_sub[,.N,by="gene_name"][N == 1],by="gene_name")
  features_sub_dup    <- features_sub %>% semi_join(features_sub[,.N,by="gene_name"][N > 1],by="gene_name")
  # First, deposit unique genes into this matrix
  M_nodup      <- M[,features_sub_unique$featID]
  features_nodup <- features_sub_unique$gene_name
  if (nrow(features_sub_dup) > 0){
    # Then, loop through all non-unique genes, sum their counts by barcode, and append that new column to the count matrix
    features_sub_dup_list <- features_sub_dup[,.N,by="gene_name"]
    for (i in 1:nrow(features_sub_dup_list)){
      newCol <- rowSums(M[,filter(features_sub_dup,gene_name == features_sub_dup_list$gene_name[i])$featID])
      M_nodup        <- cbind(M_nodup,newCol)
      features_nodup <- c(features_nodup,features_sub_dup_list$gene_name[i])
    }
  }
  M_nodup %>% write.table(mtx_nodup_loc,quote=F,sep="\t",row.names=F,col.names=F)
  data.table(gene_name = features_nodup) %>% write.table(feat_nodup_loc,quote=F,sep="\t",row.names=F,col.names=T)
} else {M_nodup <- as.matrix(fread(mtx_nodup_loc,header=F))}
features_nodup <- fread(feat_nodup_loc)

# Create SpaCET obj
M_tr <- t(M_nodup)
rownames(M_tr) <- dplyr::pull(features_nodup, 1)
colnames(M_tr) <- barcode_positions$barcode
spot <- as.matrix(select(barcode_positions,pxl_row_in_fullres,pxl_col_in_fullres))
rownames(spot) <- barcode_positions$barcode
SpaCET_obj <- create.SpaCET.object(counts = M_tr,spotCoordinates = spot,imagePath=NA,platform="Visium")

# Cell Type Deconvolution
# Note: this first QC step removes 'low-quality' spots that happen to have no detected genes present.
# Note that this will change the full set of barcodes in the final object.
SpaCET_obj <- SpaCET.quality.control(SpaCET_obj)
SpaCET_obj <- SpaCET.deconvolution(SpaCET_obj, cancerType=cancer_type_str, coreNo=cores)

spacet_dt  <- SpaCET_obj@results$deconvolution$propMat %>%
  as.data.table() %>%
  mutate(CellType = row.names(SpaCET_obj@results$deconvolution$propMat)) %>%
  melt.data.table(id.vars="CellType",variable.name = "Barcode",value.name = "Proportion")
spacet_mtx <- spacet_dt %>%
  mutate(CellType = gsub(" ","_",CellType)) %>%
  dcast.data.table(Barcode ~ CellType, value.var="Proportion")
spacet_mtx %>% write.table(file.path(outdir,"Spacet_Matrix.txt"),quote=F,sep="\t",row.names=F,col.names=T)

cat(sprintf("SpaCET complete. Output: %s\n", file.path(outdir, "Spacet_Matrix.txt")))
cat(sprintf("  Barcodes (after QC): %d\n", nrow(spacet_mtx)))
cat(sprintf("  Cell types: %d\n", ncol(spacet_mtx) - 1L))
