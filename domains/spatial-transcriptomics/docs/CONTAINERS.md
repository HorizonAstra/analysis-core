# Container Build Best Practices

Guidelines for building and running Singularity containers on GPFS HPC clusters,
based on issues encountered during TumorSPACE development.

---

## The Core Constraint: GPFS Restrictions

Two filesystem-level restrictions affect all Singularity operations on this cluster:

1. **`/tmp` is noexec on GPFS.** Singularity cannot extract SIF files or run
   squashfs operations in `/tmp`. Always provide a scratch directory.

2. **GPFS does not support sandbox creation.** Operations like creating device
   nodes, setting ownership, and other metadata operations required to build a
   Singularity sandbox fail when the sandbox is on GPFS. Sandboxes must be
   created on a scratch filesystem.

---

## Always Pass `--scratch`

All scripts that build or verify containers accept a `--scratch` flag:

```bash
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp
bash setup.sh --scratch /scratch/$USER/tmp
```

**Never run container builds without `--scratch` on this cluster.** Without it:
- `singularity build` will use `/tmp` for squashfs operations → produces
  a SIF that cannot be executed
- Post-build verification will be skipped (cannot exec the SIF without scratch)
- The build will appear to succeed but the container will be broken

---

## Environment Variables for Singularity

Two separate environment variables control where Singularity writes temporary files.
They are NOT interchangeable:

| Variable | Controls | Used by |
|---|---|---|
| `TMPDIR` | General temporary files, squashfs creation | `singularity build` |
| `SINGULARITY_TMPDIR` | SIF extraction for execution | `singularity exec`, `singularity run` |

When building containers, set **both**:

```bash
TMPDIR="$SCRATCH" SINGULARITY_TMPDIR="$SCRATCH" singularity build ...
```

When running containers (exec/run), set `SINGULARITY_TMPDIR`:

```bash
SINGULARITY_TMPDIR="$SCRATCH" singularity exec ...
```

Setting only `SINGULARITY_TMPDIR` for a build will silently produce a broken SIF
because `singularity build` ignores it and falls back to `/tmp`.

---

## Sandbox Paths Must Be on Scratch

When building a SIF via a sandbox (unpack → modify → repack), the sandbox
directory must be on scratch, not GPFS:

```bash
# WRONG — sandbox on GPFS, will fail with "permission denied"
SANDBOX=/gpfs/data/.../containers/my_sandbox
singularity build --sandbox "$SANDBOX" base.sif

# CORRECT — sandbox on scratch
SANDBOX=/scratch/$USER/tmp/my_sandbox
TMPDIR=/scratch/$USER/tmp SINGULARITY_TMPDIR=/scratch/$USER/tmp \
singularity build --sandbox "$SANDBOX" base.sif
```

The final SIF output can (and should) land on GPFS — only the intermediate
sandbox needs scratch.

---

## Installing Packages into a Sandbox: `--writable` Required

When using `singularity exec` against a **sandbox directory** (not a `.sif` file)
to install software (e.g., R packages), you must include `--writable`. Without it,
the filesystem inside the sandbox is read-only and package installation fails
immediately:

```
Warning: 'lib = "/usr/local/lib/R/site-library"' is not writable
Error in install.packages(...): unable to install packages
```

Additionally, the sandbox needs bind mounts for network access and a writable
scratch location, and the scratch path must exist as a mount point inside the sandbox:

```bash
# Create the scratch mount point inside the sandbox before exec
mkdir -p "${SANDBOX}${SCRATCH}"

SINGULARITY_TMPDIR="$SCRATCH" \
singularity exec --writable --no-home --cleanenv \
  -B /etc/resolv.conf \
  -B "${SCRATCH}:${SCRATCH}" \
  "$SANDBOX" \
  bash -c '
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/tmp
export TMPDIR='"$SCRATCH"'
export R_LIBS_SITE=/usr/local/lib/R/site-library
export R_LIBS_USER=/usr/local/lib/R/site-library
Rscript /opt/install.R'
```

Note: `--writable` applies to sandbox directories only. Finished `.sif` files
are always read-only by design.

---

## Verifying a Container After Build

After building, verify the container is functional before running a full analysis:

```bash
SCRATCH=/scratch/$USER/tmp/verify_test
mkdir -p "$SCRATCH"

# Verify the container executes at all
SINGULARITY_TMPDIR="$SCRATCH" \
singularity exec --no-home --cleanenv \
  --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  containers/tumorspace_r.sif \
  /bin/sh -c 'echo "Container OK"'

# Verify key R packages load (tumorspace_r.sif — BayesSpace / pipeline report)
SINGULARITY_TMPDIR="$SCRATCH" \
singularity exec --no-home --cleanenv \
  --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  --env R_LIBS_USER="/usr/local/lib/R/site-library" \
  containers/tumorspace_r.sif \
  /bin/sh -c 'Rscript -e "library(BayesSpace); cat(\"Packages OK\n\")"'

# Verify key R packages load (tumorspace_r45.sif — DE analysis)
SINGULARITY_TMPDIR="$SCRATCH" \
singularity exec --no-home --cleanenv \
  --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  --env R_LIBS_USER="/usr/local/lib/R/site-library" \
  containers/tumorspace_r45.sif \
  /bin/sh -c 'Rscript -e "library(Seurat); library(DESpace); cat(\"Packages OK\n\")"'
```

