#!/bin/bash
#
# run_harmonize.sh
#
# Preprocessing orchestration: SpaceRanger → TumorSPACE_AWS input format
#
# Runs three steps in sequence for a single sample:
#   Step H1  preprocess_harmonize.R    Convert SpaceRanger output to 5-file format
#   Step H2  preprocess_umi_qc.R       GMM-based UMI QC filter (optional)
#   Step H3  preprocess_harmonize.R    Re-harmonize applying UMI QC whitelist
#   Step H4  preprocess_umi_qc_summary.R  Per-run QC summary PDF
#
# Steps H2–H4 are skipped when --umi-qc-dir is not provided; the harmonized
# output from H1 is used directly by the main TumorSPACE pipeline.
#
# By default all steps run synchronously on the calling node. Pass --sbatch to
# submit preprocessing as a SLURM job instead (recommended on HPC: compute nodes
# have FUSE support so the R container runs cleanly and fast).
# When --sbatch is used the script submits the job and prints the SLURM job ID
# as the final line of stdout, matching the capture pattern of other wrappers.
#
# Usage:
#   bash run_harmonize.sh \
#       --dataset         DATASET       Sample/dataset identifier
#       --spaceranger-dir DIR           SpaceRanger outs/ directory for this sample
#       --output-dir      DIR           Where to write harmonized 5-file output
#       [--umi-qc-dir     DIR]          Where to write/read UMI QC outputs (enables QC steps)
#       [--container      DIR]          Container directory (looks for tumorspace_r.sif)
#       [--sbatch]                      Submit as a SLURM job (prints job ID on last line)
#       [--account        ACCOUNT]      SLURM account (required with --sbatch)
#       [--partition      PARTITION]    SLURM partition (required with --sbatch)
#       [--log-dir        DIR]          Directory for SLURM .out/.err logs (default: output-dir)
#       [--time           HH:MM:SS]     SLURM time limit (default: 00:30:00)
#       [--mem            SIZE]         SLURM memory (default: 16G)
#       [--dry-run]                     Print commands without executing
#       [--test]                        Test mode: strict checks, no SLURM submission
#
# Outputs (written to --output-dir/):
#   M.txt, barcodes.txt, features.txt, genes.txt, barcodes_positions.txt
#
# Outputs (written to --umi-qc-dir/ when enabled):
#   passing_barcodes.txt, umi_stats.tsv, umi_qc_plot.png, umi_qc_summary.pdf
#
# Exit codes:
#   0  success
#   1  argument error or prerequisite failure
#   2  R script execution failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
R_SCRIPTS_DIR="${SCRIPT_DIR}/../R"

# Load HPC cluster profile
_HPC_PROFILE="${REPO_ROOT}/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# ── Defaults ──────────────────────────────────────────────────────────────────
DATASET=""
SPACERANGER_DIR=""
OUTPUT_DIR=""
UMI_QC_DIR=""       # empty = skip UMI QC steps
CONTAINER_DIR=""
SBATCH_MODE=false
SLURM_ACCOUNT=""
SLURM_PARTITION=""
SLURM_LOG_DIR=""
SLURM_TIME="00:30:00"
SLURM_MEM="16G"
DRY_RUN=false
TEST_MODE=false

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset)         DATASET="$2";         shift 2 ;;
    --spaceranger-dir) SPACERANGER_DIR="$2"; shift 2 ;;
    --output-dir)      OUTPUT_DIR="$2";      shift 2 ;;
    --umi-qc-dir)      UMI_QC_DIR="$2";      shift 2 ;;
    --container)       CONTAINER_DIR="$2";   shift 2 ;;
    --sbatch)          SBATCH_MODE=true;     shift   ;;
    --account)         SLURM_ACCOUNT="$2";   shift 2 ;;
    --partition)       SLURM_PARTITION="$2"; shift 2 ;;
    --log-dir)         SLURM_LOG_DIR="$2";   shift 2 ;;
    --time)            SLURM_TIME="$2";      shift 2 ;;
    --mem)             SLURM_MEM="$2";       shift 2 ;;
    --dry-run)         DRY_RUN=true;         shift   ;;
    --test)            TEST_MODE=true;       shift   ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//' | head -60
      exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Validate required args ────────────────────────────────────────────────────
if [[ -z "$DATASET" || -z "$SPACERANGER_DIR" || -z "$OUTPUT_DIR" ]]; then
  echo "ERROR: --dataset, --spaceranger-dir, and --output-dir are required." >&2
  echo "Run with --help for usage." >&2
  exit 1
