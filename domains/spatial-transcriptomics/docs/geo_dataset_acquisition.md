# GEO Dataset Acquisition Tool

A comprehensive tool for discovering, downloading, and harmonizing **10x Visium spatial transcriptomics datasets** from NCBI GEO for use with the TumorSPACE pipeline.

## Features

- **Search GEO** for Visium datasets using free-text queries
- **Interactive selection** from search results
- **Automatic download** of supplementary files
- **Format detection** (H5, MTX, CSV)
- **Harmonization** to TumorSPACE standard format
- **Validation** of downloaded datasets
- **HTML reports** for browsing and sharing search results

## Quick Start

### Prerequisites

Load the Anaconda module (contains all required Python packages):

```bash
module load python/anaconda-2022.05
```

### Basic Usage

#### 1. Search for Datasets

```bash
# Interactive search — 5 results at a time; n/p to page, s <N> for details, q to quit
bash workflows/acquisition/orchestration/run_geo_discovery.sh --query "melanoma visium" --interactive

# Simple search (lists first 5, prints path to full results file)
bash workflows/acquisition/orchestration/run_geo_discovery.sh --query "breast cancer" --max-results 10

# Force a fresh fetch from NCBI (bypasses 7-day cache)
bash workflows/acquisition/orchestration/run_geo_discovery.sh --query "melanoma visium" --refresh

# Generate HTML report
bash workflows/acquisition/orchestration/run_geo_discovery.sh --query "visium" --html-report
```

Every search automatically writes the full retrieved list to
`local/geo_search_<query>.txt` (query, date, total count, and all records).

#### 2. Download and Harmonize a Dataset

```bash
# Download specific dataset by GEO ID
bash workflows/acquisition/orchestration/run_geo_discovery.sh --download GSE213688

# Or use Python directly
cd workflows/acquisition/python
python3 geo_tool.py download GSE213688
```

#### 3. List Local Datasets

```bash
bash workflows/acquisition/orchestration/run_geo_discovery.sh --list
```

#### 4. Show Dataset Details

```bash
bash workflows/acquisition/orchestration/run_geo_discovery.sh --show GSE213688
```

## Output Structure

Downloaded datasets are organized in `local/datasets/`:

```
local/
├── datasets/
│   └── GSE213688/
│       ├── raw/                           # Downloaded files (kept for reference)
│       ├── input_data/                    # Harmonized TumorSPACE format
│       │   ├── M.txt                      # Expression matrix (spots × genes)
│       │   ├── barcodes.txt               # Spot barcodes
│       │   ├── features.txt               # Gene IDs
│       │   └── barcodes_positions.txt     # Spatial coordinates (8 columns)
│       └── VALIDATION_REPORT.txt          # Validation results
├── geo_search_<query>.txt                 # Full text results list (auto-written on every search)
└── geo_search_results_*.html              # HTML reports (only with --html-report)
```

## Harmonized Format

The tool converts various GEO formats to TumorSPACE standard:

### M.txt
- Dense expression matrix
- Spots (rows) × Genes (columns)
- Tab-delimited, no headers
- Contains only in-tissue spots

### barcodes.txt
```
barcode
AAACAACGAATAGTTC-1
AAACAAGTATCTCCCA-1
...
```

### features.txt or genes.txt
```
ensembl_gene_id
ENSG00000000003
ENSG00000000005
...
```

### barcodes_positions.txt
8-column format with headers:
```
barcode  in_tissue  array_row  array_col  pxl_row_in_fullres  pxl_col_in_fullres  pxl_row_in_mm  pxl_col_in_mm
```

## Supported Formats

The tool automatically detects and converts:

| Format | Files | Source |
|--------|-------|--------|
| **H5** | `*_filtered_feature_bc_matrix.h5` + spatial files | Standard 10x output |
| **MTX** | `matrix.mtx` + `barcodes.tsv` + `features.tsv` + spatial |Matrix Market format |
| **CSV** | `counts.csv` + `tissue_positions_list.csv` | Plain text format |

## Validation

After harmonization, the tool validates:

- ✓ All 4 required files present
- ✓ Dimensions match across files (spots and genes)
- ✓ Minimum thresholds met (≥100 spots, ≥1000 genes)
- ✓ Spatial coordinates are reasonable
- ✓ No duplicate barcodes or empty values

Results are saved to `VALIDATION_REPORT.txt` in each dataset directory.

## Integration with TumorSPACE Pipeline

After downloading and validating a dataset, run the pipeline:

```bash
bash workflows/tumorspace_core/orchestration/run_pipeline_full.sh \
  --dataset GSE213688 \
  --output-base local/outputs/ \
  --test
```

The `--dataset` flag can accept:
- GEO ID: `GSE213688` (searches in `local/datasets/`)
- Full path: `local/datasets/GSE213688/input_data/`

## Advanced Usage

### Using Python Modules Directly

```bash
cd workflows/acquisition/python
module load python/anaconda-2022.05

# Search
python3 geo_search.py "visium melanoma" --max-results 20

# Download raw files
python3 geo_download.py GSE213688 --output-dir ./downloads <url1> <url2> ...

# Harmonize existing download
python3 geo_harmonize.py ./downloads/GSE213688 ./output/input_data/

# Validate
python3 validate_dataset.py ./output/
```

### Generate HTML Report

```bash
cd workflows/acquisition/python
python3 geo_report.py "breast cancer visium" --max-results 50 --open
```

