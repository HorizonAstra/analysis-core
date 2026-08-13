#!/bin/bash
#
# run_benchmark.sh
#
# End-to-end integration test for TumorSPACE_AWS.
# Validates the full install -> acquisition -> pipeline chain in one command.
#
# Phases:
#   Phase 0 — Acquire benchmark dataset from GEO (GSE213688_GSM6592057)
#   Phase 1 — Run TumorSPACE core pipeline in --test mode (3 SVDs, fixed seeds)
#   Phase 2 — BayesSpace spatial clustering (skipped if not available; run setup.sh first)
#
# Usage:
#   bash run_benchmark.sh --account ACCOUNT --partition PARTITION [OPTIONS]
#
# Options:
#   --account ACCOUNT       SLURM account (default: $SLURM_ACCOUNT or from config/slurm_config.sh)
#   --partition PARTITION   SLURM partition (default: $SLURM_PARTITION or from config/slurm_config.sh)
#   --skip-acquisition      Skip Phase 0 if input_data already exists locally
#   --force-redownload      Force Phase 0 even if input_data already exists (re-acquire from GEO)
#   --container SIF         Optional: Singularity container for pipeline (e.g. containers/julia_1.9_with_gotree.sif)
#   --help                  Show this help message
#
# Examples:
#   # Full end-to-end test (acquires from GEO then runs pipeline)
#   bash run_benchmark.sh --account pi-araman --partition caslake
#
#   # Skip acquisition if you've already downloaded the data
#   bash run_benchmark.sh --account pi-araman --partition caslake --skip-acquisition
#
#   # Re-download from GEO even if cached (reproducibility regression test)
#   bash run_benchmark.sh --account pi-araman --partition caslake --force-redownload
#

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
BENCHMARK_GEO_ID="GSE213688_GSM6592057"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Default config ────────────────────────────────────────────────────────────
# Load SLURM defaults from config/slurm_config.sh if it exists
_SLURM_CFG="${SCRIPT_DIR}/config/slurm_config.sh"
if [[ -f "$_SLURM_CFG" ]]; then
    # shellcheck disable=SC1090
    source "$_SLURM_CFG"
fi
unset _SLURM_CFG

ACCOUNT="${SLURM_ACCOUNT:-}"
PARTITION="${SLURM_PARTITION:-}"
CONTAINER=""
SKIP_ACQUISITION=false
FORCE_REDOWNLOAD=false

# ─── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

# ─── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --account)       ACCOUNT="$2";       shift 2 ;;
        --partition)     PARTITION="$2";     shift 2 ;;
        --container)     CONTAINER="$2";     shift 2 ;;
        --skip-acquisition) SKIP_ACQUISITION=true; shift ;;
        --force-redownload) FORCE_REDOWNLOAD=true; SKIP_ACQUISITION=false; shift ;;
        --help|-h)       usage ;;
        *) echo "Unknown option: $1" >&2; echo "Run with --help for usage." >&2; exit 1 ;;
    esac
done

# ─── Validate required args ────────────────────────────────────────────────────
if [[ -z "$ACCOUNT" ]]; then
    echo "ERROR: --account is required (or set SLURM_ACCOUNT in config/slurm_config.sh)" >&2
    exit 1
fi
if [[ -z "$PARTITION" ]]; then
    echo "ERROR: --partition is required (or set SLURM_PARTITION in config/slurm_config.sh)" >&2
    exit 1
fi

# ─── Paths ────────────────────────────────────────────────────────────────────
LOCAL_INPUT_DIR="${SCRIPT_DIR}/local/datasets/${BENCHMARK_GEO_ID}/input_data"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_BASE="${SCRIPT_DIR}/benchmarks/${BENCHMARK_GEO_ID}/runs/benchmark_${TIMESTAMP}"
ACQ_SCRIPT="${SCRIPT_DIR}/workflows/acquisition/orchestration/run_geo_discovery.sh"

# ─── Helpers ──────────────────────────────────────────────────────────────────
phase_header() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════════════════════════"
    echo ""
}

check_python3() {
    if ! command -v python3 &>/dev/null; then
        echo "ERROR: python3 not found. Load a Python module before running:" >&2
        echo "  module load python/anaconda-2022.05 && bash run_benchmark.sh ..." >&2
        exit 1
    fi
}

# ─── Phase tracking ───────────────────────────────────────────────────────────
declare -a PHASE_NAMES
declare -a PHASE_STATUS
declare -a PHASE_ELAPSED

record_phase() {
    PHASE_NAMES+=("$1")
    PHASE_STATUS+=("$2")
    PHASE_ELAPSED+=("${3:-—}")
}

# ─── Banner ───────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo "  TumorSPACE_AWS Benchmark — End-to-End Integration Test"
echo "════════════════════════════════════════════════════════════"
echo "  Dataset   : ${BENCHMARK_GEO_ID}"
echo "  Account   : ${ACCOUNT}"
echo "  Partition : ${PARTITION}"
if [[ -n "$CONTAINER" ]]; then
    echo "  Container : ${CONTAINER}"
