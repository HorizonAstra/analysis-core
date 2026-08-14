# TumorSPACE Container Build Instructions

**Last Updated:** March 2026
**Production Containers:** `julia_1.9_with_gotree.sif` (~309 MB), `tumorspace_r.sif` (~1.5 GB), `tumorspace_r45.sif` (~845 MB)
**Last Rebuild:** March 2026 (added `tumorspace_r45.sif` — R 4.5 / Bioc 3.21 container for DE analysis; Seurat, DESpace 2.0, terra, sf, and full geo library stack)

## ⚠️ Critical: Code Changes Require Container Rebuild

When you modify workflow scripts (`.jl` or `.R` files in `workflows/`):

1. **The scripts are EMBEDDED in the container image** at build time
2. **Host changes do NOT automatically appear in container**
3. **You MUST rebuild the container** for changes to take effect

### Recommended Development Workflow
- Test changes using **native mode** first (faster feedback cycle)
- Once changes are verified, rebuild the container
- Test container mode with updated scripts

### Quick Rebuild

**Julia container** (`julia_1.9_with_gotree.sif`) — for changes to `.jl` scripts in `workflows/tumorspace_core/julia/`:
```bash
bash containers/add_gotree_to_julia.sh   # ~8-12 min
```

**R container** (`tumorspace_r.sif`) — for changes to `.R` scripts in `workflows/pipeline_report/R/`, `workflows/bayesspace/R/`, etc.:
```bash
# Script layer only (~30 sec, most common — skips Phase 1 if base SIF exists)
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp

# Full rebuild including R packages (~30 min — required when adding/changing packages)
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp --force

# Same, backgrounded via nohup to survive SSH disconnect
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp --force --nohup
```

**R 4.5 container** (`tumorspace_r45.sif`) — for changes to `.R` scripts in `workflows/DE_analysis/R/`:
```bash
# Script layer only (~30 sec)
bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp

# Full rebuild including R packages (~90 min — required when adding/changing packages)
bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp --force

# Same, backgrounded via nohup to survive SSH disconnect
bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp --force --nohup
```

**`--scratch` is required for Phase 1 (base layer) builds.** It must point to a local filesystem that supports execute permissions — not GPFS, and not a `noexec`-mounted `/tmp` or `/dev/shm`. On most clusters `/scratch/$USER/tmp` works. The directory is used as `TMPDIR` during R package compilation inside the Singularity sandbox; without it, `configure` scripts cannot be executed and packages such as `stringi` will fail to build. It is safe to pass `--scratch` even when only the script layer runs (Phase 2 ignores it).

Post-build verification runs automatically after each rebuild.

---

## Automated Build (Recommended)

The easiest way to build all production containers is using the automated setup script:

```bash
# From repository root
bash setup.sh --scratch /scratch/$USER/tmp
```

`--scratch` is required on GPFS clusters where `/tmp` and `/dev/shm` have `noexec` mount options. It must point to a local filesystem with execute permissions; `/scratch/$USER/tmp` works on most clusters.

This script automatically:
1. Detects your environment (HPC/SLURM or local)
2. Pulls the base Julia 1.9 container from Docker Hub
3. Enhances it with gotree binary and workflow scripts → `julia_1.9_with_gotree.sif`
4. Builds the R base layer (R 4.4 packages) → `tumorspace_r_base.sif`
5. Builds the R script layer (workflow scripts) → `tumorspace_r.sif`
6. Builds the R 4.5 base layer (R 4.5 packages + geo libs) → `tumorspace_r45_base.sif`
7. Builds the R 4.5 script layer (DE analysis scripts) → `tumorspace_r45.sif`

**Prerequisites:**
- Singularity/Apptainer installed (on HPC: `module load singularity`)
- Internet access to pull from Docker Hub and download R packages
- ~5 GB disk space for all container images
- A scratch directory on a local (non-GPFS, exec-capable) filesystem

---

## Manual Build Process

If you need to build manually or understand the two-stage process:

### Stage 1: Obtain Base Julia Container

**Option A: Pull from Docker Hub (recommended)**
```bash
cd containers/
module load singularity
singularity pull julia_1.9.sif docker://julia:1.9
```

### Stage 2: Add TumorSPACE Components

Run the enhancement script to add:
- gotree binary for bootstrap support calculation
- Julia workflow scripts at `/opt/workflows/julia/`
- Required mount points (`/project`, `/scratch`, `/software`)
- libgomp.so.1 for parallel processing

