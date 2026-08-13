#!/bin/bash
#
# run_sg_diff_abundance.sh
#
# TumorSPACE Step 8: Differential Gene Expression Analysis
#
# Identifies differentially abundant (DA) genes between spatial group (SG) pairs using
# Wilcoxon rank-sum tests with permutation-based FDR correction.
#
# Tests for genes that show significantly different expression levels between sibling
# node pairs in the phylogenetic tree, indicating spatial localization patterns.
#
# Usage:
#   bash run_sg_diff_abundance.sh --dataset DATASET --account ACCOUNT --partition PARTITION \
#                                  --input-base DIR --data-dir DIR [OPTIONS]
#
# Required Arguments:
#   --dataset DATASET       Dataset name (e.g., GSE213688_GSM6592057)
#   --account ACCOUNT       SLURM account (e.g., pi-araman)
#   --partition PARTITION   SLURM partition (e.g., caslake)
#   --input-base DIR        Base directory containing optimal/ subdirectory
#   --data-dir DIR          Directory containing gene expression data
#
# Optional Arguments:
#   --num-shuffle N         Number of permutations for FDR (default: 20)
#   --container DIR         Container directory for Singularity execution
#   --test                  Test mode: clean previous outputs before execution
#   --mem SIZE              Memory allocation (default: 8G)
#   --time LIMIT            Time limit (default: 01:00:00)
#   --dependency JOB_ID     Wait for this job to complete before starting
#
# Inputs (in input-base/optimal/):
#   - OptimalTree_pruned_node_compare_list.txt      From Step 7
#   - OptimalTree_pruned_node_compare_leaves.txt    From Step 7
#
# Inputs (in data-dir/):
#   - M.txt                 Gene expression matrix
#   - barcodes.txt          Barcode names
#   - genes.txt             Gene names
#
# Outputs (in input-base/optimal/):
#   - DA_results.txt        All DA test results with p-values and q-values
#   - DA_significant.txt    Subset with Q < 1/num_shuffle
#
# Examples:
#   # Native mode with default 20 permutations
#   bash run_sg_diff_abundance.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_e2e_fixed \
#       --data-dir benchmarks/GSE213688_GSM6592057/input_data
#
#   # Container mode with 100 permutations and dependency
#   bash run_sg_diff_abundance.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_e2e_fixed \
#       --data-dir benchmarks/GSE213688_GSM6592057/input_data \
#       --num-shuffle 100 \
#       --container containers \
#       --dependency 12345
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
DATA_DIR=""
NUM_SHUFFLE=20
CONTAINER=""
TEST_MODE=false
MEM="32G"
TIME_LIMIT="01:00:00"
DEPENDENCY=""
WORKSPACE_ROOT=""
FIXED_SEED=""

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
        --data-dir)
            DATA_DIR="$2"
            shift 2
            ;;
        --num-shuffle)
            NUM_SHUFFLE="$2"
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
        --fixed-seed)
            FIXED_SEED="$2"
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
if [ -z "$DATASET" ] || [ -z "$ACCOUNT" ] || [ -z "$PARTITION" ] || [ -z "$INPUT_BASE" ] || [ -z "$DATA_DIR" ]; then
    echo "ERROR: Missing required arguments"
    echo ""
    echo "Required: --dataset, --account, --partition, --input-base, --data-dir"
    echo ""
    echo "Usage:"
    echo "  bash run_sg_diff_abundance.sh --dataset DATASET --account ACCOUNT --partition PARTITION \\"
    echo "                                --input-base DIR --data-dir DIR [--num-shuffle N] [--container PATH] [--test]"
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
JULIA_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia/sg_diff_abundance.jl"
JULIA_PROJECT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia"
CONTAINER_JULIA_SCRIPT="/opt/workflows/julia/sg_diff_abundance.jl"

