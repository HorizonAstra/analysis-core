#!/bin/bash

# DE Analysis Wrapper (TumorSPACE_AWS)
# Runs Seurat FindAllMarkers (and optionally DESpace) on pre-clustered spatial data.
# Run from the repo root: bash workflows/DE_analysis/orchestration/run_de_analysis.sh --datapath ... --metapath ...
#
# Execution modes (selected automatically from config/capabilities.sh; see bash setup.sh):
#   Container (default when available): singularity exec tumorspace_r45.sif
#     R script path inside container: /opt/workflows/R/run_DE_analysis.R
#   Native (when container not available): Rscript run_DE_analysis.R directly
#     Requires: R with optparse, Seurat, SingleCellExperiment, scater, DESpace
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

# Defaults
CONTAINER=""
DATAPATH=""
METAPATH=""
OUTDIR=""
CLUSTERCOL="spatial.cluster"
IDCOL="sample"
DESPACE=false
TEST=false
FORCE_NATIVE=false

# -- Parse Arguments --
while [[ $# -gt 0 ]]; do
  case $1 in
    --datapath)     DATAPATH="$2"; shift 2;;
    --metapath)     METAPATH="$2"; shift 2;;
    --outdir)       OUTDIR="$2"; shift 2;;
    --clustercol)   CLUSTERCOL="$2"; shift 2;;
    --idcol)        IDCOL="$2"; shift 2;;
    --despace)      DESPACE=true; shift;;
    --container)    CONTAINER="$2"; shift 2;;
    --no-container) FORCE_NATIVE=true; shift;;
    --test)         TEST=true; shift;;
    -h|--help)
      echo "Usage: run_de_analysis.sh --datapath /path/to/data --metapath /path/to/meta.csv --outdir /path/to/outdir [options]"
      echo ""
      echo "  Run from repo root: bash workflows/DE_analysis/orchestration/run_de_analysis.sh --datapath ..."
      echo ""
      echo "Options:"
      echo "  --datapath      Path to Visium input directory, or comma-separated list for multi-sample [required]"
      echo "  --metapath      Path to metadata CSV file with barcode and cluster columns [required]"
      echo "  --outdir        Output directory [required]"
      echo "  --clustercol    colData column containing cluster assignments [default: spatial.cluster]"
      echo "  --idcol         colData column containing sample IDs [default: sample]"
      echo "  --despace       Also run DESpace spatially-variable gene detection"
      echo "  --container     Path to Singularity .sif file (forces container mode)"
      echo "  --no-container  Force native mode even if container is available"
      echo "  --test          Test mode (reserved for future fixed-seed validation)"
      echo ""
      echo "Outputs:"
      echo "  seurat_cluster_markers_all.csv   All Seurat marker genes per cluster"
      echo "  seurat_cluster_markers_top50.csv Top 50 markers per cluster by avg_log2FC"
      echo "  despace_results_all.csv          DESpace results (--despace only)"
      echo "  despace_results_byCluster.csv    DESpace per-cluster results (--despace only)"
      echo ""
      echo "Execution mode is selected automatically from config/capabilities.sh."
      echo "Run 'bash setup.sh' to detect and record available modes."
      exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# -- Validate required arguments --
if [ -z "$DATAPATH" ]; then
  echo "Error: --datapath is required"
  exit 1
fi
if [ -z "$METAPATH" ]; then
  echo "Error: --metapath is required"
  exit 1
fi
if [ -z "$OUTDIR" ]; then
  echo "Error: --outdir is required"
  exit 1
fi
if [ ! -f "$METAPATH" ]; then
  echo "Error: metapath not found: $METAPATH"
  exit 1
fi

