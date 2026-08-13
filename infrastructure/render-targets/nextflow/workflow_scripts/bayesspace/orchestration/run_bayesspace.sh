#!/bin/bash

# BayesSpace Wrapper (TumorSPACE_AWS)
# Runs BayesSpace spatial clustering on Visium data.
# Run from the repo root: bash workflows/bayesspace/orchestration/run_bayesspace.sh --datapath ...
#
# Execution modes (selected automatically from config/capabilities.sh; see bash setup.sh):
#   Container (default when available): singularity exec tumorspace_r.sif
#     R script path inside container: /opt/workflows/R/run_bayesspace.R
#   Native (when container not available): Rscript run_bayesspace.R directly
#     Requires: R/4.4.1 with optparse, data.table, ggplot2, SingleCellExperiment, BayesSpace, harmony
#
# Pass --container /path/to.sif to force container mode.
# Omit --container to use the mode recorded in config/capabilities.sh.
#
# For multi-sample joint clustering, pass --datapath as a comma-separated list:
#   --datapath /path/sample1,/path/sample2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load HPC cluster profile (module names)
_HPC_PROFILE="${WORKSPACE_ROOT}/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# Defaults — CONTAINER is empty (opt-in), matching the core pipeline pattern
CONTAINER=""
DATAPATH=""
OUTDIR="."
NPCS=15
Q=8
THETA=2
TEST=false
FORCE_NATIVE=false

# -- Parse Arguments --
while [[ $# -gt 0 ]]; do
  case $1 in
    --datapath)      DATAPATH="$2"; shift 2;;
    --outdir)        OUTDIR="$2"; shift 2;;
    --nPCs)          NPCS="$2"; shift 2;;
    --q)             Q="$2"; shift 2;;
    --theta)         THETA="$2"; shift 2;;
    --container)     CONTAINER="$2"; shift 2;;
    --no-container)  FORCE_NATIVE=true; shift;;
    --test)          TEST=true; shift;;
    -h|--help)
      echo "Usage: run_bayesspace.sh --datapath /path/to/data [options]"
      echo ""
      echo "  Run from repo root: bash workflows/bayesspace/orchestration/run_bayesspace.sh --datapath ..."
      echo ""
      echo "Options:"
      echo "  --datapath      Path to Visium data directory, or comma-separated list for"
      echo "                  joint multi-sample clustering (required)"
      echo "  --outdir        Output directory [default: .]"
      echo "  --nPCs          Number of principal components [default: 15]"
      echo "  --q             Number of spatial clusters [default: 8]"
      echo "  --theta         Harmony clustering penalty (joint mode only) [default: 2]"
      echo "  --container     Path to Singularity .sif file (forces container mode)"
      echo "  --no-container  Force native mode even if container is available"
      echo "  --test          Run in test mode with fixed seeds"
      echo ""
      echo "Execution mode is selected automatically from config/capabilities.sh."
      echo "Run 'bash setup.sh' to detect and record available modes."
      exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# -- Validate datapath --
if [ -z "$DATAPATH" ]; then
  echo "Error: --datapath is required"
  exit 1
fi

# Split comma-separated paths and validate each
_save_IFS="$IFS"
IFS=','
# shellcheck disable=SC2206
_DATAPATHS=($DATAPATH)
IFS="$_save_IFS"
unset _save_IFS
for _p in "${_DATAPATHS[@]}"; do
  if [ ! -d "$_p" ]; then
    echo "Error: datapath does not exist: $_p"
    exit 1
  fi
