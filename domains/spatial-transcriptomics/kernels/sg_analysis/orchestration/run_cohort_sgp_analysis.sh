#!/usr/bin/env bash
#
# run_cohort_sgp_analysis.sh  —  TumorSPACE_AWS
# Cohort-level SGP K-sweep: batch-unbiased spatial program discovery + spot labeling.
#
# Run from the TumorSPACE_AWS repo root:
#   bash workflows/sg_analysis/orchestration/run_cohort_sgp_analysis.sh \
#     --manifest   /path/to/manifest.tsv \
#     --base-dir   /path/to/tumorspace_out/per_sample \
#     --output-dir /path/to/results/05_sgp
#
# Manifest format (TSV, required cols: sample_id  canonical_dir  site  group):
#   sample_id    canonical_dir                              site  group
#   S082401595   S082401595_container_prod_20260520_124500  UoC   B
#
# Execution modes (selected automatically from config/capabilities.sh; see bash setup.sh):
#   Container (default when available): singularity exec tumorspace_r45.sif
#     R script path inside container: /opt/workflows/R/run_cohort_sgp_analysis.R
#   Native (when container not available): Rscript run_cohort_sgp_analysis.R directly
#     Requires: R with data.table and optparse
#
# Pass --container /path/to.sif to force container mode.
# Pass --no-container to force native mode.
#
# Idempotency: exits 0 immediately if {output-dir}/spot_sv_labels.tsv already exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load HPC cluster profile (module names, hpc_module_load, hpc_singularity_tmpdir)
_HPC_PROFILE="${WORKSPACE_ROOT}/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
CONTAINER=""
FORCE_NATIVE=false
SKIP_SPATIAL=false
MANIFEST=""
BASE_DIR=""
OUTPUT_DIR=""
N_LOAD=30
K_MIN=5
K_MAX=30
P_SITE=0.10
P_GROUP=0.10

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)     MANIFEST="$2";     shift 2 ;;
    --base-dir)     BASE_DIR="$2";     shift 2 ;;
    --output-dir)   OUTPUT_DIR="$2";   shift 2 ;;
    --n-load)       N_LOAD="$2";       shift 2 ;;
    --k-min)        K_MIN="$2";        shift 2 ;;
    --k-max)        K_MAX="$2";        shift 2 ;;
    --p-site)       P_SITE="$2";       shift 2 ;;
    --p-group)      P_GROUP="$2";      shift 2 ;;
    --container)     CONTAINER="$2";    shift 2 ;;
    --no-container)  FORCE_NATIVE=true;  shift   ;;
    --skip-spatial)  SKIP_SPATIAL=true;  shift   ;;
    --help|-h)
      sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      echo "Run with --help for usage." >&2
      exit 1 ;;
  esac
done

# --------------------------------------------------------------------------
# Validate required arguments
# --------------------------------------------------------------------------
[[ -z "$MANIFEST"   ]] && { echo "Error: --manifest is required"   >&2; exit 1; }
[[ -z "$BASE_DIR"   ]] && { echo "Error: --base-dir is required"   >&2; exit 1; }
[[ -z "$OUTPUT_DIR" ]] && { echo "Error: --output-dir is required" >&2; exit 1; }
[[ -f "$MANIFEST"   ]] || { echo "Error: manifest not found: $MANIFEST" >&2; exit 1; }

# --------------------------------------------------------------------------
# Idempotency check
# --------------------------------------------------------------------------
if [ "$SKIP_SPATIAL" = true ]; then
  _IDEM_FILE="${OUTPUT_DIR}/sv_ksweep_top_group.tsv"
else
  _IDEM_FILE="${OUTPUT_DIR}/spot_sv_labels.tsv"
fi
if [[ -f "$_IDEM_FILE" ]]; then
  echo "Idempotency: $_IDEM_FILE exists — skipping."
  unset _IDEM_FILE
  exit 0
fi
unset _IDEM_FILE

mkdir -p "$OUTPUT_DIR"

# --------------------------------------------------------------------------
# Determine execution mode (mirrors run_de_analysis.sh / run_spacet.sh)
# --------------------------------------------------------------------------
if [ "$FORCE_NATIVE" = true ]; then
  USE_CONTAINER=false
elif [ -n "$CONTAINER" ]; then
  USE_CONTAINER=true