fi
if [[ "$SBATCH_MODE" == true && ( -z "$SLURM_ACCOUNT" || -z "$SLURM_PARTITION" ) ]]; then
  echo "ERROR: --account and --partition are required with --sbatch." >&2
  exit 1
fi

# ── SLURM submission mode ─────────────────────────────────────────────────────
# When --sbatch: generate a batch script that re-invokes this script synchronously
# on a compute node (where FUSE is available for container execution), then exit.
if [[ "$SBATCH_MODE" == true ]]; then
  _LOG_DIR="${SLURM_LOG_DIR:-${OUTPUT_DIR}}"
  mkdir -p "$_LOG_DIR"

  # Build the inner call — same args minus --sbatch/--account/--partition/--log-dir
  _INNER_ARGS=()
  _INNER_ARGS+=(--dataset         "${DATASET}")
  _INNER_ARGS+=(--spaceranger-dir "${SPACERANGER_DIR}")
  _INNER_ARGS+=(--output-dir      "${OUTPUT_DIR}")
  [[ -n "$UMI_QC_DIR"    ]] && _INNER_ARGS+=(--umi-qc-dir "${UMI_QC_DIR}")
  [[ -n "$CONTAINER_DIR" ]] && _INNER_ARGS+=(--container  "${CONTAINER_DIR}")
  [[ "$DRY_RUN"  == true ]] && _INNER_ARGS+=(--dry-run)
  [[ "$TEST_MODE" == true ]] && _INNER_ARGS+=(--test)

  _BATCH_SCRIPT=$(mktemp /tmp/run_harmonize_sbatch_XXXXXX.sh)
  cat > "$_BATCH_SCRIPT" << SBATCH_EOF
#!/bin/bash
#SBATCH --job-name=ts_preprocess_${DATASET}
#SBATCH --output=${_LOG_DIR}/preprocess_${DATASET}_%j.out
#SBATCH --error=${_LOG_DIR}/preprocess_${DATASET}_%j.err
#SBATCH --time=${SLURM_TIME}
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=${SLURM_MEM}
#SBATCH --account=${SLURM_ACCOUNT}
#SBATCH --partition=${SLURM_PARTITION}

set -euo pipefail

# Load R module for native Rscript execution (avoids container UID lookup issues)
# This is the preferred path on HPC: native R is fast and avoids LDAP/singularity issues
if command -v module &>/dev/null; then
$(if [[ -n "${MODULE_R_PREREQS:-}" ]]; then
  for _p in ${MODULE_R_PREREQS}; do echo "  module load ${_p}"; done
fi)
  module load ${MODULE_R:-R}
fi

bash '${SCRIPT_DIR}/run_harmonize.sh' $(printf "'%s' " "${_INNER_ARGS[@]}")
SBATCH_EOF

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] sbatch ${_BATCH_SCRIPT}"
    echo "[DRY-RUN] Inner args: ${_INNER_ARGS[*]}"
    rm -f "$_BATCH_SCRIPT"
    echo "12345"   # fake job ID for dry-run capture
    exit 0
  fi

  _SBATCH_OUT=$(sbatch --parsable "$_BATCH_SCRIPT" 2>&1)
  _SUBMIT_RC=$?
  rm -f "$_BATCH_SCRIPT"
  if [[ $_SUBMIT_RC -ne 0 ]]; then
    echo "ERROR: sbatch failed: ${_SBATCH_OUT}" >&2
    exit 1
  fi
  echo "  Preprocessing job submitted for ${DATASET}" >&2
  echo "${_SBATCH_OUT}"   # job ID — must be last line of stdout
  exit 0
fi

# ── Resolve Rscript runner ────────────────────────────────────────────────────
# Prefer system Rscript; fall back to container if --container is given.
# Container is only required if system Rscript is unavailable.
RSCRIPT_CMD=""
if command -v Rscript &>/dev/null; then
  RSCRIPT_CMD="Rscript"
elif [[ -n "$CONTAINER_DIR" ]]; then
  R_SIF="${CONTAINER_DIR}/tumorspace_r.sif"
  if [[ ! -f "$R_SIF" ]]; then
    echo "ERROR: tumorspace_r.sif not found at ${R_SIF}" >&2
    exit 1
  fi
  # Load singularity if needed
  if ! command -v singularity &>/dev/null; then
    if [[ -n "${MODULE_SINGULARITY_PREREQS:-}" ]]; then
      for _pre in ${MODULE_SINGULARITY_PREREQS}; do module load "$_pre" 2>/dev/null || true; done
    fi
    hpc_module_load MODULE_SINGULARITY 2>/dev/null || true
  fi
  # Build singularity exec prefix; bind the three key paths
  _BIND="${SPACERANGER_DIR}:${SPACERANGER_DIR},${OUTPUT_DIR}:${OUTPUT_DIR}"
  [[ -n "$UMI_QC_DIR" ]] && _BIND="${_BIND},${UMI_QC_DIR}:${UMI_QC_DIR}"
  RSCRIPT_CMD="singularity exec --no-home --cleanenv \
    --bind '${REPO_ROOT}:${REPO_ROOT}' \
    --bind '${_BIND}' \
    '${R_SIF}' Rscript"
  unset _BIND
