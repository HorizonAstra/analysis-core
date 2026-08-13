#!/bin/bash
# Integration test for workflows/bayesspace
#
# Runs BayesSpace with fixed seeds against the standard 371-spot benchmark
# dataset (GSE213688_GSM6592057), in both single-sample and joint modes:
#
#   Single mode: --datapath <benchmark>
#     Output validated against:
#       benchmarks/GSE213688_GSM6592057/expected_outputs/test_coldata_single.csv
#
#   Joint mode:  --datapath <benchmark>,<benchmark>  (same dataset passed twice)
#     Output validated against:
#       benchmarks/GSE213688_GSM6592057/expected_outputs/test_coldata_joint.csv
#
# --generate-reference mode: runs both modes and writes the baseline CSVs.
#   By default uses native R. Pass --container to use a container instead
#   (useful for establishing cross-cluster reproducibility baselines).
#
# Usage (from repo root):
#   bash tests/bayesspace/test_bayesspace.sh                                              # validate container == baseline
#   bash tests/bayesspace/test_bayesspace.sh --generate-reference                         # generate native baselines
#   bash tests/bayesspace/test_bayesspace.sh --generate-reference --container /path/to.sif  # generate container baselines
#   bash tests/bayesspace/test_bayesspace.sh --container /path/to.sif                    # validate with specific SIF
#
# Prerequisites:
#   - For default mode: containers/tumorspace_r.sif must exist
#   - For --generate-reference (native): R with BayesSpace+harmony installed (run setup.sh)
#   - For --generate-reference --container: the specified SIF must exist
#   - Singularity must be available (module load singularity if on HPC)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DATAPATH_SINGLE="$WORKSPACE_ROOT/benchmarks/GSE213688_GSM6592057/input_data"
DATAPATH_JOINT="$DATAPATH_SINGLE,$DATAPATH_SINGLE"
OUTDIR_SINGLE="$WORKSPACE_ROOT/local/outputs/bayesspace_test_single"
OUTDIR_JOINT="$WORKSPACE_ROOT/local/outputs/bayesspace_test_joint"
EXPECTED_DIR="$WORKSPACE_ROOT/benchmarks/GSE213688_GSM6592057/expected_outputs"
EXPECTED_SINGLE="$EXPECTED_DIR/test_coldata_single.csv"
EXPECTED_JOINT="$EXPECTED_DIR/test_coldata_joint.csv"
RUNNER="$WORKSPACE_ROOT/workflows/bayesspace/orchestration/run_bayesspace.sh"

GENERATE_REFERENCE=false
CONTAINER="${WORKSPACE_ROOT}/containers/tumorspace_r.sif"

while [[ $# -gt 0 ]]; do
    case $1 in
        --generate-reference) GENERATE_REFERENCE=true; shift ;;
        --container) CONTAINER="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

_pass() { echo "  ✓ $1"; }
_fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

# ── Pre-flight: resolve execution modes ────────────────────────────────────
_CAPS="${WORKSPACE_ROOT}/config/capabilities.sh"
if [ -f "$_CAPS" ]; then
    # shellcheck disable=SC1090
    source "$_CAPS"
else
    echo "WARNING: config/capabilities.sh not found. Run 'bash setup.sh' to generate it."
    BAYESSPACE_CONTAINER_AVAILABLE=false
    BAYESSPACE_NATIVE_AVAILABLE=false
fi
unset _CAPS

if [ ! -d "$DATAPATH_SINGLE" ]; then
    echo "ERROR: Test dataset not found: $DATAPATH_SINGLE"
    exit 1
fi

