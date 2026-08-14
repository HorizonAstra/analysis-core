# TumorSPACE Containers

Production-ready container images for TumorSPACE analysis, optimized for HPC environments with SLURM.

**⚠️ Important:** Container images (`.sif` files) are **NOT** shipped in the repository due to size (309 MB).  
Build them locally using `../setup.sh` (recommended) or see [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md) for manual build process.

## 🎯 Production Containers

### julia_1.9_with_gotree.sif (Canonical Production Container)

**Status:** ✅ Production-ready, validated Jan 19-20, 2026

Self-contained Singularity container for complete TumorSPACE workflow including phylogenetic bootstrap validation.

**Build Process:** Two-stage enhancement of base Julia container
1. Pull base Julia 1.9 container from Docker Hub
2. Add gotree binary + workflow scripts via [add_gotree_to_julia.sh](add_gotree_to_julia.sh)

**Contents:**
- Julia 1.9.0 with 105 precompiled packages
- gotree binary for phylogenetic tree manipulation
- Embedded workflow scripts at `/opt/workflows/`
- Mount points: `/project/`, `/scratch/`, `/software/`
- Size: 309 MB (compressed)

**Usage (CRITICAL - Use --no-home flag):**
```bash
# Load Singularity module
module load singularity/current

# Run TumorSPACE steps (use --no-home to prevent ~/.julia depot scan overhead)
singularity exec --no-home containers/julia_1.9_with_gotree.sif \
    julia /opt/workflows/julia/phylo_tree_build.jl --input data.tsv --output results/

# Bootstrap validation with gotree
singularity exec --no-home containers/julia_1.9_with_gotree.sif \
    bash -c "export LD_LIBRARY_PATH=/lib64:\$LD_LIBRARY_PATH && gotree prune -i tree.nwk -r tip1 -o pruned.nwk"
```

**Performance:**
- Without `--no-home`: 4m42s per task (sandbox conversion overhead)
- With `--no-home`: 24s per task (12x faster)
- See [QC validation report](../benchmarks/GSE213688_GSM6592057/qc_reports/container_validation_20260120/qc_summary.md)

---

### tumorspace_r.sif

**Status:** ✅ Production-ready for R-based workflows

Two-layer Singularity SIF for R-based analysis (Step 6: sg_identify_pairs) and Pipeline Report generation (Step 11).

**Build Process:** Built from [tumorspace_r_base.def](tumorspace_r_base.def) (base packages) and [tumorspace_r_scripts.def](tumorspace_r_scripts.def) (scripts layer) using [build_r_container.sh](build_r_container.sh)

**Contents:**
- R 4.4.1 with dplyr, data.table, ape, phangorn, ggplot2, msigdbr, fgsea, AnnotationDbi and more
- Workflow R scripts embedded at `/opt/workflows/R/`

**Usage:**
```bash
singularity exec containers/tumorspace_r.sif \
    Rscript /opt/workflows/R/sg_identify_pairs.R --input intermediate/ --output results/
```

**Build from source:**
```bash
cd containers
bash build_r_container.sh          # script layer only (~30 sec; base reused)
bash build_r_container.sh --force  # rebuild base + scripts (~30 min)
```

---

## ⚙️ Building Containers

### Automated Build (Recommended)

Use the root-level setup script - automatically detects environment and builds all containers:
```bash
cd /project/araman/vivek/TumorSPACE_AWS
./setup.sh
```

**What it does:**
1. Detects SLURM (HPC) vs Docker environment
2. Pulls base Julia 1.9 container from Docker Hub
3. Runs [add_gotree_to_julia.sh](add_gotree_to_julia.sh) to create production container
4. Outputs `julia_1.9_with_gotree.sif` (309 MB)

**Time:** 15-25 minutes (includes Julia package precompilation)

### Manual Build

**See comprehensive guide:** [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md)

**Quick reference:**

**Julia container (two-stage process):**
```bash
cd containers

# Stage 1: Get base container
singularity pull julia_1.9.sif docker://julia:1.9

# Stage 2: Add TumorSPACE components
bash add_gotree_to_julia.sh
```

**R container:**
```bash
cd containers
bash build_r_container.sh
```

**Requirements:**
- Singularity 3.8+ or Apptainer
- Internet connectivity (for Docker Hub pull)
- ~500 MB disk space
- gotree binary at `../bin/gotree`

