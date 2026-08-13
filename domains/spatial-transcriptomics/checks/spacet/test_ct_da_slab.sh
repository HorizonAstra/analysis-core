#!/bin/bash
# Integration test for workflows/spacet CT-DA-SLAB pipeline
#
# Tests the prepare_ct_matrix.R step end-to-end: converts a Spacet_Matrix.txt
# (barcode × cell_type proportions) into the standard Julia DA/SLAB input format
# and validates the outputs.
#
# Because sg_diff_abundance.jl and sg_slab_score.jl run as SLURM jobs, this test
# covers only the R preparation step.  Julia DA/SLAB format compatibility is
# validated via output format assertions.
#
# Test data is synthetic (generated inline from the benchmark barcode list) so
# the test is fully self-contained and requires no prior SpaCET run.
#
# Usage (from repo root):
#   bash tests/spacet/test_ct_da_slab.sh
#   bash tests/spacet/test_ct_da_slab.sh --no-container   # force native R
#
# Prerequisites:
#   - benchmarks/GSE213688_GSM6592057/input_data/barcodes_positions.txt
#   - containers/tumorspace_r.sif  (or native R with optparse)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DATAPATH="$WORKSPACE_ROOT/benchmarks/GSE213688_GSM6592057/input_data"
R_SCRIPT="$WORKSPACE_ROOT/workflows/spacet/R/prepare_ct_matrix.R"
WORKDIR="$WORKSPACE_ROOT/local/outputs/ct_da_slab_test"
CONTAINER_DIR="$WORKSPACE_ROOT/containers"

FORCE_NATIVE=false
for arg in "$@"; do
    [[ "$arg" == "--no-container" ]] && FORCE_NATIVE=true
done

_pass() { echo "  ✓ $1"; }
_fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

# ── Pre-flight ──────────────────────────────────────────────────────────────
_CAPS="${WORKSPACE_ROOT}/config/capabilities.sh"
if [ -f "$_CAPS" ]; then
    # shellcheck disable=SC1090
    source "$_CAPS"
else
    echo "WARNING: config/capabilities.sh not found. Assuming native R unavailable."
    SPACET_CONTAINER_AVAILABLE=false
    SPACET_NATIVE_AVAILABLE=false
fi
unset _CAPS

if [ ! -d "$DATAPATH" ]; then
    echo "ERROR: Benchmark dataset not found: $DATAPATH"
    exit 1
fi
if [ ! -f "$R_SCRIPT" ]; then
    echo "ERROR: R script not found: $R_SCRIPT"
    exit 1
fi

# Choose run mode
CONTAINER_SIF="${CONTAINER_DIR}/tumorspace_r.sif"
if [ "$FORCE_NATIVE" = true ]; then
    USE_CONTAINER=false
    if ! command -v Rscript &>/dev/null; then
        echo "ERROR: Rscript not found and --no-container requested."
        exit 1
    fi
else
    if [ "${SPACET_CONTAINER_AVAILABLE:-false}" = true ] && [ -f "$CONTAINER_SIF" ]; then
        USE_CONTAINER=true
    elif command -v Rscript &>/dev/null; then
        USE_CONTAINER=false
    elif [ -f "$CONTAINER_SIF" ]; then
        USE_CONTAINER=true
    else
        echo "ERROR: Neither container nor native Rscript available."
        echo "Fix: Run 'bash setup.sh' or build containers/tumorspace_r.sif"
        exit 1
    fi
fi

echo "========================================"
echo "CT-DA-SLAB Preparation Test"
echo "========================================"
echo "Dataset:    $DATAPATH"
echo "R script:   $R_SCRIPT"
echo "Workdir:    $WORKDIR"
echo "Mode:       $( [ "$USE_CONTAINER" = true ] && echo "container" || echo "native" )"
echo ""

# ── Build synthetic test data ───────────────────────────────────────────────
# Construct a minimal Spacet_Matrix.txt using the first 20 barcodes
# from barcodes_positions.txt and 5 synthetic cell types

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/input_data"
mkdir -p "$WORKDIR/optimal"
mkdir -p "$WORKDIR/spacet"

# Copy barcodes_positions.txt (source of truth for valid barcodes)
cp "$DATAPATH/barcodes_positions.txt" "$WORKDIR/input_data/"
_pass "Copied barcodes_positions.txt"