else
  _CAPS="${WORKSPACE_ROOT}/config/capabilities.sh"
  if [ -f "$_CAPS" ]; then
    # shellcheck disable=SC1090
    source "$_CAPS"
  else
    echo "WARNING: config/capabilities.sh not found — running inline capability probe."
    echo "         Run 'bash setup.sh' to generate it and avoid this overhead."
    SGP_ANALYSIS_CONTAINER_AVAILABLE=false
    SGP_ANALYSIS_NATIVE_AVAILABLE=false
    _DEFAULT_SIF="${WORKSPACE_ROOT}/containers/tumorspace_r45.sif"
    if [ -f "$_DEFAULT_SIF" ]; then
      hpc_module_load MODULE_SINGULARITY
      if command -v singularity &>/dev/null; then
        if SINGULARITY_TMPDIR="${SCRATCH_DIR:+${SCRATCH_DIR}/singularity_tmp_caps}" \
           singularity exec --no-home --cleanenv \
             --env R_LIBS_USER="/usr/local/lib/R/site-library" \
             "$_DEFAULT_SIF" /bin/sh -c 'Rscript -e "library(data.table)"' &>/dev/null 2>&1; then
          SGP_ANALYSIS_CONTAINER_AVAILABLE=true
          CONTAINER="$_DEFAULT_SIF"
        fi
      fi
    fi
    if [ "$SGP_ANALYSIS_CONTAINER_AVAILABLE" = false ]; then
      hpc_module_load MODULE_R
      if command -v Rscript &>/dev/null; then
        if LD_PRELOAD="${HPC_LD_PRELOAD_R:-${LD_PRELOAD:-}}${HPC_LD_PRELOAD_R:+${LD_PRELOAD:+:${LD_PRELOAD}}}" \
           Rscript -e "library(data.table);library(optparse)" &>/dev/null 2>&1; then
          SGP_ANALYSIS_NATIVE_AVAILABLE=true
        fi
      fi
    fi
    unset _DEFAULT_SIF
  fi
  unset _CAPS

  if [ "${SGP_ANALYSIS_CONTAINER_AVAILABLE:-false}" = true ]; then
    USE_CONTAINER=true
    [ -z "$CONTAINER" ] && CONTAINER="${WORKSPACE_ROOT}/containers/tumorspace_r45.sif"
  elif [ "${SGP_ANALYSIS_NATIVE_AVAILABLE:-false}" = true ]; then
    USE_CONTAINER=false
    echo "INFO: Running in native mode (no container). Use --container to force container mode."
  else
    echo "ERROR: SGP analysis is not available in container or native mode."
    echo ""
    echo "  Container: containers/tumorspace_r45.sif not found or data.table not installed in it"
    echo "  Native:    data.table/optparse not installed in system R"
    echo ""
    echo "Fix: Run 'bash setup.sh' to build the container and/or install packages natively."
    exit 1
  fi
fi

# --------------------------------------------------------------------------
# Validate container path if using container mode
# --------------------------------------------------------------------------
if [ "$USE_CONTAINER" = true ] && [ ! -f "$CONTAINER" ]; then
  echo "Error: container not found: $CONTAINER"
  echo "Fix: bash containers/build_r45_container.sh [--force]"
  exit 1
fi

# --------------------------------------------------------------------------
# Convert to absolute paths
# --------------------------------------------------------------------------
MANIFEST=$(cd "$(dirname "$MANIFEST")" && pwd)/$(basename "$MANIFEST")
MANIFEST_DIR=$(dirname "$MANIFEST")
BASE_DIR=$(cd "$BASE_DIR" && pwd)
OUTPUT_DIR=$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)

export SINGULARITY_TMPDIR="$(hpc_singularity_tmpdir)"

# --------------------------------------------------------------------------
# Execute
# --------------------------------------------------------------------------
if [ "$USE_CONTAINER" = true ]; then
  hpc_load_singularity
  singularity exec \
    --no-home \
    --cleanenv \
    --bind "$MANIFEST_DIR":"$MANIFEST_DIR" \
    --bind "$BASE_DIR":"$BASE_DIR" \
    --bind "$OUTPUT_DIR":"$OUTPUT_DIR" \
    --env R_LIBS_USER="/usr/local/lib/R/site-library" \
    "$CONTAINER" \
    /bin/sh -c "Rscript /opt/workflows/R/run_cohort_sgp_analysis.R \
      --manifest   '$MANIFEST' \
      --base-dir   '$BASE_DIR' \
      --output-dir '$OUTPUT_DIR' \
      --n-load     '$N_LOAD' \
      --k-min      '$K_MIN' \
      --k-max      '$K_MAX' \
      --p-site     '$P_SITE' \
      --p-group    '$P_GROUP'${SKIP_SPATIAL:+ --skip-spatial}"
else
  hpc_module_load MODULE_R
  _SKIP_ARG=""
  [ "$SKIP_SPATIAL" = true ] && _SKIP_ARG="--skip-spatial"
  LD_PRELOAD="${HPC_LD_PRELOAD_R:-${LD_PRELOAD:-}}${HPC_LD_PRELOAD_R:+${LD_PRELOAD:+:${LD_PRELOAD}}}" \
  Rscript "${WORKSPACE_ROOT}/workflows/sg_analysis/R/run_cohort_sgp_analysis.R" \
    --manifest   "$MANIFEST" \
    --base-dir   "$BASE_DIR" \
    --output-dir "$OUTPUT_DIR" \
    --n-load     "$N_LOAD" \
    --k-min      "$K_MIN" \
    --k-max      "$K_MAX" \
    --p-site     "$P_SITE" \
    --p-group    "$P_GROUP" \
    ${_SKIP_ARG}
  unset _SKIP_ARG
fi
