#!/bin/bash
# Integration test for workflows/preprocessing
#
# Runs the full preprocessing pipeline (harmonize + UMI QC) on the standard
# 371-spot benchmark dataset (GSE213688_GSM6592057) using synthetic SpaceRanger
# input generated from the existing input_data/ directory.
#
# Validates:
#   - All 5 harmonized output files are produced
#   - Spot count in barcodes.txt matches input (371)
#   - barcodes_positions.txt has the expected number of rows
#   - passing_barcodes.txt is produced (UMI QC step)
#   - umi_stats.tsv is produced with correct schema
#   - umi_qc_summary.pdf is produced
#   - Re-harmonized M.txt row count matches passing_barcodes.txt length
#
# Usage (from repo root):
#   bash tests/preprocessing/test_harmonize.sh                          # native Rscript
#   bash tests/preprocessing/test_harmonize.sh --container containers   # use SIF
#   bash tests/preprocessing/test_harmonize.sh --dry-run                # print commands only
#
# Prerequisites:
#   benchmarks/GSE213688_GSM6592057/spaceranger_input/ must exist.
#   Generate with: bash tests/preprocessing/generate_benchmark_spaceranger.sh
#   (or it will be generated automatically by this script if missing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DATASET="GSE213688_GSM6592057"
BENCHMARK="${WORKSPACE_ROOT}/benchmarks/${DATASET}"
SR_INPUT="${BENCHMARK}/spaceranger_input"
OUT_BASE="${WORKSPACE_ROOT}/local/outputs/preprocessing_test"
HARM_DIR="${OUT_BASE}/harmonized"
QC_DIR="${OUT_BASE}/umi_qc"
RUNNER="${WORKSPACE_ROOT}/workflows/preprocessing/orchestration/run_harmonize.sh"

CONTAINER_DIR=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --container) CONTAINER_DIR="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true;       shift   ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
FAILURES=0
_pass() { echo "  ✓ $1"; }
_fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }
_check_file()  { [[ -f "$1" ]] && _pass "$2 exists" || _fail "$2 missing: $1"; }
_check_lines() {
  local file="$1" expected="$2" label="$3"
  # Subtract 1 for header line when present
  local actual
  actual=$(wc -l < "$file")
  if [[ "$actual" -eq "$expected" ]]; then
    _pass "${label}: ${actual} lines (expected ${expected})"
  else
    _fail "${label}: ${actual} lines (expected ${expected}) — file: $1"
  fi
}

echo "========================================"
echo "TumorSPACE Preprocessing Integration Test"
echo "  Dataset : ${DATASET}"
echo "  SR input: ${SR_INPUT}"
echo "  Harm dir: ${HARM_DIR}"
echo "  QC dir  : ${QC_DIR}"
echo "========================================"
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────────
# Auto-generate SpaceRanger input if missing (first run)
if [[ ! -d "${SR_INPUT}/filtered_feature_bc_matrix" ]]; then
  echo "spaceranger_input/ not found — generating from input_data/..."
  if ! command -v Rscript &>/dev/null; then
    echo "ERROR: Rscript not available to generate SpaceRanger input." >&2
    exit 1
  fi
  Rscript --vanilla "${SCRIPT_DIR}/generate_benchmark_spaceranger.R"
fi

if [[ ! -d "$SR_INPUT" ]]; then
  echo "ERROR: SpaceRanger benchmark input not found: ${SR_INPUT}" >&2
  exit 1
fi

# Expected spot count from barcodes (371 for this benchmark)
EXPECTED_SPOTS=$(awk 'NR>1' "${BENCHMARK}/input_data/barcodes.txt" | wc -l)

# ── Clean previous run ────────────────────────────────────────────────────────
rm -rf "$OUT_BASE"
mkdir -p "$HARM_DIR" "$QC_DIR"

# ── Run preprocessing ─────────────────────────────────────────────────────────
RUNNER_ARGS=(
  --dataset         "${DATASET}"
  --spaceranger-dir "${SR_INPUT}"
  --output-dir      "${HARM_DIR}"
  --umi-qc-dir      "${QC_DIR}"
)
[[ -n "$CONTAINER_DIR" ]] && RUNNER_ARGS+=(--container "${CONTAINER_DIR}")
[[ "$DRY_RUN" == true  ]] && RUNNER_ARGS+=(--dry-run)

