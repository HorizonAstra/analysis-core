#!/bin/bash
#
# run_phylo_tree_prune.sh
#
# Step 4: Tree Pruning Orchestration Script (Job Array Version)
#
# This script prunes phylogenetic trees based on optimal support thresholds
# determined in Step 3. Uses SLURM job arrays to process multiple SVD runs in parallel.
#
# The support threshold is automatically extracted from cor_dat_all.tsv (first data row,
# "Prune" column), which contains the optimal hyperparameters from Step 3.
#
# Usage:
#   bash run_phylo_tree_prune.sh --dataset DATASET --account ACCOUNT --partition PARTITION \
#                                --input-base DIR --num-svd N \
#                                [--container PATH] [--test] [--mem SIZE]
#
# Required Arguments:
#   --dataset DATASET       Dataset name (e.g., GSE213688_GSM6592057)
#   --account ACCOUNT       SLURM account (e.g., pi-araman)
#   --partition PARTITION   SLURM partition (e.g., caslake)
#   --input-base DIR        Base directory containing Step 1-3 outputs (svd_run_N/ subdirs)
#                           Outputs will also be written here
#   --num-svd N            Number of SVD runs to process (default: 30)
#
# Optional Arguments:
#   --container PATH        Path to Singularity container (enables container mode)
#   --test                  Test mode: only process 3 SVDs (1-3)
#   --mem SIZE             Memory per task (default: 4G)
#   --time TIME            Time limit (default: 00:15:00)
#
# Environment:
#   HPC mode: Uses system Julia installation
#   Container mode: Uses Singularity container (--container flag)
#
# Outputs (per SVD, written to input-base/svd_run_N/):
#   - OptimalTree_preprune.nw: Tree before pruning (for QC)
#   - OptimalTree.nw: Pruned tree (nodes with support < threshold removed)
#
# Resource Requirements:
#   - Memory: 4 GB (sufficient for most datasets)
#   - Time: <5 min per SVD
#   - CPUs: 1 per task (no intra-task parallelization)
#
# Example:
#   # Native mode (HPC)
#   bash run_phylo_tree_prune.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_step1_output --test
#
#   # Container mode
#   bash run_phylo_tree_prune.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_step1_output \
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
NUM_SVD=30
CONTAINER=""
TEST_MODE=false
MEM="4G"
TIME_LIMIT="00:15:00"
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
    echo "  bash run_phylo_tree_prune.sh --dataset DATASET --account ACCOUNT --partition PARTITION \\"
    echo "                               --input-base DIR [--num-svd N] [--container PATH] [--test]"
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
JULIA_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia/phylo_tree_prune.jl"
CONTAINER_JULIA_SCRIPT="/opt/workflows/julia/phylo_tree_prune.jl"

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
            rm -f "$SVD_DIR/OptimalTree.nw" "$SVD_DIR/OptimalTree_preprune.nw"
        fi
    done
    echo "TEST MODE: Cleaned tree pruning outputs for SVDs 1-3"
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
SBATCH_SCRIPT="./logs/step4_sbatch_${TIMESTAMP}.sh"

cat > "$SBATCH_SCRIPT" << 'HEREDOC_END'
#!/bin/bash
#SBATCH --job-name=step4_prune
#SBATCH --output=logs/step4_%A_%a.out
#SBATCH --error=logs/step4_%A_%a.err
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
SVD_DIR="INPUT_BASE_PLACEHOLDER/svd_run_${SVD_NUM}"

# Required input files (from Step 3)
TREE_LABELPREPRUNE="$SVD_DIR/OptimalTree_labelpreprune.nw"
COR_DAT_ALL="$SVD_DIR/cor_dat_all.tsv"

# Verify inputs
if [ ! -f "$TREE_LABELPREPRUNE" ]; then
    echo "ERROR: Tree file not found: $TREE_LABELPREPRUNE"
    echo "Ensure Step 3 has completed for SVD $SVD_NUM"
    exit 1
fi

if [ ! -f "$COR_DAT_ALL" ]; then
    echo "ERROR: Hyperparameter file not found: $COR_DAT_ALL"
    echo "Ensure Step 3 has completed for SVD $SVD_NUM"
    exit 1
