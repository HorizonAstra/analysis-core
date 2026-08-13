#!/bin/bash
#
# run_spatial_optimize.sh
#
# Step 3: Spatial Clustering and Hyperparameter Optimization (Job Array Version)
#
# This script computes Ripley's K spatial statistics and performs hyperparameter
# optimization to find optimal settings for spatial clustering. Uses SLURM job arrays
# to process multiple SVD runs in parallel.
#
# Usage:
#   bash run_spatial_optimize.sh --dataset DATASET --account ACCOUNT --partition PARTITION \
#                                --input-base DIR --num-svd N \
#                                [--container PATH] [--test] [--mem SIZE]
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
#   --container PATH        Path to Singularity container (enables container mode)
#   --test                  Test mode: only process 3 SVDs (1-3)
#   --mem SIZE             Memory per task (default: 16G)
#   --time TIME            Time limit (default: 02:00:00)
#   --input-dir DIR        Input data directory (for barcodes_positions.txt)
#
# Environment:
#   HPC mode: Uses system Julia installation
#   Container mode: Uses Singularity container (--container flag)
#
# Outputs (per SVD, written to input-base/svd_run_N/):
#   - allnodes_ripley.tsv: Ripley's K spatial statistics for all internal nodes
#   - cor_dat_all.tsv: Hyperparameter search results (sorted by NodeCor descending)
#   - allnodes_leaves_passingNodes.tsv: Node filtering results with ParentPass labels
#   - predicted_spot_locations.tsv: Spot location predictions at optimal hyperparameters
#   - OptimalTree_labelpreprune.nw: Tree relabeled with ParentPass values
#   - SG_depths.txt: SG depth distribution for Pipeline Report
#
# Key Output:
#   cor_dat_all.tsv contains hyperparameter search results. First data row has:
#   - NodeCor: Correlation between predicted and actual spot locations (KEY METRIC)
#   - SupportThresh: Optimal bootstrap support threshold
#   - SpatialThresh: Optimal spatial clustering threshold
#   - KNN: Optimal K nearest neighbors
#
# Resource Requirements:
#   - Memory: 16 GB (sufficient for datasets up to ~10K spots)
#   - Time: 1-2 hours per SVD (depends on hyperparameter search space)
#   - CPUs: 1 per task (no intra-task parallelization)
#
# Example:
#   # Native mode (HPC)
#   bash run_spatial_optimize.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_step1_output \
#       --input-dir benchmarks/GSE213688_GSM6592057/input_data --test
#
#   # Container mode
#   bash run_spatial_optimize.sh --dataset GSE213688_GSM6592057 \
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
FIXED_SEED=""
MEM="16G"
TIME_LIMIT="02:00:00"
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
            FIXED_SEED="1000"
            shift
            ;;
        --fixed-seed)
            FIXED_SEED="$2"
            shift 2
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
    echo "  bash run_spatial_optimize.sh --dataset DATASET --account ACCOUNT --partition PARTITION \\"
    echo "                               --input-base DIR --input-dir DIR [--num-svd N] [--container PATH] [--test]"
    exit 1
fi

# Auto-derive workspace root if not provided
if [ -z "$WORKSPACE_ROOT" ]; then
    WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../.. && pwd)"
fi

# Validate workspace root
if [ ! -d "$WORKSPACE_ROOT" ]; then
    echo "Error: Workspace root directory not found: $WORKSPACE_ROOT"
    exit 1
fi

# Workspace and script locations
JULIA_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia/spatial_optimize.jl"
CONTAINER_JULIA_SCRIPT="/opt/workflows/julia/spatial_optimize.jl"

# Determine mode
if [ -n "$CONTAINER" ]; then
    MODE="CONTAINER"
    # If directory provided, auto-append .sif filename
    if [ -d "$CONTAINER" ]; then
        CONTAINER="$CONTAINER/julia_1.9_with_gotree.sif"
    fi
    # Validate .sif file exists
    if [ ! -f "$CONTAINER" ]; then
        echo "Error: Container SIF file not found: $CONTAINER"
        echo "Expected a .sif file, not a directory"
        exit 1
    fi
    # Convert to absolute path for SBATCH script (compute nodes may have different working directory)
    CONTAINER=$(realpath "$CONTAINER")
else
    MODE="HPC"
fi

# Convert to absolute paths
INPUT_BASE=$(realpath "$INPUT_BASE")

# Check INPUT_BASE exists
if [ ! -d "$INPUT_BASE" ]; then
    echo "ERROR: Input base directory not found: $INPUT_BASE"
    exit 1
fi

# Test mode: Clean previous outputs to force fresh computation
if [ "$TEST_MODE" = true ]; then
    for i in $(seq 1 3); do
        SVD_DIR="$INPUT_BASE/svd_run_$i"
        if [ -d "$SVD_DIR" ]; then
            rm -f "$SVD_DIR/cor_dat_all.tsv" "$SVD_DIR/allnodes_ripley.tsv" \
                  "$SVD_DIR/predicted_spot_locations.tsv" "$SVD_DIR/OptimalTree_labelpreprune.nw"
        fi
    done
    echo "TEST MODE: Cleaned spatial optimization outputs for SVDs 1-3"
    echo ""
