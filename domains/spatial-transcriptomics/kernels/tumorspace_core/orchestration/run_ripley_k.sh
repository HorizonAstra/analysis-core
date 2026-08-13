#!/bin/bash
#
# run_ripley_k.sh
#
# Step 3: Ripley's K Spatial Clustering Analysis (Job Array Version)
#
# Computes the border-corrected Ripley's K spatial clustering statistic for all
# internal nodes in the phylogenetic tree, using the R/spatstat implementation.
# Uses SLURM job arrays to process multiple SVD runs in parallel.
#
# This step produces allnodes_ripley.tsv, which is consumed by Step 4
# (run_spatial_optimize.sh, hyperparameter optimization). Step 4 will error loudly
# if this file is absent.
#
# Usage:
#   bash run_ripley_k.sh --dataset DATASET --account ACCOUNT --partition PARTITION \
#                        --input-base DIR --num-svd N \
#                        [--container PATH] [--test] [--mem SIZE]
#
# Required Arguments:
#   --dataset DATASET       Dataset name (e.g., GSE213688_GSM6592057)
#   --account ACCOUNT       SLURM account (e.g., pi-araman)
#   --partition PARTITION   SLURM partition (e.g., caslake)
#   --input-base DIR        Base directory containing Step 1-2 outputs (svd_run_N/ subdirs)
#                           Outputs will also be written here
#   --num-svd N            Number of SVD runs to process (default: 30)
#
# Optional Arguments:
#   --container PATH        Path to Singularity container directory or .sif file
#                           If directory: auto-appends tumorspace_r.sif
#   --test                  Test mode: only process 3 SVDs (1-3)
#   --mem SIZE             Memory per task (default: 16G; Ripley's K is memory-intensive)
#   --time TIME            Time limit (default: 01:00:00)
#   --input-dir DIR        Input data directory (reserved; currently unused)
#   --dependency JOB_ID    SLURM dependency (wait for this job before starting)
#
# Environment:
#   HPC mode: Uses system R installation
#   Container mode: Uses tumorspace_r.sif Singularity container (--container flag)
#
# Outputs (per SVD, written to input-base/svd_run_N/):
#   - allnodes_ripley.tsv: Ripley's K spatial statistics (Node, RipleySum, NodeSize)
#
# Resource Requirements:
#   - Memory: 16 GB (sufficient for datasets up to ~10K spots; adjust for larger)
#   - Time: ~5-30 min per SVD depending on node count and dataset size
#   - CPUs: 1 per task
#
# Example:
#   # Native mode (HPC)
#   bash run_ripley_k.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_step1_output \
#       --input-dir benchmarks/GSE213688_GSM6592057/input_data --test
#
#   # Container mode
#   bash run_ripley_k.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_step1_output \
#       --input-dir benchmarks/GSE213688_GSM6592057/input_data \
#       --container containers --test
#

set -e

# Load HPC cluster profile (exports module names; falls back to .example defaults)
_HPC_PROFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# Default values
DATASET=""
ACCOUNT=""
PARTITION=""
INPUT_BASE=""
INPUT_DIR=""
NUM_SVD=30
CONTAINER=""
TEST_MODE=false
MEM="16G"
TIME_LIMIT="01:00:00"
DEPENDENCY=""
WORKSPACE_ROOT=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dataset)
            DATASET="$2"
            shift 2
            ;;
        --account)
            ACCOUNT="$2"
            shift 2
            ;;
        --partition)
            PARTITION="$2"
            shift 2
            ;;
        --workspace-root)
            WORKSPACE_ROOT="$2"
            shift 2
            ;;
        --input-base)
            INPUT_BASE="$2"
            shift 2
            ;;
        --input-dir)
            INPUT_DIR="$2"
            shift 2
            ;;
        --num-svd)
            NUM_SVD="$2"
            shift 2
            ;;
        --container)
            CONTAINER="$2"
            shift 2
            ;;
        --test)
            TEST_MODE=true
            shift
            ;;
        --mem)
            MEM="$2"
            shift 2
            ;;
        --time)
            TIME_LIMIT="$2"
            shift 2
            ;;
        --dependency)
            DEPENDENCY="$2"
            shift 2
            ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$DATASET" ] || [ -z "$ACCOUNT" ] || [ -z "$PARTITION" ] || [ -z "$INPUT_BASE" ]; then
    echo "ERROR: Missing required arguments"
    echo ""
    echo "Required: --dataset, --account, --partition, --input-base"
    echo ""
    echo "Usage:"
    echo "  bash run_ripley_k.sh --dataset DATASET --account ACCOUNT --partition PARTITION \\"
    echo "                       --input-base DIR --input-dir DIR [--num-svd N] [--container PATH] [--test]"
    exit 1
