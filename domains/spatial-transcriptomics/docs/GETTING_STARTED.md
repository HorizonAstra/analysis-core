# Getting Started with TumorSPACE_AWS

This guide will walk you through running your first spatial transcriptomics analysis using TumorSPACE_AWS, assuming no prior experience with containers.

> **Working directory:** Every shell snippet in this guide uses paths relative to the repository root (`TumorSPACE_AWS/`). Before running any command, make sure you are in that directory:
> ```bash
> cd /path/to/TumorSPACE_AWS
> ```

## What You'll Learn

- How to set up TumorSPACE_AWS on your system
- How to prepare your input data
- How to run an analysis using the benchmark dataset
- How to interpret your results

## Prerequisites

No prior container experience needed! This guide assumes:
- You can use a command line terminal
- **Singularity/Apptainer is available** — this is the only hard requirement for building containers and running individual pipeline steps

There are two usage modes:

| Mode | Requires | Supports |
|------|----------|----------|
| **HPC (full pipeline)** | Singularity + SLURM | Automated multi-step job submission via `run_pipeline.sh` / `run_benchmark.sh` |
| **Local / laptop** | Singularity only | Building containers + running individual steps directly via `singularity exec` |

## Step 1: Installation

Container building only requires **Singularity** — SLURM is not needed at this stage.

### On HPC

```bash
# Navigate to your project directory
cd /path/to/your/workspace

# Clone the repository
git clone https://github.com/aramanlab/TumorSPACE_AWS.git
cd TumorSPACE_AWS

# Load Singularity (module name may vary by cluster)
module load singularity

# Run automated setup
./setup.sh
```

### On a Local Machine (Linux, no SLURM)

If Singularity/Apptainer is already installed (`singularity --version` works), the setup script runs identically — no extra steps:

```bash
git clone https://github.com/aramanlab/TumorSPACE_AWS.git
cd TumorSPACE_AWS
./setup.sh
```

