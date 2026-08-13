#!/bin/bash
#
# run_pipeline_full.sh
#
# Master Orchestrator: End-to-End TumorSPACE Pipeline with Job Dependencies
#
# This script orchestrates the complete TumorSPACE workflow from tree building through
# spatial group analysis with SLURM job dependencies. It submits Steps 1-9 as a dependency
# chain for fully automated execution.
#
# Usage:
#   bash run_pipeline_full.sh --dataset DATASET --account ACCOUNT --partition PARTITION \
#                            --input-dir DIR --data-dir DIR --output-base DIR [OPTIONS]
#
# Required Arguments:
#   --dataset DATASET       Dataset name (e.g., GSE213688_GSM6592057)
#   --account ACCOUNT       SLURM account (e.g., pi-araman)
#   --partition PARTITION   SLURM partition (e.g., caslake)
#   --input-dir DIR        Input directory containing barcodes_positions.txt
#   --data-dir DIR         Data directory containing M.txt, barcodes.txt, genes.txt
#   --output-base DIR      Base directory for all outputs (will create svd_run_N/ subdirs)
#
# Optional Arguments:
#   --num-svd N            Number of SVD runs (default: 30, or 3 with --test)
#   --container DIR        Container directory for Singularity execution
#   --keep-all             Keep all SVD directories after selection (default: delete non-optimal)
#   --test                 Test mode: process only 3 SVDs
#   --dry-run              Show job submission commands without executing
#
# Pipeline Steps with Dependencies:
#   Step 1:  phylo_tree_build.jl     (job array 1-N)     Independent
#   Step 1b: phylo_bootstrap_support (job array 1-N)     after Step 1 (REQUIRED)
#   Step 2:  phylo_node_extract.jl   (job array 1-N)     after Step 1b
#   Step 3:  spatial_optimize.jl     (job array 1-N)     after Step 2
#   Step 4:  phylo_tree_prune.jl     (job array 1-N)     after Step 3
#   Step 5:  SVD selection           (single job)        after Step 4
#   Step 6:  sg_identify_pairs.R     (single job)        after Step 5
#   Step 7:  sg_diff_abundance.jl    (single job)        after Step 6
#   Step 8:  sg_slab_score.jl        (single job)        after Step 7
#   Step 9:  pipeline_completion     (single job)        after Step 8
#   Step 10: bayesspace              (single job)        after Step 9
#            Auto-enabled when BAYESSPACE_*_AVAILABLE=true in config/capabilities.sh
#            Override: --bayesspace (force on) or --no-bayesspace (skip)
#   Step 11: pipeline_report          (single job)        after Step 10 (or Step 9 if BayesSpace skipped)
#            Consolidates outputs from all features into Pipeline_Report.pdf + pipeline_summary.md
#
# Outputs (written to output-base/):
#   - svd_run_1/ through svd_run_N/   (all SVD results)
#   - optimal/ -> svd_run_X/          (symlink to best SVD)
#   - optimal_svd.txt                 (selected SVD info)
#   - pipeline_jobs.txt               (job IDs for tracking)
#
# Example:
#   # Test mode with 3 SVDs
#   bash run_pipeline_full.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-dir benchmarks/GSE213688_GSM6592057/input_data \
#       --output-base test_pipeline_output --test
#
#   # Production mode with 30 SVDs, bootstrap, and containers
#   bash run_pipeline_full.sh --dataset GSE213688_GSM6592057 \
#       --account pi-araman --partition caslake \
#       --input-dir benchmarks/GSE213688_GSM6592057/input_data \
#       --output-base results/GSE213688_GSM6592057 \
#       --bootstrap --container containers
#

set -e

