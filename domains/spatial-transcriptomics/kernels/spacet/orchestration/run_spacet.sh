#!/bin/bash

# SpaCET Wrapper (TumorSPACE_AWS)
# Runs SpaCET cell-type deconvolution on Visium data.
# Run from the repo root: bash workflows/spacet/orchestration/run_spacet.sh --raw-data-dir ...
#
# Execution modes (selected automatically from config/capabilities.sh; see bash setup.sh):
#   Container (default when available): singularity exec tumorspace_r.sif
#     R script path inside container: /opt/workflows/R/run_spacet.R
#   Native (when container not available): Rscript run_spacet.R directly
#     Requires: R/4.4.1 with optparse, data.table, dplyr, SpaCET
#
# Pass --container /path/to.sif to force container mode.
# Omit --container to use the mode recorded in config/capabilities.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load HPC cluster profile (module names)
_HPC_PROFILE="${WORKSPACE_ROOT}/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# Defaults — CONTAINER is empty (opt-in), matching the core pipeline pattern
CONTAINER=""
RAW_DATA_DIR=""
OUTDIR="."
CANCER_TYPE=""
CORES=8
FORCE_NATIVE=false

# -- Parse Arguments --
while [[ $# -gt 0 ]]; do
  case $1 in
    --raw-data-dir)  RAW_DATA_DIR="$2"; shift 2;;
    --outdir)        OUTDIR="$2"; shift 2;;
    --cancer-type)   CANCER_TYPE="$2"; shift 2;;
    --cores)         CORES="$2"; shift 2;;
    --container)     CONTAINER="$2"; shift 2;;
    --no-container)  FORCE_NATIVE=true; shift;;
    -h|--help)
      echo "Usage: run_spacet.sh --raw-data-dir /path/to/data --cancer-type BRCA [options]"
      echo ""
      echo "  Run from repo root: bash workflows/spacet/orchestration/run_spacet.sh --raw-data-dir ..."
      echo ""
      echo "Options:"
      echo "  --raw-data-dir  Path to Visium input data directory (required)"
      echo "                  Must contain M.txt, features.txt, barcodes_positions.txt"
      echo "  --outdir        Output directory [default: .]"
      echo "  --cancer-type   SpaCET cancer type string, e.g. BRCA, LUAD, COAD (required)"
      echo "                  See reference_data/spacet/tissue_types_lookup.txt for mapping"
      echo "  --cores         Number of parallel cores [default: 8]"
      echo "  --container     Path to Singularity .sif file (forces container mode)"
      echo "  --no-container  Force native mode even if container is available"
      echo ""
      echo "Execution mode is selected automatically from config/capabilities.sh."
      echo "Run 'bash setup.sh' to detect and record available modes."
      exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# -- Validate required args --
if [ -z "$RAW_DATA_DIR" ]; then
  echo "Error: --raw-data-dir is required"
  exit 1
fi
if [ ! -d "$RAW_DATA_DIR" ]; then
  echo "Error: raw-data-dir does not exist: $RAW_DATA_DIR"
  exit 1
fi
if [ -z "$CANCER_TYPE" ]; then
  echo "Error: --cancer-type is required (e.g. BRCA, LUAD, COAD)"
  echo "See reference_data/spacet/tissue_types_lookup.txt for the full mapping table."
  exit 1
fi

