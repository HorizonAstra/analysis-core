#!/bin/bash
#
# TumorSPACE Bootstrap Support Calculation
# Runs after Step 1 tree building to compute TBE support values
#
# Usage:
#   run_bootstrap_support.sh --account ACCOUNT --partition PARTITION \
#                            --output-base DIR --num-svd N [--test]
#

set -e

# Load HPC cluster profile (exports module names; falls back to .example defaults)
_HPC_PROFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# Parse arguments
ACCOUNT=""
PARTITION=""
OUTPUT_BASE=""
NUM_SVD=30
BOOTSTRAPS=10
CONTAINER=""
TEST_MODE=false
DEPENDENCY=""
WORKSPACE_ROOT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --account)
            ACCOUNT="$2"
            shift 2
            ;;
        --partition)
            PARTITION="$2"
            shift 2
            ;;
        --output-base)
            OUTPUT_BASE="$2"
            shift 2
            ;;
        --workspace-root)
            WORKSPACE_ROOT="$2"
            shift 2
            ;;
        --num-svd)
            NUM_SVD="$2"
            shift 2
            ;;
        --bootstraps)
            BOOTSTRAPS="$2"
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
        --dependency)
            DEPENDENCY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$ACCOUNT" ] || [ -z "$PARTITION" ] || [ -z "$OUTPUT_BASE" ]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 --account ACCOUNT --partition PARTITION --output-base DIR [--num-svd N] [--bootstraps N] [--test]"
    exit 1
fi

# Adjust NUM_SVD for test mode
if [ "$TEST_MODE" = true ]; then
    NUM_SVD=3
fi

