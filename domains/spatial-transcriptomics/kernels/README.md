# TumorSPACE Workflows

Production orchestration framework for TumorSPACE spatial transcriptomics analysis on HPC with SLURM.

## Feature Overview

Workflows are organized into self-contained features. Each feature has its own subdirectory with compute scripts and orchestration wrappers. Features can be opted into independently.

| Feature | Directory | Runs by default in `run_pipeline.sh`? | Inputs | Outputs |
|---------|-----------|---------------------------------------|--------|---------|
| **1. Data Acquisition** | `acquisition/` | No (opt-in via `run_benchmark.sh`) | Search query / GEO ID | `local/datasets/{ID}/input_data/` (M.txt, barcodes.txt, features.txt, barcodes_positions.txt) |
| **2. TumorSPACE Core** | `tumorspace_core/` | **Yes** | Input data directory | SG pairs, diff abundance, SLAB scores |
| **3. BayesSpace** | `bayesspace/` | **Yes** (skip with `--no-bayesspace`) | Visium input data | `bayesspace_coldata.csv`, `cluster_plot.png`, `parameters.txt` |
| **4. Pipeline Report** | `pipeline_report/` | **Yes** | Core pipeline outputs | Pipeline Report PDF, validation plots |

**Execution order:** Acquisition (opt-in) → Core → BayesSpace (opt-out, Step 10) → Pipeline Report (Step 11)

> **Exploratory / Pre-production:** `workflows/sg_analysis/R/` contains downstream spatial domain analysis scripts (GSEA, pathway enrichment, SG/BayesSpace-flexible DE). These are not yet productionized and are not run by `run_pipeline.sh`. Planned for v2 as `spatial_domain_analysis`. See [docs/FEATURE_ROLLOUT.md](../docs/FEATURE_ROLLOUT.md).

## 🎯 Quick Start (Production Workflow)

**Recommended for all analyses:**

```bash
# Run complete pipeline (convenience script at repo root)
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers

# Monitor progress
squeue -u $USER

# Check job status
sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed
```

The orchestration framework handles:
- All 11 TumorSPACE analysis steps (Steps 1–9 core + Step 10 BayesSpace + Step 11 Pipeline Report)
- Automatic job dependency management
- Container vs native mode detection
- `--no-home` flag for optimal container performance
- Error handling and logging

---

## 📁 Directory Structure

```
workflows/
├── acquisition/                 # Optional: acquire & harmonize GEO datasets
│   ├── python/                  # Downloader, harmonizer, search scripts
│   └── orchestration/           # run_geo_discovery.sh
├── tumorspace_core/             # Steps 1-9: core phylogenetic analysis
│   ├── julia/                   # phylo_tree_build.jl, phylo_node_extract.jl, etc.
│   └── orchestration/           # run_pipeline_full.sh + per-step wrappers
├── bayesspace/                  # Step 10: optional spatial clustering
│   ├── R/                       # run_bayesspace.R
│   └── orchestration/           # run_bayesspace.sh, submit_bayesspace.sbatch
├── pipeline_report/             # Step 11: Pipeline Report (PDF + plots)
│   ├── R/                       # generate_qc_single_run.R, generate_qc_plots.R
│   └── orchestration/           # run_pipeline_report_slurm.sh
└── sg_analysis/                 # Exploratory: GSEA, immune signature analysis
    └── R/                       # Pathway enrichment and spatial plotting scripts
```

---

## 🚀 The TumorSPACE Pipeline