See [Running Locally (no SLURM)](#running-locally-no-slurm) in Step 4 for how to execute individual pipeline steps directly after building.

**Expected output**: The script will build two Singularity containers: `julia_1.9_with_gotree.sif` and `tumorspace_r.sif`. This takes 40-60 minutes. (`tumorspace_r_base.sif` is an intermediate build-cache layer created automatically during this process — only `tumorspace_r.sif` is the final deliverable.)

**Note**: For development without containers, see [Development Guide](DEVELOPMENT.md).

## Step 2: Understanding Your Data

TumorSPACE_AWS accepts raw 10x Visium data in several formats (HDF5 `.h5`, MTX,
or CSV) and uses the built-in acquisition toolkit to harmonize them into the
4-file format that the core TumorSPACE algorithms require.  If you already have
data, you can supply it directly in the harmonized format.

See [INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md) for the full format specification.

### Required Input Files (harmonized format)

The core pipeline expects 4 files in a single directory:

1. **M.txt** — Expression matrix (spots × genes)
2. **barcodes.txt** — List of spot barcodes
3. **features.txt** — List of gene names
4. **barcodes_positions.txt** — Spatial coordinates for each spot (in mm)

If your data is not already in this format, Step 3 (acquisition toolkit) or
the separate [geo_dataset_acquisition.md](geo_dataset_acquisition.md) guide
covers automated conversion from raw GEO downloads.

### Example: Benchmark Dataset

A complete example dataset is included at `benchmarks/GSE213688_GSM6592057/input_data/`:

```bash
# View the benchmark dataset structure
ls -lh benchmarks/GSE213688_GSM6592057/input_data/

# Expected files:
# M.txt                           (~13 MB)
# barcodes.txt                    (~10 KB)
# features.txt                    (~200 KB)
# barcodes_positions.txt          (~30 KB)
```

## Step 3: Acquiring Data from GEO (Optional)

If you don't already have data in TumorSPACE format, you can use the built-in
acquisition toolkit to discover, download, and harmonize public 10x Visium
datasets from [NCBI GEO](https://www.ncbi.nlm.nih.gov/geo/).

**On HPC:** load the Anaconda module first:
```bash
module load python/anaconda-2022.05
```
**On a local machine:** `python3` and `requests` are all that's needed (`pip install requests` if missing).

### Interactive search and download (recommended for exploration)

Run the search with `--interactive` in a **live terminal** (requires keyboard
input — not scriptable):

```bash
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --query "melanoma visium" --interactive
```

What happens:
1. Queries NCBI GEO (GSE series entries only) and fetches up to 20 matching
   datasets (raise with `--max-results` if you want a larger pool)
2. Displays **5 results at a time**, each with title, organism, sample count,
   citation URL, and GEO URL; shows how many total matches exist on GEO
3. Writes the **full retrieved list** to `local/geo_search_<query>.txt` for
   offline browsing
4. Prompts with the available commands, e.g.:
   ```
   Enter number to download, 's <N>' for details, 'n' next 5, 'p' prev 5, 'q' quit:
   ```
   - Type a **number** → confirm download → dataset is downloaded, decompressed,
     and harmonized into `local/datasets/<GEO_ID>/input_data/`
   - `s <N>` → show full details for result N (title, summary, overall design,
     citation, supplementary file list)
   - `n` / `p` → page forward / backward through results, 5 at a time
   - `q` → quit without downloading

You can narrow results with `--organism` and `--max-results`:

```bash
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --query "melanoma visium" \
  --organism "Homo sapiens" \
  --max-results 10 \
  --interactive
```

### Non-interactive (scripted) download

If you already know the accession ID, skip the search entirely:

```bash
# Supply the composite GSE_GSM ID for precise per-sample targeting
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --download GSE213688_GSM6592057

# GSE-only also works (downloads all supplementary files for the series)
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --download GSE213688
```

### Other useful commands

```bash
# List what's been downloaded locally
bash workflows/acquisition/orchestration/run_geo_discovery.sh --list

# Show full metadata for a specific accession (title, summary, overall design,
# citation, supplementary files) without downloading
bash workflows/acquisition/orchestration/run_geo_discovery.sh \
  --show GSE213688
```

The tool handles format detection (H5 / MTX / CSV), mm-coordinate conversion,
and writes the [required 4-file format](advanced/INPUT_OUTPUT_SPEC.md) to
`local/datasets/{GEO_ID}/input_data/` automatically.

See [docs/geo_dataset_acquisition.md](geo_dataset_acquisition.md) for the full
workflow, batch-download examples, and troubleshooting.

## Step 4: Running an Analysis

### On HPC with Singularity

**IMPORTANT:** Always use `--no-home` flag for optimal performance (12x faster).

To verify the container is working:

```bash
singularity exec --no-home containers/julia_1.9_with_gotree.sif julia --version
singularity exec --no-home containers/julia_1.9_with_gotree.sif gotree version
```

**Why `--no-home`?** Without this flag, Singularity performs a sandbox conversion on every invocation, adding several minutes of overhead *per task call*. With `--no-home` that overhead is eliminated. Actual task runtime depends on dataset size and pipeline step — see [benchmarks.md](benchmarks.md) for measured timings.

### Submitting a SLURM Job

Example SLURM job script:

```bash
# See benchmarking/slurm/example_job.sbatch for a complete template

sbatch benchmarking/slurm/example_job.sbatch
```

### Running Locally (no SLURM)

On a laptop or any Linux machine without SLURM, `run_pipeline.sh` and
`run_benchmark.sh` (which submit SLURM job arrays) won't apply.  Each pipeline
step is a self-contained Julia or R script that can be driven directly with
`singularity exec`.

A fully-worked reference script covering the core pipeline steps (Steps 1–8) is provided at
[docs/run_locally.sh](run_locally.sh).  Edit the `CONFIGURATION` block at the
top (clearly marked `# [MODIFY]` lines) and run:

```bash
bash docs/run_locally.sh
```

**Key `singularity exec` flags used throughout:**
- `--no-home` — skips a costly per-invocation sandbox conversion (several minutes of overhead per task call otherwise)
- `-B "${WORKSPACE_ROOT}"` — bind-mounts the repo root so scripts can read/write your data

For a full argument/output reference for each step, read the header comment of
the individual Julia/R scripts in `workflows/tumorspace_core/`.

## Step 4.5: Running BayesSpace Standalone (outside `run_pipeline.sh`)

BayesSpace produces complementary spatial cluster assignments from the same
Visium input data. When using `run_pipeline.sh`, BayesSpace runs automatically
whenever `containers/tumorspace_r.sif` is present (use `--no-bayesspace` to
skip it). This section covers running BayesSpace directly on a single dataset,
outside the full pipeline.

```bash
# Run BayesSpace on any harmonized input directory
bash workflows/bayesspace/orchestration/run_bayesspace.sh \
    --datapath benchmarks/GSE213688_GSM6592057/input_data \
    --outdir local/outputs/bayesspace_GSE213688

# Or on a locally-acquired dataset
bash workflows/bayesspace/orchestration/run_bayesspace.sh \
    --datapath local/datasets/<GEO_ID>/input_data \
    --outdir local/outputs/bayesspace_<GEO_ID>
```

Outputs written to `--outdir`:

| File | Description |
|------|-------------|
| `bayesspace_coldata.csv` | Spot-level spatial cluster labels |
| `cluster_plot.png` | Spatial cluster visualization |
| `parameters.txt` | All parameters and seeds used |

**On HPC (SLURM):** edit the header of
`workflows/bayesspace/orchestration/submit_bayesspace.sbatch` and submit with
`sbatch workflows/bayesspace/orchestration/submit_bayesspace.sbatch`.

See [workflows/bayesspace/README.md](../workflows/bayesspace/README.md) for the
full option reference.

---

## Step 4.6: Running DE Analysis

DE analysis identifies cluster marker genes (Seurat FindAllMarkers) and optionally
runs spatially-variable gene detection (DESpace). It requires `bayesspace_coldata.csv`
as input and runs in a dedicated R 4.5 container (`tumorspace_r45.sif`).

**Single-sample:**
```bash
bash workflows/DE_analysis/orchestration/run_de_analysis.sh \
    --datapath benchmarks/GSE213688_GSM6592057/input_data \
    --metapath local/outputs/bayesspace_GSE213688/bayesspace_coldata.csv \
    --outdir local/outputs/de_analysis_GSE213688
```

**With DESpace:**
```bash
bash workflows/DE_analysis/orchestration/run_de_analysis.sh \
    --datapath benchmarks/GSE213688_GSM6592057/input_data \
    --metapath local/outputs/bayesspace_GSE213688/bayesspace_coldata.csv \
    --outdir local/outputs/de_analysis_GSE213688 \
    --despace
```

**Joint (multi-sample):**
```bash
bash workflows/DE_analysis/orchestration/run_de_analysis.sh \
    --datapath /path/to/sample1,/path/to/sample2 \
    --metapath /path/to/joint_coldata.csv \
    --outdir local/outputs/de_analysis_joint
```

Outputs written to `--outdir`:

| File | Description |
|------|-------------|
| `seurat_cluster_markers_all.csv` | All Seurat marker genes per cluster |
| `seurat_cluster_markers_top50.csv` | Top 50 markers per cluster by avg_log2FC |
| `despace_results_all.csv` | DESpace results (`--despace` only) |
| `despace_results_byCluster.csv` | DESpace per-cluster results (`--despace` only) |

See [workflows/DE_analysis/README.md](../workflows/DE_analysis/README.md) for the
full option reference.

---

## Step 5: Running the Benchmark Analysis

### Quick Start: Single Command (Recommended)

The benchmark script acquires the dataset from GEO and runs the full pipeline in
one shot — the best way to verify a fresh install.

**First, configure your SLURM account and partition** (one-time step):

```bash
# Copy the template and fill in your HPC account/partition
cp config/slurm_config.sh.example config/slurm_config.sh
# Edit config/slurm_config.sh — see config/README.md for instructions
```

With `config/slurm_config.sh` populated, `--account` and `--partition` are
read automatically:

```bash
# Requires: Python 3 loaded + SLURM access
# On RCC/Midway: module load python/anaconda-2022.05
bash run_benchmark.sh
```

Or pass them explicitly:

```bash
bash run_benchmark.sh --account <your-account> --partition <your-partition>
```

This performs two phases:
1. **Phase 0** — Downloads and harmonizes `GSE213688_GSM6592057` from NCBI GEO
   into `local/datasets/GSE213688_GSM6592057/input_data/`
2. **Phase 1** — Runs the TumorSPACE core pipeline in `--test` mode
   (3 SVDs with fixed seeds for fast validation)

Results are written to `benchmarks/GSE213688_GSM6592057/runs/benchmark_<TIMESTAMP>/`.

**Already ran once?** Skip the re-download with `--skip-acquisition`:

```bash
bash run_benchmark.sh --skip-acquisition
```

**Force re-download** (reproducibility regression test):

```bash
bash run_benchmark.sh --force-redownload
```

**Runtime expectations (Phase 1):**
- Runtime depends primarily on dataset size (number of spots) and SVD count, not on native vs container mode
- Test mode (3 SVDs, 370 spots): roughly 5–20 minutes wall time
- See [benchmarks.md](benchmarks.md) for dataset-specific timing data

### Manual Path: run_pipeline.sh Directly

If you prefer to call the pipeline without re-acquiring data, point it at any
existing input directory:

```bash
# Test mode using committed benchmark data
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --account <your-account> \
    --partition <your-partition> \
    --input-dir benchmarks/GSE213688_GSM6592057/input_data \
    --data-dir benchmarks/GSE213688_GSM6592057/input_data \
    --output-base benchmarks/GSE213688_GSM6592057/runs/test_demo \
    --test

# Production mode - full analysis (30 SVDs with random seeds)
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --account <your-account> \
    --partition <your-partition> \
    --input-dir benchmarks/GSE213688_GSM6592057/input_data \
    --data-dir benchmarks/GSE213688_GSM6592057/input_data \
    --output-base benchmarks/GSE213688_GSM6592057/runs/production_run

# Monitor progress
squeue -u $USER

# Check specific job status
sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed
```

**Runtime expectations:**
- Runtime is driven by dataset size (spots) and SVD count — not by native vs container mode
- Production mode (30 SVDs): ~25 min (370 spots), ~90 min (1,109 spots), ~6 hrs (4,342 spots)
- See [benchmarks.md](benchmarks.md) for dataset-specific measured timings

**With container mode** (add `--container`):
```bash
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --account <your-account> \
    --partition <your-partition> \
    --input-dir benchmarks/GSE213688_GSM6592057/input_data \
    --data-dir benchmarks/GSE213688_GSM6592057/input_data \
    --output-base benchmarks/GSE213688_GSM6592057/runs/container_test \
    --container containers \
    --test
```

### Understanding Input and Output Paths

**Input directory** (where your data lives):
```
--input-dir benchmarks/GSE213688_GSM6592057/input_data
# Contains: M.txt, barcodes.txt, features.txt, barcodes_positions.txt
```

**Output directory** (where results are saved):
```
--output-base benchmarks/GSE213688_GSM6592057/runs/my_run_name
# OR any other path:
--output-base /scratch/$USER/results/my_analysis
```

After pipeline completion, all outputs appear in:
```
{OUTPUT_DIR}/
├── svd_run_1/
├── svd_run_2/
├── optimal/                    # Symlink to best SVD result
│   ├── pipeline_reports/             # Pipeline Report
│   │   └── {TIMESTAMP}/
│   │       ├── plot1_tree_postprune.pdf
│   │       ├── plot2_da_sg_tree.pdf
│   │       ├── plot3_slab_distribution.pdf
│   │       ├── Pipeline_Report.pdf
│   │       └── pipeline_summary.md
│   ├── SLAB_scores.txt
│   ├── OptimalTree_pruned_node_*.txt
│   └── PIPELINE_COMPLETE.txt
└── pipeline_jobs.txt
```

### Example Production Results

Results vary based on tissue type, biological heterogeneity, and spatial organization. These examples demonstrate pipeline capabilities on specific validated datasets:

**Benchmark Dataset (370 spots, GSE213688_GSM6592057):**
- Purpose: Pipeline validation and testing
- Configuration: 15 SVDs tested (production mode)
- Results: 3,234 DA genes, 14 SG pairs, optimal SVD 8
- Runtime: ~18 minutes (native mode on HPC)

**Medium Dataset (1,109 spots, GSE210616_GSM6433597):**
- Configuration: 3 SVDs tested (test mode)
- Results: 18,077 DA genes, 57 SG pairs
- Runtime: ~20 minutes (native mode on HPC)

*For detailed benchmark data and performance metrics, see [benchmarks.md](benchmarks.md).*

**For your own datasets:**
```bash
# Create your dataset directory structure
mkdir -p benchmarks/MY_DATASET/input_data

# Copy your data files there
cp /path/to/M.txt benchmarks/MY_DATASET/input_data/
cp /path/to/barcodes.txt benchmarks/MY_DATASET/input_data/
cp /path/to/features.txt benchmarks/MY_DATASET/input_data/
cp /path/to/barcodes_positions.txt benchmarks/MY_DATASET/input_data/

# Then run pipeline
bash run_pipeline.sh \
    --dataset MY_DATASET \
    --account pi-araman \
    --partition caslake \
    --input-dir benchmarks/MY_DATASET/input_data \
    --data-dir benchmarks/MY_DATASET/input_data \
    --output-base benchmarks/MY_DATASET/runs/analysis_v1 \
    --test
```

### Troubleshooting: Where Is My Pipeline Report?

After the pipeline completes, the Pipeline Report automatically appears in:

```bash
# If you used --output-base benchmarks/GSE213688_GSM6592057/runs/test_demo:
ls -lh benchmarks/GSE213688_GSM6592057/runs/test_demo/optimal/pipeline_reports/

# If you used --output-base /scratch/$USER/results/:
ls -lh /scratch/$USER/results/optimal/pipeline_reports/
```

Each Pipeline Report directory contains:
- `plot1_tree_postprune.pdf` - Post-prune phylogenetic tree
- `plot2_da_sg_tree.pdf` - DA genes and SG pairs visualization
- `plot3_slab_distribution.pdf` - SLAB score distribution
- `Pipeline_Report.pdf` - Combined PDF report
- `pipeline_summary.md` - Text summary of key metrics
- `log.txt` - Generation log

For more details about directory organization, see [DEVELOPMENT.md - Directory Organization](DEVELOPMENT.md#directory-organization).

## Step 6: Understanding Your Results

After running the pipeline, outputs are organized in:

```
benchmarks/GSE213688_GSM6592057/
└── runs/
    └── <run_name>_<timestamp>/
        ├── svd_run_1/               # Per-SVD analysis outputs
        │   ├── Tree_0.nw            # Step 1: Initial tree
        │   ├── Tree_support.nw      # Step 1b: Bootstrap validated
        │   ├── Tree_pruned.nw       # Step 2: Pruned tree
        │   └── node_data.tsv        # Step 3: Node relationships
        ├── svd_run_2/, svd_run_3/, ...
        ├── optimal/                 # Symlink to best SVD result
        │   ├── sg_pairs.tsv           # Step 6: Spatial Groups (SG) pairs
        │   ├── DA_significant.txt     # Step 7: Differential abundance
        │   ├── SLAB_scores.txt        # Step 8: Spatial Lability scores
        │   └── pipeline_reports/      # Pipeline Report (auto-generated)
        │       └── <timestamp>/
        │           ├── Pipeline_Report.pdf
        │           └── pipeline_summary.md
        └── PIPELINE_COMPLETE.txt
```

### Pipeline Report

**Note:** The Pipeline Report is automatically generated at the end of every `run_pipeline.sh` run.

For the benchmark dataset, you can optionally compare results against validated reference outputs:

```bash
# Optional: Compare benchmark results to expected outputs (validation only)
workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \
    --dataset GSE213688_GSM6592057 \
    --comparison-dir benchmarks/GSE213688_GSM6592057/expected_outputs
```

**For your own datasets:** The Pipeline report will be generated automatically in `pipeline_reports/<timestamp>/` with correlation plots and summary statistics. Comparison to reference outputs is only applicable for the benchmark dataset validation.

**Expected Pipeline Report metrics (benchmark validation):**
- Correlation: R > 0.85
- Score agreement: >95% identical
- Bootstrap validation: Passed

See [benchmarks.md](benchmarks.md) for detailed performance metrics.

## Common Issues and Solutions

### Issue: "Singularity not found"

**Solution**: Load the singularity module first:
```bash
module load singularity
# or
module load apptainer
```

### Issue: Container build fails

**Solution**: 
1. Check internet connectivity
2. Ensure sufficient disk space (~2GB for build process)
3. Check the build logs for specific errors

### Issue: Container execution is very slow (>4 minutes per task)

**Solution**: Ensure you're using the `--no-home` flag:
```bash
# ❌ Slow (4m42s per task)
singularity exec containers/julia_1.9_with_gotree.sif julia script.jl

# ✅ Fast (24s per task)
singularity exec --no-home containers/julia_1.9_with_gotree.sif julia script.jl
```

The orchestration scripts automatically include `--no-home`.

### Issue: "Cannot find input files"

**Solution**: 
- Verify your input directory structure matches the required format
- Check file permissions
- Use absolute paths when specifying input directories

## Next Steps

- Read [workflows/README.md](../workflows/README.md) for complete pipeline documentation
- Read [containers/README.md](../containers/README.md) for container details
- Read [INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md) to understand data formats in detail
- Read [benchmarks.md](benchmarks.md) for performance metrics and validation results
- Prepare your own spatial transcriptomics data
- Run individual pipeline steps for testing

## Getting Help

If you encounter issues:

1. Check this troubleshooting section
2. Review [INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md) for data format requirements
3. Open an issue on GitHub with:
   - Your environment (HPC cluster name, Singularity version)
   - The error message
   - Steps to reproduce the issue

## Additional Resources

- [TumorSPACE.jl](https://github.com/aramanlab/TumorSPACE.jl) - Core Julia package
- [Arjun Raman Lab](https://ramanlab.net/) - Lab website
- [Singularity Documentation](https://sylabs.io/docs/) - Container platform docs
- [Orchestration Framework](../workflows/README.md) - Automated workflow system
- [Container Guide](../containers/README.md) - Container setup and usage