# Extract first 20 barcodes (skip header)
BARCODES=$(awk 'NR>1 {print $1}' "$WORKDIR/input_data/barcodes_positions.txt" | head -20)
N_BARCODES=$(echo "$BARCODES" | wc -l)

# Build synthetic Spacet_Matrix.txt (tab-separated, header row)
# Using 5 representative cell types with valid proportions summing to 1
SPACET_FILE="$WORKDIR/spacet/Spacet_Matrix.txt"
{
    echo -e "Barcode\tMalignant\tT_CD8_exhausted\tMacrophage\tCAF\tEndothelial"
    while IFS= read -r bc; do
        echo -e "${bc}\t0.50\t0.20\t0.15\t0.10\t0.05"
    done <<< "$BARCODES"
} > "$SPACET_FILE"

HEADER_COLS=$(head -1 "$SPACET_FILE" | awk -F'\t' '{print NF}')
DATA_ROWS=$(wc -l < "$SPACET_FILE")
_pass "Synthetic Spacet_Matrix.txt: $N_BARCODES barcodes × $((HEADER_COLS - 1)) cell types"

# Build synthetic tree files in optimal/ (minimal valid format)
# OptimalTree_pruned_node_compare_list.txt: tab-sep, Node + Sibling columns
{
    echo -e "Node\tSibling\tNode_Leaves_Total\tSibling_Leaves_Total"
    echo -e "1\t2\t10\t10"
} > "$WORKDIR/optimal/OptimalTree_pruned_node_compare_list.txt"

# OptimalTree_pruned_node_compare_leaves.txt: one barcode per line per node
{
    echo -e "Node\tBarcode"
    while IFS= read -r bc; do
        echo -e "1\t${bc}"
    done <<< "$(echo "$BARCODES" | head -10)"
    while IFS= read -r bc; do
        echo -e "2\t${bc}"
    done <<< "$(echo "$BARCODES" | tail -10)"
} > "$WORKDIR/optimal/OptimalTree_pruned_node_compare_leaves.txt"

_pass "Synthetic tree files created in optimal/"

# ── Run prepare_ct_matrix.R ─────────────────────────────────────────────────
echo ""
echo "Running prepare_ct_matrix.R..."
echo ""

RSCRIPT_ARGS="$R_SCRIPT \
    --spacet-matrix $SPACET_FILE \
    --optimal-dir $WORKDIR/optimal \
    --input-dir $WORKDIR/input_data"

if [ "$USE_CONTAINER" = true ]; then
    singularity exec --no-home --cleanenv \
        --bind "$WORKDIR":"$WORKDIR" \
        --bind "$WORKSPACE_ROOT/workflows":"$WORKSPACE_ROOT/workflows" \
        "$CONTAINER_SIF" \
        Rscript $RSCRIPT_ARGS
else
    Rscript $RSCRIPT_ARGS
fi

echo ""
echo "Validating outputs in $WORKDIR/optimal/ct/ ..."
echo ""

CT_DIR="$WORKDIR/optimal/ct"

# ── Output existence checks ─────────────────────────────────────────────────
for f in M.txt barcodes.txt genes.txt barcodes_positions.txt feature_space_info.txt; do
    if [ -f "$CT_DIR/$f" ]; then
        _pass "$f exists"
    else
        _fail "$f missing"
    fi
done

# ── M.txt format: no header, no row names, numeric ─────────────────────────
if [ -f "$CT_DIR/M.txt" ]; then
    FIRST_FIELD=$(head -1 "$CT_DIR/M.txt" | awk '{print $1}')
    if echo "$FIRST_FIELD" | grep -qE '^[0-9.]+$'; then
        _pass "M.txt: first field is numeric (no header/rownames)"
    else
        _fail "M.txt: first field is not numeric — got: $FIRST_FIELD"
    fi

    M_ROWS=$(wc -l < "$CT_DIR/M.txt")
    M_COLS=$(awk 'NR==1{print NF}' "$CT_DIR/M.txt")
    if [ "$M_ROWS" -ge 1 ] && [ "$M_COLS" -ge 1 ]; then
        _pass "M.txt dimensions: ${M_ROWS} rows × ${M_COLS} cols"
    else
        _fail "M.txt is empty or malformed"
    fi
fi

