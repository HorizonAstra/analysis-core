#!/bin/bash
#
# run_svd_selection.sh
#
# SVD Selection: Find optimal SVD by maximum NodeCor value
#
# This script reads cor_dat_all.tsv from all SVD runs, identifies the SVD with
# the highest NodeCor (correlation between predicted and actual spot locations),
# and creates a symlink to enable downstream steps to process only the optimal SVD.
#
# Usage:
#   bash run_svd_selection.sh --dataset DATASET --account ACCOUNT --partition PARTITION \
#                            --input-base DIR --num-svd N [--keep-all] [--test]
#
# Required Arguments:
#   --dataset DATASET       Dataset name (e.g., GSE213688_GSM6592057)
#   --account ACCOUNT       SLURM account (e.g., pi-araman)
#   --partition PARTITION   SLURM partition (e.g., caslake)
#   --input-base DIR        Base directory containing svd_run_N/ subdirs with cor_dat_all.tsv
#   --num-svd N            Number of SVD runs to evaluate (default: 30)
#
# Optional Arguments:
#   --keep-all             Keep all SVD directories (default: delete non-optimal)
#   --test                 Test mode: only evaluate 3 SVDs
#   --mem SIZE            Memory (default: 2G)
#   --time TIME           Time limit (default: 00:05:00)
#
# Outputs (written to input-base/):
#   - optimal/ -> svd_run_X/  (symlink to optimal SVD directory)
#   - optimal_svd.txt         (selected SVD number and NodeCor value)
#
# The optimal SVD is selected by:
#   1. Reading first data row of cor_dat_all.tsv from each SVD (contains max NodeCor)
#   2. Finding SVD with highest NodeCor value
#   3. Creating symlink for downstream steps to use
#
# Resource Requirements:
#   - Memory: 2 GB (minimal - just reading TSV files)
#   - Time: <2 min
#   - CPUs: 1 (no parallelization)
#
# Example:
#   bash run_svd_selection.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_step1_output --test
#

set -e

# Default values
DATASET=""
ACCOUNT=""
PARTITION=""
INPUT_BASE=""
NUM_SVD=30
KEEP_ALL=false
TEST_MODE=false
MEM="2G"
TIME_LIMIT="00:05:00"
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
        --num-svd)
            NUM_SVD="$2"
            shift 2
            ;;
        --keep-all)
            KEEP_ALL=true
            shift
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
    echo "  bash run_svd_selection.sh --dataset DATASET --account ACCOUNT --partition PARTITION \\"
    echo "                           --input-base DIR [--num-svd N] [--keep-all] [--test]"
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
JULIA_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia/svd_selection.jl"

# Convert to absolute paths
INPUT_BASE=$(realpath "$INPUT_BASE")

# Check INPUT_BASE exists
if [ ! -d "$INPUT_BASE" ]; then
    echo "ERROR: Input base directory not found: $INPUT_BASE"
    exit 1
fi

# Test mode: Clean previous outputs to force fresh computation
if [ "$TEST_MODE" = true ]; then
    if [ -L "$INPUT_BASE/optimal" ]; then
        rm -f "$INPUT_BASE/optimal"
    fi
    if [ -f "$INPUT_BASE/optimal_svd.txt" ]; then
        rm -f "$INPUT_BASE/optimal_svd.txt"
    fi
    echo "TEST MODE: Cleaned SVD selection outputs"
    echo ""
fi

# Test mode: evaluate only 3 SVDs
if [ "$TEST_MODE" = true ]; then
    NUM_SVD=3
fi

# Create logs directory
mkdir -p logs

# Generate timestamp for this run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create SLURM batch script
SBATCH_SCRIPT="./logs/svd_selection_sbatch_${TIMESTAMP}.sh"

cat > "$SBATCH_SCRIPT" << 'HEREDOC_END'
#!/bin/bash
#SBATCH --job-name=svd_select
#SBATCH --output=logs/svd_selection_%j.out
#SBATCH --error=logs/svd_selection_%j.err
#SBATCH --time=TIME_LIMIT_PLACEHOLDER
#SBATCH --mem=MEM_PLACEHOLDER
#SBATCH --cpus-per-task=1
#SBATCH --account=ACCOUNT_PLACEHOLDER
#SBATCH --partition=PARTITION_PLACEHOLDER

set -euo pipefail

INPUT_BASE="INPUT_BASE_PLACEHOLDER"
NUM_SVD=NUM_SVD_PLACEHOLDER
KEEP_ALL=KEEP_ALL_PLACEHOLDER

