#!/bin/bash
#
# run_sg_depth_analysis.sh
#
# TumorSPACE Step 6b: SG GrowChain Depth Analysis
#
# Computes spatial group (SG) nesting depth using the "GrowChain" metric.
# This measures how many progressively larger spatial domains contain each SG
# by walking up the phylogenetic tree while parent interleaf distance >= node interleaf distance.
#
# Usage:
#   bash run_sg_depth_analysis.sh --dataset DATASET --account ACCOUNT --partition PARTITION \
#                                  --input-base DIR --data-dir DIR [OPTIONS]
#
# Required Arguments:
#   --dataset DATASET       Dataset name (e.g., GSE193460_GSM5808054_KP_1)
#   --account ACCOUNT       SLURM account (e.g., pi-araman)
#   --partition PARTITION   SLURM partition (e.g., caslake)
#   --input-base DIR        Base directory containing optimal/ subdirectory
#   --data-dir DIR          Directory containing barcodes_positions.txt
#
# Optional Arguments:
#   --mem SIZE              Memory allocation (default: 8G)
#   --time LIMIT            Time limit (default: 00:30:00)
#   --dependency JOB_ID     Wait for this job to complete before starting
#   --workspace-root DIR    Workspace root directory
#
# Inputs (in input-base/optimal/):
#   - OptimalTree_pruned_node_compare_list.txt      From Step 6 (SG pairs)
#   - allnodes_parents.tsv                          From Step 2 (parent relationships)
#   - allnodes_leaves.tsv                           From Step 2 (node-to-spot mappings)
#
# Inputs (in data-dir/):
#   - barcodes_positions.txt    Barcode spatial coordinates
#
# Outputs (in input-base/optimal/):
#   - SG_GrowChain_depths.txt   GrowChain depth per SG node with metadata
#
# Examples:
#   # Native mode
#   bash run_sg_depth_analysis.sh --dataset GSE193460_GSM5808054_KP_1 \
#       --account pi-araman --partition caslake \
#       --input-base local/outputs/GSE193460_GSM5808054_KP_1_native_prod_20260214_213405 \
#       --data-dir local/datasets/GSE193460_GSM5808054_KP_1/input_data
#
#   # With dependency on Step 6
#   bash run_sg_depth_analysis.sh --dataset GSE193460_GSM5808054_KP_1 \
#       --account pi-araman --partition caslake \
#       --input-base local/outputs/GSE193460_GSM5808054_KP_1_native_prod_20260214_213405 \
#       --data-dir local/datasets/GSE193460_GSM5808054_KP_1/input_data \
#       --dependency 12345678

set -e

# Load HPC cluster profile (exports module names; falls back to .example defaults)
_HPC_PROFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# ============================================================================
# Default Configuration
# ============================================================================

DATASET=""
ACCOUNT=""
PARTITION=""
INPUT_BASE=""
DATA_DIR=""
MEMORY="8G"
TIME_LIMIT="00:30:00"
DEPENDENCY=""
WORKSPACE_ROOT=""

# ============================================================================
# Parse Command Line Arguments
# ============================================================================

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
        --input-base)
            INPUT_BASE="$2"
            shift 2
            ;;
        --data-dir)
            DATA_DIR="$2"
            shift 2
            ;;
        --mem)
            MEMORY="$2"
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
        --workspace-root)
            WORKSPACE_ROOT="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ============================================================================
# Validate Required Arguments
# ============================================================================

if [ -z "$DATASET" ]; then
    echo "ERROR: --dataset is required"
    exit 1
fi

if [ -z "$ACCOUNT" ]; then
    echo "ERROR: --account is required"
    exit 1
fi

if [ -z "$PARTITION" ]; then
    echo "ERROR: --partition is required"
    exit 1
fi

if [ -z "$INPUT_BASE" ]; then
    echo "ERROR: --input-base is required"
    exit 1
fi

if [ -z "$DATA_DIR" ]; then
    echo "ERROR: --data-dir is required"
    exit 1
fi

# ============================================================================
# Setup Paths
# ============================================================================

if [ -z "$WORKSPACE_ROOT" ]; then
    WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi

JULIA_SCRIPT="${WORKSPACE_ROOT}/workflows/tumorspace_core/julia/sg_depth_growchain.jl"
INPUT_BASE=$(realpath "$INPUT_BASE")
DATA_DIR=$(realpath "$DATA_DIR")
OPTIMAL_DIR="${INPUT_BASE}/optimal"