# Default values
DATASET=""
ACCOUNT=""
PARTITION=""
INPUT_DIR=""
DATA_DIR=""
OUTPUT_BASE=""
NUM_SVD=30
CONTAINER=""
KEEP_ALL=false
TEST_MODE=false
FIXED_SEED=""
DRY_RUN=false
WORKSPACE_ROOT=""
RUN_BAYESSPACE=""  # empty = auto-detect from capabilities; "true" = force; "false" = skip

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
        --input-dir)
            INPUT_DIR="$2"
            shift 2
            ;;
        --data-dir)
            DATA_DIR="$2"
            shift 2
            ;;
        --output-base)
            OUTPUT_BASE="$2"
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
        --keep-all)
            KEEP_ALL=true
            shift
            ;;
        --test)
            TEST_MODE=true
            FIXED_SEED="1000"  # Default fixed seed for test mode
            shift
            ;;
        --fixed-seed)
            FIXED_SEED="$2"
            shift 2
            ;;
        --random-seed)
            FIXED_SEED=""
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --bayesspace)
            RUN_BAYESSPACE=true
            shift
            ;;
        --no-bayesspace)
            RUN_BAYESSPACE=false
            shift
            ;;
        --help)
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
if [ -z "$DATASET" ] || [ -z "$ACCOUNT" ] || [ -z "$PARTITION" ] || [ -z "$INPUT_DIR" ] || [ -z "$DATA_DIR" ] || [ -z "$OUTPUT_BASE" ]; then
    echo "ERROR: Missing required arguments"
    echo ""
    echo "Required: --dataset, --account, --partition, --input-dir, --data-dir, --output-base"
    echo ""
    echo "Usage:"
    echo "  bash run_pipeline_full.sh --dataset DATASET --account ACCOUNT --partition PARTITION \\"
    echo "                           --input-dir DIR --data-dir DIR --output-base DIR [OPTIONS]"
    echo ""
    echo "Run with --help for full documentation"
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
# Auto-detect BayesSpace availability from capabilities (if not forced)
if [ -z "$RUN_BAYESSPACE" ]; then
    _CAPS="${WORKSPACE_ROOT}/config/capabilities.sh"
    if [ -f "$_CAPS" ]; then
        # shellcheck disable=SC1090
        source "$_CAPS"
        if [ "${BAYESSPACE_CONTAINER_AVAILABLE:-false}" = true ] || \
           [ "${BAYESSPACE_NATIVE_AVAILABLE:-false}" = true ]; then
            RUN_BAYESSPACE=true
        else
            RUN_BAYESSPACE=false
        fi
    else
        RUN_BAYESSPACE=false
    fi
    unset _CAPS
fi
# Convert to absolute paths
INPUT_DIR=$(realpath "$INPUT_DIR")
DATA_DIR=$(realpath "$DATA_DIR")

# Determine mode string for directory naming
MODE_STR="native"
if [ -n "$CONTAINER" ]; then
    MODE_STR="container"
fi

# Test mode: only 3 SVDs
if [ "$TEST_MODE" = true ]; then
    NUM_SVD=3
    MODE_STR="${MODE_STR}_test"
else
    MODE_STR="${MODE_STR}_prod"
fi

# Generate timestamp in ISO 8601 format (YYYYMMDD_HHMMSS)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# If OUTPUT_BASE doesn't already contain the dataset name, prepend it
# This ensures outputs go INSIDE the specified directory with dataset naming
if [[ ! "$OUTPUT_BASE" =~ (^|/)${DATASET}(_|$|/) ]]; then
    # Dataset not in path - add it as subdirectory with mode_timestamp
    if [[ "$OUTPUT_BASE" == */ ]]; then
        OUTPUT_BASE="${OUTPUT_BASE}${DATASET}_${MODE_STR}_${TIMESTAMP}"
    else
        OUTPUT_BASE="${OUTPUT_BASE}/${DATASET}_${MODE_STR}_${TIMESTAMP}"
    fi
elif [[ ! "$OUTPUT_BASE" =~ (native|container)_(test|prod)_[0-9]{8}_[0-9]{6}$ ]]; then
    # Dataset is in path, but no mode_timestamp suffix yet
    if [[ "$OUTPUT_BASE" =~ (native|container)_(test|prod)$ ]]; then
        # Just append timestamp
        OUTPUT_BASE="${OUTPUT_BASE}_${TIMESTAMP}"
    else
        # Append both mode and timestamp
        OUTPUT_BASE="${OUTPUT_BASE}_${MODE_STR}_${TIMESTAMP}"
    fi
fi

OUTPUT_BASE=$(realpath -m "$OUTPUT_BASE")

# Check input directory exists
if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

# Check data directory exists
if [ ! -d "$DATA_DIR" ]; then
    echo "ERROR: Data directory not found: $DATA_DIR"
    exit 1
fi

# Check barcodes_positions.txt exists
BARCODE_POSITIONS="$INPUT_DIR/barcodes_positions.txt"
if [ ! -f "$BARCODE_POSITIONS" ]; then
    echo "ERROR: barcodes_positions.txt not found in $INPUT_DIR"
    exit 1
fi

# Check required data files for Steps 6-9
for file in M.txt barcodes.txt; do
    if [ ! -f "$DATA_DIR/$file" ]; then
        echo "ERROR: $file not found in $DATA_DIR"
        exit 1
    fi
