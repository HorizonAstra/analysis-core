# Python Workflows

This directory contains Python-based analysis and utility scripts for the TumorSPACE pipeline.

## GEO Dataset Acquisition Tool

A complete toolkit for discovering, downloading, and harmonizing 10x Visium spatial transcriptomics datasets from NCBI GEO.

### Quick Start

```bash
# Make sure to load Python module first
module load python/anaconda-2022.05

# Search for datasets interactively
bash ../orchestration/run_geo_discovery.sh --query "melanoma visium" --interactive

# Download and harmonize a specific dataset
bash ../orchestration/run_geo_discovery.sh --download GSE213688

# List local datasets
bash ../orchestration/run_geo_discovery.sh --list
```

### Modules

- **geo_search.py** - Search NCBI GEO database via E-utilities API
- **geo_download.py** - Download and extract supplementary files
- **geo_harmonize.py** - Convert various formats to TumorSPACE standard
- **validate_dataset.py** - Validate harmonized datasets
- **geo_tool.py** - Main interactive CLI interface
- **geo_report.py** - Generate HTML reports of search results

### Documentation

See [docs/geo_dataset_acquisition.md](../../docs/geo_dataset_acquisition.md) for comprehensive user guide.

### Dependencies

All required packages are available in `python/anaconda-2022.05` module:
- requests
- numpy
- pandas
- scipy
- h5py
- pyyaml
- tqdm

Alternatively, install locally:
```bash
pip install -r requirements_geo_tool.txt
```

### Usage Examples

#### Search and Browse
```bash
cd /project/araman/vivek/TumorSPACE_AWS/workflows/acquisition/python
module load python/anaconda-2022.05

# Simple search
python3 geo_search.py "visium" --max-results 10

# Generate HTML report
python3 geo_report.py "breast cancer visium" --max-results 50
```

#### Download and Process
```bash
# Complete workflow (search, download, harmonize, validate)
python3 geo_tool.py search "melanoma" --interactive

# Or directly download if you know the ID
python3 geo_tool.py download GSE213688

# Check what's available locally
python3 geo_tool.py list-local
```

### Output Structure

```
local/datasets/{GEO_ID}/
├── raw/                         # Downloaded files (archives, H5, MTX, etc.)
├── input_data/                  # Harmonized TumorSPACE format
│   ├── M.txt
│   ├── barcodes.txt
│   ├── features.txt
│   └── barcodes_positions.txt
└── VALIDATION_REPORT.txt        # Validation results and metadata
```

### Testing

Basic functionality tests:

```bash
module load python/anaconda-2022.05

# Test search
python3 geo_search.py "visium" --max-results 3

# Test validation on existing benchmark
python3 validate_dataset.py ../../benchmarks/GSE213688_GSM6592057/

# Test harmonization (if raw data available)
python3 geo_harmonize.py <input_dir> <output_dir>
```

### Integration with Pipeline

After downloading a dataset, run the TumorSPACE pipeline:

```bash
bash ../orchestration/run_pipeline_full.sh \
  --dataset GSE213688 \
  --output-base local/outputs/ \
  --test
```

The pipeline will automatically find datasets in `local/datasets/`.

### Known Limitations

- Currently supports 10x Visium format only
- Requires public supplementary files (restricted-access datasets need manual download)
- Format detection works for standard 10x outputs; unusual depositions may need manual processing

### Future Development

- Support for additional spatial platforms (Slide-seq, ST, Xenium)
- Automated raw data (FASTQ) download from SRA
- Dataset version tracking and updates
- Cross-platform format conversion

---

For questions or issues, see the main documentation or check validation reports.
