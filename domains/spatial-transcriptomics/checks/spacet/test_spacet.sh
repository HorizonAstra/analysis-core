#!/bin/bash
# Integration test for workflows/spacet
#
# Runs SpaCET deconvolution against the standard 370-spot TNBC benchmark dataset
# (GSE213688_GSM6592057, cancer type: BRCA) and validates that the output
# Spacet_Matrix.txt has the expected shape and content.
#
# SpaCET does not use a fixed seed, so this test uses structure-only assertions:
#   1. Spacet_Matrix.txt is produced and non-empty
#   2. Has a header with expected columns (Barcode + at least one cell type)
#   3. Has at least one data row (barcode)
#   4. All proportion values are in [0,1]
#
# Usage (from repo root):
#   bash tests/spacet/test_spacet.sh
#   bash tests/spacet/test_spacet.sh --no-container   # force native mode
#
# Prerequisites:
#   - For default mode: containers/tumorspace_r.sif with SpaCET installed
#   - Singularity must be available (module load singularity if on HPC)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DATAPATH="$WORKSPACE_ROOT/benchmarks/GSE213688_GSM6592057/input_data"
OUTDIR="$WORKSPACE_ROOT/local/outputs/spacet_test"
RUNNER="$WORKSPACE_ROOT/workflows/spacet/orchestration/run_spacet.sh"
CANCER_TYPE="BRCA"

FORCE_NATIVE=false
for arg in "$@"; do
    [[ "$arg" == "--no-container" ]] && FORCE_NATIVE=true
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
    SPACET_CONTAINER_AVAILABLE=false
    SPACET_NATIVE_AVAILABLE=false
fi
unset _CAPS

if [ ! -d "$DATAPATH" ]; then
    echo "ERROR: Test dataset not found: $DATAPATH"
    exit 1
fi

echo "========================================"
echo "SpaCET Integration Test"
echo "========================================"
echo "Dataset:     $DATAPATH"
echo "Cancer type: $CANCER_TYPE"
echo "Output:      $OUTDIR"
echo ""

# ── Choose run mode ────────────────────────────────────────────────────────
if [ "$FORCE_NATIVE" = true ]; then
    if [ "${SPACET_NATIVE_AVAILABLE:-false}" != true ]; then
        echo "ERROR: Native SpaCET not available and --no-container was requested."
        echo "Fix: Run 'bash setup.sh' to install SpaCET natively or build the container."
        exit 1
    fi
    _pass "Native mode (--no-container)"
    RUNNER_EXTRA="--no-container"
else
    if [ "${SPACET_CONTAINER_AVAILABLE:-false}" != true ]; then
        echo "ERROR: SpaCET container not available (tumorspace_r.sif)."
        echo "Fix: Run 'bash setup.sh' to build the container."
        exit 1
    fi
    _pass "Container mode (tumorspace_r.sif)"
    RUNNER_EXTRA=""
fi

SPOT_COUNT=$(tail -n +2 "$DATAPATH/barcodes_positions.txt" | wc -l)
_pass "Dataset found ($SPOT_COUNT spots)"

# Clean previous test output
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

echo ""
echo "Running SpaCET deconvolution (this takes a few minutes)..."
echo ""

# shellcheck disable=SC2086
bash "$RUNNER" \
    --raw-data-dir "$DATAPATH" \
    --outdir "$OUTDIR" \
    --cancer-type "$CANCER_TYPE" \
    $RUNNER_EXTRA

echo ""
echo "Verifying outputs..."

# -- Check file existence and non-empty --
OUTPUT_FILE="$OUTDIR/Spacet_Matrix.txt"
if [ -f "$OUTPUT_FILE" ]; then
    _pass "Spacet_Matrix.txt produced"
else
    _fail "Spacet_Matrix.txt missing"
    echo ""
    echo "TEST FAILED ($FAILURES failures)"
    exit 1
fi

LINE_COUNT=$(wc -l < "$OUTPUT_FILE")
if [ "$LINE_COUNT" -gt 1 ]; then
    _pass "Output non-empty ($LINE_COUNT lines including header)"
else
    _fail "Output file has only $LINE_COUNT line(s) — expected header + data rows"
fi

# -- Check header has Barcode column + at least one cell type --
HEADER=$(head -1 "$OUTPUT_FILE")
if echo "$HEADER" | grep -q "^Barcode"; then
    _pass "Header starts with Barcode column"
else
    _fail "Header does not start with Barcode: $HEADER"
fi

N_COLS=$(head -1 "$OUTPUT_FILE" | awk -F'\t' '{print NF}')
if [ "$N_COLS" -gt 1 ]; then
    _pass "Output has $N_COLS columns (Barcode + $((N_COLS - 1)) cell types)"
else
    _fail "Output has only $N_COLS column(s) — expected Barcode + at least one cell type"
fi

# -- Check proportion values are in [0, 1] using awk --
# (skip header row; skip Barcode column 1; verify remaining are numeric 0-1)
OUT_OF_RANGE=$(awk -F'\t' 'NR>1 {
    for (i=2; i<=NF; i++) {
        v = $i + 0;
        if (v < -0.001 || v > 1.001) print NR, i, $i
    }
}' "$OUTPUT_FILE" | head -5)

if [ -z "$OUT_OF_RANGE" ]; then
    _pass "All proportion values in [0, 1]"
else
    _fail "Values out of [0, 1] range detected:"
    echo "$OUT_OF_RANGE"
fi

# -- Cache files --
if [ -f "$OUTDIR/M_nodup.txt" ]; then
    _pass "M_nodup.txt cache produced"
fi
if [ -f "$OUTDIR/features_nodup.txt" ]; then
    _pass "features_nodup.txt cache produced"
fi

echo ""
echo "========================================"
if [ "$FAILURES" -eq 0 ]; then
    echo "TEST PASSED"
else
    echo "TEST FAILED ($FAILURES failures)"
    exit 1
fi