# Determine mode
if [ -n "$CONTAINER" ]; then
    MODE="CONTAINER"
    # If directory provided, auto-append .sif filename
    if [ -d "$CONTAINER" ]; then
        CONTAINER="$CONTAINER/julia_1.9_with_gotree.sif"
    fi
    CONTAINER=$(realpath "$CONTAINER")
    # Validate .sif file exists
    if [ ! -f "$CONTAINER" ]; then
        echo "Error: Container SIF file not found: $CONTAINER"
        echo "Expected a .sif file, not a directory"
        exit 1
    fi
else
    MODE="HPC"
fi

# Convert to absolute paths
INPUT_BASE=$(realpath "$INPUT_BASE")
DATA_DIR=$(realpath "$DATA_DIR")

# Check INPUT_BASE exists
if [ ! -d "$INPUT_BASE" ]; then
    echo "ERROR: Input base directory not found: $INPUT_BASE"
    exit 1
fi

# Check DATA_DIR exists
if [ ! -d "$DATA_DIR" ]; then
    echo "ERROR: Data directory not found: $DATA_DIR"
    exit 1
fi

# Check optimal directory exists (skip if using dependency)
OPTIMAL_DIR="$INPUT_BASE/optimal"
if [ -z "$DEPENDENCY" ]; then
    if [ ! -d "$OPTIMAL_DIR" ]; then
        echo "ERROR: optimal/ directory not found in $INPUT_BASE"
        echo "Make sure you have run SVD selection (Step 6) first"
        exit 1
    fi
fi

# Check required Step 7 outputs exist (skip if using dependency)
if [ -z "$DEPENDENCY" ]; then
    SG_LIST="$OPTIMAL_DIR/OptimalTree_pruned_node_compare_list.txt"
    SG_LEAVES="$OPTIMAL_DIR/OptimalTree_pruned_node_compare_leaves.txt"

    if [ ! -f "$SG_LIST" ]; then
        echo "ERROR: OptimalTree_pruned_node_compare_list.txt not found in $OPTIMAL_DIR"
        echo "Make sure you have run SG identification (Step 7) first"
        exit 1
    fi

    if [ ! -f "$SG_LEAVES" ]; then
        echo "ERROR: OptimalTree_pruned_node_compare_leaves.txt not found in $OPTIMAL_DIR"
        echo "Make sure you have run SG identification (Step 7) first"
        exit 1
    fi
fi

# Check required data files exist
for file in M.txt barcodes.txt genes.txt; do
    if [ ! -f "$DATA_DIR/$file" ]; then
        echo "ERROR: $file not found in $DATA_DIR"
        exit 1
    fi
done

# Test mode: Clean previous outputs to force fresh computation
if [ "$TEST_MODE" = true ]; then
    rm -f "$OPTIMAL_DIR/gene/DA_results.txt"
    rm -f "$OPTIMAL_DIR/gene/DA_significant.txt"
    echo "TEST MODE: Cleaned differential abundance outputs"
    echo ""
fi

# Create logs directory
mkdir -p logs

# Generate timestamp for this run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create SLURM batch script
SBATCH_SCRIPT="./logs/sg_diff_abundance_sbatch_${TIMESTAMP}.sh"

cat > "$SBATCH_SCRIPT" << 'HEREDOC_END'
#!/bin/bash
#SBATCH --job-name=sg_diffabund
#SBATCH --output=logs/sg_diff_abundance_%j.out
#SBATCH --error=logs/sg_diff_abundance_%j.err
#SBATCH --time=__TIME_LIMIT__
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --account=__ACCOUNT__
#SBATCH --partition=__PARTITION__
#SBATCH --mem=__MEM__

echo "=========================================="
echo "TumorSPACE Step 8: Differential Abundance"
echo "=========================================="
echo "Dataset:         __DATASET__"
echo "Mode:            __MODE__"
echo "Num permutations: __NUM_SHUFFLE__"
echo "Start time:      $(date)"
echo "Hostname:        $(hostname)"
echo "=========================================="
echo