fi

# Find barcodes_positions.txt
BARCODE_POSITIONS=""
if [ -n "$INPUT_DIR" ]; then
    INPUT_DIR=$(realpath "$INPUT_DIR")
    BARCODE_POSITIONS="$INPUT_DIR/barcodes_positions.txt"
    if [ ! -f "$BARCODE_POSITIONS" ]; then
        echo "ERROR: Barcode positions file not found: $BARCODE_POSITIONS"
        exit 1
    fi
else
    # Try to find in INPUT_BASE
    if [ -f "$INPUT_BASE/barcodes_positions.txt" ]; then
        BARCODE_POSITIONS="$INPUT_BASE/barcodes_positions.txt"
    else
        echo "ERROR: Cannot locate barcodes_positions.txt"
        echo "Provide --input-dir pointing to directory containing barcodes_positions.txt"
        exit 1
    fi
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
SBATCH_SCRIPT="./logs/step3_sbatch_${TIMESTAMP}.sh"

cat > "$SBATCH_SCRIPT" << 'HEREDOC_END'
#!/bin/bash
#SBATCH --job-name=step3_spatial
#SBATCH --output=logs/step3_%A_%a.out
#SBATCH --error=logs/step3_%A_%a.err
#SBATCH --array=ARRAY_SPEC_PLACEHOLDER
#SBATCH --time=TIME_LIMIT_PLACEHOLDER
#SBATCH --mem=MEM_PLACEHOLDER
#SBATCH --cpus-per-task=1
#SBATCH --account=ACCOUNT_PLACEHOLDER
#SBATCH --partition=PARTITION_PLACEHOLDER

set -euo pipefail

# Get SVD number from array task ID
SVD_NUM=$SLURM_ARRAY_TASK_ID

# Directories for this SVD
# Note: spatial_optimize.jl reads from step2_output_dir and writes to output_dir
# We use the same directory for both
SVD_DIR="INPUT_BASE_PLACEHOLDER/svd_run_${SVD_NUM}"
DATA_DIR="DATA_DIR_PLACEHOLDER"

# Required input files (from Steps 1-2)
# Use Tree_support.nw (with bootstrap support values) for spatial optimization
TREE_FILE="$SVD_DIR/Tree_support.nw"
ALLNODES_LEAVES="$SVD_DIR/allnodes_leaves.tsv"
ALLNODES_PARENTS="$SVD_DIR/allnodes_parents.tsv"
SPECTRAL_DIST="$SVD_DIR/spectral_dist_melt.tsv"
TREE_NODES="$SVD_DIR/tree_nodes.tsv"
BARCODE_POSITIONS="$DATA_DIR/barcodes_positions.txt"

# Verify Tree_support.nw exists (required for hyperparameter optimization)
if [ ! -f "$TREE_FILE" ]; then
    echo "ERROR: Tree_support.nw not found: $TREE_FILE"
    echo "Ensure Step 1b (bootstrap support computation) has completed for SVD $SVD_NUM"
    echo ""
    echo "Tree_support.nw is REQUIRED for spatial optimization because:"
    echo "  - Contains bootstrap support values (0.0-1.0) for internal nodes"
    echo "  - Prune hyperparameter filters nodes by bootstrap confidence"
    echo "  - Without it, all nodes default to Support=1.0, making Prune ineffective"
    echo ""
    echo "To generate Tree_support.nw:"
    echo "  1. Verify Tree_0.nw and Tree_1.nw...Tree_N.nw exist"
    echo "  2. Run: bash run_phylo_bootstrap_support.sh <args>"
    exit 1
fi

if [ ! -f "$ALLNODES_LEAVES" ] || [ ! -f "$ALLNODES_PARENTS" ] || \
   [ ! -f "$SPECTRAL_DIST" ] || [ ! -f "$TREE_NODES" ]; then
    echo "ERROR: Step 2 outputs not found in $SVD_DIR"
    echo "Required files: allnodes_leaves.tsv, allnodes_parents.tsv, spectral_dist_melt.tsv, tree_nodes.tsv"
    echo "Ensure Step 2 has completed for SVD $SVD_NUM"
    exit 1
fi

if [ ! -f "$BARCODE_POSITIONS" ]; then
    echo "ERROR: Barcode positions file not found: $BARCODE_POSITIONS"
    exit 1
fi

# Print job information
echo "=============================================================================="
echo "Step 3: Spatial Optimization - SVD $SVD_NUM"
echo "=============================================================================="
echo "Job ID:       ${SLURM_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
echo "Node:         $(hostname)"
echo "Started:      $(date)"
echo "Mode:         MODE_PLACEHOLDER"
echo "SVD Dir:      $SVD_DIR"
echo "Data Dir:     $DATA_DIR"
echo "Tree File:    $TREE_FILE"
echo "Barcodes:     $BARCODE_POSITIONS"
echo "Memory:       MEM_PLACEHOLDER"
echo "CPUs:         $SLURM_CPUS_PER_TASK"
echo "=============================================================================="
echo