# ============================================================================
# Display Configuration
# ============================================================================

echo "=========================================="
echo "Step 6b: SG GrowChain Depth Analysis"
echo "=========================================="
echo "Dataset:         $DATASET"
echo "Account:         $ACCOUNT"
echo "Partition:       $PARTITION"
echo "Input base:      $INPUT_BASE"
echo "Data dir:        $DATA_DIR"
echo "Optimal dir:     $OPTIMAL_DIR"
echo "Memory:          $MEMORY"
echo "Time limit:      $TIME_LIMIT"
echo "Julia script:    $JULIA_SCRIPT"
if [ -n "$DEPENDENCY" ]; then
    echo "Dependency:      $DEPENDENCY"
fi
echo ""

# ============================================================================
# Validate Input Files
# ============================================================================

echo "Validating input files..."
REQUIRED_FILES=(
    "${OPTIMAL_DIR}/allnodes_parents.tsv"
    "${OPTIMAL_DIR}/allnodes_leaves.tsv"
    "${OPTIMAL_DIR}/OptimalTree_pruned_node_compare_list.txt"
    "${DATA_DIR}/barcodes_positions.txt"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: Required file not found: $file"
        exit 1
    fi
done
echo "  ✓ All required input files present"
echo ""

# ============================================================================
# Submit SLURM Job
# ============================================================================

SLURM_SCRIPT="${INPUT_BASE}/slurm_sg_depth_analysis.sh"

cat > "$SLURM_SCRIPT" << 'EOF'
#!/bin/bash
#SBATCH --job-name=sg_depth
#SBATCH --output=PLACEHOLDER_WORKSPACE_ROOT/logs/sg_depth_analysis_%j.out
#SBATCH --error=PLACEHOLDER_WORKSPACE_ROOT/logs/sg_depth_analysis_%j.err
#SBATCH --account=PLACEHOLDER_ACCOUNT
#SBATCH --partition=PLACEHOLDER_PARTITION
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=PLACEHOLDER_MEMORY
#SBATCH --time=PLACEHOLDER_TIME_LIMIT

set -e

echo "=========================================="
echo "TumorSPACE Step 6b: SG GrowChain Depth Analysis"
echo "=========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"
echo "Start time: $(date)"
echo ""

# Load Julia module
PLACEHOLDER_HPC_LOAD_JULIA

# Run Julia script
julia PLACEHOLDER_JULIA_SCRIPT \
    PLACEHOLDER_INPUT_BASE \
    PLACEHOLDER_INPUT_BASE \
    PLACEHOLDER_DATA_DIR

EXIT_CODE=$?

echo ""
echo "Job completed with exit code: $EXIT_CODE"
echo "End time: $(date)"
echo "=========================================="

exit $EXIT_CODE
EOF

# Substitute placeholders
sed -i "s|PLACEHOLDER_WORKSPACE_ROOT|${WORKSPACE_ROOT}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_ACCOUNT|${ACCOUNT}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_PARTITION|${PARTITION}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_MEMORY|${MEMORY}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_TIME_LIMIT|${TIME_LIMIT}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_JULIA_SCRIPT|${JULIA_SCRIPT}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_INPUT_BASE|${INPUT_BASE}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_DATA_DIR|${DATA_DIR}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_HPC_LOAD_JULIA|${HPC_LOAD_JULIA}|g" "$SLURM_SCRIPT"

chmod +x "$SLURM_SCRIPT"

# Submit with or without dependency
if [ -n "$DEPENDENCY" ]; then
    JOB_ID=$(sbatch --dependency=afterok:${DEPENDENCY} --parsable "$SLURM_SCRIPT")
else
    JOB_ID=$(sbatch --parsable "$SLURM_SCRIPT")
fi

echo "Job submitted: $JOB_ID"
if [ -n "$DEPENDENCY" ]; then
    echo "Dependency: afterok:${DEPENDENCY}"
fi
echo ""
echo "Monitor with:"
echo "  squeue -j $JOB_ID"
echo "  tail -f ${WORKSPACE_ROOT}/logs/sg_depth_analysis_${JOB_ID}.out"
echo ""
echo "Expected outputs in ${OPTIMAL_DIR}:"
echo "  - SG_GrowChain_depths.txt"
echo ""

# Return job ID for downstream dependencies
echo "$JOB_ID"