else
  echo "ERROR: Rscript not found in PATH and no --container provided." >&2
  exit 1
fi

run_r() {
  local script="$1"; shift
  local full_script="${R_SCRIPTS_DIR}/${script}"
  # When running inside a container the scripts live at /opt/workflows/R/
  if [[ "$RSCRIPT_CMD" == singularity* ]]; then
    full_script="/opt/workflows/R/${script}"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] ${RSCRIPT_CMD} ${full_script} $*"
  else
    eval "${RSCRIPT_CMD} '${full_script}' $*" || {
      echo "ERROR: ${script} failed (exit $?)" >&2; exit 2
    }
  fi
}

# ── Print header ──────────────────────────────────────────────────────────────
# Per-sample QC files go under UMI_QC_DIR/<dataset>/; summary PDF at UMI_QC_DIR/
SAMPLE_QC_DIR=""
[[ -n "$UMI_QC_DIR" ]] && SAMPLE_QC_DIR="${UMI_QC_DIR}/${DATASET}"
mkdir -p "$OUTPUT_DIR"
[[ -n "$SAMPLE_QC_DIR" ]] && mkdir -p "$SAMPLE_QC_DIR"

echo "============================================================"
echo "TumorSPACE Preprocessing: ${DATASET}"
echo "============================================================"
echo "  SpaceRanger dir : ${SPACERANGER_DIR}"
echo "  Output dir      : ${OUTPUT_DIR}"
echo "  UMI QC dir      : ${UMI_QC_DIR:-(disabled)}"
echo "  Runner          : ${RSCRIPT_CMD%% *}"
echo "  Test mode       : ${TEST_MODE}"
echo "  Dry run         : ${DRY_RUN}"
echo ""

# ── Step H1: Harmonize (initial, without QC filter) ──────────────────────────
echo "--- Step H1: Harmonize SpaceRanger → TumorSPACE format"
run_r preprocess_harmonize.R \
  --spaceranger-dir "'${SPACERANGER_DIR}'" \
  --output-dir      "'${OUTPUT_DIR}'"      \
  --sample-id       "'${DATASET}'"

# ── Steps H2–H3: UMI QC + re-harmonize (only when --umi-qc-dir is set) ───────
if [[ -n "$SAMPLE_QC_DIR" ]]; then
  # Preserve pre-QC harmonized files before H3 overwrites them
  for _f in M.txt barcodes.txt features.txt genes.txt; do
    [[ -f "${OUTPUT_DIR}/${_f}" ]] && cp "${OUTPUT_DIR}/${_f}" "${OUTPUT_DIR}/${_f%.txt}_preqc.txt"
  done
  # Force regeneration of barcodes_positions.txt in H3 so it reflects QC-filtered barcodes
  rm -f "${OUTPUT_DIR}/barcodes_positions.txt"

  echo ""
  echo "--- Step H2: UMI QC filter"
  run_r preprocess_umi_qc.R \
    --spaceranger-dir  "'${SPACERANGER_DIR}'" \
    --output-dir       "'${SAMPLE_QC_DIR}'"   \
    --sample-id        "'${DATASET}'"

  echo ""
  echo "--- Step H3: Re-harmonize applying UMI QC whitelist"
  run_r preprocess_harmonize.R \
    --spaceranger-dir  "'${SPACERANGER_DIR}'" \
    --output-dir       "'${OUTPUT_DIR}'"      \
    --umi-qc-dir       "'${SAMPLE_QC_DIR}'"   \
    --sample-id        "'${DATASET}'"

  echo ""
  echo "--- Step H4: UMI QC summary PDF"
  # Summary scans UMI_QC_DIR/ subdirs — covers all samples in the run
  run_r preprocess_umi_qc_summary.R \
    --qc-dir  "'${UMI_QC_DIR}'"    \
    --samples "'${DATASET}'"
fi

echo ""
echo "============================================================"
echo "Preprocessing complete: ${DATASET}"
echo "============================================================"