```bash
cd containers/
bash add_gotree_to_julia.sh
```

This script:
1. Converts `julia_1.9.sif` → writable sandbox
2. Copies gotree binary to `/usr/local/bin/`
3. Embeds workflow scripts in `/opt/workflows/`
4. Creates mount points and dependencies
5. Precompiles Julia packages (~2-3 minutes)
6. Converts sandbox → `julia_1.9_with_gotree.sif`
7. Cleans up temporary sandbox

**Total time:** 8-12 minutes (after base container acquired)

---

## Container Contents

### Production Julia Container (`julia_1.9_with_gotree.sif`)

**Base:**
- Julia 1.9.0
- 105 precompiled Julia packages
- Ubuntu 22.04 base image

**TumorSPACE Additions:**
- **gotree binary:** `/usr/local/bin/gotree`
- **Julia workflows:** `/opt/workflows/julia/*.jl` (8 scripts)
- **Libraries:** `/lib64/libgomp.so.1`
- **Mount points:** `/project/`, `/scratch/`, `/software/`

**Key Package Dependencies:**
- Phylo.jl, StatsBase.jl, DataFrames.jl, CSV.jl, LinearAlgebra.jl
- ClusterDepth, Clustering, Distances, NearestNeighbors
- JLD2, JSON3, Optim, ProgressMeter

### R Container (`tumorspace_r.sif`)

Two-layer build. The base layer (~30 min) installs packages and rarely changes.
The script layer (~30 sec) embeds workflow scripts and rebuilds on any script change.

```bash
# Normal: rebuild script layer only (base skipped if present)
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp

# Force: rebuild both base and script layers (use when packages change)
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp --force

# Background (recommended for full rebuild — survives SSH disconnect)
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp --force --nohup
```

**Outputs:**
- `tumorspace_r_base.sif` — R 4.4.1 + all packages (base layer, gitignored)
- `tumorspace_r.sif` — base + embedded workflow scripts (final image, gitignored)

**Embedded R scripts** (copied to `/opt/workflows/R/` inside the container):
- `sg_identify_pairs.R`, `diagnose_tree_pruning.R`, `diagnose_pruning_hyperparameters.R`
- `generate_qc_single_run.R`, `generate_qc_plots.R`
- `run_bayesspace.R`

**R packages installed** (Stages 1–5):
- Stage 1 (CRAN core): dplyr, data.table, ape, phangorn, ggplot2, patchwork, tidyr, gridExtra, cowplot, msigdbr, optparse, arrow, RCurl, ggrepel
- Stage 2 (Bioc infra): BiocGenerics, S4Vectors, IRanges, GenomeInfoDb, GenomicRanges, Biobase, MatrixGenerics, SparseArray, DelayedArray, SummarizedExperiment, BiocParallel, BiocFileCache, rhdf5, Rhdf5lib
- Stage 3 (SCE ecosystem): SingleCellExperiment, beachmat, BiocSingular, ScaledMatrix, scuttle, scater, scran
- Stage 4 (Annotation): AnnotationDbi, org.Mm.eg.db, org.Hs.eg.db, fgsea
- Stage 5 (Spatial): BayesSpace

---

### R 4.5 Container (`tumorspace_r45.sif`)

Dedicated container for DE analysis. Uses R 4.5.0 / Bioconductor 3.21, required
for DESpace 2.0 (`svg_test()`). Includes a full geo library stack (GDAL, GEOS, PROJ,
terra, sf) injected as Debian trixie `.deb` files.

Two-layer build. Base layer (~90 min) installs system libs and R packages.
Script layer (~30 sec) embeds `run_DE_analysis.R`.

```bash
# Normal: rebuild script layer only (base skipped if present)
bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp

# Force: rebuild both base and script layers (use when packages change)
bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp --force

# Background (recommended for full rebuild — survives SSH disconnect)
bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp --force --nohup
```

**Outputs:**
- `tumorspace_r45_base.sif` — R 4.5.0 + all packages + geo libs (base layer, gitignored)
- `tumorspace_r45.sif` — base + embedded workflow scripts (final image, gitignored)

**Embedded R scripts** (copied to `/opt/workflows/R/` inside the container):
- `run_DE_analysis.R`

