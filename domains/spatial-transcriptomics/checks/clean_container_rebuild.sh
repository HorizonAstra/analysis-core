#!/bin/bash
# Isolation test: fresh clone rebuild and environment verification
#
# Creates a clean temporary clone of this repository, runs setup.sh from
# scratch in that clone, and verifies both containers.
#
# NON-DESTRUCTIVE: your existing containers in the working checkout are
# never touched. The temp clone is deleted on exit.
#
# Run before merging any branch to master.
#
# Usage: bash tests/clean_container_rebuild.sh
# Expected runtime: 20-40 minutes (container builds)

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load HPC cluster profile from the source repo (exports module names)
_HPC_PROFILE="${REPO_ROOT}/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# ── Load Singularity before clone (needed for builds in the clone too) ──────
hpc_module_load MODULE_SINGULARITY
if ! command -v singularity &>/dev/null; then
    echo "ERROR: Singularity not available after module load. Cannot run isolation test."
    exit 1
fi

PASS=0
FAIL=0

_pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
_fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── Create temp clone ────────────────────────────────────────────────────────
# Use a sibling directory to REPO_ROOT so git clone --local hardlinks work
# (hardlinks require same filesystem; /tmp is often a different mount)
CLONE_DIR="$(mktemp -d "$(dirname "$REPO_ROOT")/tumorspace_clean_test_XXXXXX")"
# Always clean up the temp clone on exit, whether pass or fail
trap 'echo ""; echo "Cleaning up temp clone: $CLONE_DIR"; rm -rf "$CLONE_DIR"' EXIT

echo "========================================"
echo "TumorSPACE Isolation Rebuild Test"
echo "========================================"
echo "Source repo: $REPO_ROOT"
echo "Temp clone:  $CLONE_DIR"
echo "Singularity: $(singularity --version)"
echo ""

echo "Step 1: Cloning repo to temp directory..."
# --local uses hardlinks where possible (fast, avoids re-transferring objects)
git clone --local "$REPO_ROOT" "$CLONE_DIR" 2>&1 | sed 's/^/  /'
echo ""

# Copy gitignored config files that setup.sh expects to find
mkdir -p "$CLONE_DIR/config"
if [ -f "$REPO_ROOT/config/hpc_profile.sh" ]; then
    cp "$REPO_ROOT/config/hpc_profile.sh" "$CLONE_DIR/config/hpc_profile.sh"
    echo "  Copied config/hpc_profile.sh to clone"
fi
if [ -f "$REPO_ROOT/config/slurm_config.sh" ]; then
    cp "$REPO_ROOT/config/slurm_config.sh" "$CLONE_DIR/config/slurm_config.sh"
    echo "  Copied config/slurm_config.sh to clone"
fi
echo ""

# ── Step 2: Run setup.sh in the clone ───────────────────────────────────────
echo "Step 2: Running setup.sh in clone (full clean build)..."
echo ""
cd "$CLONE_DIR"
bash setup.sh
echo ""

# ── Step 3: Verify Julia container ──────────────────────────────────────────
echo "Step 3: Verifying Julia container..."
JULIA_SIF="$CLONE_DIR/containers/julia_1.9_with_gotree.sif"

if [ -f "$JULIA_SIF" ]; then
    _pass "julia_1.9_with_gotree.sif exists"
else
    _fail "julia_1.9_with_gotree.sif not found"
fi

if singularity exec "$JULIA_SIF" gotree --version &>/dev/null; then
    _pass "gotree functional in Julia container"
else
    _fail "gotree not functional in Julia container"
fi

if singularity exec "$JULIA_SIF" test -f /opt/workflows/julia/phylo_tree_build.jl; then
    _pass "phylo_tree_build.jl present in Julia container"
else
    _fail "phylo_tree_build.jl missing from Julia container"
fi

echo ""

# ── Step 4: Verify R container ──────────────────────────────────────────────
echo "Step 4: Verifying R container..."
R_SIF="$CLONE_DIR/containers/tumorspace_r.sif"

if [ -f "$R_SIF" ]; then
    _pass "tumorspace_r.sif exists"
else
    _fail "tumorspace_r.sif not found"
fi

# Verify expected R scripts are present in the container
# (list must stay in sync with R_SCRIPTS array in containers/build_r_container.sh)
R_SCRIPT_LIST=(
    sg_identify_pairs.R
    generate_qc_single_run.R
    generate_qc_plots.R
    diagnose_tree_pruning.R
    diagnose_pruning_hyperparameters.R
    run_bayesspace.R
)
for script in "${R_SCRIPT_LIST[@]}"; do
    dst="/opt/workflows/R/$script"
    if singularity exec "$R_SIF" test -f "$dst"; then
        _pass "$dst in R container"
    else
        _fail "$dst missing from R container"
    fi
done