fi

# Auto-derive workspace root if not provided
if [ -z "$WORKSPACE_ROOT" ]; then
    WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../.. && pwd)"
fi

if [ ! -d "$WORKSPACE_ROOT" ]; then
    echo "Error: Workspace root directory not found: $WORKSPACE_ROOT"
    exit 1
fi

# Script locations
R_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/R/compute_ripley_k.R"
CONTAINER_R_SCRIPT="/opt/workflows/R/compute_ripley_k.R"

# Determine mode
if [ -n "$CONTAINER" ]; then
    MODE="CONTAINER"
    # If directory provided, auto-append R SIF filename
    if [ -d "$CONTAINER" ]; then
        CONTAINER="$CONTAINER/tumorspace_r.sif"
    fi
    if [ ! -f "$CONTAINER" ]; then
        echo "Error: Container SIF file not found: $CONTAINER"
        exit 1
    fi
    CONTAINER=$(realpath "$CONTAINER")
else
    MODE="HPC"
fi

# Convert to absolute paths
INPUT_BASE=$(realpath "$INPUT_BASE")

if [ ! -d "$INPUT_BASE" ]; then
    echo "ERROR: Input base directory not found: $INPUT_BASE"
    exit 1
fi

# Resolve DATA_DIR (reserved; passed through for interface consistency)
DATA_DIR="${INPUT_DIR:-$INPUT_BASE}"
if [ -n "$INPUT_DIR" ]; then
    DATA_DIR=$(realpath "$INPUT_DIR")
fi

# Test mode: clean previous Ripley's K outputs to force fresh computation
if [ "$TEST_MODE" = true ]; then
    for i in $(seq 1 3); do
        SVD_DIR="$INPUT_BASE/svd_run_$i"
        if [ -d "$SVD_DIR" ]; then
            rm -f "$SVD_DIR/allnodes_ripley.tsv"
        fi
    done
    echo "TEST MODE: Cleaned allnodes_ripley.tsv for SVDs 1-3"
    echo ""
fi

# Test mode: limit to 3 SVDs
if [ "$TEST_MODE" = true ]; then
    NUM_SVD=3
    ARRAY_SPEC="1-3"
else
    ARRAY_SPEC="1-${NUM_SVD}"
fi

# Create logs directory
mkdir -p logs

# Generate timestamp for this run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create SLURM batch script
SBATCH_SCRIPT="./logs/step3_ripley_sbatch_${TIMESTAMP}.sh"

cat > "$SBATCH_SCRIPT" << 'HEREDOC_END'
#!/bin/bash
#SBATCH --job-name=step3_ripley
#SBATCH --output=logs/step3_ripley_%A_%a.out
#SBATCH --error=logs/step3_ripley_%A_%a.err
#SBATCH --array=ARRAY_SPEC_PLACEHOLDER
#SBATCH --time=TIME_LIMIT_PLACEHOLDER
#SBATCH --mem=MEM_PLACEHOLDER
#SBATCH --cpus-per-task=1
#SBATCH --account=ACCOUNT_PLACEHOLDER
#SBATCH --partition=PARTITION_PLACEHOLDER

set -euo pipefail

SVD_NUM=$SLURM_ARRAY_TASK_ID
SVD_DIR="INPUT_BASE_PLACEHOLDER/svd_run_${SVD_NUM}"
DATA_DIR="DATA_DIR_PLACEHOLDER"

# Required input files (from Step 2)
ALLNODES_LEAVES="$SVD_DIR/allnodes_leaves.tsv"

if [ ! -f "$ALLNODES_LEAVES" ]; then
    echo "ERROR: allnodes_leaves.tsv not found: $ALLNODES_LEAVES"
    echo "Ensure Step 2 (node extraction) has completed for SVD $SVD_NUM"
    exit 1
fi

echo "=============================================================================="
echo "Step 3: Ripley's K Spatial Clustering - SVD $SVD_NUM"
echo "=============================================================================="
echo "Job ID:       ${SLURM_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
echo "Node:         $(hostname)"
echo "Started:      $(date)"
echo "Mode:         MODE_PLACEHOLDER"
echo "SVD Dir:      $SVD_DIR"
echo "Data Dir:     $DATA_DIR"
echo "Memory:       MEM_PLACEHOLDER"
echo "=============================================================================="
echo