done

# Check for genes.txt or features.txt
if [ ! -f "$DATA_DIR/genes.txt" ] && [ ! -f "$DATA_DIR/features.txt" ]; then
    echo "ERROR: Neither genes.txt nor features.txt found in $DATA_DIR"
    exit 1
fi

# Create output directory (optimal/ will be created by Step 5 as symlink)
mkdir -p "$OUTPUT_BASE"
mkdir -p logs

# Print pipeline information
echo "=============================================================================="
echo "TumorSPACE Full Pipeline: Steps 1-9 with Job Dependencies"
echo "=============================================================================="
echo "Dataset:       $DATASET"
echo "Account:       $ACCOUNT"
echo "Partition:     $PARTITION"
echo "Input Dir:     $INPUT_DIR"
echo "Data Dir:      $DATA_DIR"
echo "Output Base:   $OUTPUT_BASE"
echo "Num SVDs:      $NUM_SVD"
echo "Container:     ${CONTAINER:-none}"
echo "Keep All:      $KEEP_ALL"
echo "Test Mode:     $TEST_MODE"
echo "Fixed Seed:    ${FIXED_SEED:-random}"
echo "Dry Run:       $DRY_RUN"
echo "=============================================================================="
echo

# Initialize job tracking
PIPELINE_JOBS="$OUTPUT_BASE/pipeline_jobs.txt"
cat > "$PIPELINE_JOBS" << EOF
# TumorSPACE Pipeline Job IDs
# Generated: $(date)
# Dataset: $DATASET
# Output: $OUTPUT_BASE

EOF

# Step 1: Phylogenetic Tree Building
echo "[Step 1/5] Submitting phylogenetic tree building (job array 1-$NUM_SVD)..."
STEP1_ARGS="--account $ACCOUNT --partition $PARTITION --dataset $DATASET --workspace-root $WORKSPACE_ROOT --input-dir $INPUT_DIR --output-dir $OUTPUT_BASE"
if [ "$TEST_MODE" = true ]; then
    STEP1_ARGS="$STEP1_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP1_ARGS="$STEP1_ARGS --container $CONTAINER"
fi

STEP1_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh $STEP1_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP1_CMD"
    STEP1_JOB="12345"
else
    STEP1_JOB=$($STEP1_CMD 2>&1 | tail -1)
    echo "  ✓ Step 1 submitted: Job $STEP1_JOB"
    echo "Step1_TreeBuild: $STEP1_JOB" >> "$PIPELINE_JOBS"
fi

# Step 1b: Bootstrap Support (REQUIRED)
echo "[Step 1b/5] Submitting bootstrap support calculation..."
STEP1B_ARGS="--account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --output-base $OUTPUT_BASE --num-svd $NUM_SVD --dependency $STEP1_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP1B_ARGS="$STEP1B_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP1B_ARGS="$STEP1B_ARGS --container $CONTAINER"
fi

STEP1B_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_phylo_bootstrap_support.sh $STEP1B_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP1B_CMD"
    STEP1B_JOB="12346"
else
    STEP1B_JOB=$($STEP1B_CMD 2>&1 | tail -1)
    echo "  ✓ Step 1b submitted: Job $STEP1B_JOB (after $STEP1_JOB)"
    echo "Step1b_Bootstrap: $STEP1B_JOB" >> "$PIPELINE_JOBS"
fi
PREV_JOB=$STEP1B_JOB

# Step 2: Node Extraction
echo "[Step 2/5] Submitting node extraction..."
STEP2_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --input-dir $INPUT_DIR --num-svd $NUM_SVD --dependency $PREV_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP2_ARGS="$STEP2_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP2_ARGS="$STEP2_ARGS --container $CONTAINER"
fi

STEP2_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_phylo_node_extract.sh $STEP2_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP2_CMD"
    STEP2_JOB="12347"
else
    STEP2_JOB=$($STEP2_CMD 2>&1 | tail -1)
    echo "  ✓ Step 2 submitted: Job $STEP2_JOB (after $PREV_JOB)"
    echo "Step2_NodeExtract: $STEP2_JOB" >> "$PIPELINE_JOBS"
fi

# Step 3: Spatial Optimization
echo "[Step 3/5] Submitting spatial optimization..."
STEP3_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --input-dir $INPUT_DIR --num-svd $NUM_SVD --dependency $STEP2_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP3_ARGS="$STEP3_ARGS --test"
fi
if [ -n "$FIXED_SEED" ]; then
    STEP3_ARGS="$STEP3_ARGS --fixed-seed $FIXED_SEED"