# Print job information
echo "=============================================================================="
echo "SVD Selection: Find Optimal SVD by Maximum NodeCor"
echo "=============================================================================="
echo "Job ID:       $SLURM_JOB_ID"
echo "Node:         $(hostname)"
echo "Started:      $(date)"
echo "Input Base:   $INPUT_BASE"
echo "Num SVDs:     $NUM_SVD"
echo "Keep All:     $KEEP_ALL"
echo "=============================================================================="
echo

# Record start time
START_TIME=$(date +%s)

# Find optimal SVD by maximum NodeCor
echo "[1/3] Scanning SVD runs for NodeCor values..."
BEST_SVD=""
BEST_NODECOR=-1
BEST_SUPPORT=""
BEST_SPATIAL=""
BEST_KNN=""

for i in $(seq 1 $NUM_SVD); do
    COR_FILE="$INPUT_BASE/svd_run_${i}/cor_dat_all.tsv"
    
    if [ ! -f "$COR_FILE" ]; then
        echo "  ⚠ Warning: cor_dat_all.tsv not found for SVD $i, skipping"
        continue
    fi
    
    # Extract first data row (row 2): NodeCor, Run, SVD_end, KNN_spatial_run, Prune, Spatial, KNN
    DATA_ROW=$(head -2 "$COR_FILE" | tail -1)
    NODECOR=$(echo "$DATA_ROW" | cut -f1)
    SUPPORT=$(echo "$DATA_ROW" | cut -f5)
    SPATIAL=$(echo "$DATA_ROW" | cut -f6)
    KNN=$(echo "$DATA_ROW" | cut -f7)
    
    echo "  SVD $i: NodeCor = $NODECOR"
    
    # Compare NodeCor values (using bc for floating point comparison)
    if (( $(echo "$NODECOR > $BEST_NODECOR" | bc -l) )); then
        BEST_SVD=$i
        BEST_NODECOR=$NODECOR
        BEST_SUPPORT=$SUPPORT
        BEST_SPATIAL=$SPATIAL
        BEST_KNN=$KNN
    fi
done

if [ -z "$BEST_SVD" ]; then
    echo "ERROR: No valid SVD runs found with cor_dat_all.tsv"
    exit 1
fi

echo ""
echo "Selected optimal SVD: $BEST_SVD"
echo "  NodeCor (correlation):    $BEST_NODECOR"
echo "  Support threshold:        $BEST_SUPPORT"
echo "  Spatial threshold:        $BEST_SPATIAL"
echo "  K nearest neighbors:      $BEST_KNN"
echo ""

# Copy outputs from optimal SVD to optimal/ directory
echo "[2/3] Copying outputs from optimal SVD to optimal directory..."
OPTIMAL_DIR="$INPUT_BASE/optimal"
SOURCE_DIR="$INPUT_BASE/svd_run_${BEST_SVD}"

# Remove existing optimal directory if present
if [ -e "$OPTIMAL_DIR" ]; then
    echo "  Removing existing optimal directory"
    rm -rf "$OPTIMAL_DIR"
fi

# Create fresh optimal directory
mkdir -p "$OPTIMAL_DIR"

# Copy key output files needed by downstream steps (only if they exist)
# From spatial analysis steps (always present)
cp "$SOURCE_DIR/OptimalTree.nw" "$OPTIMAL_DIR/" || true
cp "$SOURCE_DIR/OptimalTree_preprune.nw" "$OPTIMAL_DIR/" || true
cp "$SOURCE_DIR/SPI_Dist_mtx.txt" "$OPTIMAL_DIR/" || true

# From node analysis steps (usually present)
[ -f "$SOURCE_DIR/OptimalTree_labelpreprune.nw" ] && cp "$SOURCE_DIR/OptimalTree_labelpreprune.nw" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/tree_edges.tsv" ] && cp "$SOURCE_DIR/tree_edges.tsv" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/tree_nodes.tsv" ] && cp "$SOURCE_DIR/tree_nodes.tsv" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/allnodes_leaves.tsv" ] && cp "$SOURCE_DIR/allnodes_leaves.tsv" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/allnodes_parents.tsv" ] && cp "$SOURCE_DIR/allnodes_parents.tsv" "$OPTIMAL_DIR/" || true

# From tree pruning step (optional, only exists if prune step was run)
[ -f "$SOURCE_DIR/OptimalTree_pruned.nw" ] && cp "$SOURCE_DIR/OptimalTree_pruned.nw" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/OptimalTree_pruned_node_compare_list.txt" ] && cp "$SOURCE_DIR/OptimalTree_pruned_node_compare_list.txt" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/OptimalTree_pruned_node_compare_leaves.txt" ] && cp "$SOURCE_DIR/OptimalTree_pruned_node_compare_leaves.txt" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/OptimalTree_pruned_node_info.txt" ] && cp "$SOURCE_DIR/OptimalTree_pruned_node_info.txt" "$OPTIMAL_DIR/" || true