# Verify required packages load.
# --no-home --cleanenv: prevent host bind-mounts
# --env R_LIBS_USER=<non-empty>: R treats "" as "not set" and falls back to ~/R/... which
# resolves to the NFS host path — host .so files fail on RHEL. Also avoid piping to grep:
# grep exit 0 would mask R's non-zero exit and silently swallow the failure.
_r_verify_out=$(singularity exec --no-home --cleanenv \
    --env R_LIBS_USER="/usr/local/lib/R/site-library" \
    "$R_SIF" R --vanilla -e '
  pkgs <- c("dplyr", "data.table", "ape", "phangorn", "ggplot2", "patchwork",
            "tidyr", "gridExtra", "cowplot", "ggrepel", "msigdbr",
            "fgsea", "AnnotationDbi", "optparse",
            "SingleCellExperiment", "BayesSpace")
  missing <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]
  if (length(missing) > 0) {
    stop(paste("Missing packages:", paste(missing, collapse=", ")))
  }
  cat("  ✓ All", length(pkgs), "R packages load correctly\n")
' 2>&1)
_r_verify_rc=$?
echo "$_r_verify_out"
if [ $_r_verify_rc -ne 0 ]; then
  _fail "R package verification failed (see output above)"
else
  _pass "All R packages load inside container"
fi
unset _r_verify_out _r_verify_rc

echo ""

# ── Step 5: Verify R 4.5 container (DE analysis) ───────────────────────────
echo "Step 5: Verifying R 4.5 container (tumorspace_r45.sif)..."
R45_SIF="$CLONE_DIR/containers/tumorspace_r45.sif"

if [ -f "$R45_SIF" ]; then
    _pass "tumorspace_r45.sif exists"
else
    _fail "tumorspace_r45.sif not found"
fi

# Verify run_DE_analysis.R is embedded
if singularity exec "$R45_SIF" test -f /opt/workflows/R/run_DE_analysis.R; then
    _pass "/opt/workflows/R/run_DE_analysis.R in R 4.5 container"
else
    _fail "/opt/workflows/R/run_DE_analysis.R missing from R 4.5 container"
fi

# Verify all 14 required packages load and DESpace svg_test() >= 2.0 is present.
_r45_verify_out=$(singularity exec --no-home --cleanenv \
    --env R_LIBS_USER="/usr/local/lib/R/site-library" \
    "$R45_SIF" R --vanilla -e '
  pkgs <- c("optparse", "dplyr", "data.table", "ggplot2", "stringr",
            "SingleCellExperiment", "scater",
            "Seurat", "harmony", "presto",
            "SpatialExperiment", "edgeR", "limma", "DESpace")
  missing <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]
  if (length(missing) > 0) {
    stop(paste("Missing packages:", paste(missing, collapse=", ")))
  }
  cat("  ✓ All", length(pkgs), "R 4.5 packages load correctly\n")
  if (!"svg_test" %in% getNamespaceExports("DESpace"))
    stop("DESpace present but svg_test() not found — version < 2.0. Rebuild with --force.")
  cat("  ✓ DESpace svg_test() confirmed (>= 2.0)\n")
' 2>&1)
_r45_verify_rc=$?
echo "$_r45_verify_out"
if [ $_r45_verify_rc -ne 0 ]; then
    _fail "R 4.5 package/DESpace verification failed (see output above)"
else
    _pass "All R 4.5 packages load and DESpace svg_test() confirmed"
fi
unset _r45_verify_out _r45_verify_rc

echo ""

# ── Step 6: Verify native workflow prerequisites ─────────────────────────────
echo "Step 6: Verifying native workflow prerequisites..."

if [ -x "$CLONE_DIR/bin/gotree" ]; then
    _pass "bin/gotree exists and is executable"
else
    _fail "bin/gotree missing or not executable"
fi

for script in run_pipeline_full.sh run_sg_identify_pairs.sh; do
    if [ -f "$CLONE_DIR/workflows/tumorspace_core/orchestration/$script" ]; then
        _pass "workflows/tumorspace_core/orchestration/$script present"
    else
        _fail "workflows/tumorspace_core/orchestration/$script missing"
    fi
done

if [ -f "$CLONE_DIR/workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh" ]; then
    _pass "workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh present"
else
    _fail "workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh missing"
fi

if [ -f "$CLONE_DIR/config/slurm_config.sh" ]; then
    _pass "config/slurm_config.sh present"
elif [ -f "$CLONE_DIR/config/slurm_config.sh.example" ]; then
    _pass "config/slurm_config.sh.example present (user must copy to slurm_config.sh)"
else
    _fail "config/slurm_config.sh and .example both missing"
fi

echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo "FAIL: $FAIL check(s) did not pass. Do not merge to master."
    exit 1
else
    echo "PASS: All checks passed. Safe to merge to master."
    exit 0
fi