fi
if [ -n "$CONTAINER" ]; then
    STEP3_ARGS="$STEP3_ARGS --container $CONTAINER"
fi

STEP3_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_spatial_optimize.sh $STEP3_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP3_CMD"
    STEP3_JOB="12348"
else
    STEP3_JOB=$($STEP3_CMD 2>&1 | tail -1)
    echo "  ✓ Step 3 submitted: Job $STEP3_JOB (after $STEP2_JOB)"
    echo "Step3_SpatialOpt: $STEP3_JOB" >> "$PIPELINE_JOBS"
fi

# Step 4: Tree Pruning
echo "[Step 4/5] Submitting tree pruning..."
STEP4_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --num-svd $NUM_SVD --dependency $STEP3_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP4_ARGS="$STEP4_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP4_ARGS="$STEP4_ARGS --container $CONTAINER"
fi

STEP4_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_phylo_tree_prune.sh $STEP4_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP4_CMD"
    STEP4_JOB="12349"
else
    STEP4_JOB=$($STEP4_CMD 2>&1 | tail -1)
    echo "  ✓ Step 4 submitted: Job $STEP4_JOB (after $STEP3_JOB)"
    echo "Step4_TreePrune: $STEP4_JOB" >> "$PIPELINE_JOBS"
fi

# Step 5: SVD Selection
echo "[Step 5/5] Submitting SVD selection..."
KEEP_ALL_FLAG=""
if [ "$KEEP_ALL" = true ]; then
    KEEP_ALL_FLAG="--keep-all"
fi

STEP5_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --num-svd $NUM_SVD $KEEP_ALL_FLAG --dependency $STEP4_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP5_ARGS="$STEP5_ARGS --test"
fi

STEP5_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_svd_selection.sh $STEP5_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP5_CMD"
    STEP5_JOB="12350"
else
    STEP5_JOB=$($STEP5_CMD 2>&1 | tail -1)
    echo "  ✓ Step 5 submitted: Job $STEP5_JOB (after $STEP4_JOB)"
    echo "Step5_SVDSelect: $STEP5_JOB" >> "$PIPELINE_JOBS"
fi

# Step 6: SG Identification
echo "[Step 6/9] Submitting SG identification..."
STEP6_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --dependency $STEP5_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP6_ARGS="$STEP6_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP6_ARGS="$STEP6_ARGS --container $CONTAINER"
fi

STEP6_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_sg_identify_pairs.sh $STEP6_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP6_CMD"
    STEP6_JOB="12351"
else
    STEP6_JOB=$($STEP6_CMD 2>&1 | tail -1)
    echo "  ✓ Step 6 submitted: Job $STEP6_JOB (after $STEP5_JOB)"
    echo "Step6_SGIdentify: $STEP6_JOB" >> "$PIPELINE_JOBS"
fi

# Step 7: Differential Abundance
echo "[Step 7/9] Submitting differential abundance..."
STEP7_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --data-dir $DATA_DIR --dependency $STEP6_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP7_ARGS="$STEP7_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP7_ARGS="$STEP7_ARGS --container $CONTAINER"
fi
if [ -n "$FIXED_SEED" ]; then
    STEP7_ARGS="$STEP7_ARGS --fixed-seed $FIXED_SEED"
fi

STEP7_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_sg_diff_abundance.sh $STEP7_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP7_CMD"
    STEP7_JOB="12352"
else
    STEP7_JOB=$($STEP7_CMD 2>&1 | tail -1)
    echo "  ✓ Step 7 submitted: Job $STEP7_JOB (after $STEP6_JOB)"
    echo "Step7_DiffAbund: $STEP7_JOB" >> "$PIPELINE_JOBS"
fi

# Step 8: SLAB Scoring
# Adaptive memory allocation based on spot count
SPOT_COUNT=$(wc -l < "$DATA_DIR/barcodes.txt")
if [ "$SPOT_COUNT" -gt 2000 ]; then
    MEM_STEP8="16G"
    echo "[Step 8/9] Submitting SLAB scoring (${SPOT_COUNT} spots, using 16G memory)..."
elif [ "$SPOT_COUNT" -gt 1000 ]; then
    MEM_STEP8="8G"
    echo "[Step 8/9] Submitting SLAB scoring (${SPOT_COUNT} spots, using 8G memory)..."
else
    MEM_STEP8="4G"
    echo "[Step 8/9] Submitting SLAB scoring (${SPOT_COUNT} spots, using 4G memory)..."
