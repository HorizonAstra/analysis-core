# TumorSPACE Usage Guide

Comprehensive guide for running the TumorSPACE pipeline on HPC with SLURM.

## Overview

TumorSPACE analyzes spatial transcriptomics data through a multi-step pipeline that builds phylogenetic trees, identifies Spatial Groups (SGs), and computes Spatial Lability (SLAB) scores. A Pipeline Report is automatically generated at the end.

## Quick Reference

| What You Want | Command |
|---------------|---------|
| **Run complete pipeline** | `run_pipeline.sh --dataset <name> --container containers` |
| **Run single step** | `workflows/tumorspace_core/orchestration/run_<step>.sh --dataset <name> --container containers` |
| **Check job status** | `squeue -u $USER` or `sacct -j <jobid>` |
| **View logs** | `tail -f benchmarks/<dataset>/logs/step<N>_*.err` |
| **Generate Pipeline Report only** | `workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh --dataset <name>` |

See [workflows/README.md](../workflows/README.md) for complete step-by-step documentation.

---

## Pipeline Steps

1. **Phylogenetic Tree Construction** - Build tree from expression data
2. **Bootstrap Support Validation** - Validate tree with bootstrap analysis (uses gotree)
3. **Tree Pruning** - Prune branches below support threshold
4. **Node Extraction** - Extract node relationships
5. **SVD Feature Selection** - Select informative features
6. **Spatial Optimization** - Optimize spatial parameters
7. **Spatial Groups Identification** - Identify SG root nodes and pairs
8. **Differential Abundance** - Test differential expression (R-based)
9. **Spatial Lability Scoring** - Compute SLAB scores for genes
10. **BayesSpace** - Opt-out spatial clustering (auto-runs when `tumorspace_r.sif` present; skip with `--no-bayesspace`)
11. **Pipeline Report** - Automatic validation and visualization (auto-generated at end of every `run_pipeline.sh` run)

**For benchmark validation only:** You can compare results to expected outputs using `--comparison-dir` with `run_pipeline_report_slurm.sh`.

---

## Execution Modes

### Container Mode (Recommended)

**Production-ready with validated performance:**

```bash
run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers
```

**Benefits:**
- ✅ Fully reproducible across environments
- ✅ Self-contained Julia 1.9 + gotree runtime
- ✅ 12x performance improvement with `--no-home` flag (auto-applied)
- ✅ Bootstrap validation fully functional

**Performance:** 24s per task (with `--no-home`)

### Native Mode

**For development or when containers aren't available:**

```bash
run_pipeline.sh \
    --dataset GSE213688_GSM6592057
```

**Requirements:**
- Julia 1.9+ with TumorSPACE.jl installed
- R 4.4+ with required packages
- gotree installed for bootstrap validation
- Modules loaded: `module load julia/1.9 R/4.4`

**Performance:** 22s per task (slightly faster than container)

---

## Common Workflows

### 1. Complete Pipeline (Most Common)

Run the complete pipeline:

```bash
# Container mode (recommended)
run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers

# Native mode
run_pipeline.sh \
    --dataset GSE213688_GSM6592057

# Custom SLURM parameters
run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers \
    --partition <your-partition> \
    --account <your-account>
```