This opens an interactive HTML table in your browser with:
- Dataset metadata (organism, tissue, etc.)
- Publication links
- Local status (downloaded, validated, not available)
- Direct links to GEO pages

### Search Filters

```bash
# Filter by organism
bash workflows/acquisition/orchestration/run_geo_discovery.sh --query "visium" --organism "Homo sapiens"

# Limit results
bash workflows/acquisition/orchestration/run_geo_discovery.sh --query "cancer" --max-results 100
```

## Troubleshooting

### "No module named 'numpy'"

**Solution**: Load the Anaconda module:
```bash
module load python/anaconda-2022.05
```

### "Could not find supplementary files"

**Causes**:
- Dataset may not have public supplementary files
- GEO ID might be incorrect
- Dataset might be under restricted access

**Solution**: Verify the GEO ID at https://www.ncbi.nlm.nih.gov/geo/

### "Harmonization failed"

**Causes**:
- Unexpected file format
- Missing required files (positions, scale factors)
- Non-standard 10x output structure

**Solution**: 
1. Check the `raw/` directory to see what files were downloaded
2. Manually identify the matrix, barcodes, features, and position files
3. Report the issue with the GEO ID for future enhancement

### "Results look incomplete or fields are missing"

**Cause**: Search and detail results are cached locally for 7 days
(`reference_data/feature_references/geo_tool/cache/`). Cache files written by
an older version of the code may be missing fields added in a later update.
The cache now includes a schema version; any version mismatch is detected
automatically and the entry is discarded. However, if you are seeing stale data
after a `git pull`, force a fresh fetch with `--refresh`:

```bash
# Re-fetch search results
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --query "melanoma visium" --refresh

# Re-fetch details for a specific accession
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --show GSE296660 --refresh

# Nuclear option: delete all cache files
rm reference_data/feature_references/geo_tool/cache/*.json
```

### "Validation failed"

**Causes**:
- Dimension mismatch between files
- Too few spots or genes
- Missing spatial coordinates

**Solution**: Check `VALIDATION_REPORT.txt` for specific issues. Minor warnings are acceptable; errors need fixing.

## File Structure Reference

```
workflows/acquisition/
├── python/
│   ├── geo_search.py           # GEO API search module
│   ├── geo_download.py         # Download & extract module
│   ├── geo_harmonize.py        # Format conversion module
│   ├── validate_dataset.py     # Validation module
│   ├── geo_tool.py             # Main CLI interface
│   ├── geo_report.py           # HTML report generator
│   └── requirements_geo_tool.txt
└── orchestration/
    └── run_geo_discovery.sh    # Bash wrapper (use this)

reference_data/feature_references/geo_tool/
├── README.md                   # Reference data documentation
├── known_datasets.json         # Validated dataset metadata
├── format_patterns.yaml        # File detection patterns
└── cache/                      # Search result cache (auto-managed)

local/
├── datasets/                   # Downloaded datasets
│   └── {GEO_ID}/
│       ├── raw/
│       ├── input_data/
│       └── VALIDATION_REPORT.txt
├── geo_search_<query>.txt      # Auto-written text results file
└── geo_search_results_*.html   # HTML reports (--html-report only)

tests/acquisition/                 # Tests (future)
```

## Known Limitations

- **10x Visium only**: Other ST platforms not yet supported
- **Public data only**: Restricted-access datasets require manual download
- **Human & mouse**: Other organisms work but are untested
- **Format detection**: Some unusual GEO depositions may not be auto-detected

## Future Enhancements

- Support for Slide-seq, ST, and other platforms
- Integration with SRA for downloading raw FASTQ files
- Automated comparison with reference datasets
- Batch download of multiple datasets
- Dataset versioning and update tracking

## Examples

### Example 1: Discover and Download Melanoma Dataset

```bash
# Search interactively
bash workflows/acquisition/orchestration/run_geo_discovery.sh --query "melanoma visium" --interactive

# Results are shown 5 at a time:
#   n = next 5, p = prev 5, s <N> = show full details, <number> = download, q = quit
# The full result list is also written to local/geo_search_melanoma_visium.txt

# Run pipeline on the downloaded dataset
bash workflows/tumorspace_core/orchestration/run_pipeline_full.sh \
  --dataset GSE311909 \
  --output-base local/outputs/ \
  --test
```

### Example 2: Batch Download Multiple Datasets

```bash
for geo_id in GSE213688 GSE210616 GSE179572; do
  bash workflows/acquisition/orchestration/run_geo_discovery.sh --download $geo_id
done

bash workflows/acquisition/orchestration/run_geo_discovery.sh --list
```

### Example 3: Generate HTML Report for Lab Meeting

```bash
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --query "spatial transcriptomics cancer" \
  --organism "Homo sapiens" \
  --max-results 100 \
  --html-report

# Opens local/geo_search_results_*.html
# Share file with collaborators for dataset selection
```

## Support

For issues or questions:
1. Check `VALIDATION_REPORT.txt` for specific errors
2. Verify GEO ID at https://www.ncbi.nlm.nih.gov/geo/
3. See troubleshooting section above
4. Check `workflows/acquisition/python/requirements_geo_tool.txt` for dependencies

## Citation

If using datasets from GEO, cite both:
- The original publication (check GEO page for PubMed ID)
- NCBI GEO: https://www.ncbi.nlm.nih.gov/geo/

---

**Generated**: February 2026  
**Version**: 1.0  
**Part of**: TumorSPACE_AWS Pipeline