START_TIME=$(date +%s)

MODE_EXEC_PLACEHOLDER

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo
echo "=============================================================================="
echo "Step 3 Complete - SVD $SVD_NUM"
echo "=============================================================================="
echo "Elapsed time: ${ELAPSED}s"
echo "Outputs written to: $SVD_DIR"
echo "  - allnodes_ripley.tsv"
echo "=============================================================================="

HEREDOC_END

# Substitute placeholders
sed -i "s|ARRAY_SPEC_PLACEHOLDER|${ARRAY_SPEC}|g"     "$SBATCH_SCRIPT"
sed -i "s|TIME_LIMIT_PLACEHOLDER|${TIME_LIMIT}|g"     "$SBATCH_SCRIPT"
sed -i "s|MEM_PLACEHOLDER|${MEM}|g"                   "$SBATCH_SCRIPT"
sed -i "s|ACCOUNT_PLACEHOLDER|${ACCOUNT}|g"           "$SBATCH_SCRIPT"
sed -i "s|PARTITION_PLACEHOLDER|${PARTITION}|g"       "$SBATCH_SCRIPT"
sed -i "s|INPUT_BASE_PLACEHOLDER|${INPUT_BASE}|g"     "$SBATCH_SCRIPT"
sed -i "s|DATA_DIR_PLACEHOLDER|${DATA_DIR}|g"         "$SBATCH_SCRIPT"
sed -i "s|MODE_PLACEHOLDER|${MODE}|g"                 "$SBATCH_SCRIPT"

# Append mode-specific execution command
if [ "$MODE" = "CONTAINER" ]; then
    cat >> "$SBATCH_SCRIPT" << EOF

# Container execution (R/spatstat)
${HPC_LOAD_SINGULARITY}

export SINGULARITYENV_R_LIBS_USER="/usr/local/lib/R/site-library"
export SINGULARITYENV_R_LIBS="/usr/local/lib/R/site-library:/usr/lib/R/site-library:/usr/lib/R/library"

singularity exec --no-home \\
    --bind "$INPUT_BASE:$INPUT_BASE" \\
    "$CONTAINER" \\
    Rscript "$CONTAINER_R_SCRIPT" \\
    "\$SVD_DIR" "\$DATA_DIR" "\$SVD_DIR"
EOF
else
    cat >> "$SBATCH_SCRIPT" << EOF

# Native HPC execution (R/spatstat)
${HPC_LOAD_R}

export R_LIBS_USER="${HPC_R_LIBS:+${HPC_R_LIBS}:}\${HOME}/R/x86_64-pc-linux-gnu-library/4.4:\${HOME}/R/x86_64-pc-linux-gnu-library/4.4.1:\${R_LIBS_USER:-}"

Rscript "$R_SCRIPT" "\$SVD_DIR" "\$DATA_DIR" "\$SVD_DIR"
EOF
fi

# Remove placeholder line
sed -i '/MODE_EXEC_PLACEHOLDER/d' "$SBATCH_SCRIPT"

# Submit job
echo "=============================================================================="
echo "Step 3: Ripley's K Job Submission"
echo "=============================================================================="
echo "Dataset:      $DATASET"
echo "Mode:         $MODE"
echo "Account:      $ACCOUNT"
echo "Partition:    $PARTITION"
echo "Input Base:   $INPUT_BASE"
echo "SVD Array:    $ARRAY_SPEC"
echo "Memory:       $MEM per task"
echo "Time Limit:   $TIME_LIMIT per task"
if [ "$MODE" = "CONTAINER" ]; then
    echo "Container:    $CONTAINER"
fi
if [ -n "$DEPENDENCY" ]; then
    echo "Dependency:   afterok:$DEPENDENCY"
fi
echo "=============================================================================="
echo

if [ -n "$DEPENDENCY" ]; then
    JOB_ID=$(sbatch --parsable --dependency=afterok:"$DEPENDENCY" "$SBATCH_SCRIPT")
else
    JOB_ID=$(sbatch --parsable "$SBATCH_SCRIPT")
fi

echo "✓ Job submitted successfully"
echo "Job ID: $JOB_ID"
echo "SLURM script saved to: $SBATCH_SCRIPT"
echo ""
echo "Monitor job status:"
echo "  squeue -j $JOB_ID --array"
echo "  tail -f ./logs/step3_ripley_${JOB_ID}_*.out"
echo ""

# Return job ID for downstream dependency management
echo "$JOB_ID"
