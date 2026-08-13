#!/bin/bash
# Test script for DE analysis workflow.
# Validates seurat_cluster_markers_all.csv, seurat_cluster_markers_top50.csv,
# despace_results_all.csv, and despace_results_byCluster.csv via md5sum comparison
# against committed baselines, for both single-sample and joint (multi-sample) modes.
#
# Usage:
#   bash tests/de_analysis/test_de_analysis.sh                          # validate against baselines
#   bash tests/de_analysis/test_de_analysis.sh --generate-reference     # generate baselines
#   bash tests/de_analysis/test_de_analysis.sh --container /path/to.sif # specify container

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -- Paths --
RUNNER="${WORKSPACE_ROOT}/workflows/DE_analysis/orchestration/run_de_analysis.sh"
DATAPATH_SINGLE="${WORKSPACE_ROOT}/benchmarks/GSE213688_GSM6592057/input_data"
DATAPATH_JOINT="${DATAPATH_SINGLE},${DATAPATH_SINGLE}"
META_SINGLE="${WORKSPACE_ROOT}/benchmarks/GSE213688_GSM6592057/expected_outputs/test_coldata_single.csv"
META_JOINT="${WORKSPACE_ROOT}/benchmarks/GSE213688_GSM6592057/expected_outputs/test_coldata_joint.csv"
EXPECTED_DIR="${WORKSPACE_ROOT}/benchmarks/GSE213688_GSM6592057/expected_outputs"
OUTDIR_SINGLE="${WORKSPACE_ROOT}/local/outputs/de_analysis_test_single"
OUTDIR_JOINT="${WORKSPACE_ROOT}/local/outputs/de_analysis_test_joint"

# Baseline filenames — Seurat
EXPECTED_SINGLE_ALL="${EXPECTED_DIR}/de_single_markers_all.csv"
EXPECTED_SINGLE_TOP="${EXPECTED_DIR}/de_single_markers_top50.csv"
EXPECTED_JOINT_ALL="${EXPECTED_DIR}/de_joint_markers_all.csv"
EXPECTED_JOINT_TOP="${EXPECTED_DIR}/de_joint_markers_top50.csv"

# Baseline filenames — DESpace
EXPECTED_SINGLE_DE_ALL="${EXPECTED_DIR}/de_single_despace_all.csv"
EXPECTED_SINGLE_DE_CLUSTER="${EXPECTED_DIR}/de_single_despace_byCluster.csv"
EXPECTED_JOINT_DE_ALL="${EXPECTED_DIR}/de_joint_despace_all.csv"
EXPECTED_JOINT_DE_CLUSTER="${EXPECTED_DIR}/de_joint_despace_byCluster.csv"

# -- Defaults --
GENERATE_REFERENCE=false
CONTAINER="${WORKSPACE_ROOT}/containers/tumorspace_r45.sif"
FAILURES=0

# -- Parse args --
while [[ $# -gt 0 ]]; do
  case $1 in
    --generate-reference) GENERATE_REFERENCE=true; shift;;
    --container) CONTAINER="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# -- Helper functions --
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

_validate_md5() {
  local _file="$1" _expected="$2" _label="$3"
  if [ ! -f "$_file" ]; then
    _fail "$_label not produced"
  else
    _obs=$(md5sum "$_file" | awk '{print $1}')
    _exp=$(md5sum "$_expected" | awk '{print $1}')
    if [ "$_obs" = "$_exp" ]; then
      _pass "$_label md5sum"
    else
      _fail "$_label md5sum mismatch"
      echo "         expected: $_exp"
      echo "         observed: $_obs"
    fi
    unset _obs _exp
  fi
}

# -- Source capabilities --
_CAPS="${WORKSPACE_ROOT}/config/capabilities.sh"
if [ -f "$_CAPS" ]; then
  # shellcheck disable=SC1090
  source "$_CAPS"
fi
unset _CAPS

# -- Pre-flight checks --
if [ ! -d "$DATAPATH_SINGLE" ]; then
  echo "ERROR: benchmark input data not found: $DATAPATH_SINGLE"
  exit 1
fi
if [ ! -f "$META_SINGLE" ]; then
  echo "ERROR: single-sample metadata not found: $META_SINGLE"
  echo "       Run test_bayesspace.sh --generate-reference first."
  exit 1
fi

