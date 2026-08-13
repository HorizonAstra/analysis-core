#!/bin/bash
#
# run_sg_slab_score.sh
#
# TumorSPACE Step 9: SLAB (Spatially Localized Abundance Bias) Scoring
#
# Computes spatial localization scores for differentially abundant genes based on
# which barcodes (spots) show DA changes across the spatial hierarchy.
#
# SLAB score = (# spots with DA change) / (total # spots)
#
# Higher SLAB scores indicate genes with stronger spatial localization patterns.
#
# Usage:
#   bash run_sg_slab_score.sh --dataset DATASET --account ACCOUNT --partition PARTITION \
#                             --input-base DIR --data-dir DIR [OPTIONS]
#
# Required Arguments:
#   --dataset DATASET       Dataset name (e.g., GSE213688_GSM6592057)
#   --account ACCOUNT       SLURM account (e.g., pi-araman)
#   --partition PARTITION   SLURM partition (e.g., caslake)
#   --input-base DIR        Base directory containing optimal/ subdirectory
#   --data-dir DIR          Directory containing spatial positions data
#
# Optional Arguments:
#   --container DIR         Container directory for Singularity execution
#   --test                  Test mode: clean previous outputs before execution
#   --mem SIZE              Memory allocation (default: 4G)
#   --time LIMIT            Time limit (default: 00:30:00)
#   --dependency JOB_ID     Wait for this job to complete before starting
#
# Inputs (in input-base/optimal/):
#   - DA_significant.txt                             From Step 8
#   - OptimalTree_pruned_node_compare_list.txt       From Step 8
#   - OptimalTree_pruned_node_compare_leaves.txt     From Step 8
#
# Inputs (in data-dir/):
#   - barcodes_positions.txt    Barcode spatial coordinates
#
# Outputs (in input-base/optimal/):
#   - SLAB_scores.txt           SLAB score per gene per direction
#   - SLAB_barcodes.txt         Barcode-level details
#
# Examples:
#   # Native mode
#   bash run_sg_slab_score.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_e2e_fixed \
#       --data-dir benchmarks/GSE213688_GSM6592057/input_data
#
#   # Container mode with dependency
#   bash run_sg_slab_score.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_e2e_fixed \
#       --data-dir benchmarks/GSE213688_GSM6592057/input_data \
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
CONTAINER=""
TEST_MODE=false
MEM="32G"
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
        --data-dir)
            DATA_DIR="$2"
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
if [ -z "$DATASET" ] || [ -z "$ACCOUNT" ] || [ -z "$PARTITION" ] || [ -z "$INPUT_BASE" ] || [ -z "$DATA_DIR" ]; then
    echo "ERROR: Missing required arguments"
    echo ""
    echo "Required: --dataset, --account, --partition, --input-base, --data-dir"
    echo ""
    echo "Usage:"
    echo "  bash run_sg_slab_score.sh --dataset DATASET --account ACCOUNT --partition PARTITION \\"
    echo "                            --input-base DIR --data-dir DIR [--container PATH] [--test]"
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
JULIA_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia/sg_slab_score.jl"
JULIA_PROJECT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia"
CONTAINER_JULIA_SCRIPT="/opt/workflows/julia/sg_slab_score.jl"

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

# Check required Step 8 and Step 7 outputs exist (skip if using dependency)
if [ -z "$DEPENDENCY" ]; then
    DA_FILE="$OPTIMAL_DIR/gene/DA_significant.txt"
    if [ ! -f "$DA_FILE" ]; then
        echo "ERROR: DA_significant.txt not found in $OPTIMAL_DIR/gene"
        echo "Make sure you have run differential abundance analysis (Step 8) first"
        exit 1
    fi

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

# Check barcodes_positions.txt exists
BARCODE_POS="$DATA_DIR/barcodes_positions.txt"
if [ ! -f "$BARCODE_POS" ]; then
    echo "ERROR: barcodes_positions.txt not found in $DATA_DIR"
    exit 1
fi

# Test mode: Clean previous outputs to force fresh computation
if [ "$TEST_MODE" = true ]; then
    rm -f "$OPTIMAL_DIR/gene/SLAB_scores.txt"
    rm -f "$OPTIMAL_DIR/gene/SLAB_barcodes.txt"
    echo "TEST MODE: Cleaned SLAB scoring outputs"
    echo ""
fi

# Create logs directory
mkdir -p logs

# Generate timestamp for this run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create SLURM batch script
SBATCH_SCRIPT="./logs/sg_slab_score_sbatch_${TIMESTAMP}.sh"

cat > "$SBATCH_SCRIPT" << 'HEREDOC_END'
#!/bin/bash
#SBATCH --job-name=sg_slab
#SBATCH --output=logs/sg_slab_score_%j.out
#SBATCH --error=logs/sg_slab_score_%j.err
#SBATCH --time=__TIME_LIMIT__
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --account=__ACCOUNT__
#SBATCH --partition=__PARTITION__
#SBATCH --mem=__MEM__

echo "=========================================="
echo "TumorSPACE Step 9: SLAB Scoring"
echo "=========================================="
echo "Dataset:    __DATASET__"
echo "Mode:       __MODE__"
echo "Start time: $(date)"
echo "Hostname:   $(hostname)"
echo "=========================================="
echo

# Optimal directory
OPTIMAL_DIR="__OPTIMAL_DIR__"
BARCODE_POS="__BARCODE_POS__"
GENE_DIR="${OPTIMAL_DIR}/gene"

