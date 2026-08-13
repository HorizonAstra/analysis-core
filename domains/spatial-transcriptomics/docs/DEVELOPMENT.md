# Development Guide

This guide explains how to modify TumorSPACE_AWS code and test your changes.

## Code Organization

### Workflow Scripts
- **Location:** `workflows/tumorspace_core/julia/` - Core analysis algorithms
  - `phylo_tree_build.jl` - Phylogenetic tree construction with seeding
  - `tumorspace_core.jl` - Main analysis pipeline
  - Other *.jl files - Supporting utilities

- **Location:** `workflows/tumorspace_core/orchestration/` (and other feature orchestration dirs) - Orchestration and execution
  - `run_pipeline_full.sh` - Main entry point orchestrating the full pipeline
  - `run_*.sh` - Individual step execution scripts
  - Job dependency and SLURM parameter management

### Container Architecture

**CRITICAL:** The container embeds workflow scripts at build time. Host code changes are NOT automatically visible to the container.

- Container build path: `/opt/workflows/` (internal, inside Singularity image)
- Host path: `/project/araman/vivek/TumorSPACE_AWS/workflows/` (your edits)

**Implication:** After editing host files, you must rebuild the container for container mode to use updated code.

### Container Rebuild: When to Run What

The R container is split into two layers to keep iteration fast:

- **`tumorspace_r_base.sif`** (~10 min): OS + all R packages, built once and reused
- **`tumorspace_r.sif`** (~30 sec): workflow scripts only, layered on top of the base

| Scenario | What changed | Command |
|---|---|---|
| 1. Script-only change | Edited an R workflow script | `bash containers/build_r_container.sh --scratch /scratch/$USER/tmp` |
| 2. R package change | Added/changed a CRAN or Bioconductor package | `bash containers/build_r_container.sh --scratch /scratch/$USER/tmp --force` |
| 3. First-time setup | New clone, no containers yet | `bash setup.sh --scratch /scratch/$USER/tmp` |
| 4. Pre-merge isolation test | Verify a full clean build from scratch | `bash tests/clean_container_rebuild.sh` |

**Scenario 1** (most common) detects that the base already exists and only rebuilds the script layer (~30 sec). Post-build verification runs automatically. `--scratch` is only strictly required when Phase 1 runs, but passing it always is safe and avoids the error if the base SIF is missing.

**Scenario 2** rebuilds the base from a public Docker Hub image and then the script layer (~30 min total). Use `--force` only when package-level changes are needed. Add `--nohup` to background the build and survive SSH disconnects: `bash containers/build_r_container.sh --scratch /scratch/$USER/tmp --force --nohup`.

**Scenario 3** `setup.sh` passes `--scratch` through to `build_r_container.sh` automatically.

**Scenario 4** clones the repo to a sibling directory on the same filesystem (not `/tmp`, which is a separate mount on some HPC systems and causes `git clone --local` hardlinks to fail). Your local containers are never touched; the temp clone is deleted automatically when the test finishes.

## HPC Configuration

TumorSPACE runs on multiple HPC systems. Module names for Singularity, Julia, and R differ across clusters, and some clusters (e.g. Randi) require prerequisite modules (e.g. `gcc`) before loading language modules. The `config/hpc_profile.sh` system handles these differences uniformly.

### First-time setup

```bash
cp config/hpc_profile.sh.example config/hpc_profile.sh
```

The live copy is gitignored. The `.example` file is the committed template and serves as a fallback if the live copy is absent.

### Auto-detection

The profile auto-detects the cluster by matching the short hostname:

| Hostname pattern | Detected profile | Notes |
|---|---|---|
| `*midway*`, `*rcc*` | `midway3` | UChicago RCC |
| `*randi*`, `*rand*` | `randi` | Collaborator HPC — requires `gcc` before julia |
| (anything else) | `local` | Workstation — module commands are no-ops |

Override auto-detection before sourcing:
```bash
export HPC_PROFILE=randi
source config/hpc_profile.sh
```

### What the profile provides

Each script that uses modules sources the profile near its top:

```bash
_HPC_PROFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
source "$_HPC_PROFILE" && unset _HPC_PROFILE
```

This exports:
- `MODULE_SINGULARITY`, `MODULE_JULIA`, `MODULE_R` — module names for each tool
- `HPC_LOAD_SINGULARITY`, `HPC_LOAD_JULIA`, `HPC_LOAD_R` — pre-expanded command strings used inside heredocs when generating SBATCH scripts
- `hpc_module_load VAR_NAME` — loads the module named by a variable; silent no-op when empty
- `hpc_load_julia` — loads prereqs (e.g. `gcc` on Randi) then Julia