# -- Determine reference generation mode --
if [ "$GENERATE_REFERENCE" = true ]; then
  if [ -f "$CONTAINER" ]; then
    REF_FLAG="--container $CONTAINER"
    echo "INFO: Generating reference baselines using container: $CONTAINER"
  elif [ "${DE_ANALYSIS_NATIVE_AVAILABLE:-false}" = true ]; then
    REF_FLAG="--no-container"
    echo "INFO: Generating reference baselines using native R."
  else
    echo "ERROR: Cannot generate reference — container not found and native DE analysis not available."
    exit 1
  fi
fi

# -- Default validation: check container and baselines --
if [ "$GENERATE_REFERENCE" = false ]; then
  if [ ! -f "$CONTAINER" ]; then
    echo "ERROR: container not found: $CONTAINER"
    echo "       Build with: bash containers/build_r45_container.sh [--force]"
    exit 1
  fi
  for _f in "$EXPECTED_SINGLE_ALL" "$EXPECTED_SINGLE_TOP" \
            "$EXPECTED_SINGLE_DE_ALL" "$EXPECTED_SINGLE_DE_CLUSTER"; do
    if [ ! -f "$_f" ]; then
      echo "ERROR: baseline not found: $_f"
      echo "       Run with --generate-reference first."
      exit 1
    fi
  done
  if [ -f "$META_JOINT" ]; then
    for _f in "$EXPECTED_JOINT_ALL" "$EXPECTED_JOINT_TOP" \
              "$EXPECTED_JOINT_DE_ALL" "$EXPECTED_JOINT_DE_CLUSTER"; do
      if [ ! -f "$_f" ]; then
        echo "ERROR: baseline not found: $_f"
        echo "       Run with --generate-reference first."
        exit 1
      fi
    done
  fi
  unset _f
fi

# ============================================================
# -- Single-sample test --
# ============================================================
echo ""
echo "=== DE Analysis: single-sample mode ==="

if [ "$GENERATE_REFERENCE" = true ]; then
  _REF_TMP="${WORKSPACE_ROOT}/local/outputs/de_analysis_reference_gen/single"
  mkdir -p "$_REF_TMP"
  # shellcheck disable=SC2086
  bash "$RUNNER" \
    --datapath "$DATAPATH_SINGLE" \
    --metapath "$META_SINGLE" \
    --outdir   "$_REF_TMP" \
    --despace \
    $REF_FLAG

  for _f in seurat_cluster_markers_all.csv seurat_cluster_markers_top50.csv \
            despace_results_all.csv despace_results_byCluster.csv; do
    if [ ! -f "$_REF_TMP/$_f" ]; then
      echo "ERROR: single-sample reference output not produced: $_f"
      exit 1
    fi
  done
  unset _f
  cp "$_REF_TMP/seurat_cluster_markers_all.csv"   "$EXPECTED_SINGLE_ALL"
  cp "$_REF_TMP/seurat_cluster_markers_top50.csv" "$EXPECTED_SINGLE_TOP"
  cp "$_REF_TMP/despace_results_all.csv"          "$EXPECTED_SINGLE_DE_ALL"
  cp "$_REF_TMP/despace_results_byCluster.csv"    "$EXPECTED_SINGLE_DE_CLUSTER"
  echo "Saved single-sample baselines:"
  echo "  $EXPECTED_SINGLE_ALL"
  echo "  $EXPECTED_SINGLE_TOP"
  echo "  $EXPECTED_SINGLE_DE_ALL"
  echo "  $EXPECTED_SINGLE_DE_CLUSTER"
else
  mkdir -p "$OUTDIR_SINGLE"
  bash "$RUNNER" \
    --datapath  "$DATAPATH_SINGLE" \
    --metapath  "$META_SINGLE" \
    --outdir    "$OUTDIR_SINGLE" \
    --despace \
    --container "$CONTAINER"

  _validate_md5 "$OUTDIR_SINGLE/seurat_cluster_markers_all.csv"   "$EXPECTED_SINGLE_ALL"        "seurat_cluster_markers_all.csv (single)"
  _validate_md5 "$OUTDIR_SINGLE/seurat_cluster_markers_top50.csv" "$EXPECTED_SINGLE_TOP"        "seurat_cluster_markers_top50.csv (single)"
  _validate_md5 "$OUTDIR_SINGLE/despace_results_all.csv"          "$EXPECTED_SINGLE_DE_ALL"     "despace_results_all.csv (single)"
  _validate_md5 "$OUTDIR_SINGLE/despace_results_byCluster.csv"    "$EXPECTED_SINGLE_DE_CLUSTER" "despace_results_byCluster.csv (single)"