# ════════════════════════════════════════════════════════════════
# --generate-reference: produce baselines and commit prompt
# ════════════════════════════════════════════════════════════════
if [ "$GENERATE_REFERENCE" = true ]; then
    if [ -f "$CONTAINER" ]; then
        REF_MODE="container"
        REF_FLAG="--container $CONTAINER"
        echo "========================================"
        echo "BayesSpace Reference Generator (container)"
        echo "  SIF: $CONTAINER"
    else
        REF_MODE="native"
        REF_FLAG="--no-container"
        echo "========================================"
        echo "BayesSpace Reference Generator (native)"
        if [ "${BAYESSPACE_NATIVE_AVAILABLE:-false}" != true ]; then
            echo "ERROR: Native BayesSpace not available and no container found at:"
            echo "  $CONTAINER"
            echo "Fix: Run 'bash setup.sh' to install natively, or pass --container /path/to.sif"
            exit 1
        fi
    fi
    echo "========================================"
    echo "Dataset:       $DATAPATH_SINGLE"
    echo "Output single: $EXPECTED_SINGLE"
    echo "Output joint:  $EXPECTED_JOINT"
    echo ""

    _pass "Dataset found ($(wc -l < "$DATAPATH_SINGLE/barcodes.txt") spots)"

    _REF_TMP="$WORKSPACE_ROOT/local/outputs/bayesspace_reference_gen"
    rm -rf "$_REF_TMP"
    mkdir -p "$_REF_TMP"
    mkdir -p "$EXPECTED_DIR"

    echo ""
    echo "Running BayesSpace in $REF_MODE single mode with fixed seeds (--test)..."
    # shellcheck disable=SC2086
    bash "$RUNNER" \
        --datapath "$DATAPATH_SINGLE" \
        --outdir "$_REF_TMP/single" \
        --test \
        $REF_FLAG

    if [ ! -f "$_REF_TMP/single/test_coldata_single.csv" ]; then
        echo "ERROR: test_coldata_single.csv not produced by $REF_MODE single run."
        exit 1
    fi
    cp "$_REF_TMP/single/test_coldata_single.csv" "$EXPECTED_SINGLE"
    _pass "Single baseline written: $EXPECTED_SINGLE"

    echo ""
    echo "Running BayesSpace in $REF_MODE joint mode with fixed seeds (--test)..."
    # shellcheck disable=SC2086
    bash "$RUNNER" \
        --datapath "$DATAPATH_JOINT" \
        --outdir "$_REF_TMP/joint" \
        --test \
        $REF_FLAG

    if [ ! -f "$_REF_TMP/joint/test_coldata_joint.csv" ]; then
        echo "ERROR: test_coldata_joint.csv not produced by $REF_MODE joint run."
        exit 1
    fi
    cp "$_REF_TMP/joint/test_coldata_joint.csv" "$EXPECTED_JOINT"
    _pass "Joint baseline written: $EXPECTED_JOINT"

    rm -rf "$_REF_TMP"

    echo ""
    echo "========================================"
    echo "References generated successfully ($REF_MODE)."
    echo "  Single md5: $(md5sum "$EXPECTED_SINGLE" | awk '{print $1}')"
    echo "  Joint  md5: $(md5sum "$EXPECTED_JOINT" | awk '{print $1}')"
    echo ""
    echo "Next step: commit these files to git:"
    echo "  git add benchmarks/GSE213688_GSM6592057/expected_outputs/test_coldata_single.csv"
    echo "  git add benchmarks/GSE213688_GSM6592057/expected_outputs/test_coldata_joint.csv"
    echo "  git commit -m 'test(bayesspace): commit $REF_MODE reference baselines (single + joint)'"
    echo "========================================"
    exit 0
fi

# ════════════════════════════════════════════════════════════════
# Default mode: container runs validated against baselines
# ════════════════════════════════════════════════════════════════
echo "========================================"
echo "BayesSpace Integration Test"
echo "  SIF: $CONTAINER"
echo "========================================"
echo "Dataset:   $DATAPATH_SINGLE"
echo ""

if [ ! -f "$CONTAINER" ]; then
    echo "ERROR: Container not found: $CONTAINER"
    echo "Fix: Run 'bash setup.sh' to build the container, or pass --container /path/to.sif"
    exit 1
fi
_pass "Container found: $(basename "$CONTAINER")"
_pass "Dataset found ($(wc -l < "$DATAPATH_SINGLE/barcodes.txt") spots)"