# Optimal directory
OPTIMAL_DIR="__OPTIMAL_DIR__"
DATA_DIR="__DATA_DIR__"
GENE_DIR="${OPTIMAL_DIR}/gene"

echo "Optimal directory: $OPTIMAL_DIR"
echo "Gene feature dir:  $GENE_DIR"
echo "Data directory: $DATA_DIR"
echo "Num shuffle: __NUM_SHUFFLE__"
echo ""

# Create gene subdirectory
mkdir -p "$GENE_DIR"

# Copy data files to gene subdirectory (required by Julia script)
echo "Copying data files to gene directory..."
cp "$DATA_DIR/M.txt" "$GENE_DIR/"
cp "$DATA_DIR/barcodes.txt" "$GENE_DIR/"
cp "$DATA_DIR/genes.txt" "$GENE_DIR/" || cp "$DATA_DIR/features.txt" "$GENE_DIR/genes.txt"

# Symlink tree files from optimal/ into gene/ (single source of truth)
for tree_file in OptimalTree_pruned_node_compare_list.txt \
                 OptimalTree_pruned_node_compare_leaves.txt; do
    ln -sf "../${tree_file}" "$GENE_DIR/${tree_file}" 2>/dev/null || true
done
echo "✓ Data files copied, tree files symlinked"
echo ""

# Verify input files exist
echo "Checking input files..."
for file in OptimalTree_pruned_node_compare_list.txt OptimalTree_pruned_node_compare_leaves.txt M.txt barcodes.txt genes.txt; do
    if [ -f "$GENE_DIR/$file" ]; then
        echo "✓ $file"
    else
        echo "✗ ERROR: $file not found"
        exit 1
    fi
done
echo ""

echo "Starting differential abundance analysis..."
echo ""

MODE_EXEC_PLACEHOLDER

echo ""
echo "Differential abundance analysis completed"
echo "End time: $(date)"
echo ""

# Verify outputs were created
if [ -f "$GENE_DIR/DA_results.txt" ]; then
    NUM_TESTS=$(tail -n +2 "$GENE_DIR/DA_results.txt" | wc -l)
    echo "✓ Created DA_results.txt ($NUM_TESTS tests)"
else
    echo "✗ WARNING: DA_results.txt not created"
fi

if [ -f "$GENE_DIR/DA_significant.txt" ]; then
    NUM_SIG=$(tail -n +2 "$GENE_DIR/DA_significant.txt" | wc -l)
    echo "✓ Created DA_significant.txt ($NUM_SIG significant DA genes)"
else
    echo "✗ WARNING: DA_significant.txt not created"
fi

echo ""
echo "=========================================="
HEREDOC_END

# Substitute placeholders
sed -i "s|__ACCOUNT__|$ACCOUNT|g" "$SBATCH_SCRIPT"
sed -i "s|__PARTITION__|$PARTITION|g" "$SBATCH_SCRIPT"
sed -i "s|__DATASET__|$DATASET|g" "$SBATCH_SCRIPT"
sed -i "s|__MODE__|$MODE|g" "$SBATCH_SCRIPT"
sed -i "s|__OPTIMAL_DIR__|$OPTIMAL_DIR|g" "$SBATCH_SCRIPT"
sed -i "s|__DATA_DIR__|$DATA_DIR|g" "$SBATCH_SCRIPT"
sed -i "s|__NUM_SHUFFLE__|$NUM_SHUFFLE|g" "$SBATCH_SCRIPT"
sed -i "s|__TIME_LIMIT__|$TIME_LIMIT|g" "$SBATCH_SCRIPT"
sed -i "s|__MEM__|$MEM|g" "$SBATCH_SCRIPT"

# Append mode-specific execution block
if [ "$MODE" = "CONTAINER" ]; then
    cat >> "$SBATCH_SCRIPT" << EOF
# Container execution
${HPC_LOAD_SINGULARITY}

EOF
    # Add seed export and build singularity command
    if [ -n "$FIXED_SEED" ]; then
        cat >> "$SBATCH_SCRIPT" << EOF