`bash setup.sh --scratch /scratch/$USER/tmp` runs these checks automatically
and writes the results to `config/capabilities.sh`.

---

## Executable Wrapping: Always Use `/bin/sh -c`

Singularity with `--cleanenv` strips `PATH`. When calling executables like
`Rscript`, `julia`, or `gotree`, do not pass them as the command directly —
Singularity resolves them against the **host** `PATH`, not the container's:

```bash
# WRONG — Rscript resolved against host PATH, fails with "executable not found"
singularity exec --cleanenv container.sif Rscript script.R

# CORRECT — /bin/sh exists on both host and container; Rscript resolved inside
singularity exec --cleanenv \
  --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  container.sif /bin/sh -c 'Rscript script.R'
```

Always add `--env "PATH=..."` to restore standard PATH inside the container.

---

## Container-Specific Notes

### Julia container (`julia_1.9_with_gotree.sif`)

The `gotree` binary (BOOSTER) requires `libgomp.so.1`, which is injected into
`/lib64/` inside the container. Set `LD_LIBRARY_PATH` when running gotree:

```bash
/bin/sh -c 'export LD_LIBRARY_PATH=/lib64:$LD_LIBRARY_PATH && gotree ...'
```

`gotree` always exits non-zero unless given valid required arguments (`-i`, `-b`).
To verify gotree is functional without valid input data, check for "Usage:" in output:

```bash
/bin/sh -c 'export LD_LIBRARY_PATH=/lib64:$LD_LIBRARY_PATH && gotree 2>&1 | grep -q "Usage:"'
```

### Julia package precompilation and CPU target (CRITICAL for HPC)

When precompiling Julia packages inside the container (at build time), you must
set `JULIA_CPU_TARGET=generic`. **Without this, the compiled `.ji` cache files
will only work on a CPU with the same microarchitecture as the machine where the
container was built.** On a heterogeneous HPC cluster, this means:

- The cache is compiled on the **login node** (e.g., `midway3-login3`).
- Compute nodes in the batch queue may have **different CPU generations** (e.g.,
  different AVX-512 or AVX2 support levels).
- Julia rejects the cached `.ji` files as invalid on those nodes and silently
  recompiles from scratch at task startup.
- With many array tasks, recompilation pressure on `/tmp` causes failures:
  `Failed to precompile PhyloNetworks`.

**Fix: always use `JULIA_CPU_TARGET=generic` at both build time and runtime.**

Build time — inside `containers/add_gotree_to_julia.sh`:
```bash
singularity exec --no-home --cleanenv --writable \
    --env JULIA_DEPOT_PATH=/opt/julia_depot \
    --env JULIA_CPU_TARGET=generic \
    "$JULIA_SANDBOX" /bin/sh -c '
    set -e
    export LD_LIBRARY_PATH=/lib64:$LD_LIBRARY_PATH
    cd /opt/workflows/julia
    julia --project=. -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
    echo "✓ Julia packages precompiled successfully"
'
```

Runtime — in each SLURM orchestration script:
```bash
singularity exec --no-home --cleanenv \
    --env JULIA_DEPOT_PATH=/tmp/julia_depot_${SLURM_JOB_ID}_${SLURM_ARRAY_TASK_ID:-0}:/opt/julia_depot \
    --env JULIA_CPU_TARGET=generic \
    ...
```

Note the two-path depot: the per-task writable path (left) allows task-isolated
writes if needed, while `/opt/julia_depot` (right, read-only fallback) provides
the pre-compiled generic cache. With `JULIA_CPU_TARGET=generic`, the cache in
`/opt/julia_depot` is always valid and Julia does not recompile.

**Do not use `Pkg.resolve()` inside the container.** `Pkg.resolve()` requires
network access to the Julia package registry and will fail if the registry is
stale or unavailable. Use `Pkg.instantiate()` only, which uses the
`Manifest.toml` already committed to the repo.

---

### R containers (`tumorspace_r.sif` and `tumorspace_r45.sif`)

There are two R containers with separate purposes:

| Container | R version | Bioc | Contents | Build script |
|-----------|-----------|------|----------|--------------|
| `tumorspace_r.sif` | 4.4.1 | 3.20 | BayesSpace, pipeline report | `build_r_container.sh` |
| `tumorspace_r45.sif` | 4.5.0 | 3.21 | Seurat, DESpace 2.0, terra, sf | `build_r45_container.sh` |

Packages are installed to `/usr/local/lib/R/site-library`. Always set
`R_LIBS_USER` to this path when running R inside either container:

```bash
--env R_LIBS_USER="/usr/local/lib/R/site-library"
```

Both containers are built in two phases:
- **Phase 1** (`--force`): Pulls the base Docker image, injects system libraries,
  installs all R packages (~30–90 min). Required when adding new packages.
- **Phase 2** (default): Unpacks the base SIF, copies updated R scripts,
  repacks. Fast (~30 sec). Run after any script changes.

Both phases require `--scratch`. Example:

```bash
bash containers/build_r_container.sh --scratch /scratch/$USER/tmp
bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp --force
```