fi

STEP8_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --data-dir $DATA_DIR --dependency $STEP7_JOB --mem $MEM_STEP8"
if [ "$TEST_MODE" = true ]; then
    STEP8_ARGS="$STEP8_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP8_ARGS="$STEP8_ARGS --container $CONTAINER"
fi

STEP8_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_sg_slab_score.sh $STEP8_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP8_CMD"
    STEP8_JOB="12353"
else
    STEP8_JOB=$($STEP8_CMD 2>&1 | tail -1)
    echo "  ✓ Step 8 submitted: Job $STEP8_JOB (after $STEP7_JOB)"
    echo "Step8_SLABScore: $STEP8_JOB" >> "$PIPELINE_JOBS"
fi

# Step 9: Pipeline Completion
echo "[Step 9/10] Submitting pipeline completion..."
STEP9_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --mode $MODE_STR --num-svd $NUM_SVD --dependency $STEP8_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP9_ARGS="$STEP9_ARGS --test"
fi

STEP9_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_pipeline_completion.sh $STEP9_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP9_CMD"
    STEP9_JOB="12354"
else
    STEP9_JOB=$($STEP9_CMD 2>&1 | tail -1)
    echo "  ✓ Step 9 submitted: Job $STEP9_JOB (after $STEP8_JOB)"
    echo "Step9_Completion: $STEP9_JOB" >> "$PIPELINE_JOBS"
fi

# Step 10: BayesSpace (optional — depends on Step 9; reads INPUT_DIR for spatial clustering)
BS_JOB="skipped"
if [ "$RUN_BAYESSPACE" = true ]; then
    echo "[Step 10] Submitting BayesSpace spatial clustering (after Step 9)..."
    BS_OUTDIR="$OUTPUT_BASE/bayesspace"
    mkdir -p "$BS_OUTDIR"
    BS_EXTRA=""
    if [ "$TEST_MODE" = true ]; then
        BS_EXTRA="--test"
    fi

    BS_SBATCH_CMD="sbatch \
        --account $ACCOUNT \
        --partition $PARTITION \
        --mem=16G \
        --time=30:00 \
        --dependency=afterok:${STEP9_JOB} \
        --job-name=bayesspace_${DATASET} \
        --output=${BS_OUTDIR}/slurm_%j.out \
        --error=${BS_OUTDIR}/slurm_%j.err \
        --wrap=\"bash ${WORKSPACE_ROOT}/workflows/bayesspace/orchestration/run_bayesspace.sh \
            --datapath ${INPUT_DIR} \
            --outdir ${BS_OUTDIR} \
            ${BS_EXTRA}\""

    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: $BS_SBATCH_CMD"
        BS_JOB="dry-run"
    else
        BS_JOB=$(eval "$BS_SBATCH_CMD" 2>&1 | tail -1 | awk '{print $NF}')
        if [[ "$BS_JOB" =~ ^[0-9]+$ ]]; then
            echo "  ✓ BayesSpace submitted: Job $BS_JOB (after $STEP9_JOB)"
            echo "Step10_BayesSpace: $BS_JOB" >> "$PIPELINE_JOBS"
        else
            echo "  ✗ BayesSpace submission failed: $BS_JOB"
            echo "Step10_BayesSpace: FAILED" >> "$PIPELINE_JOBS"
            BS_JOB="FAILED"
        fi
    fi
else
    echo "[Step 10] BayesSpace: skipped (not available or --no-bayesspace)"
fi

# Step 11: Pipeline Report (mandatory — depends on BayesSpace if it ran, else Step 9)
# Consolidates outputs from all features into Pipeline_Report.pdf + pipeline_summary.md
echo "[Step 11] Submitting pipeline report..."

# Determine dependency: use BS_JOB if it was submitted, otherwise STEP9_JOB
if [[ "$BS_JOB" =~ ^[0-9]+$ ]]; then
    REPORT_DEP="$BS_JOB"
else
    REPORT_DEP="$STEP9_JOB"
fi

STEP11_ARGS="--output-dir $OUTPUT_BASE/optimal --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --dependency $REPORT_DEP"
if [ -n "$CONTAINER" ]; then
    STEP11_ARGS="$STEP11_ARGS --container $CONTAINER"
fi

