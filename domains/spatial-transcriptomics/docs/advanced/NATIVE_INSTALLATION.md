# TumorSPACE Native Installation Guide

This guide covers installing and running TumorSPACE **without containers**, using system Julia and R installations on HPC or local machines.

## When to Use Native Mode

**Use native mode when:**
- You have access to Julia/R modules on HPC
- You want faster execution (no container overhead)
- You're developing/debugging pipeline scripts
- Container builds are not feasible

**Use containers when:**
- You need guaranteed reproducibility across systems
- System dependencies are difficult to manage
- You're deploying on cloud/AWS infrastructure

## Prerequisites

### Required Software Versions

| Software | Minimum Version | Recommended | Purpose |
|----------|----------------|-------------|---------|
| **Julia** | 1.9+ | 1.9.0 | Core pipeline Steps 1-6, 8-9 |
| **R** | 4.4+ | 4.4.1 | Step 7 (SG pairs), Steps 10-11 (BayesSpace, Pipeline Report) |
| **Git** | Any | Latest | Repository management |

### System Requirements

- **Memory**: 4-64GB depending on dataset size (see [benchmarks.md](../benchmarks.md#resource-planning-guide))
- **Disk**: ~500MB for dependencies + dataset storage
- **OS**: Linux (tested on CentOS 7/8, Ubuntu 20.04+)

## Installation Steps

### 1. Clone Repository

```bash
cd /path/to/your/workspace
git clone https://github.com/aramanlab/TumorSPACE_AWS.git
cd TumorSPACE_AWS
```

### 2. Install Julia Dependencies

TumorSPACE uses a portable Julia environment defined in [workflows/tumorspace_core/julia/Project.toml](../workflows/tumorspace_core/julia/Project.toml).

```bash
# Load Julia module (HPC)
module load julia/1.9  # Or julia/1.9.0, check: module avail julia

# Navigate to Julia scripts directory
cd workflows/tumorspace_core/julia

# Install all dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

**Expected output:**
```
Updating registry at `~/.julia/registries/General.toml`
Installed CSV ──────────── v0.10.11
Installed DataFrames ────── v1.6.1
Installed PhyloNetworks ─── v0.16.4
Installed SpectralInference v0.1.0
Installed NewickTree ────── v0.5.0
...
Precompiling project...
✓ CSV
✓ DataFrames
✓ PhyloNetworks
```

**What gets installed:**
- CSV, DataFrames (data I/O)
- SpectralInference, NewickTree (tree building)
- PhyloNetworks (tree manipulation)
- Distances, StatsBase, Random, Noise (core algorithms)

**Installation location:** `~/.julia/packages/` (user-specific, no admin rights needed)

### 3. Install R Dependencies

#### Core Packages (Steps 5-7)

```bash
# Load R module (HPC)
module load R/4.4  # Check: module avail R

# Install core packages
R -e "install.packages(c('dplyr', 'data.table', 'ape', 'phangorn'), \
                       repos='https://cloud.r-project.org')"
```

#### Visualization Packages (Pipeline Report - Optional)

```bash
# Install ggplot2 and patchwork
R -e "install.packages(c('ggplot2', 'patchwork'), \
                       repos='https://cloud.r-project.org')"

# Install ggtree from Bioconductor
R -e "install.packages('BiocManager', repos='https://cloud.r-project.org'); \
      BiocManager::install('ggtree')"
```

**Package purposes:**
- **dplyr, data.table**: Data manipulation
- **ape, phangorn**: Phylogenetic tree operations
- **ggplot2, patchwork**: Visualization
- **ggtree**: Phylogenetic tree visualization

**Installation location:** 
- Default: `~/R/x86_64-pc-linux-gnu-library/4.4/`
- Or system-wide if installed by admin

#### BayesSpace (Step 11 - Optional)

BayesSpace (Step 10) enables spatial clustering of spot-level transcriptomics data. It is handled
automatically by `setup.sh` when `--install-native` is requested.

> **Recommendation:** Use the container (`containers/tumorspace_r.sif`) rather than native
> BayesSpace whenever Singularity/Apptainer is available. Container mode sidesteps the
> GLIBCXX and RAM requirements described below entirely.

**Installation via setup.sh:**

```bash
# Automatically installs BayesSpace and all dependencies:
bash setup.sh --install-native
```

**Arrow C++ compilation requires ~16 GB RAM — must run on a compute node:**

BayesSpace depends on `arrow`, which compiles Arrow C++ from source. This compilation
requires ~16 GB of RAM and will silently fail or OOM-kill on a login node.

`setup.sh` includes a login-node guard: it detects the login-node context (no
`SLURM_JOB_ID` present, or hostname matching `login*`/`midway*login*`) and refuses Arrow
compilation, printing the correct `srun` command. If you see this guard, run:

```bash
# On midway3: allocate a compute node with enough RAM
srun --mem=16G --partition=caslake --time=01:00:00 bash setup.sh --install-native
```

**GLIBCXX_3.4.30 / igraph incompatibility (midway3 / RHEL 8):**

BayesSpace depends on `igraph`, which requires the C++ symbol `GLIBCXX_3.4.30`. The
system-default `libstdc++` linked by RHEL 8's GCC 8.5 only provides up to
`GLIBCXX_3.4.26`, so loading `igraph` in native R produces:

```
/lib/x86_64-linux-gnu/libstdc++.so.6: version 'GLIBCXX_3.4.30' not found
```

The fix is to preload a newer `libstdc++` before any R invocation:

```bash
export LD_PRELOAD=/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6
Rscript workflows/bayesspace/R/run_bayesspace.R ...
```

**This `LD_PRELOAD` is already applied automatically** by both `run_bayesspace.sh` and
`setup.sh`; you do not need to set it manually when using the orchestration scripts. The
path above is correct for midway3; on other HPC systems you need the equivalent GCC 12+
`libstdc++.so.6` path (check with `find /software -name 'libstdc++.so.6' | xargs -I{} sh -c 'strings {} | grep GLIBCXX_3.4.30 && echo {}'`).

**Verify BayesSpace native installation:**

```bash
LD_PRELOAD=/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6 \
R --vanilla -e '
library(BayesSpace)
library(igraph)
cat("✓ BayesSpace loaded successfully\n")
'
```

### 4. Verify Installation

#### Test Julia

```bash
cd TumorSPACE_AWS/workflows/tumorspace_core/julia

julia --project=. -e '
include("tumorspace_core.jl")
println("✓ All Julia packages loaded successfully")
'
```

#### Test R

```bash
R --vanilla -e '
library(dplyr)
library(data.table)
library(ape)
library(phangorn)
cat("✓ All R packages loaded successfully\n")
'
```

#### Test Bundled Binary

```bash
cd TumorSPACE_AWS
./bin/gotree --version
# Expected: booster version v0.1.2
```

## Running the Pipeline (Native Mode)

### Option 1: Orchestration Scripts (Recommended)

Full pipeline with SLURM job arrays and dependency management:

```bash
cd TumorSPACE_AWS

# Test mode (3 SVD values, small dataset)
bash run_pipeline.sh \
  --dataset GSE213688_GSM6592057 \
  --account <your-account> \
  --partition <your-partition> \
  --test

# Production mode (30 SVD values)
bash run_pipeline.sh \
  --dataset GSE213688_GSM6592057 \
  --account <your-account> \
  --partition <your-partition>
```

### Option 2: Manual Step-by-Step

Run individual steps for debugging or custom workflows:

```bash
# Load modules
module load julia/1.9
module load R/4.4

# Step 1: Tree building (run for each SVD value)
bash workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh \
  --account <your-account> \
  --partition <your-partition> \
  --dataset GSE213688_GSM6592057 \
  --input-dir benchmarks/GSE213688_GSM6592057/input_data \
  --output-dir benchmarks/output \
  --test

# Bootstrap support calculation
bash workflows/tumorspace_core/orchestration/run_phylo_bootstrap_support.sh \
  --account <your-account> \
  --partition <your-partition> \
  --output-base benchmarks/output \
  --test

# Step 2: Node extraction (for each SVD)
# Step 3: Spatial optimization (for each SVD)
# SVD selection
# Steps 4-7: Downstream analysis on optimal SVD
```

### Option 3: Direct Script Invocation

For local testing without SLURM:

```bash
module load julia/1.9

# Step 1: Single tree
julia --project=workflows/tumorspace_core/julia workflows/tumorspace_core/julia/phylo_tree_build.jl \
  --dataset GSE213688_GSM6592057 \
  --input-dir benchmarks/GSE213688_GSM6592057/input_data \
  --output-dir output/svd_run_1 \
  --svd-run 1 \
  --svd-value 50 \
  --boot 0

# Step 2: Node extraction
julia --project=workflows/tumorspace_core/julia workflows/tumorspace_core/julia/phylo_node_extract.jl \
  output/svd_run_1 \
  output/svd_run_1/Tree_0.nw \
  benchmarks/GSE213688_GSM6592057/input_data/barcodes_positions.txt
```

## Module Loading Best Practices

### On HPC Systems

Create an activation script for consistent environment setup:

```bash
# Create activate_tumorspace.sh
cat > activate_tumorspace.sh << 'EOF'
#!/bin/bash
# TumorSPACE environment activation

# Load required modules
module load julia/1.9
module load R/4.4

# Set Julia project path
export JULIA_PROJECT="$PWD/workflows/tumorspace_core/julia"

# Verify
echo "✓ Julia: $(julia --version)"
echo "✓ R: $(R --version | head -1)"
echo "✓ Julia project: $JULIA_PROJECT"
EOF

chmod +x activate_tumorspace.sh

# Use in scripts
source activate_tumorspace.sh
```

### In SLURM Job Scripts

```bash
#!/bin/bash
#SBATCH --job-name=tumorspace
#SBATCH --account=<your-account>
#SBATCH --partition=<your-partition>
#SBATCH --mem=8G
#SBATCH --time=00:30:00

# Load modules
module load julia/1.9
module load R/4.4

# Run pipeline step
julia --project=/path/to/TumorSPACE_AWS/workflows/tumorspace_core/julia \
  workflows/tumorspace_core/julia/phylo_tree_build.jl ...
```

## Troubleshooting

### Julia Issues

**Problem**: `ERROR: ArgumentError: Package X not found in current path`

**Solution**: Ensure you're using `--project` flag or `JULIA_PROJECT` environment variable:
```bash
julia --project=workflows/tumorspace_core/julia script.jl
# OR
export JULIA_PROJECT=workflows/tumorspace_core/julia
julia script.jl
```

**Problem**: `ERROR: LoadError: UndefVarError: model_calc not defined`

**Solution**: The script needs to include tumorspace_core.jl first:
```julia
include(joinpath(@__DIR__, "tumorspace_core.jl"))
```

### R Issues

**Problem**: `Error in library(X) : there is no package called 'X'`

**Solution**: Install missing package:
```bash
R -e "install.packages('X', repos='https://cloud.r-project.org')"
```

**Problem**: `ggtree` installation fails with compilation errors

**Solution**: Use conda/mamba instead:
```bash
conda create -n tumorspace_r r-base=4.4 r-dplyr r-data.table r-ape r-phangorn
conda activate tumorspace_r
conda install -c bioconda bioconductor-ggtree
```

### Binary Issues

**Problem**: `bin/gotree: command not found` or `Permission denied`

**Solution**: Ensure binary is executable:
```bash
chmod +x bin/gotree
./bin/gotree --version
```

**Problem**: `bin/gotree: error while loading shared libraries`

**Solution**: System may be missing libgomp (OpenMP library):
```bash
# CentOS/RedHat
sudo yum install libgomp

# Ubuntu/Debian
sudo apt-get install libgomp1
```

## Performance Tips

### Julia Compilation

First run of any Julia script includes compilation time (~5-30 seconds). Use `--compile=min` to reduce:
```bash
julia --project=. --compile=min script.jl
```

### Parallel Processing

Adjust thread counts based on available CPUs:
- **gotree**: `-@ 4` (4 threads for bootstrap support)
- **Julia**: Single-threaded by default (sufficient for most operations)
- **R**: Single-threaded (use `parallel` package if needed)

### Memory Allocation

Monitor memory usage and adjust SLURM `--mem` accordingly:
- Small datasets (<1k spots): 4GB
- Medium datasets (1-10k spots): 8-16GB  
- Large datasets (>10k spots): 32-64GB

## Updating Dependencies

### Update Julia Packages

```bash
cd workflows/tumorspace_core/julia
julia --project=. -e 'using Pkg; Pkg.update()'
```

### Update R Packages

```bash
R -e "update.packages(repos='https://cloud.r-project.org', ask=FALSE)"
```

## Comparison: Native vs Container

| Aspect | Native Mode | Container Mode |
|--------|-------------|----------------|
| **Installation** | Per-user, ~10 minutes | One-time build, 15-20 minutes |
| **Performance** | Fastest (no overhead) | ~10-20% slower |
| **Reproducibility** | Depends on module versions | Guaranteed identical |
| **Flexibility** | Easy to modify/debug | Requires rebuild |
| **Portability** | Requires matching HPC setup | Runs anywhere |
| **Storage** | ~500MB (packages only) | ~5GB (full environment) |

**Recommendation**: Use native mode for development and HPC production runs. Use containers for AWS deployments and cross-system reproducibility.

## Support

- **Documentation**: [docs/](../docs/)
- **Issues**: https://github.com/aramanlab/TumorSPACE_AWS/issues
- **Examples**: [benchmarks/](../benchmarks/)

---

**Next**: See [GETTING_STARTED.md](../GETTING_STARTED.md) for a complete walkthrough with example data.