### Adding a new cluster

1. Add a hostname pattern in `_hpc_detect_profile()` in `config/hpc_profile.sh.example`
2. Add a `case` block with the correct `MODULE_*` values
3. Set `MODULE_JULIA_PREREQS` to a space-separated list of prerequisite modules (empty if none)

## Directory Organization

Understanding where inputs and outputs are stored is critical when running pipelines.

### Input Data Location

Input datasets must be organized under `benchmarks/{DATASET}/input_data/`:

```
benchmarks/
├── GSE213688_GSM6592057/
│   └── input_data/
│       ├── barcodes_positions.txt    (required: spot coordinates)
│       ├── M.txt                     (required: expression matrix)
│       ├── barcodes.txt              (required: spot names)
│       ├── features.txt              (required: gene names — canonical filename)
│       └── genes.txt                 (alias for features.txt, also accepted)
```

When specifying `--input-dir`, point to this directory:
```bash
--input-dir benchmarks/GSE213688_GSM6592057/input_data
```

### Output Directory Structures

The pipeline creates outputs in different structures depending on your `--output-dir` specification. Both are supported:

#### Option 1: Organized Structure (Recommended)
Use `--output-dir benchmarks/{DATASET}/runs/{RUN_ID}/`:

```
benchmarks/
├── GSE213688_GSM6592057/
│   └── runs/
│       ├── native_test_20260128_162956/
│       │   ├── svd_run_1/
│       │   ├── svd_run_2/
│       │   ├── svd_run_3/
│       │   ├── optimal/              (symlink to best SVD)
│       │   │   ├── OptimalTree_pruned_node_*.txt
│       │   │   └── SLAB_scores.txt
│       │   ├── pipeline_reports/     (Pipeline Report files — sibling to optimal/)
│       │   ├── pipeline_jobs.txt
│       │   └── PIPELINE_COMPLETE.txt
│       └── container_test_20260128_163015/
│           └── [same structure]
```

#### Option 2: Root-Level Output
Use `--output-dir /absolute/path/outputs`:

```
/absolute/path/outputs/
├── svd_run_1/
├── svd_run_2/
├── optimal/                  (symlink to best SVD)
│   └── [same structure as above]
├── pipeline_reports/         (Pipeline Report files — sibling to optimal/)
└── PIPELINE_COMPLETE.txt
```

### Pipeline Report Location

After pipeline completion, Pipeline Report files automatically appear in:

```
{OUTPUT_BASE}/pipeline_reports/
```

Where `{OUTPUT_BASE}` is the run directory containing `optimal/` (i.e., the parent of your `--output-dir`).

**Example paths:**
- Organized: `benchmarks/GSE213688_GSM6592057/runs/native_test_20260128_162956/pipeline_reports/`
- Root-level: `/tmp/outputs/pipeline_reports/`

### Where to Store Everything