---

## 📋 Container Definition Files

| File | Purpose | Output |
|------|---------|--------|
| `tumorspace_r_base.def` | R packages (base layer) | `tumorspace_r_base.sif` |
| `tumorspace_r_scripts.def` | R scripts (script layer) | `tumorspace_r.sif` |

The Julia container has no `.def` file — it is built by `add_gotree_to_julia.sh` which enhances a pulled base container at build time.

---

## 🚀 Usage in Workflows

The orchestration framework automatically uses containers when available:

```bash
# Run complete E2E workflow with containers
bash run_pipeline.sh \
    --dataset GSE213688_GSM6592057 \
    --container containers
```

The orchestration system handles:
- Automatic `--no-home` flag injection
- Container path resolution
- Job dependency management
- Error handling and retry logic

See [workflows/README.md](../workflows/README.md) for complete orchestration documentation.

---

## ⚠️ Critical Usage Notes

### The --no-home Flag

**ALWAYS use `--no-home` when running the Julia container.**

Without this flag, Singularity bind-mounts your home directory into the container. Julia then scans `~/.julia/` (its default depot) on startup — on HPC NFS home directories this scan takes several minutes:
- ❌ Without flag: 4m42s per task
- ✅ With flag: 24s per task

**Why this happens:**
Julia searches the default depot (`~/.julia/`) for packages at startup. On NFS-mounted home directories this scan is extremely slow. `--no-home` prevents the bind-mount so Julia only sees the precompiled depot inside the container.

**Orchestration scripts automatically include this flag.**

### Container vs Native Performance

Container mode now matches native performance when using `--no-home`:
- Container (with `--no-home`): 24s per task
- Native Julia: 22s per task
- Performance difference: <10%

---

## 🔍 Validation & Testing

All containers are validated against expected outputs using the benchmark dataset:

**Validation test:**
```bash
# Run container validation
tests/clean_container_rebuild.sh \
    --dataset GSE213688_GSM6592057
```

**Latest validation:** Jan 20, 2026
- Correlation: R=0.8636
- Score agreement: 95.8% identical
- Bootstrap validation: ✅ Passed
- Report: [container_validation_20260120](../benchmarks/GSE213688_GSM6592057/qc_reports/container_validation_20260120/)

---

## 🛠️ Troubleshooting

### Slow execution despite using container
**Solution:** Verify `--no-home` flag is present in your command.

### "Permission denied" errors
**Solution:** Ensure container files have execute permissions:
```bash
chmod +x containers/julia_1.9_with_gotree.sif
```

### Build fails with network errors
**Solution:** Check internet connectivity and retry. Some HPC compute nodes may not have internet access - build from login node.

### Julia package precompilation during run
**Solution:** This should not happen with production container. If it does, container may need rebuilding with updated precompilation.

### Bootstrap validation fails
**Solution:** Verify gotree is available in container:
```bash
singularity exec --no-home containers/julia_1.9_with_gotree.sif which gotree
```

---

## 📦 Adding New Dependencies

### Julia Packages
Add the package to the precompilation step in `add_gotree_to_julia.sh`:
```bash
# In the singularity exec precompile block, add:
julia -e 'using Pkg; Pkg.add("NewPackage"); Pkg.precompile()'
```
Then rebuild: `bash containers/add_gotree_to_julia.sh`

### R Packages
Add to `tumorspace_r_base.def` (the `%post` section) and rebuild:
```bash
bash containers/build_r_container.sh --force
```

**After editing:** Rebuild container and run validation tests.

---

## 📚 Additional Resources

- [Singularity Documentation](https://sylabs.io/docs/)
- [Apptainer Documentation](https://apptainer.org/docs/)
- [TumorSPACE.jl](https://github.com/aramanlab/TumorSPACE.jl) - Core package repository
- [Orchestration Guide](../workflows/README.md) - Automated workflow execution

---

## 🔖 Version History

- **Jan 20, 2026:** Production containers validated with `--no-home` optimization
- **Jan 18, 2026:** Bootstrap validation fixed in containerized workflow
- **Jan 17, 2026:** Initial container implementation with Julia 1.9 + gotree

See [archive/implementation_notes/](../archive/implementation_notes/) for historical development details.