**R packages installed** (Stages 1–5):
- Stage 1 (CRAN core): dplyr, data.table, ggplot2, optparse, stringr
- Stage 2 (Bioc infra): BiocGenerics, S4Vectors, IRanges, GenomeInfoDb, GenomicRanges, Biobase, MatrixGenerics, SummarizedExperiment, BiocParallel, BiocFileCache
- Stage 3 (SCE ecosystem): SingleCellExperiment, scuttle, scater
- Stage 4 (Seurat + tools): Seurat (CRAN); harmony (CRAN); presto (GitHub — `immunogenomics/presto`)
- Stage 5 (DESpace ecosystem): SpatialExperiment, edgeR, limma, terra, sf (Bioc/CRAN); DESpace (Bioc 3.21)

---

## Verification

### Test Julia Container

```bash
# Check Julia version
singularity exec --no-home containers/julia_1.9_with_gotree.sif julia --version

# Check gotree binary
singularity exec containers/julia_1.9_with_gotree.sif sh -c 'export LD_LIBRARY_PATH=/lib64:$LD_LIBRARY_PATH && gotree version'

# Verify workflow scripts
singularity exec containers/julia_1.9_with_gotree.sif ls /opt/workflows/julia/

# Test package loading
singularity exec --no-home containers/julia_1.9_with_gotree.sif julia -e 'using Phylo, DataFrames, CSV'
```

### Performance Check

The `--no-home` flag is **critical** for performance:

```bash
# Correct (fast startup: ~12 seconds)
singularity exec --no-home containers/julia_1.9_with_gotree.sif julia script.jl

# Incorrect (slow startup: ~4 minutes)
singularity exec containers/julia_1.9_with_gotree.sif julia script.jl
```

**Why?** Without `--no-home`, Singularity bind-mounts your home directory into the container. Julia then scans `~/.julia/` (its default depot) on startup — on HPC NFS home directories this scan takes several minutes. `--no-home` prevents the bind-mount so Julia uses only the precompiled depot inside the container.

---

## Troubleshooting

### Error: "julia_1.9.sif not found"

The base container wasn't pulled. Run:
```bash
cd containers/
singularity pull julia_1.9.sif docker://julia:1.9
```

### Error: "gotree binary not found at ../bin/gotree"

Ensure gotree binary is present at `bin/gotree` in repository root. Download from:
```bash
wget https://github.com/evolbioinfo/gotree/releases/download/v0.4.5/gotree_amd64_linux -O bin/gotree
chmod +x bin/gotree
```

### Error: "Singularity not found"

On HPC systems, load the module:
```bash
module load singularity
```

### Container startup is slow (>1 minute)

You're missing the `--no-home` flag. All Julia steps require:
```bash
singularity exec --no-home containers/julia_1.9_with_gotree.sif <command>
```

### Precompilation fails

Check Julia package compatibility:
```bash
singularity exec --no-home containers/julia_1.9_with_gotree.sif \
    julia --project=/opt/workflows/julia -e 'using Pkg; Pkg.status()'
```

---

## Container Size

- **julia_1.9.sif** (base): ~370 MB
- **julia_1.9_with_gotree.sif** (production): ~309 MB
- **tumorspace_r_base.sif** (R 4.4 packages): ~1.5 GB
- **tumorspace_r.sif** (R 4.4 packages + scripts): ~1.5 GB
- **tumorspace_r45_base.sif** (R 4.5 packages + geo libs): ~845 MB
- **tumorspace_r45.sif** (R 4.5 packages + geo libs + scripts): ~845 MB

*SIF files are compressed; expect ~30% larger during build as sandbox*

---

## Historical Build Methods (Archived)

Previous development used these approaches (now obsolete):

### Docker-based Build (archived)
Early prototypes used Docker:
```bash
docker build -t tumorspace_aws:latest -f Dockerfile ..
```
Abandoned in favor of Singularity for HPC compatibility.

### Single-stage .def Build (archived)
Initial attempt to build everything from `tumorspace_aws.def`:
```bash
singularity build tumorspace_aws.sif tumorspace_aws.def
```
Replaced by two-stage process for flexibility and faster iteration.

---

## Best Practices

1. **Always use `--no-home` flag** - Critical for performance
2. **Verify container after build** - Run test commands before full pipeline
3. **Keep base container** - Don't delete `julia_1.9.sif`, useful for rebuilds
4. **Document modifications** - If you modify `add_gotree_to_julia.sh`, update this doc
5. **Test with benchmark dataset** - Validate container with known-good data before production runs

---

## References

- [Singularity Documentation](https://sylabs.io/docs/)
- [Julia Container Best Practices](https://github.com/JuliaContainerization/julia-containerization)
- [gotree GitHub Repository](https://github.com/evolbioinfo/gotree)
