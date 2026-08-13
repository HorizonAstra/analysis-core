#!/bin/bash
#
# TumorSPACE Step 1 Orchestration: Tree Building
# Submits SLURM job array for parallel tree construction
#
# Usage:
#   run_step1.sh --account ACCOUNT --partition PARTITION \
#                --dataset DATASET --input-dir DIR --output-dir DIR \
#                [--container PATH] [--test] [--mem 16G|32G|64G]
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
DATASET=""
INPUT_DIR=""
OUTPUT_DIR=""
CONTAINER=""
TEST_MODE=false
FIXED_SEED=""
MEMORY="16G"
WORKSPACE_ROOT=""
DEPENDENCY=""

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
        --dataset)
            DATASET="$2"
            shift 2
            ;;
        --workspace-root)
            WORKSPACE_ROOT="$2"
            shift 2
            ;;
        --input-dir)
            INPUT_DIR="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
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
            MEMORY="$2"
            shift 2
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

# Auto-derive workspace root if not provided
if [ -z "$WORKSPACE_ROOT" ]; then
    WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../.. && pwd)"
fi

# Validate workspace root
if [ ! -d "$WORKSPACE_ROOT" ]; then
    echo "Error: Workspace root directory not found: $WORKSPACE_ROOT"
    exit 1
fi

# Define script locations (before any use)
JULIA_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia/phylo_tree_build.jl"
JULIA_PROJECT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia"
CONTAINER_JULIA_SCRIPT="/opt/workflows/julia/phylo_tree_build.jl"