# Record start time
START_TIME=$(date +%s)

# Run spatial optimization
MODE_EXEC_PLACEHOLDER

# Record completion
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo
echo "=============================================================================="
echo "Step 3 Complete - SVD $SVD_NUM"
echo "=============================================================================="
echo "Elapsed time: ${ELAPSED}s"
echo "Outputs written to: $SVD_DIR"
echo "  - allnodes_ripley.tsv"
echo "  - cor_dat_all.tsv (NodeCor = correlation metric)"
echo "  - allnodes_leaves_passingNodes.tsv"
echo "  - predicted_spot_locations.tsv"
echo "  - OptimalTree_labelpreprune.nw"
echo "  - SG_depths.txt"
echo "=============================================================================="

HEREDOC_END

# Substitute placeholders
sed -i "s|ARRAY_SPEC_PLACEHOLDER|${ARRAY_SPEC}|g" "$SBATCH_SCRIPT"
sed -i "s|TIME_LIMIT_PLACEHOLDER|${TIME_LIMIT}|g" "$SBATCH_SCRIPT"
sed -i "s|MEM_PLACEHOLDER|${MEM}|g" "$SBATCH_SCRIPT"
sed -i "s|ACCOUNT_PLACEHOLDER|${ACCOUNT}|g" "$SBATCH_SCRIPT"
sed -i "s|PARTITION_PLACEHOLDER|${PARTITION}|g" "$SBATCH_SCRIPT"
sed -i "s|INPUT_BASE_PLACEHOLDER|${INPUT_BASE}|g" "$SBATCH_SCRIPT"
sed -i "s|DATA_DIR_PLACEHOLDER|$(dirname "$BARCODE_POSITIONS")|g" "$SBATCH_SCRIPT"
sed -i "s|MODE_PLACEHOLDER|${MODE}|g" "$SBATCH_SCRIPT"

# Generate mode-specific execution command
if [ "$MODE" = "CONTAINER" ]; then
    # Write execution block for container mode
    cat >> "$SBATCH_SCRIPT" << EOF

# Container execution
${HPC_LOAD_SINGULARITY}

if [ -n "$FIXED_SEED" ]; then
    export TUMORSPACE_FIXED_SEED="$FIXED_SEED"
fi
singularity exec --no-home --cleanenv \\
    --env JULIA_DEPOT_PATH=/tmp/julia_depot:/opt/julia_depot \\
    --env TUMORSPACE_FIXED_SEED="\$TUMORSPACE_FIXED_SEED" \\
    --bind "$INPUT_BASE:$INPUT_BASE" \\
    --bind "$(dirname "$BARCODE_POSITIONS"):$(dirname "$BARCODE_POSITIONS")" \\
    "$CONTAINER" \\
    julia "$CONTAINER_JULIA_SCRIPT" "\$SVD_DIR" "\$DATA_DIR" "\$SVD_DIR"
EOF
else
    # Write execution block for native mode
    cat >> "$SBATCH_SCRIPT" << EOF

# Native execution
${HPC_LOAD_JULIA}
if [ -n "$FIXED_SEED" ]; then
    export TUMORSPACE_FIXED_SEED="$FIXED_SEED"
fi
julia "$JULIA_SCRIPT" "\$SVD_DIR" "\$DATA_DIR" "\$SVD_DIR"
EOF
fi

# Remove placeholder line
sed -i '/MODE_EXEC_PLACEHOLDER/d' "$SBATCH_SCRIPT"

# Submit job
echo "=============================================================================="
echo "Step 3: Spatial Optimization Job Submission"
echo "=============================================================================="
echo "Dataset:      $DATASET"
echo "Mode:         $MODE"
echo "Account:      $ACCOUNT"
echo "Partition:    $PARTITION"
echo "Input Base:   $INPUT_BASE"
echo "Data Dir:     $(dirname "$BARCODE_POSITIONS")"
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
    JOB_ID=$(sbatch --parsable --dependency=afterok:$DEPENDENCY "$SBATCH_SCRIPT")
else
    JOB_ID=$(sbatch --parsable "$SBATCH_SCRIPT")
fi

echo "✓ Job submitted successfully"
echo "Job ID: $JOB_ID"
echo "SLURM script saved to: $SBATCH_SCRIPT"
echo ""
echo "Monitor job status:"
echo "  squeue -j $JOB_ID -u \$USER"
echo "  squeue -j $JOB_ID --array"
echo "  tail -f ./logs/step3_${JOB_ID}_*.out"
echo ""
echo "Check completion:"
echo "  sacct -j $JOB_ID --format=JobID,State,ExitCode,Elapsed"
echo ""
echo "Check NodeCor (correlation metric) after completion:"
echo "  head -2 $INPUT_BASE/svd_run_1/cor_dat_all.tsv | tail -1 | cut -f2"
echo ""

# Return job ID for downstream dependency management
echo "$JOB_ID"