done
unset _p

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
    BAYESSPACE_CONTAINER_AVAILABLE=false
    BAYESSPACE_NATIVE_AVAILABLE=false
    _DEFAULT_SIF="${WORKSPACE_ROOT}/containers/tumorspace_r.sif"
    if [ -f "$_DEFAULT_SIF" ]; then
      hpc_module_load MODULE_SINGULARITY
      if command -v singularity &>/dev/null; then
        if SINGULARITY_TMPDIR="${SCRATCH_DIR:+${SCRATCH_DIR}/singularity_tmp_caps}" \
           singularity exec --no-home --cleanenv \
            --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            --env R_LIBS_USER="/usr/local/lib/R/site-library" \
            "$_DEFAULT_SIF" /bin/sh -c 'Rscript -e "library(BayesSpace)"' &>/dev/null 2>&1; then
          BAYESSPACE_CONTAINER_AVAILABLE=true
          CONTAINER="$_DEFAULT_SIF"
        fi
      fi
    fi
    if [ "$BAYESSPACE_CONTAINER_AVAILABLE" = false ]; then
      hpc_module_load MODULE_R
      if command -v Rscript &>/dev/null; then
        if LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
           Rscript -e "library(optparse);library(data.table);library(ggplot2);library(SingleCellExperiment);library(BayesSpace)" &>/dev/null 2>&1; then
          BAYESSPACE_NATIVE_AVAILABLE=true
        fi
      fi
    fi
    unset _DEFAULT_SIF
  fi
  unset _CAPS

  if [ "${BAYESSPACE_CONTAINER_AVAILABLE:-false}" = true ]; then
    USE_CONTAINER=true
    # Use default SIF path if not already set by inline probe
    [ -z "$CONTAINER" ] && CONTAINER="${WORKSPACE_ROOT}/containers/tumorspace_r.sif"
  elif [ "${BAYESSPACE_NATIVE_AVAILABLE:-false}" = true ]; then
    USE_CONTAINER=false
    echo "INFO: Running in native mode (no container). Use --container to force container mode."
  else
    echo "ERROR: BayesSpace is not available in container or native mode."
    echo ""
    echo "  Container: containers/tumorspace_r.sif not found or BayesSpace not installed in it"
    echo "  Native:    BayesSpace not installed in system R"
    echo ""
    echo "Fix: Run 'bash setup.sh' to build the container and/or install BayesSpace natively."
    exit 1
  fi
fi

# -- Validate container if using container mode --
if [ "$USE_CONTAINER" = true ] && [ ! -f "$CONTAINER" ]; then
  echo "Error: container not found: $CONTAINER"
  echo "Fix: bash containers/build_r_container.sh [--force]"
  exit 1
fi

# Convert paths to absolute
OUTDIR=$(mkdir -p "$OUTDIR" && cd "$OUTDIR" && pwd)

# Resolve each datapath to absolute and rebuild the comma-separated string
_ABS_PATHS=()
for _p in "${_DATAPATHS[@]}"; do
  _p="${_p// /}"
  _ABS_PATHS+=("$(cd "$_p" && pwd)")
done
DATAPATH=$(IFS=','; echo "${_ABS_PATHS[*]}")
unset _p _ABS_PATHS _DATAPATHS

TEST_FLAG=""
if [ "$TEST" = true ]; then
  TEST_FLAG="--test"
fi

# -- Execute --
if [ "$USE_CONTAINER" = true ]; then
  hpc_module_load MODULE_SINGULARITY

  # Build --bind flags for each datapath and outdir
  _BIND_ARGS=()
  _save_IFS="$IFS"
  IFS=','
  # shellcheck disable=SC2206
  _PATHS=($DATAPATH)
  IFS="$_save_IFS"
  unset _save_IFS
  for _p in "${_PATHS[@]}"; do
    _BIND_ARGS+=(--bind "$_p":"$_p")
  done
  _BIND_ARGS+=(--bind "$OUTDIR":"$OUTDIR")
  unset _p _PATHS

  singularity exec \
    --no-home \
    --cleanenv \
    "${_BIND_ARGS[@]}" \
    --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --env R_LIBS_USER="/usr/local/lib/R/site-library" \
    "$CONTAINER" \
    /bin/sh -c "Rscript /opt/workflows/R/run_bayesspace.R \
      --datapath '$DATAPATH' \
      --nPCs '$NPCS' \
      --q '$Q' \
      --theta '$THETA' \
      --outdir '$OUTDIR' \
      $TEST_FLAG"
  unset _BIND_ARGS
else
  hpc_module_load MODULE_R
  LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
  Rscript "${WORKSPACE_ROOT}/workflows/bayesspace/R/run_bayesspace.R" \
    --datapath "$DATAPATH" \
    --nPCs "$NPCS" \
    --q "$Q" \
    --theta "$THETA" \
    --outdir "$OUTDIR" \
    $TEST_FLAG
fi