# Auto-derive workspace root if not provided
if [ -z "$WORKSPACE_ROOT" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

# Validate workspace root
if [ ! -d "$WORKSPACE_ROOT" ]; then
    echo "Error: Workspace root directory not found: $WORKSPACE_ROOT"
    exit 1
fi

GOTREE_BIN="$WORKSPACE_ROOT/bin/gotree"

# Validate gotree binary exists (native mode only)
if [ -z "$CONTAINER" ] && [ ! -x "$GOTREE_BIN" ]; then
    echo "Error: gotree binary not found at $GOTREE_BIN"
    echo "Please ensure bin/gotree is present and executable"
    exit 1
fi

# Validate container if provided
if [ -n "$CONTAINER" ]; then
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
fi

# Test mode: Clean previous outputs to force fresh computation
if [ "$TEST_MODE" = true ]; then
    for i in $(seq 1 3); do
        SVD_DIR="$OUTPUT_BASE/svd_run_$i"
        if [ -d "$SVD_DIR" ]; then
            rm -f "$SVD_DIR/Tree_Bootstrap.nw" "$SVD_DIR/Tree_support.nw"
        fi
    done
    echo "TEST MODE: Cleaned bootstrap outputs for SVDs 1-3"
    echo ""
fi

# Create log directory
LOG_DIR="$(dirname "$OUTPUT_BASE")/logs"
mkdir -p "$LOG_DIR"

# Generate SLURM job script
SBATCH_SCRIPT=$(mktemp)
ARRAY_MAX=$((NUM_SVD - 1))

# Determine mode
if [ -n "$CONTAINER" ]; then
    USE_CONTAINER=true
    MODE="Container"
else
    USE_CONTAINER=false
    MODE="Native (Direct HPC)"
fi

# Generate appropriate script based on mode
if [ "$USE_CONTAINER" = true ]; then
    # Container mode
    cat > "$SBATCH_SCRIPT" <<'EOFCONTAINER'
#!/bin/bash
#SBATCH --job-name=tumorspace_bootstrap
#SBATCH --output=__LOG_DIR__/bootstrap_support_%A_%a.out
#SBATCH --error=__LOG_DIR__/bootstrap_support_%A_%a.err
#SBATCH --time=00:15:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --account=__ACCOUNT__
#SBATCH --partition=__PARTITION__
#SBATCH --mem=32G
#SBATCH --array=0-__ARRAY_MAX__

echo "=========================================="
echo "Bootstrap Support Calculation (Container)"
echo "=========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Array Task ID: $SLURM_ARRAY_TASK_ID"
echo "Node: $(hostname)"
echo "Start: $(date)"
echo "=========================================="

# Load Singularity
__HPC_LOAD_SINGULARITY__

# Calculate SVD run number (1-indexed)
SVD_RUN=$((SLURM_ARRAY_TASK_ID + 1))
SVD_DIR="__OUTPUT_BASE__/svd_run_${SVD_RUN}"

echo "SVD run: $SVD_RUN"
echo "Directory: $SVD_DIR"
echo "Container: __CONTAINER__"
echo ""

# Validate all bootstrap trees exist (Tree_1.nw through Tree_N.nw)
BOOTSTRAPS=__BOOTSTRAPS__
MISSING_TREES=()
for i in $(seq 1 $BOOTSTRAPS); do
    if [ ! -f "$SVD_DIR/Tree_${i}.nw" ]; then
        MISSING_TREES+=("Tree_${i}.nw")
    fi
done

if [ ${#MISSING_TREES[@]} -gt 0 ]; then
    echo "ERROR: Missing ${#MISSING_TREES[@]} bootstrap tree(s):"
    for tree in "${MISSING_TREES[@]}"; do
        echo "  - $tree"
    done
    echo ""
    echo "Expected: Tree_1.nw through Tree_${BOOTSTRAPS}.nw ($BOOTSTRAPS bootstrap replicates)"
    echo "Found: $((BOOTSTRAPS - ${#MISSING_TREES[@]})) trees"
    echo ""
    echo "Ensure Step 1 completed successfully for all bootstrap jobs."
    echo "Check logs: __LOG_DIR__/step1_*_${SLURM_ARRAY_TASK_ID}.{out,err}"
    exit 1
fi

echo "✓ Validated all $BOOTSTRAPS bootstrap trees present"

# Concatenate bootstrap trees
BOOT_FILE="$SVD_DIR/Tree_Bootstrap.nw"
echo "[1/2] Concatenating bootstrap trees..."
rm -f "$BOOT_FILE"
for i in $(seq 1 $BOOTSTRAPS); do
    cat "$SVD_DIR/Tree_${i}.nw" >> "$BOOT_FILE"
done

echo "  ✓ Created Tree_Bootstrap.nw ($(wc -l < "$BOOT_FILE") trees)"

# Calculate TBE support values using gotree in container
SUPPORT_FILE="$SVD_DIR/Tree_support.nw"
echo "[2/2] Computing TBE support values..."
echo "  Using: gotree (inside container)"
echo "  Reference tree: Tree_0.nw"
echo "  Bootstrap trees: Tree_Bootstrap.nw"
echo "  Output: Tree_support.nw"
echo ""

singularity exec --no-home --bind __OUTPUT_BASE__:__OUTPUT_BASE__ __CONTAINER__ \
    sh -c 'export LD_LIBRARY_PATH=/usr/local/julia/lib/julia:/lib64:$LD_LIBRARY_PATH && \
           gotree \
           -i "'"$SVD_DIR"'/Tree_0.nw" \
           -b "'"$BOOT_FILE"'" \
           -o "'"$SUPPORT_FILE"'" \
           -@ 4 \
           -a tbe'

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✓ Bootstrap support calculation complete"
    echo "=========================================="
    echo "Output: $SUPPORT_FILE"
    echo "Size: $(du -h "$SUPPORT_FILE" | cut -f1)"
    echo "End: $(date)"
    echo "=========================================="
else
    echo ""
    echo "=========================================="
    echo "✗ Bootstrap support calculation FAILED"
    echo "=========================================="
    echo "End: $(date)"
    echo "=========================================="
    exit 1
fi
EOFCONTAINER
else
    # Native mode
    cat > "$SBATCH_SCRIPT" <<'EOFNATIVE'
#!/bin/bash
#SBATCH --job-name=tumorspace_bootstrap
#SBATCH --output=__LOG_DIR__/bootstrap_support_%A_%a.out
#SBATCH --error=__LOG_DIR__/bootstrap_support_%A_%a.err
#SBATCH --time=00:15:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --account=__ACCOUNT__
#SBATCH --partition=__PARTITION__
#SBATCH --mem=32G
#SBATCH --array=0-__ARRAY_MAX__

echo "=========================================="
echo "Bootstrap Support Calculation"
echo "=========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Array Task ID: $SLURM_ARRAY_TASK_ID"
echo "Node: $(hostname)"
echo "Start: $(date)"
echo "=========================================="

# Calculate SVD run number (1-indexed)
SVD_RUN=$((SLURM_ARRAY_TASK_ID + 1))
SVD_DIR="__OUTPUT_BASE__/svd_run_${SVD_RUN}"

echo "SVD run: $SVD_RUN"
echo "Directory: $SVD_DIR"
echo ""

# Check if directory exists
if [ ! -d "$SVD_DIR" ]; then
    echo "ERROR: SVD run directory not found: $SVD_DIR"
    echo "Ensure Step 1 completed successfully"
    exit 1
fi

# Check for Tree_0.nw
if [ ! -f "$SVD_DIR/Tree_0.nw" ]; then
    echo "ERROR: Tree_0.nw not found in $SVD_DIR"
    exit 1
fi

# Validate all bootstrap trees exist (Tree_1.nw through Tree_N.nw)
BOOTSTRAPS=__BOOTSTRAPS__
MISSING_TREES=()
for i in $(seq 1 $BOOTSTRAPS); do
    if [ ! -f "$SVD_DIR/Tree_${i}.nw" ]; then
        MISSING_TREES+=("Tree_${i}.nw")
    fi
done

if [ ${#MISSING_TREES[@]} -gt 0 ]; then
    echo "ERROR: Missing ${#MISSING_TREES[@]} bootstrap tree(s):"
    for tree in "${MISSING_TREES[@]}"; do
        echo "  - $tree"
    done
    echo ""
    echo "Expected: Tree_1.nw through Tree_${BOOTSTRAPS}.nw ($BOOTSTRAPS bootstrap replicates)"
    echo "Found: $((BOOTSTRAPS - ${#MISSING_TREES[@]})) trees"
    echo ""
    echo "Ensure Step 1 completed successfully for all bootstrap jobs."
    echo "Check logs: __LOG_DIR__/step1_*_${SLURM_ARRAY_TASK_ID}.{out,err}"
    exit 1
fi

echo "✓ Validated all $BOOTSTRAPS bootstrap trees present"

# Concatenate bootstrap trees
BOOT_FILE="$SVD_DIR/Tree_Bootstrap.nw"
echo "[1/2] Concatenating bootstrap trees..."
rm -f "$BOOT_FILE"
for i in $(seq 1 $BOOTSTRAPS); do
    cat "$SVD_DIR/Tree_${i}.nw" >> "$BOOT_FILE"
done

echo "  ✓ Created Tree_Bootstrap.nw ($(wc -l < "$BOOT_FILE") trees)"

# Calculate TBE support values
SUPPORT_FILE="$SVD_DIR/Tree_support.nw"
echo "[2/2] Computing TBE support values..."
echo "  Using: __GOTREE_BIN__"
echo "  Reference tree: Tree_0.nw"
echo "  Bootstrap trees: Tree_Bootstrap.nw"
echo "  Output: Tree_support.nw"
echo ""

__GOTREE_BIN__ \
    -i "$SVD_DIR/Tree_0.nw" \
    -b "$BOOT_FILE" \
    -o "$SUPPORT_FILE" \
    -@ 4 \
    -a tbe

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✓ Bootstrap support calculation complete"
    echo "=========================================="
    echo "Output: $SUPPORT_FILE"
    echo "Size: $(du -h "$SUPPORT_FILE" | cut -f1)"
    echo "End: $(date)"
    echo "=========================================="
else
    echo ""
    echo "=========================================="
    echo "✗ Bootstrap support calculation FAILED"
    echo "=========================================="
    exit 1
fi
EOFNATIVE
fi

# Substitute variables
sed -i "s|__ACCOUNT__|$ACCOUNT|g" "$SBATCH_SCRIPT"
sed -i "s|__PARTITION__|$PARTITION|g" "$SBATCH_SCRIPT"
sed -i "s|__LOG_DIR__|$LOG_DIR|g" "$SBATCH_SCRIPT"
sed -i "s|__OUTPUT_BASE__|$OUTPUT_BASE|g" "$SBATCH_SCRIPT"
sed -i "s|__ARRAY_MAX__|$ARRAY_MAX|g" "$SBATCH_SCRIPT"
sed -i "s|__BOOTSTRAPS__|$BOOTSTRAPS|g" "$SBATCH_SCRIPT"
python3 -c "
import sys
content = open(sys.argv[1], encoding='utf-8').read()
content = content.replace('__HPC_LOAD_SINGULARITY__', sys.argv[2])
open(sys.argv[1], 'w', encoding='utf-8').write(content)
" "$SBATCH_SCRIPT" "${HPC_LOAD_SINGULARITY}"

if [ "$USE_CONTAINER" = true ]; then
    sed -i "s|__CONTAINER__|$CONTAINER|g" "$SBATCH_SCRIPT"
else
    sed -i "s|__GOTREE_BIN__|$GOTREE_BIN|g" "$SBATCH_SCRIPT"
fi

# Submit job
echo "Submitting bootstrap support calculation..."
echo "  Mode: $MODE"
echo "  Account: $ACCOUNT"
echo "  Partition: $PARTITION"
echo "  SVD runs: $NUM_SVD (array 0-$ARRAY_MAX)"
echo "  Output base: $OUTPUT_BASE"
if [ "$USE_CONTAINER" = true ]; then
    echo "  Container: $CONTAINER"
else
    echo "  gotree binary: $GOTREE_BIN"
fi
if [ -n "$DEPENDENCY" ]; then
    echo "  Dependency: $DEPENDENCY"
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
echo "Bootstraps per SVD: $BOOTSTRAPS"
echo "Job array: $JOB_ID [0-$ARRAY_MAX]"
echo ""
echo "Monitor with:"
echo "  squeue -j $JOB_ID --array"
echo "  tail -f $LOG_DIR/bootstrap_support_${JOB_ID}_*.out"

# Return job ID for dependency chaining
echo "$JOB_ID"