### Step 1: Phylogenetic Tree Construction
**Script:** `run_phylo_tree_build.sh`
```bash
workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers/julia_1.9_with_gotree.sif
```
- Builds phylogenetic tree from expression data
- **Dataset:** GSE213688_GSM6592057 (370 spots, 18,030 genes) | **Mode:** Test (3 SVDs)
- **Timing:** ~23s-1m33s per tree job (11 jobs per SVD: 1 main tree + 10 bootstraps)
- **Resources:** 8 CPUs, 32GB memory
- **Total test runtime:** ~5-10 min across 3 SVDs with job array parallelization
- See [complete timing data](../docs/benchmarks.md#resource-planning-by-dataset-size) for production mode and dataset scaling
- Output: `Tree_0.nw`

### Step 1b: Bootstrap Support Validation
**Script:** `run_phylo_bootstrap_support.sh`
```bash
workflows/tumorspace_core/orchestration/run_phylo_bootstrap_support.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers \
    --bootstrap-tree bootstrap_trees.nwk
```
- Validates tree structure with bootstrap analysis using gotree (TBE algorithm)
- **Dataset:** GSE213688_GSM6592057 (370 spots) | **Mode:** Test (3 SVDs)
- **Timing:** ~2s per bootstrap tree
- **Resources:** 4 CPUs, 16GB memory
- **Total test runtime:** <1 min for 3 SVDs
- Output: `Tree_support.nw`

### Step 2: Tree Pruning
**Script:** `run_phylo_tree_prune.sh`
- Prunes tree branches below support threshold (auto-extracted)
- **Timing:** ~13s-33s per pruned tree (test mode, 3 SVDs)
- **Resources:** 4 CPUs, 8GB memory
- Output: `Tree_pruned.nw`

### Step 3: Node Extraction
**Script:** `run_phylo_node_extract.sh`
- Extracts node relationships from pruned tree
- **Timing:** ~32s-48s per extraction (test mode, 3 SVDs)
- **Resources:** 4 CPUs, 8GB memory
- Output: `node_data.tsv`

### Step 4: SVD Feature Selection
**Script:** `run_svd_selection.sh`
- Selects optimal SVD by maximum NodeCor (spatial optimization metric)
- **Timing:** ~2s for feature selection
- **Resources:** 8 CPUs, 16GB memory
- Output: `selected_features.txt`, symlink to optimal SVD results

### Step 5: Spatial Optimization
**Script:** `run_spatial_optimize.sh`
- Optimizes spatial parameters on selected SVD (calculates NodeCor metric per SVD for ranking)
- **Timing:** ~52s-1m27s per optimization (test mode, 3 SVDs)
- **Resources:** 8 CPUs, 16GB memory
- Output: `spatial_params.json`, NodeCor scores

### Step 6: Spatial Groups (SG) Identification
**Script:** `run_sg_identify_pairs.sh`
- Identifies Spatial Groups (SG) root nodes and pairs on optimal SVD
- **Timing:** Typically <5 min (test mode)
- **Resources:** 8 CPUs, 16GB memory
- Output: `sg_pairs.tsv`

### Step 7: Differential Abundance (R)
**Script:** `run_sg_diff_abundance.sh`
- Tests differential abundance between conditions using R statistical framework
- **Timing:** Typically <5 min (test mode)
- **Resources:** 4 CPUs, 16GB memory
- Output: `DA_significant.txt`

### Step 8: Spatial Lability Scoring
**Script:** `run_sg_slab_score.sh`
- Computes Spatial Lability (SLAB) scores for differential genes
- **Timing:** Typically <5 min (test mode)
- **Resources:** 4 CPUs, 8GB memory
- Output: `SLAB_scores.txt`

### Step 9: Pipeline Completion
**Script:** `run_pipeline_completion.sh`
- Writes `PIPELINE_COMPLETE.txt` and creates the `optimal/` symlink to the best SVD result
- **Timing:** <5 seconds
- **Resources:** 1 CPU, 4GB memory

### Step 10: BayesSpace Spatial Clustering (R)
**Script:** `run_bayesspace.sh`
- Runs BayesSpace spatial clustering on the Visium input data; auto-enabled when `tumorspace_r.sif` is present
- Skip with `--no-bayesspace`
- **Timing:** ~5-15 min depending on spot count
- **Resources:** 4 CPUs, 16GB memory
- Output: `bayesspace_coldata.csv`, `cluster_plot.png`, `parameters.txt`

### Step 11: Pipeline Report (R)
**Script:** `run_pipeline_report_slurm.sh`
```bash
workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \
    --dataset GSE213688_GSM6592057 \
    --comparison-dir benchmarks/GSE213688_GSM6592057/expected_outputs
```
- Generates comprehensive Pipeline Report with tree structure plots, DA gene visualization, SLAB distributions
- Validates results against baseline with Pearson correlation analysis
- **Timing:** ~2-5 min (test mode)
- **Resources:** 2 CPUs, 8GB memory
- Output: `pipeline_reports/<timestamp>/pipeline_summary.md`

---

## ⚙️ Orchestration Framework Features

### Container vs Native Mode

**Container mode (recommended):**
```bash
--container containers
```
- Uses `julia_1.9_with_gotree.sif` and `tumorspace_r.sif`
- Automatically adds `--no-home` flag for performance
- Fully reproducible across environments
- Performance: 24s per task (with `--no-home`)

**Native mode:**
```bash
# Omit --container flag for native mode
```
- Uses system-installed Julia 1.9 and R 4.4
- Slightly faster (22s per task)
- Requires manual environment setup
- Good for development

### Automatic Job Dependencies

The orchestration framework automatically manages SLURM job dependencies:
```bash
# Step 1 must complete before Step 2
job1=$(sbatch step1.sh)
sbatch --dependency=afterok:$job1 step2.sh
```

No manual tracking needed - the framework handles all dependencies.

### Error Handling

Each script includes:
- Exit on error (`set -e`)
- Job status checking
- Informative error messages
- Automatic log file creation

### Resource Management

Scripts automatically allocate appropriate resources:
- Small datasets (<1k spots): 8 CPUs, 16GB, 30min
- Medium datasets (1k-10k): 16 CPUs, 32GB, 1-2hr
- Large datasets (>10k): 32 CPUs, 64GB, 4-6hr

---

## 📊 Running Individual Steps

You can run any step independently:

```bash
# Run just tree building
workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers/julia_1.9_with_gotree.sif

# Run just Pipeline Report (Step 11)
workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \
    --dataset GSE213688_GSM6592057 \
    --comparison-dir benchmarks/GSE213688_GSM6592057/expected_outputs
```

**Prerequisites:** Ensure input files from previous steps exist.

---

## 📋 Common Workflows

### Complete Validation Run

Test entire pipeline with benchmark dataset:
```bash
# Full pipeline with validation
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers \
    --test

# Optionally compare results to reference outputs after completion:
workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \
    --dataset GSE213688_GSM6592057 \
    --comparison-dir benchmarks/GSE213688_GSM6592057/expected_outputs
```

**Expected runtime:** Production mode (30 SVD runs): ~1-2 hours. For testing, add `--test` flag for quick 3-SVD run: ~5-15 min native, ~30-60 min container. See [benchmarking guide](../docs/benchmarks.md) for complete timing details.

### Container vs Native Comparison

Run both modes for performance comparison:
```bash
# Container mode
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers \
    --output-suffix container_test

# Native mode
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --output-suffix native_test

# Compare results
workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \
    --dataset GSE213688_GSM6592057 \
    --comparison-dir benchmarks/.../native_test_<timestamp>
```

---

## 🛠️ Script Arguments

### Common Arguments

All orchestration scripts support:

| Argument | Description | Required | Default |
|----------|-------------|----------|---------|
| `--dataset` | Dataset ID (e.g., GSE213688_GSM6592057) | Yes | - |
| `--container` | Path to containers directory (e.g. `containers`). Omit for native mode. | No | none (native) |
| `--output-suffix` | Custom suffix for output directory | No | Mode name |
| `--partition` | SLURM partition | No | (none - user must specify) |
| `--account` | SLURM account | No | (none - user must specify) |
| `--test` | Test mode: process only 3 SVDs with fixed deterministic seeds | No | (false - uses all 30 SVDs with random seeds) |
| `--fixed-seed VALUE` | Use custom fixed seed (enables deterministic output) | No | `1000` (in test mode) / random (in production) |
| `--mem SIZE` | Memory allocation (e.g., 16G, 32G, 64G) | No | Automatic by step |

**Test Mode Notes:**
- `--test` flag enables fixed-seed reproducibility (seed formula: `1000 + svd_run*100 + bootstrap*1000`)
- Reduces SVD runs from 30 to 3 for quick validation
- Expected runtime: ~5-15 min native, ~30-60 min container (370-spot dataset)
- Produces byte-identical output across runs with same input
- See [DEVELOPMENT.md](../docs/DEVELOPMENT.md#testing-modes) for testing workflow details

### Step-Specific Arguments

**Bootstrap support:**
- `--bootstrap-tree`: Path to bootstrap tree file

**Pipeline Report:**
- `--comparison-dir`: Directory with reference outputs for comparison

---

## 📈 Monitoring & Debugging

### Check Job Status
```bash
# List your jobs
squeue -u $USER

# Check specific job
sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed,MaxRSS

# View logs
ls benchmarks/GSE213688_GSM6592057/logs/
tail -f benchmarks/GSE213688_GSM6592057/logs/step1_*.err
```

### Common Issues

**Job fails immediately:**
- Check SLURM logs in `benchmarks/<dataset>/logs/`
- Verify input files exist
- Check resource allocation

**Container execution slow:**
- Verify `--no-home` flag is present in container commands
- Check logs for sandbox conversion warnings

**R step fails:**
- Verify `tumorspace_r.sif` container exists (run `cd containers && bash build_r_container.sh`)
- Check R package dependencies

---

## 🔍 Output Structure

After running the full pipeline:

```
benchmarks/GSE213688_GSM6592057/
└── runs/
    └── <run_name>_<timestamp>/
        ├── svd_run_1/
        │   ├── Tree_0.nw            # Step 1: Initial tree
        │   ├── Tree_support.nw      # Step 1b: Bootstrap validated
        │   ├── Tree_pruned.nw       # Step 2: Pruned tree
        │   └── node_data.tsv        # Step 3: Node relationships
        ├── svd_run_2/, svd_run_3/, ...
        ├── optimal/                 # Symlink to best SVD result (Step 9)
        │   ├── sg_pairs.tsv         # Step 6
        │   ├── DA_significant.txt   # Step 7
        │   ├── SLAB_scores.txt      # Step 8
        │   └── pipeline_reports/   # Step 11 (Pipeline Report)
        │       └── <timestamp>/
        │           └── Pipeline_Report.pdf
        └── PIPELINE_COMPLETE.txt
```

---

## 🔧 Development

### Adding New Steps

1. Create Julia/R script in `julia/` or `R/` directory
2. Create orchestration wrapper in `orchestration/`
3. Add job dependency to `run_pipeline_full.sh`
4. Test with benchmark dataset
5. Update this documentation

### Modifying Existing Steps

1. Edit script in `julia/` or `R/`
2. Test with: `workflows/tumorspace_core/orchestration/run_<step>.sh --dataset GSE213688_GSM6592057 --container containers`
3. Run full pipeline to verify dependencies
4. Run Pipeline Report to validate outputs

### Before Merging

Run the pre-merge isolation test to verify a clean build from scratch:
```bash
bash tests/clean_container_rebuild.sh
```
See [docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md) for the full developer workflow including container rebuild scenarios and HPC configuration.

---

## 📚 Additional Resources

- [Container Documentation](../containers/README.md) - Container setup and usage
- [Getting Started Guide](../docs/GETTING_STARTED.md) - Tutorial for new users
- [Benchmark Documentation](../docs/benchmarks.md) - Performance metrics
- [Archive](../archive/implementation_notes/) - Historical implementation details

---

## 🏆 Validation Results

For the latest validation run results, see `benchmarks/GSE213688_GSM6592057/qc_reports/`.
