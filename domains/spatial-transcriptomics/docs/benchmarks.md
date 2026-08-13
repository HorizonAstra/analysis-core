# Benchmarks & Performance Data

**Last Updated**: February 4, 2026  
**Environment**: HPC with SLURM + Singularity containers

---

## Table of Contents

1. [Benchmark Dataset](#benchmark-dataset) - Small dataset shipped with repository
2. [Production-Tested Datasets](#production-tested-datasets) - Validated on real datasets
3. [Resource Planning Guide](#resource-planning-guide) - Memory and runtime estimates
4. [Using Your Own Data](#using-your-own-data) - How to analyze custom datasets
5. [Reproducibility Testing](#reproducibility-testing) - Fixed-seed validation

---

## Benchmark Dataset

**GSE213688_GSM6592057** - Small dataset for testing and validation

- **Size**: 370 spots, 18,030 genes (~13 MB)
- **Included**: Shipped with repository in `benchmarks/GSE213688_GSM6592057/input_data/`
- **Purpose**: Quick validation, CI/CD testing, development

### Performance Data

| Configuration | SVDs | Runtime | DA Genes | SG Pairs | Optimal SVD | NodeCor |
|--------------|------|---------|----------|----------|-------------|----------|
| **Test Mode** (native) | 3 | ~5 min | 2,160 | 14 | 2 | 0.79 |
| **Production Mode** (native, custom) | 15 | ~18 min | 3,234 | 14 | 8 | 0.84 |
| **Production Mode** (native, default) | 30 | ~25 min | 2,475 | 15 | 4 | 0.82 |
| **Container Mode** (test) | 3 | ~4 min | 2,160 | 14 | 2 | 0.79 |

**Key Insight**: Default production mode (30 SVDs) provides thorough SVD parameter space exploration with optimal SVD=4 and strong spatial correlation (NodeCor=0.82). The 30-SVD configuration is recommended for most analyses, though you can customize with `--num-svd N`.

### Test Mode Usage

```bash
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --account YOUR_ACCOUNT \
    --partition YOUR_PARTITION \
    --input-dir benchmarks/GSE213688_GSM6592057/input_data \
    --data-dir benchmarks/GSE213688_GSM6592057/input_data \
    --output-base test_run \
    --test  # 3 SVDs, fixed seeds for reproducibility
```

### Production Mode Usage

```bash
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --account YOUR_ACCOUNT \
    --partition YOUR_PARTITION \
    --input-dir benchmarks/GSE213688_GSM6592057/input_data \
    --data-dir benchmarks/GSE213688_GSM6592057/input_data \
    --output-base production_run
    # Default: 30 SVDs (use --num-svd N to customize, e.g., --num-svd 15)
```

---

## Production-Tested Datasets

### GSE210616_GSM6433597 - Medium Dataset

- **Size**: 1,109 spots, ~18,000 genes (~50 MB)
- **Access**: [GEO Database GSE210616](https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE210616)
- **Status**: Production-validated February 2026

**Test Mode Results (3 SVDs):**
- Runtime: ~20 minutes
- DA genes: 18,077
- SG pairs: 57
- Memory: 8-16 GB

**Production Mode Results (30 SVDs):**
- Runtime: ~90 minutes
- DA genes: 28,165
- SG pairs: 57
- Optimal SVD: 3
- NodeCor: 0.74
- Memory: 8-16 GB (4GB sufficient for most steps)

### GSE179572_GSM5420753 - Large Dataset

- **Size**: 4,342 spots, ~32,000 genes (~200 MB)
- **Access**: [GEO Database GSE179572](https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE179572)
- **Status**: Production-validated February 2026

**Production Mode Results (30 SVDs):**
- Runtime: ~6 hours
- DA genes: 20,950
- SG pairs: 9
- Optimal SVD: 6
- NodeCor: 0.61
- Memory: **16GB required for Step 8** (SLAB scoring with >10K DA genes)

**Note**: Results reflect biological complexity of tissue sample. DA gene counts and SG pair numbers depend on tissue heterogeneity and spatial organization patterns, not just dataset size. Large datasets with many DA genes require increased memory allocation for Step 8.

### Downloading from GEO

Use the acquisition toolkit to download and harmonize directly:

```bash
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --download GSE210616_GSM6433597
```

This will download the supplementary files, detect the format (H5/MTX/CSV),
and write the harmonized 4-file dataset to
`local/datasets/GSE210616_GSM6433597/input_data/`.
See [docs/geo_dataset_acquisition.md](geo_dataset_acquisition.md) for details.

---

## Resource Planning Guide

Use these estimates to allocate HPC resources based on your dataset size:

| Dataset Size | Spots | Memory | Test Mode (3 SVDs) | Production (15 SVDs) | Production (30 SVDs) |
|--------------|-------|--------|-------------------|---------------------|---------------------|
| **Small** | <500 | 4-8 GB | ~5 min | ~18 min | ~25 min |
| **Medium** | 500-3,000 | 8-16 GB | ~20 min | ~45 min | ~90 min |
| **Large** | 3,000-10,000 | 16-32 GB | ~1-2 hours | ~2-3 hours | ~4-6 hours |
| **Very Large** | >10,000 | 32-64 GB | ~2+ hours | ~4+ hours | ~8+ hours |

### Recommendations by Size

**Small Datasets (<500 spots):**
- Memory: `--mem 8G`
- Time: `--time 00:30:00` (test), `--time 01:00:00` (production)
- Can run test mode interactively
- Example: GSE213688_GSM6592057

**Medium Datasets (500-3,000 spots):**
- Memory: `--mem 16G`
- Time: `--time 01:00:00` (test), `--time 02:00:00` (production)
- **Use SLURM batch jobs** (not interactive sessions - risk of HANGUP signal)
- Example: GSE210616_GSM6433597 (1,109 spots)

**Large Datasets (3,000-10,000 spots):**
- Memory: `--mem 32G` or higher
- Time: `--time 02:00:00` (test), `--time 06:00:00` (production)
- Always use SLURM batch submission
- Consider using more SVDs (30+) for thorough exploration
- Example: GSE179572_GSM5420753 (4,342 spots)
- **Note**: Some steps (Step 7 differential abundance, Step 8 SLAB scoring) may require additional memory when DA gene counts are high

**Very Large Datasets (>10,000 spots):**
- Memory: `--mem 64G` or higher  
- Time: `--time 04:00:00` (test), `--time 12:00:00` (production)
- Always use SLURM batch submission
- Monitor memory usage per step and adjust as needed

### Per-Step Memory Requirements

For large datasets (>3,000 spots), individual pipeline steps may need memory overrides:

| Step | Default Memory | Large Dataset Needs | When to Increase |
|------|---------------|---------------------|------------------|
| Step 1-2 (Tree Build) | 16G | 16-32G | Rarely needed |
| Step 6 (Spatial Opt) | 8G | 16-32G | >5,000 spots |
| Step 8 (Diff Abundance) | 8G | 16-32G | >15,000 DA genes |
| Step 9 (SLAB Scoring) | 4G | 16-32G | >10,000 DA genes |
| Step 10/11 (BayesSpace/Pipeline Report) | 8G | 16G | >10,000 spots |

**Observed Failure**: GSE179572_GSM5420753 (4,342 spots, 20,950 DA genes) required 16GB for Step 9 SLAB scoring (default 4GB caused OOM kill).

### Manual Step Memory Override

If a step fails with out-of-memory, resubmit with higher memory:

```bash
# Example: Resubmit Step 8 (SLAB scoring) with 16GB
bash workflows/tumorspace_core/orchestration/run_sg_slab_score.sh \
    --dataset YOUR_DATASET \
    --account YOUR_ACCOUNT \
    --partition YOUR_PARTITION \
    --workspace-root . \
    --input-base path/to/run/directory \
    --data-dir local/datasets/YOUR_DATASET \
    --mem 16G
```

### SLURM Submission Example

```bash
bash run_pipeline.sh \
    --dataset MY_DATASET \
    --account YOUR_ACCOUNT \
    --partition YOUR_PARTITION \
    --input-dir local/datasets/MY_DATASET \
    --data-dir local/datasets/MY_DATASET \
    --output-base local/outputs/MY_DATASET_results \
    --num-svd 15
```

---

## Using Your Own Data

### Required Files

Your dataset directory must contain:

1. **M.txt** - Gene expression matrix (spots × genes)
2. **barcodes.txt** - Spot identifiers (one per line)
3. **genes.txt** or **features.txt** - Gene names (one per line)
4. **barcodes_positions.txt** - Spatial coordinates (8 columns: barcode, x, y, etc.)

### Dataset Preparation

```bash
# Create dataset directory
mkdir -p local/datasets/MY_DATASET

# Copy your data files
cp /path/to/your/M.txt local/datasets/MY_DATASET/
cp /path/to/your/barcodes.txt local/datasets/MY_DATASET/
cp /path/to/your/features.txt local/datasets/MY_DATASET/
cp /path/to/your/barcodes_positions.txt local/datasets/MY_DATASET/

# If your dataset uses features.txt instead of genes.txt, create symlink
cd local/datasets/MY_DATASET
ln -s features.txt genes.txt
```

### File Format Details

See [advanced/INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md) for detailed specifications of each input file format.

### Available GEO Datasets

Reference datasets available for download (not shipped with repository):

| GEO ID | Spots | Genes | Size | Notes |
|--------|-------|-------|------|-------|
| GSE213688_GSM6592057 | 370 | 18,030 | 13 MB | Included with repo |
| GSE210616_GSM6433597 | 1,109 | ~18,000 | 50 MB | Tested Feb 2026 |
| GSE211956_GSM6506111 | 1,936 | 21,415 | 80 MB | Available for testing |

Visit [GEO Database](https://www.ncbi.nlm.nih.gov/geo/) to search for additional spatial transcriptomics datasets.

---

## Reproducibility Testing

TumorSPACE supports fixed-seed mode for perfect reproducibility testing, ensuring identical results across runs and platforms.

### Test Mode (Fixed Seeds Enabled)

Test mode automatically uses fixed seeds (seed = 1000):

```bash
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --account YOUR_ACCOUNT \
    --partition YOUR_PARTITION \
    --input-dir benchmarks/GSE213688_GSM6592057/input_data \
    --data-dir benchmarks/GSE213688_GSM6592057/input_data \
    --output-base test_reproducible \
    --test  # Enables fixed seeds
```

### Production Mode with Custom Seeds

```bash
# Use specific seed for reproducibility
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --account YOUR_ACCOUNT \
    --partition YOUR_PARTITION \
    --input-dir benchmarks/GSE213688_GSM6592057/input_data \
    --data-dir benchmarks/GSE213688_GSM6592057/input_data \
    --output-base production_reproducible \
    --fixed-seed 42
```

### Verifying Reproducibility

Compare results between two runs:

```bash
python3 benchmarking/verify_fixed_seed_reproducibility.py \
    --native path/to/run1/optimal \
    --container path/to/run2/optimal \
    --verbose
```

**Expected for perfect reproducibility:**
- All phylogenetic trees identical (byte-level)
- Optimal hyperparameters identical
- DA genes and SG pairs identical
- SLAB scores identical (within numerical tolerance ≤1e-12)

### Stochastic Operations

Pipeline uses random number generation in these steps (all seeded in test mode):

1. **Step 1**: Bootstrap noise injection (Gaussian, SD=0.2)
2. **Step 3**: Hyperparameter optimization (random grid search)
3. **Step 3**: Spot location sampling (random sampling with replacement)
4. **Step 7**: Permutation FDR testing (shuffled permutations)

---

## Timing Database

All pipeline runs automatically log timing data to:

- **Location**: `benchmarks/timing_database.tsv`
- **Format**: TSV with columns: dataset, mode, timestamp, step, job_id, runtime_sec, memory_kb, date, svd_count

### Viewing Timing Data

```bash
# View recent runs
tail -20 benchmarks/timing_database.tsv

# Aggregate timing statistics
bash benchmarking/aggregate_timing_data.sh
```

---

## Pipeline Report

Every pipeline run generates an automated Pipeline Report:

**Location**: `{OUTPUT_DIR}/optimal/pipeline_reports/`

**Contents**:
- `plot1_tree_postprune.pdf` - Post-prune phylogenetic tree
- `plot2_da_sg_tree.pdf` - DA genes and SG pairs visualization
- `plot3_slab_distribution.pdf` - SLAB score distribution
- `Pipeline_Report.pdf` - Combined PDF report
- `pipeline_summary.md` - Text summary of key metrics

### Report Contents

The Pipeline Report includes:
- Number of SG pairs identified
- Number of DA genes (with FDR correction)
- Number of SLAB score entries
- Tree structure statistics (nodes, polytomies, pruning changes)
- Reference validation correlation (test mode with expected_outputs)

---

For detailed pipeline usage, see [GETTING_STARTED.md](GETTING_STARTED.md).  
For file format specifications, see [advanced/INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md).
For development and testing, see [DEVELOPMENT.md](DEVELOPMENT.md).