# Export seed for reproducible permutations
export TUMORSPACE_DA_SEED="$FIXED_SEED"

singularity exec --no-home \\
    --env JULIA_DEPOT_PATH=/tmp/julia_depot:/opt/julia_depot \\
    --env JULIA_PKG_PRECOMPILE_AUTO=0 \\
    --env TUMORSPACE_DA_SEED="\$TUMORSPACE_DA_SEED" \\
    --bind "$INPUT_BASE":"$INPUT_BASE" \\
    "$CONTAINER" \\
    julia --project=/opt/workflows/julia "$CONTAINER_JULIA_SCRIPT" \\
    "${OPTIMAL_DIR}/gene" \\
    "$NUM_SHUFFLE"
EOF
    else
        cat >> "$SBATCH_SCRIPT" << EOF
singularity exec --no-home \\
    --env JULIA_DEPOT_PATH=/tmp/julia_depot:/opt/julia_depot \\
    --env JULIA_PKG_PRECOMPILE_AUTO=0 \\
    --bind "$INPUT_BASE":"$INPUT_BASE" \\
    "$CONTAINER" \\
    julia --project=/opt/workflows/julia "$CONTAINER_JULIA_SCRIPT" \\
    "${OPTIMAL_DIR}/gene" \\
    "$NUM_SHUFFLE"
EOF
    fi
else
    cat >> "$SBATCH_SCRIPT" << EOF
# Native HPC execution
${HPC_LOAD_JULIA}
EOF
    # Add seed export if provided
    if [ -n "$FIXED_SEED" ]; then
        echo "export TUMORSPACE_DA_SEED=\"$FIXED_SEED\"" >> "$SBATCH_SCRIPT"
    fi
    cat >> "$SBATCH_SCRIPT" << EOF
export JULIA_DEPOT_PATH=${HPC_JULIA_DEPOT}
export JULIA_PKG_PRECOMPILE_AUTO=0

julia --project="$JULIA_PROJECT" "$JULIA_SCRIPT" \\
    "${OPTIMAL_DIR}/gene" \\
    "$NUM_SHUFFLE"
EOF
fi

# Remove placeholder line
sed -i '/MODE_EXEC_PLACEHOLDER/d' "$SBATCH_SCRIPT"

# Make script executable
chmod +x "$SBATCH_SCRIPT"

# Display submission info
echo "=========================================="
echo "Submitting Step 8: Differential Abundance"
echo "=========================================="
echo "Dataset:         $DATASET"
echo "Mode:            $MODE"
echo "Account:         $ACCOUNT"
echo "Partition:       $PARTITION"
echo "Input base:      $INPUT_BASE"
echo "Data dir:        $DATA_DIR"
echo "Optimal dir:     $OPTIMAL_DIR"
echo "Num shuffle:     $NUM_SHUFFLE"
if [ "$MODE" = "CONTAINER" ]; then
    echo "Container:       $CONTAINER"
else
    echo "Julia script:    $JULIA_SCRIPT"
fi
if [ -n "$DEPENDENCY" ]; then
    echo "Dependency:      $DEPENDENCY"
fi
echo ""

# Submit with optional dependency
if [ -n "$DEPENDENCY" ]; then
    JOB_ID=$(sbatch --parsable --dependency=afterok:$DEPENDENCY "$SBATCH_SCRIPT")
else
    JOB_ID=$(sbatch --parsable "$SBATCH_SCRIPT")
fi
rm "$SBATCH_SCRIPT"

echo "Job submitted: $JOB_ID"
echo ""
echo "Monitor with:"
echo "  squeue -j $JOB_ID"
echo "  tail -f logs/sg_diff_abundance_${JOB_ID}.out"
echo ""
echo "Expected outputs in $OPTIMAL_DIR/gene:"
echo "  - DA_results.txt"
echo "  - DA_significant.txt"
echo ""
echo "$JOB_ID"