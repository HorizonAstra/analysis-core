# Input and Output Specification

This document describes the exact format requirements for input data and what outputs you can expect from TumorSPACE_AWS.

## Input Data Format

### Directory Structure

Each spatial transcriptomics dataset should be organized in a single directory with the following files:

```
your_dataset/
├── M.txt                        # Expression matrix
├── barcodes.txt                 # Spot barcodes
├── features.txt                 # Gene names
└── barcodes_positions.txt       # Spatial coordinates
```

### File Specifications

#### 1. M.txt - Expression Matrix

**Format**: Tab-delimited text file  
**Dimensions**: N_spots × N_genes  
**Content**: Raw or normalized gene expression counts

**Requirements**:
- Each row represents one spot
- Each column represents one gene
- Values are numeric (integers or floats)
- No row or column headers
- Rows correspond to barcodes in `barcodes.txt`
- Columns correspond to genes in `features.txt`

**Example** (first 3 rows, 5 columns):
```
0	1	0	3	0
2	0	1	0	4
0	0	0	2	1
```

**File size**: Varies (13 MB for 370 spots × 18,030 genes; up to 121 MB for larger datasets)

---

#### 2. barcodes.txt - Spot Identifiers

**Format**: Plain text file, one barcode per line  
**Content**: Unique identifier for each spot

**Requirements**:
- Header line: `barcode`
- One barcode per line after the header
- Order matches rows in M.txt
- Typically formatted as: `BARCODE-1`

**Example**:
```
barcode
AAACATGGTGAGAGGA-1
AAACCGTTCGTCCAGG-1
AAAGAATGACCTTAGA-1
AAAGGCTACGGACCAT-1
```

**File size**: Typically 5-15 KB

---

#### 3. features.txt - Gene Names

**Format**: Plain text file, one gene per line  
**Content**: Gene symbols or identifiers

**Requirements**:
- Header line: `ensembl_gene_id` (or another single-column header)
- One gene identifier per line after the header
- Order matches columns in M.txt
- Ensembl IDs (`ENSG...`) are fully supported and used in the included benchmark dataset; HUGO symbols also work
- Ensembl IDs appear as-is in the data output files (`DA_significant.txt`, `SLAB_scores.txt`, etc.)
- **In user-facing Pipeline Report plots**, Ensembl IDs are automatically translated to common gene names using the bundled `reference_data/Hg38_GeneNames_MultipleFormats.txt` lookup table. For non-hg38 or unrecognized IDs, the Ensembl ID is shown as a fallback label

**Example** (from included benchmark):
```
ensembl_gene_id
ENSG00000238009
ENSG00000241860
ENSG00000237491
ENSG00000228794
```

**File size**: Typically 100-500 KB

---

#### 4. barcodes_positions.txt - Spatial Coordinates

**Format**: Tab-delimited text file  
**Content**: Spatial location information for each spot

**Requirements**:
- Header line with exactly these 8 column names: `barcode`, `in_tissue`, `array_row`, `array_col`, `pxl_row_in_fullres`, `pxl_col_in_fullres`, `pxl_row_in_mm`, `pxl_col_in_mm`
- One row per spot after the header (order must match barcodes.txt)
- All 8 columns are required (`validate_dataset.py` will error on missing columns)

**Column descriptions**:
1. **barcode**: Spot identifier (matches barcodes.txt)
2. **in_tissue**: Binary (0 or 1) — only in-tissue spots are used
3. **array_row**: Row position in Visium spot array
4. **array_col**: Column position in Visium spot array
5. **pxl_row_in_fullres**: Y-coordinate in pixels (full resolution image)
6. **pxl_col_in_fullres**: X-coordinate in pixels (full resolution image)
7. **pxl_row_in_mm**: Y-coordinate in millimeters (derived from pixels via scale factor)
8. **pxl_col_in_mm**: X-coordinate in millimeters (derived from pixels via scale factor)

**Example** (from included benchmark):
```
barcode	in_tissue	array_row	array_col	pxl_row_in_fullres	pxl_col_in_fullres	pxl_row_in_mm	pxl_col_in_mm
AAACATGGTGAGAGGA-1	1	62	0	18240	2298	5.006	0.631
AAACCGTTCGTCCAGG-1	1	52	42	15529	8761	4.262	2.404
```

**File size**: Typically 20-50 KB

---

## Data Validation

Before running analyses, verify your data:

### Automated Validation

Use the built-in validator — it checks all of the above automatically and reports errors and warnings:

```bash
cd workflows/acquisition/python
python3 validate_dataset.py /path/to/your_dataset/
```

The validator checks:
- All 4 required files are present
- Row/column counts are consistent across files
- No duplicate barcodes
- barcodes_positions.txt has all 8 required columns
- Coordinates are numeric and reasonable

Errors cause a non-zero exit code; warnings are printed but do not block the run.

---

## Output Data Format

### Output Directory Structure