echo "Optimal directory: $OPTIMAL_DIR"
echo "Gene feature dir:  $GENE_DIR"
echo "Barcode positions: $BARCODE_POS"
echo ""

# Copy barcodes_positions.txt to gene subdirectory (required by Julia script)
echo "Copying barcodes_positions.txt to gene directory..."
cp "$BARCODE_POS" "$GENE_DIR/"
echo "✓ Barcodes positions file copied"
echo ""

# Verify input files exist
echo "Checking input files..."
for file in DA_significant.txt OptimalTree_pruned_node_compare_list.txt OptimalTree_pruned_node_compare_leaves.txt barcodes_positions.txt; do
    if [ -f "$GENE_DIR/$file" ]; then
        echo "✓ $file"
    else
        echo "✗ ERROR: $file not found"
        exit 1
    fi
done
echo ""

echo "Starting SLAB score calculation..."
echo ""

MODE_EXEC_PLACEHOLDER

echo ""
echo "SLAB score calculation completed"
echo "End time: $(date)"
echo ""

# Verify outputs were created
if [ -f "$GENE_DIR/SLAB_scores.txt" ]; then
    NUM_SCORES=$(tail -n +2 "$GENE_DIR/SLAB_scores.txt" | wc -l)
    echo "✓ Created SLAB_scores.txt ($NUM_SCORES gene-direction pairs)"
else
    echo "✗ WARNING: SLAB_scores.txt not created"
fi

if [ -f "$GENE_DIR/SLAB_barcodes.txt" ]; then
    NUM_BARCODES=$(tail -n +2 "$GENE_DIR/SLAB_barcodes.txt" | wc -l)
    echo "✓ Created SLAB_barcodes.txt ($NUM_BARCODES barcode entries)"
else
    echo "✗ WARNING: SLAB_barcodes.txt not created"
fi

# Write gene feature-space done sentinel and update registry
touch "${GENE_DIR}/gene_slab_done.txt"
echo "✓ gene_slab_done.txt written"
FSTSV="${OPTIMAL_DIR}/feature_spaces.tsv"
if [ ! -f "$FSTSV" ]; then
    printf "name\ttype\tn_features\tda_sig_path\tslab_path\tstatus\n" > "$FSTSV"
fi
if ! grep -q "^gene	" "$FSTSV" 2>/dev/null; then
    N_GENE=$(tail -n +2 "${GENE_DIR}/genes.txt" | wc -l)
    printf "gene\tgene_expression\t%s\t%s\t%s\tcomplete\n" \
        "$N_GENE" \
        "${GENE_DIR}/DA_significant.txt" \
        "${GENE_DIR}/SLAB_scores.txt" >> "$FSTSV"
    echo "✓ feature_spaces.tsv updated (gene, ${N_GENE} genes)"
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
sed -i "s|__BARCODE_POS__|$BARCODE_POS|g" "$SBATCH_SCRIPT"
sed -i "s|__TIME_LIMIT__|$TIME_LIMIT|g" "$SBATCH_SCRIPT"
sed -i "s|__MEM__|$MEM|g" "$SBATCH_SCRIPT"

# Append mode-specific execution block
if [ "$MODE" = "CONTAINER" ]; then
    cat >> "$SBATCH_SCRIPT" << EOF
# Container execution
${HPC_LOAD_SINGULARITY}

singularity exec --no-home \\
    --env JULIA_DEPOT_PATH=/tmp/julia_depot:/opt/julia_depot \\
    --env JULIA_PKG_PRECOMPILE_AUTO=0 \\
    --bind "$INPUT_BASE":"$INPUT_BASE" \\
    "$CONTAINER" \\
    julia --project=/opt/workflows/julia "$CONTAINER_JULIA_SCRIPT" \\
    "${OPTIMAL_DIR}/gene"
EOF
else
    cat >> "$SBATCH_SCRIPT" << EOF
# Native HPC execution
${HPC_LOAD_JULIA}
export JULIA_DEPOT_PATH=${HPC_JULIA_DEPOT}
export JULIA_PKG_PRECOMPILE_AUTO=0

julia --project="$JULIA_PROJECT" "$JULIA_SCRIPT" \\
    "${OPTIMAL_DIR}/gene"
EOF
fi

# Remove placeholder line
sed -i '/MODE_EXEC_PLACEHOLDER/d' "$SBATCH_SCRIPT"

# Make script executable
chmod +x "$SBATCH_SCRIPT"

# Display submission info
echo "=========================================="
echo "Submitting Step 9: SLAB Scoring"
echo "=========================================="
echo "Dataset:      $DATASET"
echo "Mode:         $MODE"
echo "Account:      $ACCOUNT"
echo "Partition:    $PARTITION"
echo "Input base:   $INPUT_BASE"
echo "Data dir:     $DATA_DIR"
echo "Optimal dir:  $OPTIMAL_DIR"
if [ "$MODE" = "CONTAINER" ]; then
    echo "Container:    $CONTAINER"
else
    echo "Julia script: $JULIA_SCRIPT"
fi
if [ -n "$DEPENDENCY" ]; then
    echo "Dependency:   $DEPENDENCY"
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
echo "  tail -f logs/sg_slab_score_${JOB_ID}.out"
echo ""
echo "Expected outputs in $OPTIMAL_DIR:"
echo "  - SLAB_scores.txt"
echo "  - SLAB_barcodes.txt"
echo ""
echo "$JOB_ID"