echo "Running: bash ${RUNNER} ${RUNNER_ARGS[*]}"
echo ""
bash "$RUNNER" "${RUNNER_ARGS[@]}"

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "[DRY-RUN] Skipping validation (no files produced in dry-run mode)"
  exit 0
fi

# ── Validate outputs ──────────────────────────────────────────────────────────
echo ""
echo "=== Validation ==="

echo ""
echo "-- Harmonized files (${HARM_DIR}) --"
_check_file "${HARM_DIR}/M.txt"                    "M.txt"
_check_file "${HARM_DIR}/barcodes.txt"             "barcodes.txt"
_check_file "${HARM_DIR}/features.txt"             "features.txt"
_check_file "${HARM_DIR}/genes.txt"                "genes.txt"
_check_file "${HARM_DIR}/barcodes_positions.txt"   "barcodes_positions.txt"

echo ""
echo "-- Spot counts --"
# barcodes.txt has a header; check data rows only
BC_LINES=$(awk 'NR>1' "${HARM_DIR}/barcodes.txt" | wc -l)
if [[ "$BC_LINES" -gt 0 && "$BC_LINES" -le "$EXPECTED_SPOTS" ]]; then
  _pass "barcodes.txt: ${BC_LINES} spots (≤ ${EXPECTED_SPOTS} after QC — OK)"
else
  _fail "barcodes.txt: ${BC_LINES} spots (expected ≤ ${EXPECTED_SPOTS})"
fi

# M.txt rows should match barcodes count
MTX_ROWS=$(wc -l < "${HARM_DIR}/M.txt")
if [[ "$MTX_ROWS" -eq "$BC_LINES" ]]; then
  _pass "M.txt row count (${MTX_ROWS}) matches barcodes.txt (${BC_LINES})"
else
  _fail "M.txt row count (${MTX_ROWS}) != barcodes.txt (${BC_LINES})"
fi

# barcodes_positions.txt: header + BC_LINES data rows
BP_DATA=$(awk 'NR>1' "${HARM_DIR}/barcodes_positions.txt" | wc -l)
if [[ "$BP_DATA" -eq "$BC_LINES" ]]; then
  _pass "barcodes_positions.txt: ${BP_DATA} spots matches barcodes.txt"
else
  _fail "barcodes_positions.txt: ${BP_DATA} spots != barcodes.txt (${BC_LINES})"
fi

echo ""
echo "-- UMI QC outputs (${QC_DIR}/${DATASET}/) --"
SAMPLE_QC_DIR="${QC_DIR}/${DATASET}"
_check_file "${SAMPLE_QC_DIR}/passing_barcodes.txt"  "passing_barcodes.txt"
_check_file "${SAMPLE_QC_DIR}/umi_stats.tsv"         "umi_stats.tsv"
_check_file "${SAMPLE_QC_DIR}/umi_qc_plot.png"       "umi_qc_plot.png"
_check_file "${QC_DIR}/umi_qc_summary.pdf"           "umi_qc_summary.pdf (root)"

# passing_barcodes.txt count should match re-harmonized barcodes
if [[ -f "${SAMPLE_QC_DIR}/passing_barcodes.txt" && -f "${HARM_DIR}/barcodes.txt" ]]; then
  PB_COUNT=$(wc -l < "${SAMPLE_QC_DIR}/passing_barcodes.txt")
  if [[ "$PB_COUNT" -eq "$BC_LINES" ]]; then
    _pass "passing_barcodes.txt (${PB_COUNT}) matches re-harmonized barcodes.txt (${BC_LINES})"
  else
    _fail "passing_barcodes.txt (${PB_COUNT}) != re-harmonized barcodes.txt (${BC_LINES})"
  fi
fi

# umi_stats.tsv schema check
if [[ -f "${SAMPLE_QC_DIR}/umi_stats.tsv" ]]; then
  for col in sample_id n_total n_pass n_fail filter_applied cutoff_umi n_components; do
    if head -1 "${SAMPLE_QC_DIR}/umi_stats.tsv" | grep -q "$col"; then
      _pass "umi_stats.tsv has column: ${col}"
    else
      _fail "umi_stats.tsv missing column: ${col}"
    fi
  done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
if [[ "$FAILURES" -eq 0 ]]; then
  echo "  ALL TESTS PASSED (${DATASET})"
else
  echo "  ${FAILURES} TEST(S) FAILED — see above"
fi
echo "========================================"
[[ "$FAILURES" -eq 0 ]]