fi

# Extract optimal support threshold from cor_dat_all.tsv
# First data row (row 2), column 5 (Prune)
SUPPORT_THRESHOLD=$(head -2 "$COR_DAT_ALL" | tail -1 | cut -f5)

if [ -z "$SUPPORT_THRESHOLD" ]; then
    echo "ERROR: Could not extract support threshold from $COR_DAT_ALL"
    exit 1
fi

# Print job information
echo "=============================================================================="
echo "Step 4: Tree Pruning - SVD $SVD_NUM"
echo "=============================================================================="
echo "Job ID:             ${SLURM_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
echo "Node:               $(hostname)"
echo "Started:            $(date)"
echo "Mode:               MODE_PLACEHOLDER"
echo "SVD Dir:            $SVD_DIR"
echo "Tree Input:         $TREE_LABELPREPRUNE"
echo "Support Threshold:  $SUPPORT_THRESHOLD"
echo "Memory:             MEM_PLACEHOLDER"
echo "CPUs:               $SLURM_CPUS_PER_TASK"
echo "=============================================================================="
echo

# Record start time
START_TIME=$(date +%s)

# Run tree pruning
MODE_EXEC_PLACEHOLDER

# Record completion
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo
echo "=============================================================================="
echo "Step 4 Complete - SVD $SVD_NUM"
echo "=============================================================================="
echo "Elapsed time: ${ELAPSED}s"
echo "Outputs written to: $SVD_DIR"
echo "  - OptimalTree_preprune.nw (before pruning)"
echo "  - OptimalTree.nw (after pruning)"
echo "=============================================================================="

HEREDOC_END

# Substitute placeholders
sed -i "s|ARRAY_SPEC_PLACEHOLDER|${ARRAY_SPEC}|g" "$SBATCH_SCRIPT"
sed -i "s|TIME_LIMIT_PLACEHOLDER|${TIME_LIMIT}|g" "$SBATCH_SCRIPT"
sed -i "s|MEM_PLACEHOLDER|${MEM}|g" "$SBATCH_SCRIPT"
sed -i "s|ACCOUNT_PLACEHOLDER|${ACCOUNT}|g" "$SBATCH_SCRIPT"
sed -i "s|PARTITION_PLACEHOLDER|${PARTITION}|g" "$SBATCH_SCRIPT"
sed -i "s|INPUT_BASE_PLACEHOLDER|${INPUT_BASE}|g" "$SBATCH_SCRIPT"
sed -i "s|MODE_PLACEHOLDER|${MODE}|g" "$SBATCH_SCRIPT"

# Generate mode-specific execution command
if [ "$MODE" = "CONTAINER" ]; then
    # Write execution block for container mode
    cat >> "$SBATCH_SCRIPT" << EOF

# Container execution
${HPC_LOAD_SINGULARITY}

singularity exec --no-home --cleanenv \\
    --env JULIA_DEPOT_PATH=/tmp/julia_depot:/opt/julia_depot \\
    --bind "$INPUT_BASE:$INPUT_BASE" \\
    "$CONTAINER" \\
    julia "$CONTAINER_JULIA_SCRIPT" "\$SVD_DIR" "\$SVD_DIR" "\$SUPPORT_THRESHOLD"
EOF
else
    # Write execution block for native mode
    cat >> "$SBATCH_SCRIPT" << EOF

# Native execution
${HPC_LOAD_JULIA}
julia "$JULIA_SCRIPT" "\$SVD_DIR" "\$SVD_DIR" "\$SUPPORT_THRESHOLD"
EOF
fi

# Remove placeholder line
sed -i '/MODE_EXEC_PLACEHOLDER/d' "$SBATCH_SCRIPT"

# Submit job
echo "=============================================================================="
echo "Step 4: Tree Pruning Job Submission"
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
echo "  tail -f ./logs/step4_${JOB_ID}_*.out"
echo ""
echo "Check completion:"
echo "  sacct -j $JOB_ID --format=JobID,State,ExitCode,Elapsed"
echo ""

# Return job ID for downstream dependency management
echo "$JOB_ID"