**Quick guide:**
1. **Input data:** `benchmarks/{DATASET}/input_data/`
2. **Outputs:** `benchmarks/{DATASET}/runs/{YOUR_RUN_NAME}/` OR any `--output-dir` you specify
3. **Pipeline reports:** Automatically in `{OUTPUT_BASE}/pipeline_reports/` (sibling to `optimal/`)
4. **Logs:** `logs/` directory at repo root
5. **Test outputs:** Already ignored by `.gitignore` (won't be committed)

### Example Commands

```bash
# Organized structure - test mode
bash run_pipeline.sh \
  --dataset GSE213688_GSM6592057 \
  --input-dir benchmarks/GSE213688_GSM6592057/input_data \
  --output-dir benchmarks/GSE213688_GSM6592057/runs/test_run \
  --account pi-araman --partition caslake --test

# Root-level output - production mode
bash run_pipeline.sh \
  --dataset GSE213688_GSM6592057 \
  --input-dir benchmarks/GSE213688_GSM6592057/input_data \
  --output-dir /scratch/vivek/results \
  --account pi-araman --partition caslake

# Check results
ls -lh /scratch/vivek/results/pipeline_reports/
```

## Development Workflow

### Quick Validation: One-Button Test

**Before pushing to main branch**, validate your installation and changes:

```bash
# Quick test - just verify prerequisites and submit test pipeline (~30 sec)
bash test_installation.sh --account YOUR_ACCOUNT --partition YOUR_PARTITION

# Full test - wait for completion and validate all outputs (15-60 min)
bash test_installation.sh --account YOUR_ACCOUNT --partition YOUR_PARTITION --wait

# Validate existing run - get instant binary PASS/FAIL for completed run
bash test_installation.sh --validate-run benchmarks/GSE213688_GSM6592057/runs/install_test_*
```

**Three Testing Modes:**

1. **Quick Mode** (30 seconds): Checks prerequisites and submits pipeline
   - ✓ Container exists and is built correctly
   - ✓ Benchmark data is present
   - ✓ Workflow scripts are in place
   - ✓ SLURM is available
   - ✓ Test pipeline submits successfully

2. **Full Mode** (15-60 minutes, with `--wait`): Complete validation including reproducibility
   - ✓ All Quick Mode checks
   - ✓ Waits for pipeline completion
   - ✓ Validates all expected outputs exist
   - ✓ **Byte-level comparison to reference outputs** (confirms reproducibility)

3. **Validate Existing Run** (instant, with `--validate-run DIR`): Validate already-completed run
   - ✓ Validates all expected outputs exist
   - ✓ **Byte-level comparison to reference outputs**
   - ✓ Useful for checking runs after they complete without re-running

**Exit codes:**
- 0 = PASS - Safe to push to main
- 1 = FAIL - Fix issues before pushing

**Reproducibility Validation:**
The test compares 5 critical output files byte-for-byte against reference outputs in `benchmarks/GSE213688_GSM6592057/expected_outputs/`:
- `OptimalTree_pruned.nw`
- `OptimalTree_preprune.nw`
- `OptimalTree_pruned_node_compare_list.txt`
- `SLAB_scores.txt`
- `DA_significant.txt`

Fixed seeds in `--test` mode ensure deterministic outputs. Any differences indicate non-deterministic behavior or code changes affecting results.

This replaces manual testing and ensures consistent validation across all developers.

### Detailed Development Workflow

### Step 1: Edit Code

Make changes to files in `workflows/tumorspace_core/julia/` or `workflows/tumorspace_core/orchestration/`:

```bash
# Example: Edit phylo tree builder
nano workflows/tumorspace_core/julia/phylo_tree_build.jl

# Commit your changes
git add workflows/
git commit -m "feature: add new phylogenetic method"
```

### Step 2: Test Native Mode

Test your changes using native (non-containerized) execution:

```bash
# Test mode: runs with 3 SVDs and fixed seeds for reproducibility
bash run_pipeline.sh --test

# Monitor progress
watch -n 1 'tail -20 logs/*.log'

# When complete, check results
ls -lh local/outputs/
```

**Native mode advantages:**
- Faster feedback loop (no container rebuild)
- Easier debugging with direct file access
- Can modify and re-run without rebuilding

### Step 3: Rebuild Container

There are two containers — rebuild the one appropriate to what you changed:

**Julia container** (`julia_1.9_with_gotree.sif`) — for changes to `.jl` scripts:
```bash
bash containers/add_gotree_to_julia.sh   # ~8-15 min
```

**R container** (`tumorspace_r.sif`) — for changes to `.R` scripts (pipeline report, BayesSpace, DE_analysis, etc.):
```bash
# Script layer only (~30 sec, most common — skips Phase 1 if base SIF exists)
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp

# Full rebuild including R packages (~30 min — use when adding/changing packages)
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp --force

# Same, but backgrounded via nohup to survive SSH disconnect
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp --force --nohup
```

`--scratch` must point to a local filesystem with execute permissions (not GPFS, not a `noexec`-mounted `/tmp` or `/dev/shm`). On most clusters `/scratch/$USER/tmp` works. The path is used as `TMPDIR` during R package compilation inside the container.

Post-build verification runs automatically after each rebuild.

### Step 4: Test Container Mode

Run same test with container to verify identical results:

```bash
# Test container mode: runs with fixed seeds
bash run_pipeline.sh --container containers --test

# Monitor progress
watch -n 1 'squeue -u $USER'

# Check SLURM job logs
sacct -j <jobid> --format=JobID,State,Elapsed,MaxRSS
```

### Step 5: Compare Results

Verify native and container modes produce identical outputs against the reference baseline:

```bash
# Validate the container test run against reference outputs
bash test_installation.sh --validate-run benchmarks/GSE213688_GSM6592057/runs/install_test_*

# Both native and container test runs should produce PASS (identical to reference)
```

## Testing Modes

### Test Mode (`--test`)

```bash
bash run_pipeline.sh --test
```

**Purpose:** Quick validation with fixed seeds and reduced data  
**What it does:**
- Runs only 3 SVD runs (instead of 30)
- Uses fixed seeds: `seed = 1000 + svd_run*100 + bootstrap*1000`
- Expected runtime: ~5-10 minutes native, ~30-60 minutes container
- **Output:** Deterministic results, identical across runs

**Use for:**
- Validating code changes
- Checking reproducibility
- Quick sanity checks

### Production Mode (no `--test`)

```bash
bash run_pipeline.sh
```

**Purpose:** Full analysis with 30 SVD runs and random seeds  
**What it does:**
- Runs 30 SVD runs with random seeds
- Full bootstrap analysis
- Complete pipeline report generation
- Expected runtime: 2-4 hours on typical HPC nodes
- **Output:** Publication-quality analysis results

## Debugging

### View Logs

```bash
# Real-time logs from current run
tail -f logs/*.log

# All completed logs
ls -lh logs/
cat logs/phylo_tree_build*.log
```

### Enable Debug Output

Edit `workflows/tumorspace_core/julia/phylo_tree_build.jl` to add logging:

```julia
# Add before key computation steps
println(stderr, "DEBUG: seed_val = $seed_val")
println(stderr, "DEBUG: matrix size = $(size(matrix))")
```

### Run Individual Steps

Execute pipeline steps manually for targeted testing:

```bash
# Run just phylo tree building
bash workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh --dataset GSE213688_GSM6592057 --test

# Run just node extraction
bash workflows/tumorspace_core/orchestration/run_phylo_node_extract.sh
```

### Check Seed Application

Verify seeds are being applied correctly:

```bash
# Search for seed debug output
grep -r "seed_val\|Random.seed" logs/

# Expected output shows seed values for each bootstrap/SVD combination
```

## Reproducibility & Seeding

### Seed Formula

When `--test` flag is enabled:
```
seed = 1000 + svd_run * 100 + bootstrap * 1000
```

**Example:**
- SVD run 0, bootstrap 0 → seed = 1000
- SVD run 1, bootstrap 0 → seed = 1100
- SVD run 0, bootstrap 5 → seed = 6000
- SVD run 3, bootstrap 2 → seed = 4300

**Why deterministic seeding matters:**
- Ensures identical results for same input + same code
- Allows verification that code changes don't introduce bugs
- Enables reproducible benchmarking across platforms

### Verifying Reproducibility

```bash
# Run test twice
bash run_pipeline.sh --test
mv local/outputs local/outputs_run1

bash run_pipeline.sh --test
mv local/outputs local/outputs_run2

# Compare trees - should be byte-identical
diff local/outputs_run1/Tree_*.nw local/outputs_run2/Tree_*.nw

# Expected: No differences
```

## Common Issues

### Container Changes Not Taking Effect

**Symptom:** Tree output differs between native and container despite identical code.
**Cause:** Container wasn't rebuilt after code changes.
**Solution:**
```bash
bash containers/add_gotree_to_julia.sh
bash run_pipeline.sh --container containers --test
```

### Different Results Between Runs (with `--test`)

**Symptom:** Tree_0.nw differs across identical runs with `--test` flag.  
**Cause:** Seeding not properly applied in code.  
**Debugging:**
```bash
# Check for seed application in logs
grep "seed" logs/phylo_tree_build*.log

# If no seed output: Check phylo_tree_build.jl lines 87-95
# Should show seed calculation and application
```

### Memory Issues on Large Datasets

**Symptom:** Job killed with "Segmentation fault" or memory exceeded.  
**Solution:**
```bash
# Check SLURM memory settings in config/slurm_config.sh
cat config/slurm_config.sh | grep MEM

# Increase for large datasets (>5K spots)
# Edit config/slurm_config.sh and set MEMORY=32G
```

## Committing Changes

When your changes are working in both native and container modes:

```bash
# Stage changes
git add workflows/ config/ docs/

# Commit with clear message
git commit -m "feature: description of what was added/fixed"

# Push to repository
git push origin master
```

**Commit message guidelines:**
- Start with `feature:`, `fix:`, `docs:`, or `refactor:`
- Be specific about what changed
- Include ticket/issue reference if applicable
- Example: `fix(seeding): Include bootstrap offset in seed calculation`

## Related Documentation

- [README.md](../README.md) - Project overview and quick links
- [GETTING_STARTED.md](GETTING_STARTED.md) - User setup and first run
- [benchmarks.md](benchmarks.md) - Timing data and performance analysis
- [BUILD_INSTRUCTIONS.md](../containers/BUILD_INSTRUCTIONS.md) - Container build details
- [advanced/MOUSE_KP_ISG_IMMUNE_EXPLORATION.md](advanced/MOUSE_KP_ISG_IMMUNE_EXPLORATION.md) - Exploratory immune analysis
- [FEATURE_ROLLOUT.md](FEATURE_ROLLOUT.md) - Planned sg_analysis v2 enhancements