```
<output_base>/runs/<run_name>_<timestamp>/
├── optimal_svd.txt              # SVD selection: optimal SVD number + NodeCor score
├── optimal/                     # Symlink to best svd_run_N directory
│   ├── DA_results.txt           # Full differential abundance results (all genes)
│   ├── DA_significant.txt       # DA genes passing FDR threshold
│   ├── DA_counts_by_node.txt    # DA gene counts per tree node
│   ├── SLAB_scores.txt          # Spatial Lability (SLAB) scores per gene
│   ├── SLAB_barcodes.txt        # Spot barcodes for SLAB output
│   ├── OptimalTree.nw           # Optimal phylogenetic tree (Newick)
│   ├── OptimalTree_preprune.nw  # Tree before pruning
│   ├── OptimalTree_labelpreprune.nw  # Labeled pre-prune tree
│   ├── OptimalTree_pruned.nw    # Final pruned tree
│   ├── OptimalTree_pruned_node_compare_list.txt  # SG pair comparisons
│   ├── OptimalTree_pruned_node_compare_leaves.txt
│   ├── OptimalTree_pruned_node_info.txt
│   ├── allnodes_leaves.tsv      # Node-to-leaf assignments
│   ├── allnodes_parents.tsv     # Node parent relationships
│   ├── tree_edges.tsv           # Tree edge data
│   ├── tree_nodes.tsv           # Tree node data
│   ├── SPI_Dist_mtx.txt         # Spectral distance matrix
│   └── PIPELINE_COMPLETE.txt    # Written when all steps finish successfully
├── svd_run_N/                   # One directory per SVD value tested
│   ├── Tree_0.nw ... Tree_N.nw  # Bootstrap replicate trees
│   ├── Tree_Bootstrap.nw        # Consensus bootstrap tree
│   ├── Tree_support.nw          # Tree with bootstrap support values
│   ├── cor_dat_all.tsv          # NodeCor scores across hyperparameter grid
│   ├── predicted_spot_locations.tsv  # Spatial optimization predictions
│   ├── spectral_dist_melt.tsv   # KNN pairwise distances
│   ├── allnodes_leaves.tsv      # Node-leaf relationships
│   ├── allnodes_parents.tsv
│   ├── allnodes_ripley.tsv      # Ripley's K spatial statistics per node
│   └── tree_edges.tsv, tree_nodes.tsv
├── bayesspace/                  # Step 10: BayesSpace outputs (if not skipped)
│   ├── bayesspace_coldata.csv   # Spot-level spatial cluster labels
│   ├── cluster_plot.png         # Spatial cluster visualization
│   └── parameters.txt           # Parameters and seeds used
└── qc_reports/                  # Step 11: Pipeline Report (auto-generated)
    ├── QC_Dashboard.pdf         # Combined QC report
    ├── qc_summary.md            # Key metrics in text form
    ├── plot1_tree_comparison.pdf/.png
    ├── plot2_da_sg_tree.pdf/.png
    ├── plot3_slab_distribution.pdf/.png
    └── plot4_reference_validation.pdf/.png
```

**Note**: Gene identifiers in all output files (`DA_significant.txt`, `SLAB_scores.txt`, etc.) are exactly as provided in `features.txt` — Ensembl IDs if that is what you supplied.

---

## Benchmark Dataset

### GSE213688/GSM6592057

The included benchmark dataset has the following characteristics:

- **Spots**: 370
- **Genes**: 18,030
- **Tissue type**: See [GEO accession GSE213688](https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE213688)
- **Platform**: Visium Spatial Gene Expression
- **M.txt size**: ~13 MB
- **Total size**: ~13.5 MB

**Location**: `benchmarks/GSE213688_GSM6592057/input_data/`

This dataset is ideal for:
- Testing installation
- Validating workflows
- Learning the analysis pipeline
- Quick turnaround (small size)

---

## Data Preparation Tips

### Converting from 10x Genomics / GEO Format

The GEO acquisition toolkit handles conversion automatically from Space Ranger outputs (H5, MTX, or CSV) and GEO supplementary files:

```bash
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --download GSE210616_GSM6433597
```

This detects the format, harmonizes to 4-file TumorSPACE format, and writes to `local/datasets/<id>/input_data/`. See [docs/geo_dataset_acquisition.md](../geo_dataset_acquisition.md) for details.

For manual conversion from Space Ranger output:

```bash
cd workflows/acquisition/python
python3 geo_harmonize.py --input /path/to/space_ranger/outs/ --output /path/to/output/
```

### Converting from Other Formats

For other spatial transcriptomics platforms (e.g., Slide-seq, MERFISH), you'll need to manually:

1. Extract spot/cell barcodes → `barcodes.txt` (with `barcode` header)
2. Create expression matrix in spots × genes format → `M.txt` (no headers, tab-delimited)
3. Extract gene names → `features.txt` (with single-column header)
4. Extract spatial coordinates → `barcodes_positions.txt` (see column spec above)

---

## Frequently Asked Questions

### Q: Can I use normalized data in M.txt?

A: Yes, both raw counts and normalized data are acceptable. Document which you're using for reproducibility.

### Q: What if my gene names contain special characters?

A: Gene names with special characters are acceptable but may cause issues. Ensembl IDs (`ENSG...`) are the recommended format — they're unambiguous, used in the included benchmark dataset, and flow through the pipeline without modification.

### Q: My coordinates are in a different scale. Is that okay?

A: Yes, as long as relative distances are preserved. The analysis uses relative spatial relationships.

### Q: Can I include additional metadata files?

A: Yes, additional files in the dataset directory will be ignored but preserved.

### Q: What's the maximum dataset size supported?

A: The system has been tested with datasets up to 10,000+ spots. Memory requirements scale linearly with dataset size.

### Q: Do I need the histology image?

A: No, the image is not required for TumorSPACE analysis. Only the expression matrix and spatial coordinates are needed.

---

## Additional Resources

- Space Ranger output format: https://support.10xgenomics.com/
- Gene nomenclature: https://www.genenames.org/
- TumorSPACE.jl documentation: https://github.com/aramanlab/TumorSPACE.jl

---

## Need Help?

If your data doesn't match this format or you're unsure about conversions:
- Open an issue on GitHub
- Contact: Vivek Behera (beheravivek@gmail.com)
- Include a sample of your data structure