# -- Split DATAPATH and validate each dir --
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
    DE_ANALYSIS_CONTAINER_AVAILABLE=false
    DE_ANALYSIS_NATIVE_AVAILABLE=false
    _DEFAULT_SIF="${WORKSPACE_ROOT}/containers/tumorspace_r45.sif"
    if [ -f "$_DEFAULT_SIF" ]; then
      hpc_module_load MODULE_SINGULARITY
      if command -v singularity &>/dev/null; then
        if SINGULARITY_TMPDIR="${SCRATCH_DIR:+${SCRATCH_DIR}/singularity_tmp_caps}" \
           singularity exec --no-home --cleanenv \
            --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            --env R_LIBS_USER="/usr/local/lib/R/site-library" \
            "$_DEFAULT_SIF" /bin/sh -c 'Rscript -e "library(Seurat)"' &>/dev/null 2>&1; then
          DE_ANALYSIS_CONTAINER_AVAILABLE=true
          CONTAINER="$_DEFAULT_SIF"
        fi
      fi
    fi
    if [ "$DE_ANALYSIS_CONTAINER_AVAILABLE" = false ]; then
      hpc_module_load MODULE_R
      if command -v Rscript &>/dev/null; then
        if LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
           Rscript -e "library(optparse);library(Seurat);library(SingleCellExperiment);library(DESpace)" \
           &>/dev/null 2>&1; then
          DE_ANALYSIS_NATIVE_AVAILABLE=true
        fi
      fi
    fi
    unset _DEFAULT_SIF
  fi
  unset _CAPS

  if [ "${DE_ANALYSIS_CONTAINER_AVAILABLE:-false}" = true ]; then
    USE_CONTAINER=true
    [ -z "$CONTAINER" ] && CONTAINER="${WORKSPACE_ROOT}/containers/tumorspace_r45.sif"
  elif [ "${DE_ANALYSIS_NATIVE_AVAILABLE:-false}" = true ]; then
    USE_CONTAINER=false
    echo "INFO: Running in native mode (no container). Use --container to force container mode."
  else
    echo "ERROR: DE analysis is not available in container or native mode."
    echo ""
    echo "  Container: containers/tumorspace_r45.sif not found or Seurat not installed in it"
    echo "  Native:    Seurat not installed in system R"
    echo ""
    echo "Fix: Run 'bash setup.sh' to build the container and/or install packages natively."
    exit 1
  fi
fi

# -- Validate container if using container mode --
if [ "$USE_CONTAINER" = true ] && [ ! -f "$CONTAINER" ]; then
  echo "Error: container not found: $CONTAINER"
  echo "Fix: bash containers/build_r45_container.sh [--force]"
  exit 1
fi

# -- Convert to absolute paths --
METAPATH=$(cd "$(dirname "$METAPATH")" && pwd)/$(basename "$METAPATH")
METAPATH_DIR=$(dirname "$METAPATH")
OUTDIR=$(mkdir -p "$OUTDIR" && cd "$OUTDIR" && pwd)

# Resolve each datapath to absolute and rebuild the comma-separated string
_ABS_PATHS=()
for _p in "${_DATAPATHS[@]}"; do
  _p="${_p// /}"
  _ABS_PATHS+=("$(cd "$_p" && pwd)")
done
DATAPATH=$(IFS=','; echo "${_ABS_PATHS[*]}")
unset _p _ABS_PATHS _DATAPATHS

DESPACE_FLAG=""
[ "$DESPACE" = true ] && DESPACE_FLAG="--despace"

TEST_FLAG=""
[ "$TEST" = true ] && TEST_FLAG="--test"

# -- Execute --
if [ "$USE_CONTAINER" = true ]; then
  hpc_module_load MODULE_SINGULARITY

  # Build --bind flags for each datapath, metapath dir, and outdir
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
  _BIND_ARGS+=(--bind "$METAPATH_DIR":"$METAPATH_DIR")
  _BIND_ARGS+=(--bind "$OUTDIR":"$OUTDIR")
  unset _p _PATHS

  singularity exec \
    --no-home \
    --cleanenv \
    "${_BIND_ARGS[@]}" \
    --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --env R_LIBS_USER="/usr/local/lib/R/site-library" \
    "$CONTAINER" \
    /bin/sh -c "Rscript /opt/workflows/R/run_DE_analysis.R \
      --datapath   '$DATAPATH' \
      --metapath   '$METAPATH' \
      --outdir     '$OUTDIR' \
      --clustercol '$CLUSTERCOL' \
      --idcol      '$IDCOL' \
      $DESPACE_FLAG \
      $TEST_FLAG"
else
  hpc_module_load MODULE_R
  LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
  Rscript "${WORKSPACE_ROOT}/workflows/DE_analysis/R/run_DE_analysis.R" \
    --datapath   "$DATAPATH" \
    --metapath   "$METAPATH" \
    --outdir     "$OUTDIR" \
    --clustercol "$CLUSTERCOL" \
    --idcol      "$IDCOL" \
    $DESPACE_FLAG \
    $TEST_FLAG
fi