fi
echo "  Output    : ${OUTPUT_BASE}"
echo "  Started   : $(date)"
echo "════════════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 0: Acquire dataset from GEO
# ═══════════════════════════════════════════════════════════════════════════════
phase_header "Phase 0: Data Acquisition (${BENCHMARK_GEO_ID})"

_do_acquisition=true
if $SKIP_ACQUISITION; then
    _do_acquisition=false
    echo "  --skip-acquisition supplied: skipping Phase 0"
elif [[ -f "${LOCAL_INPUT_DIR}/M.txt" ]] && ! $FORCE_REDOWNLOAD; then
    _do_acquisition=false
    echo "  Input data already present at: ${LOCAL_INPUT_DIR}"
    echo "  (Use --force-redownload to re-acquire from GEO)"
fi

if $_do_acquisition; then
    check_python3
    echo "  Downloading ${BENCHMARK_GEO_ID} from NCBI GEO..."
    t0=$SECONDS
    if bash "$ACQ_SCRIPT" --download "$BENCHMARK_GEO_ID"; then
        elapsed=$(( SECONDS - t0 ))
        echo ""
        echo "  ✓ Phase 0 PASSED (${elapsed}s)"
        record_phase "Phase 0: Acquisition" "PASS" "${elapsed}s"
    else
        echo ""
        echo "  ✗ Phase 0 FAILED — acquisition error"
        record_phase "Phase 0: Acquisition" "FAIL" "—"
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "  BENCHMARK RESULT: FAIL (Phase 0 — Acquisition)"
        echo "════════════════════════════════════════════════════════════"
        exit 1
    fi
else
    record_phase "Phase 0: Acquisition" "SKIPPED" "—"
fi

# Validate that input_data exists before proceeding
if [[ ! -f "${LOCAL_INPUT_DIR}/M.txt" ]]; then
    echo ""
    echo "ERROR: Input data not found at ${LOCAL_INPUT_DIR}/M.txt" >&2
    echo "  Run without --skip-acquisition to download from GEO." >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1: TumorSPACE core pipeline (--test mode)
# ═══════════════════════════════════════════════════════════════════════════════
phase_header "Phase 1: TumorSPACE Core Pipeline (--test mode)"
echo "  Input     : ${LOCAL_INPUT_DIR}"
echo "  Output    : ${OUTPUT_BASE}"
echo ""
echo "  Submitting SLURM jobs via run_pipeline.sh..."
echo ""

t0=$SECONDS

PIPELINE_ARGS=(
    --dataset    "$BENCHMARK_GEO_ID"
    --account    "$ACCOUNT"
    --partition  "$PARTITION"
    --input-dir  "$LOCAL_INPUT_DIR"
    --data-dir   "$LOCAL_INPUT_DIR"
    --output-base "$OUTPUT_BASE"
    --test
)
if [[ -n "$CONTAINER" ]]; then
    PIPELINE_ARGS+=(--container "$CONTAINER")
fi

if bash "${SCRIPT_DIR}/run_pipeline.sh" "${PIPELINE_ARGS[@]}"; then
    elapsed=$(( SECONDS - t0 ))
    echo ""
    echo "  ✓ Phase 1 PASSED (${elapsed}s)"
    record_phase "Phase 1: Core Pipeline" "PASS" "${elapsed}s"
else
    elapsed=$(( SECONDS - t0 ))
    echo ""
    echo "  ✗ Phase 1 FAILED (${elapsed}s)"
    record_phase "Phase 1: Core Pipeline" "FAIL" "${elapsed}s"
    PIPELINE_FAILED=true
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2: BayesSpace (optional — skipped if not available)
# ═══════════════════════════════════════════════════════════════════════════════
phase_header "Phase 2: BayesSpace Spatial Clustering"
echo "  Input  : ${LOCAL_INPUT_DIR}"
echo "  Output : ${OUTPUT_BASE}/bayesspace"
echo ""

_CAPS="${SCRIPT_DIR}/config/capabilities.sh"
BAYESSPACE_AVAILABLE=false
if [ -f "$_CAPS" ]; then
    # shellcheck disable=SC1090
    source "$_CAPS"
    if [ "${BAYESSPACE_CONTAINER_AVAILABLE:-false}" = true ] || \
       [ "${BAYESSPACE_NATIVE_AVAILABLE:-false}" = true ]; then
        BAYESSPACE_AVAILABLE=true
    fi
fi
unset _CAPS

if ! $BAYESSPACE_AVAILABLE; then
    echo "  BayesSpace not available — skipping phase."
    echo "  (Run 'bash setup.sh' to install container or native mode.)"
    record_phase "Phase 2: BayesSpace" "SKIPPED" "—"