echo "  ✓ Copied outputs from svd_run_${BEST_SVD} to $OPTIMAL_DIR"

# Write optimal SVD info to file
OPTIMAL_INFO="$INPUT_BASE/optimal_svd.txt"
cat > "$OPTIMAL_INFO" << EOF
# Optimal SVD Selection Results
# Generated: $(date)
# Dataset: DATASET_PLACEHOLDER

SVD_Number: $BEST_SVD
NodeCor: $BEST_NODECOR
Support_Threshold: $BEST_SUPPORT
Spatial_Threshold: $BEST_SPATIAL
KNN: $BEST_KNN

# NodeCor represents the correlation between predicted and actual spot locations.
# Higher values indicate better spatial clustering performance.
# Range: 0.0 (no correlation) to 1.0 (perfect correlation)
EOF

echo "  ✓ Wrote: $OPTIMAL_INFO"

# Optionally delete non-optimal SVD directories to save space
echo ""
if [ "$KEEP_ALL" = "false" ]; then
    echo "[3/3] Deleting non-optimal SVD directories..."
    DELETED=0
    for i in $(seq 1 $NUM_SVD); do
        if [ $i -ne $BEST_SVD ]; then
            SVD_DIR="$INPUT_BASE/svd_run_${i}"
            if [ -d "$SVD_DIR" ]; then
                rm -rf "$SVD_DIR"
                echo "  Deleted: svd_run_${i}"
                DELETED=$((DELETED + 1))
            fi
        fi
    done
    echo "  ✓ Deleted $DELETED non-optimal SVD directories"
else
    echo "[3/3] Keeping all SVD directories (--keep-all specified)"
fi

# Record completion
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "=============================================================================="
echo "SVD Selection Complete"
echo "=============================================================================="
echo "Elapsed time: ${ELAPSED}s"
echo "Optimal SVD:  $BEST_SVD (NodeCor = $BEST_NODECOR)"
echo "Output dir:   $OPTIMAL_DIR"
echo "Info file:    $OPTIMAL_INFO"
echo ""
echo "Next steps:"
echo "  - Use optimal/ directory for downstream analysis (Steps 6-8)"
echo "  - Read optimal_svd.txt for selected hyperparameters"
echo "=============================================================================="

HEREDOC_END

# Substitute placeholders
sed -i "s|TIME_LIMIT_PLACEHOLDER|${TIME_LIMIT}|g" "$SBATCH_SCRIPT"
sed -i "s|MEM_PLACEHOLDER|${MEM}|g" "$SBATCH_SCRIPT"
sed -i "s|ACCOUNT_PLACEHOLDER|${ACCOUNT}|g" "$SBATCH_SCRIPT"
sed -i "s|PARTITION_PLACEHOLDER|${PARTITION}|g" "$SBATCH_SCRIPT"
sed -i "s|INPUT_BASE_PLACEHOLDER|${INPUT_BASE}|g" "$SBATCH_SCRIPT"
sed -i "s|NUM_SVD_PLACEHOLDER|${NUM_SVD}|g" "$SBATCH_SCRIPT"
sed -i "s|KEEP_ALL_PLACEHOLDER|${KEEP_ALL}|g" "$SBATCH_SCRIPT"
sed -i "s|DATASET_PLACEHOLDER|${DATASET}|g" "$SBATCH_SCRIPT"

# Submit job
echo "=============================================================================="
echo "SVD Selection Job Submission"
echo "=============================================================================="
echo "Dataset:      $DATASET"
echo "Account:      $ACCOUNT"
echo "Partition:    $PARTITION"
echo "Input Base:   $INPUT_BASE"
echo "Num SVDs:     $NUM_SVD"
echo "Keep All:     $KEEP_ALL"
echo "Memory:       $MEM"
echo "Time Limit:   $TIME_LIMIT"
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
echo "  tail -f ./logs/svd_selection_${JOB_ID}.out"
echo ""
echo "Check completion:"
echo "  sacct -j $JOB_ID --format=JobID,State,ExitCode,Elapsed"
echo ""
echo "After completion, check results:"
echo "  cat $INPUT_BASE/optimal_svd.txt"
echo "  ls -la $INPUT_BASE/optimal"
echo ""

# Return job ID for downstream dependency management
echo "$JOB_ID"