# Validate required arguments
if [ -z "$ACCOUNT" ] || [ -z "$PARTITION" ] || [ -z "$DATASET" ] || \
   [ -z "$INPUT_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 --account ACCOUNT --partition PARTITION --dataset DATASET"
    echo "          --input-dir DIR --output-dir DIR [--container PATH]"
    echo "          [--test] [--mem SIZE]"
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
    if [ -d "$OUTPUT_BASE" ]; then
        echo "TEST MODE: Cleaning previous outputs from $OUTPUT_BASE"
        rm -rf "$OUTPUT_BASE"
        echo "✓ Cleaned up previous test run"
        echo ""
    fi
fi

# Pipeline parameters (controlled by us)
if [ "$TEST_MODE" = true ]; then
    SVD_VALUES=(5 50 150)
else
    SVD_VALUES=(5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100 105 110 115 120 125 130 135 140 145 150)
fi

BOOTSTRAPS=10
NUM_SVD=${#SVD_VALUES[@]}
TOTAL_TASKS=$((NUM_SVD * (BOOTSTRAPS + 1)))
ARRAY_MAX=$((TOTAL_TASKS - 1))

# Determine execution mode
if [ -n "$CONTAINER" ]; then
    USE_CONTAINER=true
else
    USE_CONTAINER=false
fi

# Create output and log directories
mkdir -p "$OUTPUT_DIR"
LOG_DIR="$(dirname "$OUTPUT_DIR")/logs"
mkdir -p "$LOG_DIR"

# Generate SLURM job script
SBATCH_SCRIPT=$(mktemp)

if [ "$USE_CONTAINER" = true ]; then
    # Container mode
    cat > "$SBATCH_SCRIPT" <<EOFCONTAINER
#!/bin/bash
#SBATCH --job-name=tumorspace_step1
#SBATCH --output=$LOG_DIR/step1_%A_%a.out
#SBATCH --error=$LOG_DIR/step1_%A_%a.err
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --account=$ACCOUNT
#SBATCH --partition=$PARTITION
#SBATCH --mem=$MEMORY
#SBATCH --array=0-$ARRAY_MAX%50

echo "=========================================="
echo "TumorSPACE Step 1: Tree Building (Container)"
echo "=========================================="
echo "Job ID: \$SLURM_JOB_ID"
echo "Array Task ID: \$SLURM_ARRAY_TASK_ID"
echo "Node: \$(hostname)"
echo "Start: \$(date)"
echo "=========================================="

# Load Singularity
${HPC_LOAD_SINGULARITY}

# Parse task ID
TASK_ID=\$SLURM_ARRAY_TASK_ID
NUM_BOOTSTRAPS=$((BOOTSTRAPS + 1))
SVD_INDEX=\$((TASK_ID / NUM_BOOTSTRAPS))
BOOT=\$((TASK_ID % NUM_BOOTSTRAPS))

SVD_VALUES=(${SVD_VALUES[*]})
SVD_VALUE=\${SVD_VALUES[\$SVD_INDEX]}
SVD_RUN=\$((SVD_INDEX + 1))

echo "Configuration:"
echo "  Dataset: $DATASET"
echo "  SVD run: \$SVD_RUN (value=\$SVD_VALUE)"
echo "  Bootstrap: \$BOOT"
echo "  Container: $CONTAINER"
echo ""

OUTPUT_DIR="$OUTPUT_DIR/svd_run_\$SVD_RUN"
mkdir -p "\$OUTPUT_DIR"

# Check if already completed
if [ -f "\$OUTPUT_DIR/Tree_\${BOOT}.done" ]; then
    echo "Already complete - skipping"
    exit 0
fi

# Run via container
echo "Running tree_build.jl via Singularity..."
echo ""

# Set BLAS threads to 1 to match SLURM allocation (avoid thread over-subscription)
export OPENBLAS_NUM_THREADS=1

# Use embedded container scripts (built into container image)
# Per-task depot path prevents precompile cache races; generic CPU target ensures the /opt/julia_depot cache is valid on all nodes
singularity exec --no-home --env JULIA_DEPOT_PATH=/tmp/julia_depot_\${SLURM_JOB_ID}_\${SLURM_ARRAY_TASK_ID:-0}:/opt/julia_depot --env JULIA_CPU_TARGET=generic --bind "$INPUT_DIR:$INPUT_DIR" --bind "$OUTPUT_DIR:$OUTPUT_DIR" $CONTAINER \
  julia $CONTAINER_JULIA_SCRIPT \\
    --dataset "$DATASET" \\
    --input-dir "$INPUT_DIR" \\
    --output-dir "\$OUTPUT_DIR" \\
    --svd-run "\$SVD_RUN" \\
    --svd-value "\$SVD_VALUE" \\
    --boot "\$BOOT"$([ -n "$FIXED_SEED" ] && echo " --test-seed")

EXIT_CODE=\$?

echo ""
echo "=========================================="
if [ \$EXIT_CODE -eq 0 ]; then
    echo "✓ Tree building completed successfully"
else
    echo "✗ Tree building failed (exit code: \$EXIT_CODE)"
fi
echo "End: \$(date)"
echo "=========================================="

exit \$EXIT_CODE
EOFCONTAINER

else
    # Direct HPC mode
    cat > "$SBATCH_SCRIPT" <<EOFDIRECT
#!/bin/bash
#SBATCH --job-name=tumorspace_step1
#SBATCH --output=$LOG_DIR/step1_%A_%a.out
#SBATCH --error=$LOG_DIR/step1_%A_%a.err
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --account=$ACCOUNT
#SBATCH --partition=$PARTITION
#SBATCH --mem=$MEMORY
#SBATCH --array=0-$ARRAY_MAX%50

echo "=========================================="
echo "TumorSPACE Step 1: Tree Building (Direct HPC)"
echo "=========================================="
echo "Job ID: \$SLURM_JOB_ID"
echo "Array Task ID: \$SLURM_ARRAY_TASK_ID"
echo "Node: \$(hostname)"
echo "Start: \$(date)"
echo "=========================================="

# Parse task ID
TASK_ID=\$SLURM_ARRAY_TASK_ID
NUM_BOOTSTRAPS=$((BOOTSTRAPS + 1))
SVD_INDEX=\$((TASK_ID / NUM_BOOTSTRAPS))
BOOT=\$((TASK_ID % NUM_BOOTSTRAPS))

SVD_VALUES=(${SVD_VALUES[*]})
SVD_VALUE=\${SVD_VALUES[\$SVD_INDEX]}
SVD_RUN=\$((SVD_INDEX + 1))

echo "Configuration:"
echo "  Dataset: $DATASET"
echo "  SVD run: \$SVD_RUN (value=\$SVD_VALUE)"
echo "  Bootstrap: \$BOOT"
echo ""

OUTPUT_DIR="$OUTPUT_DIR/svd_run_\$SVD_RUN"
mkdir -p "\$OUTPUT_DIR"

# Check if already completed
if [ -f "\$OUTPUT_DIR/Tree_\${BOOT}.done" ]; then
    echo "Already complete - skipping"
    exit 0
fi

# Run tree building
echo "Running tree_build.jl..."
echo ""

# Load Julia module
${HPC_LOAD_JULIA}

export JULIA_DEPOT_PATH=${HPC_JULIA_DEPOT}
export JULIA_PKG_PRECOMPILE_AUTO=0

julia --project="$JULIA_PROJECT" $JULIA_SCRIPT \\
    --dataset "$DATASET" \\
    --input-dir "$INPUT_DIR" \\
    --output-dir "\$OUTPUT_DIR" \\
    --svd-run "\$SVD_RUN" \\
    --svd-value "\$SVD_VALUE" \\
    --boot "\$BOOT"$([ -n "$FIXED_SEED" ] && echo " --test-seed")

EXIT_CODE=\$?

echo ""
echo "=========================================="
if [ \$EXIT_CODE -eq 0 ]; then
    echo "✓ Tree building completed successfully"
else
    echo "✗ Tree building failed (exit code: \$EXIT_CODE)"
fi
echo "End: \$(date)"
echo "=========================================="

exit \$EXIT_CODE
EOFDIRECT

fi

# Submit job
echo "=========================================="
echo "TumorSPACE Step 1: Tree Building"
echo "=========================================="
echo "Dataset: $DATASET"
echo "Input: $INPUT_DIR"
echo "Output: $OUTPUT_DIR"
if [ -n "$CONTAINER" ]; then
    echo "Execution: Container"
    echo "Container: $CONTAINER"
else
    echo "Execution: Direct HPC (julia/1.9.0)"
fi
echo "Mode: $([ "$TEST_MODE" = true ] && echo "TEST (3 SVD values)" || echo "PRODUCTION (30 SVD values)")"
echo "Tasks: $TOTAL_TASKS (${NUM_SVD} SVD × $((BOOTSTRAPS + 1)) bootstraps)"
echo "Memory: $MEMORY per task"
echo "Compute: 1 CPU, 30 min"
echo "=========================================="
echo ""

if [ -n "${DEPENDENCY:-}" ]; then
    sbatch_output=$(sbatch --dependency=afterok:"${DEPENDENCY}" --parsable "$SBATCH_SCRIPT" 2>&1)
else
    sbatch_output=$(sbatch "$SBATCH_SCRIPT" 2>&1)
fi
SUBMIT_EXIT=$?

if [ $SUBMIT_EXIT -eq 0 ]; then
    # Extract job ID from sbatch output (format: "Submitted batch job 12345")
    JOB_ID=$(echo "$sbatch_output" | grep -oP '(?<=Submitted batch job )\d+')
    
    SAVED_SCRIPT="$LOG_DIR/step1_sbatch_$(date +%Y%m%d_%H%M%S).sh"
    cp "$SBATCH_SCRIPT" "$SAVED_SCRIPT"
    echo "✓ Job submitted successfully"
    echo "Job ID: $JOB_ID"
    echo "SLURM script saved to: $SAVED_SCRIPT"
    
    # Output job ID on last line for capture by orchestration scripts
    echo "$JOB_ID"
else
    echo "✗ Job submission failed (exit code: $SUBMIT_EXIT)"
    exit $SUBMIT_EXIT
fi

rm -f "$SBATCH_SCRIPT"
exit 0