else
    BS_OUTDIR="${OUTPUT_BASE}/bayesspace"
    mkdir -p "$BS_OUTDIR"
    BS_RUNNER="${SCRIPT_DIR}/workflows/bayesspace/orchestration/run_bayesspace.sh"

    t0=$SECONDS
    if bash "$BS_RUNNER" \
           --datapath "$LOCAL_INPUT_DIR" \
           --outdir   "$BS_OUTDIR"; then
        elapsed=$(( SECONDS - t0 ))
        # Verify expected output exists
        if [ -f "$BS_OUTDIR/bayesspace_coldata.csv" ]; then
            echo ""
            echo "  ✓ Phase 2 PASSED (${elapsed}s)"
            record_phase "Phase 2: BayesSpace" "PASS" "${elapsed}s"
        else
            echo ""
            echo "  ✗ Phase 2 FAILED — bayesspace_coldata.csv not produced"
            record_phase "Phase 2: BayesSpace" "FAIL" "${elapsed}s"
        fi
    else
        elapsed=$(( SECONDS - t0 ))
        echo ""
        echo "  ✗ Phase 2 FAILED (${elapsed}s)"
        record_phase "Phase 2: BayesSpace" "FAIL" "${elapsed}s"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3: DE Analysis (optional — requires BayesSpace coldata and DE container)
# ═══════════════════════════════════════════════════════════════════════════════
phase_header "Phase 3: DE Analysis (Seurat + DESpace)"

# Source capabilities (may already be sourced from Phase 2, re-source to be safe)
_CAPS2="${SCRIPT_DIR}/config/capabilities.sh"
DE_ANALYSIS_CONTAINER_AVAILABLE=false
if [ -f "$_CAPS2" ]; then
    # shellcheck disable=SC1090
    source "$_CAPS2"
fi
unset _CAPS2

# Phase 3 requires Phase 2 to have produced bayesspace_coldata.csv as clustering metadata
_BS_META="${BS_OUTDIR:-}/bayesspace_coldata.csv"

if [ "${DE_ANALYSIS_CONTAINER_AVAILABLE:-false}" != true ]; then
    echo "  DE analysis not available — skipping phase."
    echo "  (Run 'bash setup.sh' to build containers/tumorspace_r45.sif.)"
    record_phase "Phase 3: DE Analysis" "SKIPPED" "—"
elif [ -z "${BS_OUTDIR:-}" ] || [ ! -f "$_BS_META" ]; then
    echo "  Skipping DE analysis — Phase 2 (BayesSpace) did not produce bayesspace_coldata.csv."
    echo "  DE analysis requires BayesSpace cluster assignments as metadata input."
    record_phase "Phase 3: DE Analysis" "SKIPPED" "—"
else
    DE_OUTDIR="${OUTPUT_BASE}/de_analysis"
    mkdir -p "$DE_OUTDIR"
    DE_RUNNER="${SCRIPT_DIR}/workflows/DE_analysis/orchestration/run_de_analysis.sh"

    echo "  Input     : ${LOCAL_INPUT_DIR}"
    echo "  Metadata  : ${_BS_META}"
    echo "  Output    : ${DE_OUTDIR}"
    echo ""

    t0=$SECONDS
    if bash "$DE_RUNNER" \
           --datapath  "$LOCAL_INPUT_DIR" \
           --metapath  "$_BS_META" \
           --outdir    "$DE_OUTDIR" \
           --despace; then
        elapsed=$(( SECONDS - t0 ))
        if [ -f "$DE_OUTDIR/seurat_cluster_markers_all.csv" ]; then
            echo ""
            echo "  ✓ Phase 3 PASSED (${elapsed}s)"
            record_phase "Phase 3: DE Analysis" "PASS" "${elapsed}s"
        else
            echo ""
            echo "  ✗ Phase 3 FAILED — seurat_cluster_markers_all.csv not produced"
            record_phase "Phase 3: DE Analysis" "FAIL" "${elapsed}s"
        fi
    else
        elapsed=$(( SECONDS - t0 ))
        echo ""
        echo "  ✗ Phase 3 FAILED (${elapsed}s)"
        record_phase "Phase 3: DE Analysis" "FAIL" "${elapsed}s"
    fi
fi
unset _BS_META

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  BENCHMARK SUMMARY"
echo "════════════════════════════════════════════════════════════"
printf "  %-35s  %-8s  %s\n" "Phase" "Result" "Elapsed"
printf "  %-35s  %-8s  %s\n" "─────────────────────────────────" "──────" "───────"
OVERALL_PASS=true
for i in "${!PHASE_NAMES[@]}"; do
    status="${PHASE_STATUS[$i]}"
    elapsed="${PHASE_ELAPSED[$i]}"
    if [[ "$status" == "FAIL" ]]; then
        OVERALL_PASS=false
        icon="✗"
    elif [[ "$status" == "PASS" ]]; then
        icon="✓"
    else
        icon="─"
    fi
    printf "  %s %-33s  %-8s  %s\n" "$icon" "${PHASE_NAMES[$i]}" "$status" "$elapsed"
done
echo ""
echo "  Completed : $(date)"
echo "  Output    : ${OUTPUT_BASE}"
echo ""

if $OVERALL_PASS; then
    echo "════════════════════════════════════════════════════════════"
    echo "  BENCHMARK RESULT: PASS"
    echo "════════════════════════════════════════════════════════════"
    exit 0
else
    echo "════════════════════════════════════════════════════════════"
    echo "  BENCHMARK RESULT: FAIL"
    echo "  See SLURM logs in: ${OUTPUT_BASE}/logs/"
    echo "════════════════════════════════════════════════════════════"
    exit 1
fi
