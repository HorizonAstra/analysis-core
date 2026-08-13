#!/bin/bash
#
# run_sg_identify_pairs.sh
#
# TumorSPACE Step 6: Spatial Group (SG) Identification
#
# Identifies sibling node pairs in the pruned phylogenetic tree that meet minimum
# size thresholds. Each pair represents a spatial group (SG) - phylogenetically-related
# clusters with spatial proximity.
#
# SG = Spatial Group: Phylogenetically-related cell clusters with shared spatial context
#
# Usage:
#   bash run_sg_identify_pairs.sh --dataset DATASET --account ACCOUNT --partition PARTITION \
#                                  --input-base DIR [OPTIONS]
#
# Required Arguments:
#   --dataset DATASET       Dataset name (e.g., GSE213688_GSM6592057)
#   --account ACCOUNT       SLURM account (e.g., pi-araman)
#   --partition PARTITION   SLURM partition (e.g., caslake)
#   --input-base DIR        Base directory containing optimal/ subdirectory
#
# Optional Arguments:
#   --container DIR         Container directory for Singularity execution
#   --test                  Test mode: clean previous outputs before execution
#   --mem SIZE              Memory allocation (default: 4G)
#   --time LIMIT            Time limit (default: 00:30:00)
#   --dependency JOB_ID     Wait for this job to complete before starting
#
# Inputs (in input-base/optimal/):
#   - OptimalTree.nw        Pruned phylogenetic tree from Step 4
#
# Outputs (in input-base/optimal/):
#   - OptimalTree_pruned_node_compare_list.txt      SG pair definitions
#   - OptimalTree_pruned_node_compare_leaves.txt    Barcode assignments per SG
#   - OptimalTree_pruned_node_info.txt              Node statistics
#   - OptimalTree_pruned_node_skip_list.txt         Skipped nodes
#
# Examples:
#   # Native mode
#   bash run_sg_identify_pairs.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_e2e_fixed
#
#   # Container mode with dependency
#   bash run_sg_identify_pairs.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-base test_e2e_fixed \
#       --container containers/tumorspace_r.sif \
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
CONTAINER=""
TEST_MODE=false
MEM="4G"
TIME_LIMIT="00:30:00"
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
    echo "  bash run_sg_identify_pairs.sh --dataset DATASET --account ACCOUNT --partition PARTITION \\"
    echo "                                --input-base DIR [--container PATH] [--test]"
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
R_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/R/sg_identify_pairs.R"
CONTAINER_R_SCRIPT="/opt/workflows/R/sg_identify_pairs.R"

# Determine mode
if [ -n "$CONTAINER" ]; then
    MODE="CONTAINER"
    # If directory provided, auto-append R SIF filename
    if [ -d "$CONTAINER" ]; then
        CONTAINER="$CONTAINER/tumorspace_r.sif"
    fi
    CONTAINER=$(realpath "$CONTAINER")
    if [ ! -f "$CONTAINER" ]; then
        echo "ERROR: Container SIF file not found: $CONTAINER"
        exit 1
    fi
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

# Check optimal directory exists (skip if using dependency)
OPTIMAL_DIR="$INPUT_BASE/optimal"
if [ -z "$DEPENDENCY" ]; then
    if [ ! -d "$OPTIMAL_DIR" ]; then
        echo "ERROR: optimal/ directory not found in $INPUT_BASE"
        echo "Make sure you have run SVD selection (Step 5) first"
        exit 1
    fi
fi

# Check required input file exists (skip if using dependency)
if [ -z "$DEPENDENCY" ]; then
    TREE_FILE="$OPTIMAL_DIR/OptimalTree.nw"
    if [ ! -f "$TREE_FILE" ]; then
        echo "ERROR: OptimalTree.nw not found in $OPTIMAL_DIR"
        echo "Make sure you have run tree pruning (Step 4) first"
        exit 1
    fi
fi

# Test mode: Clean previous outputs to force fresh computation
if [ "$TEST_MODE" = true ]; then
    rm -f "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_list.txt"
    rm -f "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_leaves.txt"
    rm -f "$OPTIMAL_DIR/OptimalTree_pruned_node_info.txt"
    rm -f "$OPTIMAL_DIR/OptimalTree_pruned_node_skip_list.txt"
    echo "TEST MODE: Cleaned SG identification outputs"
    echo ""
fi

# Create logs directory
mkdir -p logs

# Generate timestamp for this run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create SLURM batch script
SBATCH_SCRIPT="./logs/sg_identify_pairs_sbatch_${TIMESTAMP}.sh"

cat > "$SBATCH_SCRIPT" << 'HEREDOC_END'
#!/bin/bash
#SBATCH --job-name=sg_identify
#SBATCH --output=logs/sg_identify_pairs_%j.out
#SBATCH --error=logs/sg_identify_pairs_%j.err
#SBATCH --time=__TIME_LIMIT__
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --account=__ACCOUNT__
#SBATCH --partition=__PARTITION__
#SBATCH --mem=__MEM__

echo "=========================================="
echo "TumorSPACE Step 6: SG Identification"
echo "=========================================="
echo "Dataset:    __DATASET__"
echo "Mode:       __MODE__"
echo "Start time: $(date)"
echo "Hostname:   $(hostname)"
echo "=========================================="
echo

# Optimal directory
OPTIMAL_DIR="__OPTIMAL_DIR__"