# -- Determine execution mode --
# If --container was passed explicitly, use container mode unconditionally.
# Otherwise, read config/capabilities.sh (written by setup.sh); fall back to
# an inline probe if the file doesn't exist yet.

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
    SPACET_CONTAINER_AVAILABLE=false
    SPACET_NATIVE_AVAILABLE=false
    _DEFAULT_SIF="${WORKSPACE_ROOT}/containers/tumorspace_r.sif"
    if [ -f "$_DEFAULT_SIF" ]; then
      hpc_module_load MODULE_SINGULARITY
      if command -v singularity &>/dev/null; then
        if singularity exec --no-home --cleanenv \
            --env R_LIBS_USER="/usr/local/lib/R/site-library" \
            "$_DEFAULT_SIF" Rscript -e "library(SpaCET)" &>/dev/null 2>&1; then
          SPACET_CONTAINER_AVAILABLE=true
          CONTAINER="$_DEFAULT_SIF"
        fi
      fi
    fi
    if [ "$SPACET_CONTAINER_AVAILABLE" = false ]; then
      hpc_module_load MODULE_R
      if command -v Rscript &>/dev/null; then
        if LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
           Rscript -e "library(optparse);library(data.table);library(dplyr);library(SpaCET)" &>/dev/null 2>&1; then
          SPACET_NATIVE_AVAILABLE=true
        fi
      fi
    fi
    unset _DEFAULT_SIF
  fi
  unset _CAPS

  if [ "${SPACET_CONTAINER_AVAILABLE:-false}" = true ]; then
    USE_CONTAINER=true
    # Use default SIF path if not already set by inline probe
    [ -z "$CONTAINER" ] && CONTAINER="${WORKSPACE_ROOT}/containers/tumorspace_r.sif"
  elif [ "${SPACET_NATIVE_AVAILABLE:-false}" = true ]; then
    USE_CONTAINER=false
    echo "INFO: Running in native mode (no container). Use --container to force container mode."
  else
    echo "ERROR: SpaCET is not available in container or native mode."
    echo ""
    echo "  Container: containers/tumorspace_r.sif not found or SpaCET not installed in it"
    echo "  Native:    SpaCET not installed in system R"
    echo ""
    echo "Fix: Run 'bash setup.sh' to build the container and/or install SpaCET natively."
    exit 1
  fi
fi

# -- Validate container if using container mode --
if [ "$USE_CONTAINER" = true ] && [ ! -f "$CONTAINER" ]; then
  echo "Error: container not found: $CONTAINER"
  echo "Fix: bash containers/build_r_container.sh [--force]"
  exit 1
fi

# Convert to absolute paths
RAW_DATA_DIR=$(cd "$RAW_DATA_DIR" && pwd)
OUTDIR=$(mkdir -p "$OUTDIR" && cd "$OUTDIR" && pwd)
REF_DIR="${WORKSPACE_ROOT}/reference_data"

# Redirect Singularity's extraction tmpdir away from home dir (home quota is small).
# hpc_singularity_tmpdir: uses exec-safe scratch on GPFS clusters (Randi),
# or SLURM-provided local $TMPDIR / /tmp on Midway3 and local environments.
export SINGULARITY_TMPDIR="$(hpc_singularity_tmpdir)"

# -- Execute --
if [ "$USE_CONTAINER" = true ]; then
  hpc_module_load MODULE_SINGULARITY
  singularity exec \
    --no-home \
    --cleanenv \
    --bind "$RAW_DATA_DIR":"$RAW_DATA_DIR" \
    --bind "$OUTDIR":"$OUTDIR" \
    --bind "$REF_DIR":"$REF_DIR" \
    --env R_LIBS_USER="/usr/local/lib/R/site-library" \
    "$CONTAINER" \
    Rscript /opt/workflows/R/run_spacet.R \
    --raw-data-dir "$RAW_DATA_DIR" \
    --outdir "$OUTDIR" \
    --cancer-type "$CANCER_TYPE" \
    --cores "$CORES" \
    --ref-dir "$REF_DIR"
else
  hpc_module_load MODULE_R
  LD_PRELOAD="${HPC_LD_PRELOAD_R:-${LD_PRELOAD:-}}${HPC_LD_PRELOAD_R:+${LD_PRELOAD:+:${LD_PRELOAD}}}" \
  Rscript "${WORKSPACE_ROOT}/workflows/spacet/R/run_spacet.R" \
    --raw-data-dir "$RAW_DATA_DIR" \
    --outdir "$OUTDIR" \
    --cancer-type "$CANCER_TYPE" \
    --cores "$CORES" \
    --ref-dir "$REF_DIR"
fi