for f in "$EXPECTED_SINGLE" "$EXPECTED_JOINT"; do
    if [ ! -f "$f" ]; then
        echo ""
        echo "ERROR: Baseline not found: $f"
        echo "Fix: Generate baselines first with:"
        echo "  bash tests/bayesspace/test_bayesspace.sh --generate-reference [--container /path/to.sif]"
        echo "Then commit the files to git."
        exit 1
    fi
done
EXPECTED_SINGLE_MD5=$(md5sum "$EXPECTED_SINGLE" | awk '{print $1}')
EXPECTED_JOINT_MD5=$(md5sum "$EXPECTED_JOINT" | awk '{print $1}')
_pass "Single baseline present (md5: $EXPECTED_SINGLE_MD5)"
_pass "Joint  baseline present (md5: $EXPECTED_JOINT_MD5)"

# ── Single-sample test ──────────────────────────────────────────
echo ""
echo "── Single-sample run ─────────────────────────────────────"
rm -rf "$OUTDIR_SINGLE"
mkdir -p "$OUTDIR_SINGLE"

bash "$RUNNER" \
    --datapath "$DATAPATH_SINGLE" \
    --outdir "$OUTDIR_SINGLE" \
    --test \
    --container "$CONTAINER"

echo ""
echo "Verifying single-sample outputs..."

if [ -f "$OUTDIR_SINGLE/test_coldata_single.csv" ]; then
    _pass "test_coldata_single.csv produced"
else
    _fail "test_coldata_single.csv missing"
fi

if [ -f "$OUTDIR_SINGLE/cluster_plot.png" ]; then
    _pass "cluster_plot.png produced"
else
    _fail "cluster_plot.png missing"
fi

if [ "$FAILURES" -eq 0 ]; then
    OBSERVED_SINGLE_MD5=$(md5sum "$OUTDIR_SINGLE/test_coldata_single.csv" | awk '{print $1}')
    if [ "$OBSERVED_SINGLE_MD5" = "$EXPECTED_SINGLE_MD5" ]; then
        _pass "single md5sum matches baseline"
    else
        _fail "single md5sum MISMATCH"
        echo "  Expected: $EXPECTED_SINGLE_MD5"
        echo "  Observed: $OBSERVED_SINGLE_MD5"
    fi
fi

# ── Joint-sample test ───────────────────────────────────────────
echo ""
echo "── Joint-sample run (same dataset passed twice) ──────────"
rm -rf "$OUTDIR_JOINT"
mkdir -p "$OUTDIR_JOINT"

bash "$RUNNER" \
    --datapath "$DATAPATH_JOINT" \
    --outdir "$OUTDIR_JOINT" \
    --test \
    --container "$CONTAINER"

echo ""
echo "Verifying joint-sample outputs..."

if [ -f "$OUTDIR_JOINT/test_coldata_joint.csv" ]; then
    _pass "test_coldata_joint.csv produced"
else
    _fail "test_coldata_joint.csv missing"
fi

if [ -f "$OUTDIR_JOINT/cluster_plot_sample1.png" ]; then
    _pass "cluster_plot_sample1.png produced"
else
    _fail "cluster_plot_sample1.png missing"
fi

if [ "$FAILURES" -eq 0 ]; then
    OBSERVED_JOINT_MD5=$(md5sum "$OUTDIR_JOINT/test_coldata_joint.csv" | awk '{print $1}')
    if [ "$OBSERVED_JOINT_MD5" = "$EXPECTED_JOINT_MD5" ]; then
        _pass "joint md5sum matches baseline"
    else
        _fail "joint md5sum MISMATCH"
        echo "  Expected: $EXPECTED_JOINT_MD5"
        echo "  Observed: $OBSERVED_JOINT_MD5"
    fi
fi

echo ""
echo "========================================"
if [ "$FAILURES" -eq 0 ]; then
    echo "TEST PASSED"
else
    echo "TEST FAILED ($FAILURES failures)"
    exit 1
fi