# Add reference directory for test dataset
if [ "$DATASET" = "GSE213688_GSM6592057" ]; then
    REFERENCE_BASE="$(realpath $WORKSPACE_ROOT/benchmarks/$DATASET/expected_outputs 2>/dev/null)"
    if [ -n "$REFERENCE_BASE" ] && [ -d "$REFERENCE_BASE" ]; then
        STEP11_ARGS="$STEP11_ARGS --reference-dir $REFERENCE_BASE"
        echo "  Test dataset: Will validate against reference baseline"
    else
        echo "  Test dataset: No reference baseline yet (will note in report)"
    fi
fi

STEP11_CMD="bash $WORKSPACE_ROOT/workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh $STEP11_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP11_CMD"
    STEP11_JOB="12355"
else
    STEP11_OUTPUT=$($STEP11_CMD 2>&1)
    STEP11_JOB=$(echo "$STEP11_OUTPUT" | grep -E '^[0-9]+$' | head -1)

    if echo "$STEP11_OUTPUT" | grep -i "error\|failed" > /dev/null; then
        echo "  ⚠ Step 11 warnings/errors detected:" >&2
        echo "$STEP11_OUTPUT" | grep -i "error\|failed" >&2
    fi

    if [[ "$STEP11_JOB" =~ ^[0-9]+$ ]]; then
        echo "  ✓ Step 11 submitted: Job $STEP11_JOB (after $REPORT_DEP)"
        echo "Step11_Pipeline_Report: $STEP11_JOB" >> "$PIPELINE_JOBS"
    else
        echo "  ✗ Step 11 submission failed: $STEP11_JOB"
        echo "  Full output:" >&2
        echo "$STEP11_OUTPUT" >&2
        echo "Step11_Pipeline_Report: FAILED" >> "$PIPELINE_JOBS"
    fi
fi

echo ""
echo "=============================================================================="
echo "All jobs submitted with dependency chain:"
echo "  Step 1  (Tree Build):      $STEP1_JOB"
echo "  Step 1b (Bootstrap):       $STEP1B_JOB  (after $STEP1_JOB)"
echo "  Step 2  (Node Extract):    $STEP2_JOB  (after $STEP1B_JOB)"
echo "  Step 3  (Spatial Opt):     $STEP3_JOB  (after $STEP2_JOB)"
echo "  Step 4  (Tree Prune):      $STEP4_JOB  (after $STEP3_JOB)"
echo "  Step 5  (SVD Selection):   $STEP5_JOB  (after $STEP4_JOB)"
echo "  Step 6  (SG Identify):     $STEP6_JOB  (after $STEP5_JOB)"
echo "  Step 7  (Diff Abund):      $STEP7_JOB  (after $STEP6_JOB)"
echo "  Step 8  (SLAB Score):      $STEP8_JOB  (after $STEP7_JOB)"
echo "  Step 9  (Completion):      $STEP9_JOB  (after $STEP8_JOB)"
echo "  Step 10 (BayesSpace):      $BS_JOB (after $STEP9_JOB)"
echo "  Step 11 (Pipeline Report): $STEP11_JOB (after ${REPORT_DEP}) **MANDATORY**"
echo ""
echo "Job tracking saved to: $PIPELINE_JOBS"
echo ""
echo "Monitor pipeline status:"
echo "  squeue -u \$USER"
echo "  watch -n 5 'squeue -u \$USER'"
echo ""
echo "Check individual job status:"
echo "  sacct -j $STEP1_JOB --format=JobID,State,ExitCode,Elapsed"
echo ""
echo "After completion, check results:"
echo "  cat $OUTPUT_BASE/optimal_svd.txt"
echo "  cat $OUTPUT_BASE/optimal/PIPELINE_COMPLETE.txt"
echo "  ls -la $OUTPUT_BASE/optimal/"
echo ""
echo "Pipeline Report will be generated automatically:"
echo "  Location: $OUTPUT_BASE/pipeline_reports/"
echo "  Contains: Pipeline_Report.pdf, pipeline_summary.md, all feature plots"
if [ "$TEST_MODE" = true ]; then
    echo "  Test Mode: Includes reference validation (Plot 5) and BayesSpace clusters"
fi
echo ""
echo "Pipeline outputs will be in:"
echo "  $OUTPUT_BASE/svd_run_1/ through svd_run_$NUM_SVD/"
echo "  $OUTPUT_BASE/optimal/ (symlink to best SVD)"
echo "  $OUTPUT_BASE/optimal/OptimalTree_pruned_node_*.txt (SG pairs)"
echo "  $OUTPUT_BASE/optimal/DA_significant.txt (significant genes)"
echo "  $OUTPUT_BASE/optimal/SLAB_scores.txt (spatial scores)"
echo "=============================================================================="