fi

# ============================================================
# -- Joint (multi-sample) test --
# ============================================================
echo ""
echo "=== DE Analysis: joint (multi-sample) mode ==="

if [ ! -f "$META_JOINT" ]; then
  echo "SKIP: joint-mode metadata not found: $META_JOINT"
  echo "      Commit test_coldata_joint.csv to expected_outputs to enable joint testing."
else
  if [ "$GENERATE_REFERENCE" = true ]; then
    _REF_TMP="${WORKSPACE_ROOT}/local/outputs/de_analysis_reference_gen/joint"
    mkdir -p "$_REF_TMP"
    # shellcheck disable=SC2086
    bash "$RUNNER" \
      --datapath "$DATAPATH_JOINT" \
      --metapath "$META_JOINT" \
      --outdir   "$_REF_TMP" \
      --despace \
      $REF_FLAG

    for _f in seurat_cluster_markers_all.csv seurat_cluster_markers_top50.csv \
              despace_results_all.csv despace_results_byCluster.csv; do
      if [ ! -f "$_REF_TMP/$_f" ]; then
        echo "ERROR: joint-mode reference output not produced: $_f"
        exit 1
      fi
    done
    unset _f
    cp "$_REF_TMP/seurat_cluster_markers_all.csv"   "$EXPECTED_JOINT_ALL"
    cp "$_REF_TMP/seurat_cluster_markers_top50.csv" "$EXPECTED_JOINT_TOP"
    cp "$_REF_TMP/despace_results_all.csv"          "$EXPECTED_JOINT_DE_ALL"
    cp "$_REF_TMP/despace_results_byCluster.csv"    "$EXPECTED_JOINT_DE_CLUSTER"
    echo "Saved joint-mode baselines:"
    echo "  $EXPECTED_JOINT_ALL"
    echo "  $EXPECTED_JOINT_TOP"
    echo "  $EXPECTED_JOINT_DE_ALL"
    echo "  $EXPECTED_JOINT_DE_CLUSTER"
  else
    mkdir -p "$OUTDIR_JOINT"
    bash "$RUNNER" \
      --datapath  "$DATAPATH_JOINT" \
      --metapath  "$META_JOINT" \
      --outdir    "$OUTDIR_JOINT" \
      --despace \
      --container "$CONTAINER"

    _validate_md5 "$OUTDIR_JOINT/seurat_cluster_markers_all.csv"   "$EXPECTED_JOINT_ALL"        "seurat_cluster_markers_all.csv (joint)"
    _validate_md5 "$OUTDIR_JOINT/seurat_cluster_markers_top50.csv" "$EXPECTED_JOINT_TOP"        "seurat_cluster_markers_top50.csv (joint)"
    _validate_md5 "$OUTDIR_JOINT/despace_results_all.csv"          "$EXPECTED_JOINT_DE_ALL"     "despace_results_all.csv (joint)"
    _validate_md5 "$OUTDIR_JOINT/despace_results_byCluster.csv"    "$EXPECTED_JOINT_DE_CLUSTER" "despace_results_byCluster.csv (joint)"
  fi
fi

# ============================================================
# -- Summary --
# ============================================================
echo ""
if [ "$GENERATE_REFERENCE" = true ]; then
  echo "Reference baselines generated. Commit the following files:"
  echo "  git add $EXPECTED_SINGLE_ALL"
  echo "  git add $EXPECTED_SINGLE_TOP"
  echo "  git add $EXPECTED_SINGLE_DE_ALL"
  echo "  git add $EXPECTED_SINGLE_DE_CLUSTER"
  if [ -f "$META_JOINT" ]; then
    echo "  git add $EXPECTED_JOINT_ALL"
    echo "  git add $EXPECTED_JOINT_TOP"
    echo "  git add $EXPECTED_JOINT_DE_ALL"
    echo "  git add $EXPECTED_JOINT_DE_CLUSTER"
  fi
  echo "  git commit -m 'chore(benchmarks): add DE analysis reference baselines'"
else
  if [ "$FAILURES" -eq 0 ]; then
    echo "All DE analysis tests passed."
    exit 0
  else
    echo "$FAILURES test(s) failed."
    exit 1
  fi
fi