# ── barcodes.txt: header row = "barcode" ───────────────────────────────────
if [ -f "$CT_DIR/barcodes.txt" ]; then
    HEADER=$(head -1 "$CT_DIR/barcodes.txt")
    if [ "$HEADER" = "barcode" ]; then
        _pass "barcodes.txt: header = 'barcode'"
    else
        _fail "barcodes.txt: wrong header — got: $HEADER"
    fi

    BC_ROWS=$(tail -n +2 "$CT_DIR/barcodes.txt" | wc -l)
    if [ -f "$CT_DIR/M.txt" ]; then
        M_ROWS=$(wc -l < "$CT_DIR/M.txt")
        if [ "$BC_ROWS" -eq "$M_ROWS" ]; then
            _pass "barcodes.txt: $BC_ROWS barcodes matches M.txt rows"
        else
            _fail "barcodes.txt: $BC_ROWS rows does not match M.txt rows ($M_ROWS)"
        fi
    fi
fi

# ── genes.txt: header row = "cell_type" ────────────────────────────────────
if [ -f "$CT_DIR/genes.txt" ]; then
    HEADER=$(head -1 "$CT_DIR/genes.txt")
    if [ "$HEADER" = "cell_type" ]; then
        _pass "genes.txt: header = 'cell_type'"
    else
        _fail "genes.txt: wrong header — got: $HEADER"
    fi

    CT_ROWS=$(tail -n +2 "$CT_DIR/genes.txt" | wc -l)
    if [ -f "$CT_DIR/M.txt" ]; then
        M_COLS=$(awk 'NR==1{print NF}' "$CT_DIR/M.txt")
        if [ "$CT_ROWS" -eq "$M_COLS" ]; then
            _pass "genes.txt: $CT_ROWS cell types matches M.txt columns"
        else
            _fail "genes.txt: $CT_ROWS rows does not match M.txt cols ($M_COLS)"
        fi
    fi
fi

# ── barcodes_positions.txt: copied correctly ───────────────────────────────
if [ -f "$CT_DIR/barcodes_positions.txt" ]; then
    SRC_LINES=$(wc -l < "$WORKDIR/input_data/barcodes_positions.txt")
    COPY_LINES=$(wc -l < "$CT_DIR/barcodes_positions.txt")
    if [ "$SRC_LINES" -eq "$COPY_LINES" ]; then
        _pass "barcodes_positions.txt: $COPY_LINES lines (matches source)"
    else
        _fail "barcodes_positions.txt: $COPY_LINES lines (expected $SRC_LINES)"
    fi
fi

# ── Symlinks to tree files ──────────────────────────────────────────────────
for tf in OptimalTree_pruned_node_compare_list.txt OptimalTree_pruned_node_compare_leaves.txt; do
    if [ -L "$CT_DIR/$tf" ]; then
        _pass "$tf: symlink present"
        if [ -e "$CT_DIR/$tf" ]; then
            _pass "$tf: symlink resolves"
        else
            _fail "$tf: symlink is broken"
        fi
    else
        _fail "$tf: not a symlink"
    fi
done

# ── feature_space_info.txt content ─────────────────────────────────────────
if [ -f "$CT_DIR/feature_space_info.txt" ]; then
    if grep -q "^type=ct$" "$CT_DIR/feature_space_info.txt"; then
        _pass "feature_space_info.txt: type=ct"
    else
        _fail "feature_space_info.txt: missing type=ct"
    fi
    if grep -q "^n_features=" "$CT_DIR/feature_space_info.txt"; then
        N_FEAT=$(grep "^n_features=" "$CT_DIR/feature_space_info.txt" | cut -d= -f2)
        _pass "feature_space_info.txt: n_features=$N_FEAT"
    else
        _fail "feature_space_info.txt: missing n_features"
    fi
fi

# ── Proportion values in M.txt are in [0,1] ────────────────────────────────
if [ -f "$CT_DIR/M.txt" ]; then
    BAD_VALUES=$(awk '{ for(i=1;i<=NF;i++) if($i<0||$i>1) print $i }' "$CT_DIR/M.txt" | wc -l)
    if [ "$BAD_VALUES" -eq 0 ]; then
        _pass "M.txt: all proportion values in [0, 1]"
    else
        _fail "M.txt: $BAD_VALUES values outside [0, 1]"
    fi
fi

# ── Final result ────────────────────────────────────────────────────────────
echo ""
echo "========================================"
if [ "$FAILURES" -eq 0 ]; then
    echo "TEST PASSED (all assertions)"
    echo "Output directory: $CT_DIR"
else
    echo "TEST FAILED ($FAILURES failure(s))"
fi
echo "========================================"
[ "$FAILURES" -eq 0 ]