**Expected runtime:** Production mode (30 SVD runs): ~1-2 hours for benchmark dataset (370 spots). For quick testing, use `--test` flag: ~5-15 min native, ~30-60 min container. Reference: [timing estimates](benchmarks.md#resource-planning-by-dataset-size).

**Output location:** `benchmarks/<dataset>/container_test_<timestamp>/`

---

### 2. Run Individual Steps

Execute specific analysis steps independently:

```bash
# Step 1: Build phylogenetic tree
workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers

# Step 1b: Bootstrap validation (requires bootstrap tree file)
workflows/tumorspace_core/orchestration/run_phylo_bootstrap_support.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers \
    --bootstrap-tree benchmarks/.../bootstrap_trees.nwk

# Step 7: Differential abundance (R-based)
workflows/tumorspace_core/orchestration/run_sg_diff_abundance.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers

# Step 11: Pipeline Report only
workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \
    --dataset GSE213688_GSM6592057
```

**Note:** Individual steps require input files from previous steps to exist.

---

### 3. Benchmark Validation

Compare results against validated reference outputs:

```bash
# Run pipeline
run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers

# After completion, compare to expected outputs
workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \
    --dataset GSE213688_GSM6592057 \
    --comparison-dir benchmarks/GSE213688_GSM6592057/expected_outputs
```

**Expected validation metrics (with `--test` flag, fixed deterministic seed):**
- Correlation: R = 1.0 (exact)
- Score agreement: 100% identical
- Bootstrap validation: Passed

**Note:** These metrics apply when comparing against `expected_outputs` using `--test` mode (fixed seed). Both benchmark validation and container vs native comparison must use `--test` to be deterministic.

---

### 4. Container vs Native Comparison

Run both modes to compare performance and outputs:

```bash
# Container mode
run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers \
    --output-suffix container_comparison

# Native mode  
run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --output-suffix native_comparison

# Compare outputs
workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \
    --dataset GSE213688_GSM6592057 \
    --comparison-dir benchmarks/.../native_comparison_<timestamp>
```

---

## Input Data Requirements

TumorSPACE requires spatial transcriptomics data in specific format:

### Required Files

The included benchmark datasets already have these files in place under `benchmarks/<dataset>/input_data/`. For your own datasets, place these files in `benchmarks/<dataset>/input_data/` (or any directory you pass to `--input-dir`):

1. **M.txt** - Expression matrix (spots × genes)
   - Tab-separated, numeric values
   - Rows = spots, Columns = genes

2. **barcodes.txt** - List of spot barcodes
   - One barcode per line
   - Order must match M.txt rows

3. **features.txt** - List of gene names
   - One gene per line
   - Order must match M.txt columns

4. **barcodes_positions.txt** - Spatial coordinates
   - Format: `barcode\tx\ty`
   - Must include all barcodes from barcodes.txt

### Example: Benchmark Dataset

```bash
benchmarks/GSE213688_GSM6592057/input_data/
├── M.txt                      # ~13 MB, 370 spots × 18,085 genes
├── barcodes.txt               # 370 lines
├── features.txt               # 18,085 lines
└── barcodes_positions.txt     # 370 lines with coordinates
```

See [INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md) for detailed format specifications.

---

## Output Structure

After running the pipeline:

```
benchmarks/<dataset>/
└── runs/
    └── <run_name>_<timestamp>/
        ├── svd_run_1/               # Per-SVD analysis outputs
        ├── svd_run_2/, svd_run_3/, ...
        ├── bayesspace/              # Step 10: BayesSpace outputs (if run)
        │   ├── bayesspace_coldata.csv # Spot-level spatial cluster labels
        │   ├── cluster_plot.png       # Spatial cluster visualization
        │   └── parameters.txt         # Parameters and seeds used
        ├── optimal/                 # Symlink to best SVD result
        │   ├── sg_pairs.tsv           # Step 6: Spatial Groups pairs
        │   ├── DA_significant.txt     # Step 7: Differential abundance
        │   ├── SLAB_scores.txt        # Step 8: Spatial Lability scores
        │   └── pipeline_reports/      # Pipeline Report (auto-generated)
        │       └── <timestamp>/
        │           ├── Pipeline_Report.pdf
        │           └── pipeline_summary.md
        └── PIPELINE_COMPLETE.txt
```

---

## Monitoring & Debugging

### Check Job Status

```bash
# List your jobs
squeue -u $USER

# Check specific job
sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed,MaxRSS

# Monitor all pipeline jobs
watch -n 10 'squeue -u $USER'
```

### View Logs

```bash
# Latest logs
ls -lt benchmarks/<dataset>/logs/

# Follow error log in real-time
tail -f benchmarks/<dataset>/logs/step1_<jobid>.err

# Check for errors
grep -i error benchmarks/<dataset>/logs/*.err
```

### Common Issues

**Job fails immediately:**
- Check SLURM logs: `benchmarks/<dataset>/logs/step<N>_*.err`
- Verify input files exist and have correct format
- Check resource allocation (memory, CPUs)

**Container execution slow (>4 min per task):**
- Verify orchestration scripts include `--no-home` flag (they should auto-apply)
- Check logs for sandbox conversion warnings

**R step fails:**
- Ensure `tumorspace_r.sif` container exists (run `cd containers && bash build_r_container.sh`)
- Check R package dependencies in container
- View R error messages in SLURM logs

**Bootstrap validation fails:**
- Verify gotree is available: `singularity exec --no-home containers/julia_1.9_with_gotree.sif gotree version`
- Check bootstrap tree file exists
- Review bootstrap support output

**Missing output files:**
- Verify previous steps completed successfully
- Check SLURM job exit codes
- Review step-specific error logs

---

## Advanced Usage

### Custom Resource Allocation

Override default resource allocations:

```bash
workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers \
    --partition <your-partition> \
    --account <your-account> \
    --time 12:00:00 \
    --mem 128GB \
    --cpus 32
```

### Chain Multiple Datasets

Process multiple datasets sequentially:

```bash
for dataset in GSE213688_GSM6592057 GSE211956_GSM6506111; do
    run_pipeline.sh \
        --dataset $dataset \
        --container containers
done
```

### Custom Output Location

Specify custom output directory:

```bash
run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers \
    --output-suffix production_run_$(date +%Y%m%d)
```

---

## Best Practices

### For Production Analyses

1. **Always use container mode** for reproducibility
2. **Keep Pipeline Reports** for documentation
3. **Document SLURM parameters** used (partition, account, resources)
4. **Archive results** after completion
5. **Generate Pipeline Report** for every run

### For Development

1. **Use native mode** for faster iteration
2. **Test with benchmark dataset** first (370 spots, fast)
3. **Run individual steps** to debug specific stages
4. **Check logs frequently** during development
5. **Verify outputs** match expected format

### For Benchmark Validation

1. **Run complete pipeline** with container mode
2. **Generate Pipeline Report** with comparison to expected outputs
3. **Verify metrics** meet thresholds (R>0.85, >95% agreement)
4. **Document any deviations** from expected results

---

## Performance Expectations

For measured per-step and total runtimes across all three benchmark datasets, see [benchmarks.md](benchmarks.md).

Brief summary for the benchmark dataset (370 spots, 18K genes):
- **Production mode** (30 SVDs): ~25 min native, ~45 min container
- **Test mode** (3 SVDs): ~5 min native, ~15 min container
- Container overhead is <10% per task when `--no-home` is applied (auto-applied by orchestration scripts)

### Scaling to Larger Datasets

| Dataset Size | Spots | Expected Runtime | Recommended Resources |
|--------------|-------|------------------|----------------------|
| Small | <1,000 | 1-2 hours | 8 CPUs, 32GB |
| Medium | 1,000-5,000 | 2-6 hours | 16 CPUs, 64GB |
| Large | 5,000-10,000 | 6-12 hours | 32 CPUs, 128GB |
| Very Large | >10,000 | 12-24 hours | 64 CPUs, 256GB |

---

## Troubleshooting

### Where Is My Pipeline Report?

**Problem:** Pipeline completed but you can't find the Pipeline Report.

**Solution:** Pipeline Reports are automatically generated at the **end of the pipeline** (Step 11) and appear in:

```bash
# Using organized output directory:
{OUTPUT_DIR}/optimal/pipeline_reports/{TIMESTAMP}/

# Example:
ls -lh benchmarks/GSE213688_GSM6592057/runs/analysis_v1/optimal/pipeline_reports/

# Using absolute path output directory:
ls -lh /scratch/$USER/results/optimal/pipeline_reports/
```

**What to look for:**
```
optimal/pipeline_reports/20260128_164522/
├── plot1_tree_postprune.pdf        # Post-prune phylogenetic tree
├── plot2_da_sg_tree.pdf            # DA genes and SG pairs
├── plot3_slab_distribution.pdf     # SLAB score distribution
├── pipeline_summary.md             # Text summary of key metrics
├── Pipeline_Report.pdf             # Combined PDF report
└── log.txt                         # Generation log
```

**If the Pipeline Report is missing:**

1. **Check pipeline completion:**
   ```bash
   cat {OUTPUT_DIR}/PIPELINE_COMPLETE.txt
   ```
   If this file exists, pipeline finished. If not, jobs still running.

2. **Check Pipeline Report job status:**
   ```bash
   # Find the Pipeline Report job ID (Step 11)
   grep "step_11\|pipeline_report" {OUTPUT_DIR}/pipeline_jobs.txt
   
   # Check its status
   sacct -j <REPORT_JOB_ID> --format=JobID,State,ExitCode
   ```

3. **Check Pipeline Report job logs for errors:**
   ```bash
   ls -lh logs/ | grep pipeline_report
   cat logs/*pipeline_report*.err
   ```

4. **Manual Pipeline Report generation (if auto-generation failed):**
   ```bash
   bash workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \
       --output-dir {YOUR_OUTPUT_DIR}/optimal \
       --account pi-araman \
       --partition caslake
   ```

### Common Pipeline Report Issues

**No plots generated:**
- Check that optimal/ directory exists: `ls -la {OUTPUT_DIR}/optimal/`
- Verify at least one SVD run completed: `ls -la {OUTPUT_DIR}/svd_run_1/`
- Check R is available: `module load R && R --version`

**Pipeline Report shows low correlation (<0.5):**
- This may indicate code changes between runs
- Verify you're using same code version: `git log --oneline -1`
- Re-run with `--fixed-seed` flag to ensure reproducibility

**Memory error during Pipeline Report generation:**
- Pipeline Report generation typically needs 8GB, try: `--mem 16G`
- If still failing, check other jobs: `squeue -u $USER`

---

## Additional Resources

- **Complete Pipeline Documentation:** [workflows/README.md](../workflows/README.md)
- **Container Setup:** [containers/README.md](../containers/README.md)
- **Getting Started Tutorial:** [GETTING_STARTED.md](GETTING_STARTED.md)
- **Performance Benchmarks:** [benchmarks.md](benchmarks.md)
- **Input/Output Formats:** [INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md)
- **TumorSPACE.jl Package:** https://github.com/aramanlab/TumorSPACE.jl
- **Arjun Raman Lab:** https://ramanlab.net/

---

## Getting Help

If you encounter issues:

1. Check [workflows/README.md](../workflows/README.md) troubleshooting section
2. Review SLURM logs in `benchmarks/<dataset>/logs/`
3. Verify input file formats match [INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md)
4. Open an issue on GitHub with:
   - Dataset name and size
   - Command used
   - Error messages from logs
   - Job ID and SLURM parameters