echo "Optimal directory: $OPTIMAL_DIR"
echo "Tree file: $OPTIMAL_DIR/OptimalTree.nw"
echo ""

# Verify input file exists
if [ ! -f "$OPTIMAL_DIR/OptimalTree.nw" ]; then
    echo "ERROR: OptimalTree.nw not found"
    exit 1
fi

echo "Starting SG identification..."
echo ""

MODE_EXEC_PLACEHOLDER

echo ""
echo "SG identification completed"
echo "End time: $(date)"
echo ""

# Verify outputs were created
if [ -f "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_list.txt" ]; then
    NUM_PAIRS=$(tail -n +2 "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_list.txt" | wc -l)
    echo "✓ Created node_compare_list.txt ($NUM_PAIRS SG pairs)"
else
    echo "✗ WARNING: node_compare_list.txt not created"
fi

if [ -f "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_leaves.txt" ]; then
    NUM_LEAVES=$(tail -n +2 "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_leaves.txt" | wc -l)
    echo "✓ Created node_compare_leaves.txt ($NUM_LEAVES barcode assignments)"
else
    echo "✗ WARNING: node_compare_leaves.txt not created"
fi

if [ -f "$OPTIMAL_DIR/OptimalTree_pruned_node_info.txt" ]; then
    echo "✓ Created node_info.txt"
else
    echo "✗ WARNING: node_info.txt not created"
fi

if [ -f "$OPTIMAL_DIR/OptimalTree_pruned_node_skip_list.txt" ]; then
    echo "✓ Created node_skip_list.txt"
else
    echo "✗ WARNING: node_skip_list.txt not created"
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
sed -i "s|__TIME_LIMIT__|$TIME_LIMIT|g" "$SBATCH_SCRIPT"
sed -i "s|__MEM__|$MEM|g" "$SBATCH_SCRIPT"

# Append mode-specific execution block
if [ "$MODE" = "CONTAINER" ]; then
    cat >> "$SBATCH_SCRIPT" << EOF
# Container execution
${HPC_LOAD_SINGULARITY}

# Set R library path inside container (SINGULARITYENV_ prefix passes to container)
# R_LIBS_USER must be non-empty: empty string triggers R's ~/R/... fallback which resolves
# to the NFS-mounted host path, causing .so load failures (libRblas.so absent on RHEL).
export SINGULARITYENV_R_LIBS_USER="/usr/local/lib/R/site-library"
export SINGULARITYENV_R_LIBS="/usr/local/lib/R/site-library:/usr/lib/R/site-library:/usr/lib/R/library"

singularity exec --no-home --cleanenv \\
    --bind "$INPUT_BASE":"$INPUT_BASE" \\
    "$CONTAINER" \\
    Rscript "$CONTAINER_R_SCRIPT" \\
    "$OPTIMAL_DIR" \\
    "$OPTIMAL_DIR"
EOF
else
    cat >> "$SBATCH_SCRIPT" << EOF
# Native HPC execution
${HPC_LOAD_R}

# Set R library paths to find user-installed packages
export R_LIBS_USER="\${HOME}/R/x86_64-pc-linux-gnu-library/4.4:\${HOME}/R/x86_64-pc-linux-gnu-library/4.4.1:\${R_LIBS_USER}"

# Pre-flight check: Verify required R packages are available
echo "Verifying required R packages..."
Rscript --vanilla -e "
required_pkgs <- c('dplyr', 'data.table', 'ape', 'phangorn')
missing <- character(0)
for (pkg in required_pkgs) {
    if (!require(pkg, character.only=TRUE, quietly=TRUE)) {
        missing <- c(missing, pkg)
    }
}
if (length(missing) > 0) {
    cat('ERROR: Required packages missing:', paste(missing, collapse=', '), '\\\\n')
    cat('Install with: R -e \"install.packages(c(', paste(paste0(\"'\", missing, \"'\"), collapse=', '), '), repos=\\'https://cloud.r-project.org\\')\"\\\\n')
    quit(status=1)
}
cat('✓ All required packages available\\\\n')
"

Rscript "$R_SCRIPT" \\
    "$OPTIMAL_DIR" \\
    "$OPTIMAL_DIR"
EOF
fi

# Remove placeholder line
sed -i '/MODE_EXEC_PLACEHOLDER/d' "$SBATCH_SCRIPT"

# Make script executable
chmod +x "$SBATCH_SCRIPT"

# Display submission info
echo "=========================================="
echo "Submitting Step 6: SG Identification"
echo "=========================================="
echo "Dataset:      $DATASET"
echo "Mode:         $MODE"
echo "Account:      $ACCOUNT"
echo "Partition:    $PARTITION"
echo "Input base:   $INPUT_BASE"
echo "Optimal dir:  $OPTIMAL_DIR"
if [ "$MODE" = "CONTAINER" ]; then
    echo "Container:    $CONTAINER"
else
    echo "R script:     $R_SCRIPT"
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
echo "  tail -f logs/sg_identify_pairs_${JOB_ID}.out"
echo ""
echo "Expected outputs in $OPTIMAL_DIR:"
echo "  - OptimalTree_pruned_node_compare_list.txt"
echo "  - OptimalTree_pruned_node_compare_leaves.txt"
echo "  - OptimalTree_pruned_node_info.txt"
echo "  - OptimalTree_pruned_node_skip_list.txt"
echo ""
echo "$JOB_ID"