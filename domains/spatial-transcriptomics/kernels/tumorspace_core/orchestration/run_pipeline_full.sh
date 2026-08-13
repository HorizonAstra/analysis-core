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
#   --harmonize            Run preprocessing (SpaceRanger → TumorSPACE format) before Step 1
#                          Requires --spaceranger-dir; writes to --input-dir / --data-dir
#   --spaceranger-dir DIR  SpaceRanger outs/ directory (required when --harmonize is set)
#   --umi-qc-dir DIR       UMI QC output directory (optional; enables GMM-based spot filtering)
#
# Pipeline Steps with Dependencies:
#   Step 1:  phylo_tree_build.jl     (job array 1-N)     Independent
#   Step 1b: phylo_bootstrap_support (job array 1-N)     after Step 1 (REQUIRED)
#   Step 2:  phylo_node_extract.jl   (job array 1-N)     after Step 1b
#   Step 3:  compute_ripley_k.R      (job array 1-N)     after Step 2  (R/spatstat)
#   Step 4:  spatial_optimize.jl     (job array 1-N)     after Step 3  (hyperparameter opt)
#   Step 5:  phylo_tree_prune.jl     (job array 1-N)     after Step 4
#   Step 6:  SVD selection           (single job)        after Step 5
#   Step 7:  sg_identify_pairs.R     (single job)        after Step 6
#   Step 8:  sg_diff_abundance.jl    (single job)        after Step 7
#   Step 9:  sg_slab_score.jl        (single job)        after Step 8
#   Step 10: pipeline_completion     (single job)        after Step 9
#   Step 11: bayesspace              (single job)        after Step 10
#            Auto-enabled when BAYESSPACE_*_AVAILABLE=true in config/capabilities.sh
#            Override: --bayesspace (force on) or --no-bayesspace (skip)
#   SpaCET:  cell type deconvolution (single job)        independent (no dependency)
#            Requires --cancer-type; auto-enabled when SPACET_*_AVAILABLE=true
#            Override: --no-spacet
#   CT-DA-SLAB: cell type DA + SLAB  (single job)        after Step 7 + SpaCET
#            Runs only when SpaCET is enabled; outputs to optimal/ct/
#   Step 12: pipeline_report          (single job)        after Step 11 (or Step 10 if BayesSpace skipped)
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
RUN_SPACET=""      # empty = auto-detect from capabilities; "true" = force; "false" = skip
CANCER_TYPE=""
NUM_SHUFFLE_CT=100
HARMONIZE=false    # when true, run preprocessing before Step 1
AFTER_JOB=""       # optional: wait for this SLURM job before submitting Step 1
SPACERANGER_DIR="" # required when --harmonize is set
UMI_QC_DIR=""      # optional: pass to run_harmonize.sh for UMI QC step

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
        --harmonize)
            HARMONIZE=true
            shift
            ;;
        --no-harmonize)
            HARMONIZE=false
            shift
            ;;
        --spaceranger-dir)
            SPACERANGER_DIR="$2"
            shift 2
            ;;
        --umi-qc-dir)
            UMI_QC_DIR="$2"
            shift 2
            ;;
        --after)
            AFTER_JOB="$2"
            shift 2
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
        --no-spacet)
            RUN_SPACET=false
            shift
            ;;
        --cancer-type)
            CANCER_TYPE="$2"
            shift 2
            ;;
        --num-shuffle-ct)
            NUM_SHUFFLE_CT="$2"
            shift 2
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
# Auto-detect SpaCET availability (requires --cancer-type + container/R environment)
if [ -z "$RUN_SPACET" ]; then
    _CAPS="${WORKSPACE_ROOT}/config/capabilities.sh"
    if [ -n "$CANCER_TYPE" ] && [ -f "$_CAPS" ]; then
        # shellcheck disable=SC1090
        source "$_CAPS"
        if [ "${SPACET_CONTAINER_AVAILABLE:-false}" = true ] || \
           [ "${SPACET_NATIVE_AVAILABLE:-false}" = true ]; then
            RUN_SPACET=true
        else
            echo "WARNING: --cancer-type provided but SpaCET not available in capabilities"
            RUN_SPACET=false
        fi
    else
        RUN_SPACET=false
    fi
    unset _CAPS
fi
# Convert to absolute paths (-m allows non-existent paths when --after is used)
INPUT_DIR=$(realpath -m "$INPUT_DIR")
DATA_DIR=$(realpath -m "$DATA_DIR")

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
# (skipped when --after is set: directory will be created by the prerequisite job)
if [ -z "${AFTER_JOB:-}" ] && [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

# Check data directory exists
if [ -z "${AFTER_JOB:-}" ] && [ ! -d "$DATA_DIR" ]; then
    echo "ERROR: Data directory not found: $DATA_DIR"
    exit 1
fi

# Check barcodes_positions.txt exists
BARCODE_POSITIONS="$INPUT_DIR/barcodes_positions.txt"
if [ -z "${AFTER_JOB:-}" ] && [ ! -f "$BARCODE_POSITIONS" ]; then
    echo "ERROR: barcodes_positions.txt not found in $INPUT_DIR"
    exit 1
fi

# Check required data files for Steps 6-9
for file in M.txt barcodes.txt; do
    if [ -z "${AFTER_JOB:-}" ] && [ ! -f "$DATA_DIR/$file" ]; then
        echo "ERROR: $file not found in $DATA_DIR"
        exit 1
    fi
done

# Check for genes.txt or features.txt
if [ -z "${AFTER_JOB:-}" ] && [ ! -f "$DATA_DIR/genes.txt" ] && [ ! -f "$DATA_DIR/features.txt" ]; then
    echo "ERROR: Neither genes.txt nor features.txt found in $DATA_DIR"
    exit 1
fi

# Create output directory (optimal/ will be created by Step 5 as symlink)
mkdir -p "$OUTPUT_BASE"
mkdir -p logs

# ── Optional Step H: Preprocessing (SpaceRanger → harmonized format) ──────────
if [ "$HARMONIZE" = true ]; then
    if [ -z "$SPACERANGER_DIR" ]; then
        echo "ERROR: --harmonize requires --spaceranger-dir" >&2
        exit 1
    fi
    HARMONIZE_SCRIPT="${WORKSPACE_ROOT}/workflows/preprocessing/orchestration/run_harmonize.sh"
    if [ ! -f "$HARMONIZE_SCRIPT" ]; then
        echo "ERROR: run_harmonize.sh not found at ${HARMONIZE_SCRIPT}" >&2
        exit 1
    fi
    echo "=============================================================================="
    echo "Step H: Preprocessing"
    echo "=============================================================================="
    HARM_ARGS=(--dataset "$DATASET" --spaceranger-dir "$SPACERANGER_DIR"
               --output-dir "$INPUT_DIR")
    [ -n "$UMI_QC_DIR"   ] && HARM_ARGS+=(--umi-qc-dir "$UMI_QC_DIR")
    [ -n "$CONTAINER"    ] && HARM_ARGS+=(--container  "$CONTAINER")
    [ "$DRY_RUN" = true  ] && HARM_ARGS+=(--dry-run)
    [ "$TEST_MODE" = true ] && HARM_ARGS+=(--test)
    bash "$HARMONIZE_SCRIPT" "${HARM_ARGS[@]}"
fi

# Idempotency: sentinel check directory
OPTIMAL_CHECK="$OUTPUT_BASE/optimal"

# Adaptive memory allocation based on spot count (steps 2, 4, 8, 9)
# Step 3 (R Ripley's K) uses fixed 16G (set in run_ripley_k.sh)
# Tiers: Small (<=3000 spots): 32G | Large (3001-8000): 64G | Very Large (>8000): 128G
# When --after is set, barcodes.txt may not exist yet; default to Large tier.
if [ -n "${AFTER_JOB:-}" ] && [ ! -f "$DATA_DIR/barcodes.txt" ]; then
    SPOT_COUNT=0
    MEM_STEP2="64G"; MEM_STEP4="64G"; MEM_STEP8="32G"; MEM_STEP9="64G"
    echo "[Memory] --after mode (barcodes.txt not yet available) → defaulting to Large tier"
else
    SPOT_COUNT=$(wc -l < "$DATA_DIR/barcodes.txt")
    if [ "$SPOT_COUNT" -gt 8000 ]; then
        MEM_STEP2="128G"; MEM_STEP4="128G"; MEM_STEP8="32G"; MEM_STEP9="64G"
        echo "[Memory] ${SPOT_COUNT} spots → Very Large tier: step2=128G, step4=128G, step8=32G, step9=64G"
    elif [ "$SPOT_COUNT" -gt 3000 ]; then
        MEM_STEP2="64G"; MEM_STEP4="64G"; MEM_STEP8="32G"; MEM_STEP9="64G"
        echo "[Memory] ${SPOT_COUNT} spots → Large tier: step2=64G, step4=64G, step8=32G, step9=64G"
    else
        MEM_STEP2="32G"; MEM_STEP4="32G"; MEM_STEP8="32G"; MEM_STEP9="32G"
        echo "[Memory] ${SPOT_COUNT} spots → Small tier: step2=32G, step4=32G, step8=32G, step9=32G"
    fi
fi

# Print pipeline information
echo "=============================================================================="
echo "TumorSPACE Full Pipeline: Steps 1-10 with Job Dependencies"
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
echo "SpaCET:        ${RUN_SPACET:-false}"
echo "Cancer Type:   ${CANCER_TYPE:-none}"
echo "CT Shuffles:   $NUM_SHUFFLE_CT"
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

# ============================================================================
# Idempotency: skip tree (Steps 1-7) if already complete
# ============================================================================
STEP1_JOB=""; STEP1B_JOB=""; STEP2_JOB=""; STEP3_JOB=""; STEP4_JOB=""
STEP5_JOB=""; STEP6_JOB=""; STEP7_JOB=""
TREE_DONE=false
if [ -f "$OPTIMAL_CHECK/tree_complete.txt" ]; then
    echo "[Steps 1-7] Tree already complete (tree_complete.txt found) — skipping"
    TREE_DONE=true
fi

if [ "$TREE_DONE" = false ]; then

# Step 1: Phylogenetic Tree Building
echo "[Step 1/5] Submitting phylogenetic tree building (job array 1-$NUM_SVD)..."
STEP1_ARGS="--account $ACCOUNT --partition $PARTITION --dataset $DATASET --workspace-root $WORKSPACE_ROOT --input-dir $INPUT_DIR --output-dir $OUTPUT_BASE"
if [ "$TEST_MODE" = true ]; then
    STEP1_ARGS="$STEP1_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP1_ARGS="$STEP1_ARGS --container $CONTAINER"
fi
if [ -n "${AFTER_JOB:-}" ]; then
    STEP1_ARGS="$STEP1_ARGS --dependency $AFTER_JOB"
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
STEP2_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --input-dir $INPUT_DIR --num-svd $NUM_SVD --dependency $PREV_JOB --mem $MEM_STEP2"
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

# Step 3: Ripley's K Spatial Clustering
echo "[Step 3] Submitting Ripley's K spatial analysis (R/spatstat, job array 1-$NUM_SVD)..."
STEP3_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --input-dir $INPUT_DIR --num-svd $NUM_SVD --dependency $STEP2_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP3_ARGS="$STEP3_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP3_ARGS="$STEP3_ARGS --container $CONTAINER"
fi

STEP3_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_ripley_k.sh $STEP3_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP3_CMD"
    STEP3_JOB="12348"
else
    STEP3_JOB=$($STEP3_CMD 2>&1 | tail -1)
    echo "  ✓ Step 3 submitted: Job $STEP3_JOB (after $STEP2_JOB)"
    echo "Step3_RipleyK: $STEP3_JOB" >> "$PIPELINE_JOBS"
fi

# Step 4: Hyperparameter Optimization (depends on Step 3 Ripley's K)
echo "[Step 4] Submitting hyperparameter optimization (Julia, job array 1-$NUM_SVD)..."
STEP4_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --input-dir $INPUT_DIR --num-svd $NUM_SVD --dependency $STEP3_JOB --mem $MEM_STEP4"
if [ "$TEST_MODE" = true ]; then
    STEP4_ARGS="$STEP4_ARGS --test"
fi
if [ -n "$FIXED_SEED" ]; then
    STEP4_ARGS="$STEP4_ARGS --fixed-seed $FIXED_SEED"
fi
if [ -n "$CONTAINER" ]; then
    STEP4_ARGS="$STEP4_ARGS --container $CONTAINER"
fi

STEP4_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_spatial_optimize.sh $STEP4_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP4_CMD"
    STEP4_JOB="12349"
else
    STEP4_JOB=$($STEP4_CMD 2>&1 | tail -1)
    echo "  ✓ Step 4 submitted: Job $STEP4_JOB (after $STEP3_JOB)"
    echo "Step4_HyperOpt: $STEP4_JOB" >> "$PIPELINE_JOBS"
fi

# Step 5: Tree Pruning
echo "[Step 5] Submitting tree pruning..."
STEP5_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --num-svd $NUM_SVD --dependency $STEP4_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP5_ARGS="$STEP5_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP5_ARGS="$STEP5_ARGS --container $CONTAINER"
fi

STEP5_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_phylo_tree_prune.sh $STEP5_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP5_CMD"
    STEP5_JOB="12350"
else
    STEP5_JOB=$($STEP5_CMD 2>&1 | tail -1)
    echo "  ✓ Step 5 submitted: Job $STEP5_JOB (after $STEP4_JOB)"
    echo "Step5_TreePrune: $STEP5_JOB" >> "$PIPELINE_JOBS"
fi

# Step 6: SVD Selection
echo "[Step 6] Submitting SVD selection..."
KEEP_ALL_FLAG=""
if [ "$KEEP_ALL" = true ]; then
    KEEP_ALL_FLAG="--keep-all"
fi

STEP6_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --num-svd $NUM_SVD $KEEP_ALL_FLAG --dependency $STEP5_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP6_ARGS="$STEP6_ARGS --test"
fi

STEP6_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_svd_selection.sh $STEP6_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP6_CMD"
    STEP6_JOB="12351"
else
    STEP6_JOB=$($STEP6_CMD 2>&1 | tail -1)
    echo "  ✓ Step 6 submitted: Job $STEP6_JOB (after $STEP5_JOB)"
    echo "Step6_SVDSelect: $STEP6_JOB" >> "$PIPELINE_JOBS"
fi

# Step 7: SG Identification
echo "[Step 7] Submitting SG identification..."
STEP7_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --dependency $STEP6_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP7_ARGS="$STEP7_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP7_ARGS="$STEP7_ARGS --container $CONTAINER"
fi

STEP7_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_sg_identify_pairs.sh $STEP7_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP7_CMD"
    STEP7_JOB="12352"
else
    STEP7_JOB=$($STEP7_CMD 2>&1 | tail -1)
    echo "  ✓ Step 7 submitted: Job $STEP7_JOB (after $STEP6_JOB)"
    echo "Step7_SGIdentify: $STEP7_JOB" >> "$PIPELINE_JOBS"
fi

fi # end TREE_DONE=false block

# ============================================================================
# SpaCET: Cell type deconvolution (skip if Spacet_Matrix.txt already exists)
# ============================================================================
SPACET_JOB="skipped"
if [ "$RUN_SPACET" = true ]; then
    if [ -f "$OUTPUT_BASE/spacet/Spacet_Matrix.txt" ]; then
        echo "[SpaCET] Already complete (Spacet_Matrix.txt found) — skipping"
    else
        echo "[SpaCET] Submitting cell type deconvolution (no dependency — runs immediately)..."
        SPACET_OUTDIR="$OUTPUT_BASE/spacet"
        mkdir -p "$SPACET_OUTDIR"
        SPACET_WRAP="bash ${WORKSPACE_ROOT}/workflows/spacet/orchestration/run_spacet.sh \
            --raw-data-dir ${INPUT_DIR} \
            --outdir ${SPACET_OUTDIR} \
            --cancer-type ${CANCER_TYPE}"
        if [ -n "$CONTAINER" ]; then
            SPACET_WRAP="$SPACET_WRAP --container $CONTAINER"
        fi
        SPACET_SBATCH_CMD="sbatch \
            --account $ACCOUNT \
            --partition $PARTITION \
            --mem=64G \
            --time=4:00:00 \
            --cpus-per-task=8 \
            --job-name=spacet_${DATASET} \
            --output=${SPACET_OUTDIR}/slurm_%j.out \
            --error=${SPACET_OUTDIR}/slurm_%j.err \
            --parsable \
            --wrap=\"${SPACET_WRAP}\""
        if [ "$DRY_RUN" = true ]; then
            echo "  DRY RUN: $SPACET_SBATCH_CMD"
            SPACET_JOB="dry-run"
        else
            SPACET_JOB=$(eval "$SPACET_SBATCH_CMD" 2>&1 | tail -1 | awk '{print $NF}')
            if [[ "$SPACET_JOB" =~ ^[0-9]+$ ]]; then
                echo "  ✓ SpaCET submitted: Job $SPACET_JOB (no dependency)"
                echo "SpaCET: $SPACET_JOB" >> "$PIPELINE_JOBS"
            else
                echo "  ✗ SpaCET submission failed: $SPACET_JOB"
                echo "SpaCET: FAILED" >> "$PIPELINE_JOBS"
                SPACET_JOB="FAILED"
            fi
        fi
    fi
else
    echo "[SpaCET] Skipped (--no-spacet or no --cancer-type provided)"
fi

# ============================================================================
# CT-DA-SLAB: skip if already complete, else build dynamic dep and submit
# ============================================================================
CT_DASLAB_JOB=""
if [ "$RUN_SPACET" = true ]; then
    if [ -f "$OPTIMAL_CHECK/ct/ct_slab_done.txt" ]; then
        echo "[CT-DA-SLAB] Already complete (ct_slab_done.txt found) — skipping"
    else
        echo "[CT-DA-SLAB] Submitting cell type DA + SLAB scoring..."
        SPACET_OUTDIR="$OUTPUT_BASE/spacet"
        # Build dep from only jobs that actually ran
        CT_DEPS=()
        [[ "$STEP7_JOB" =~ ^[0-9]+$ ]] && CT_DEPS+=("afterok:${STEP7_JOB}")
        [[ "$SPACET_JOB" =~ ^[0-9]+$ ]] && CT_DEPS+=("afterok:${SPACET_JOB}")
        CT_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION \
            --spacet-dir $SPACET_OUTDIR \
            --input-base $OUTPUT_BASE \
            --input-dir $INPUT_DIR \
            --workspace-root $WORKSPACE_ROOT \
            --num-shuffle $NUM_SHUFFLE_CT"
        if [ ${#CT_DEPS[@]} -gt 0 ]; then
            CT_DEP=$(IFS=','; echo "${CT_DEPS[*]}")
            CT_ARGS="$CT_ARGS --dependency $CT_DEP"
        fi
        if [ -n "$CONTAINER" ]; then
            CT_ARGS="$CT_ARGS --container $CONTAINER"
        fi
        CT_CMD="bash $WORKSPACE_ROOT/workflows/spacet/orchestration/run_ct_da_slab.sh $CT_ARGS"
        if [ "$DRY_RUN" = true ]; then
            echo "  DRY RUN: $CT_CMD"
            CT_DASLAB_JOB="dry-run"
        else
            CT_DASLAB_JOB=$($CT_CMD 2>&1 | tail -1)
            if [[ "$CT_DASLAB_JOB" =~ ^[0-9]+$ ]]; then
                echo "  ✓ CT-DA-SLAB submitted: Job $CT_DASLAB_JOB"
                echo "CT_DASLAB: $CT_DASLAB_JOB" >> "$PIPELINE_JOBS"
            else
                echo "  ✗ CT-DA-SLAB submission failed: $CT_DASLAB_JOB"
                echo "CT_DASLAB: FAILED" >> "$PIPELINE_JOBS"
                CT_DASLAB_JOB="FAILED"
            fi
        fi
    fi
else
    echo "[CT-DA-SLAB] Skipped (SpaCET not enabled)"
fi

# ============================================================================
# Steps 8-9: Gene DA + SLAB (skip if already complete)
# ============================================================================
STEP8_JOB=""; STEP9_JOB=""
GENE_DONE=false
if [ -f "$OPTIMAL_CHECK/gene/gene_slab_done.txt" ]; then
    echo "[Steps 8-9] Gene DA+SLAB already complete (gene_slab_done.txt found) — skipping"
    GENE_DONE=true
fi

if [ "$GENE_DONE" = false ]; then

# Step 8: Differential Abundance
echo "[Step 8] Submitting differential abundance..."
STEP8_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --data-dir $DATA_DIR --mem $MEM_STEP8"
[[ "$STEP7_JOB" =~ ^[0-9]+$ ]] && STEP8_ARGS="$STEP8_ARGS --dependency $STEP7_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP8_ARGS="$STEP8_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP8_ARGS="$STEP8_ARGS --container $CONTAINER"
fi
if [ -n "$FIXED_SEED" ]; then
    STEP8_ARGS="$STEP8_ARGS --fixed-seed $FIXED_SEED"
fi

STEP8_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_sg_diff_abundance.sh $STEP8_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP8_CMD"
    STEP8_JOB="12353"
else
    STEP8_JOB=$($STEP8_CMD 2>&1 | tail -1)
    echo "  ✓ Step 8 submitted: Job $STEP8_JOB"
    echo "Step8_DiffAbund: $STEP8_JOB" >> "$PIPELINE_JOBS"
fi

# Step 9: SLAB Scoring
echo "[Step 9] Submitting SLAB scoring (${SPOT_COUNT} spots, using ${MEM_STEP9} memory)..."

STEP9_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --data-dir $DATA_DIR --mem $MEM_STEP9"
[[ "$STEP8_JOB" =~ ^[0-9]+$ ]] && STEP9_ARGS="$STEP9_ARGS --dependency $STEP8_JOB"
if [ "$TEST_MODE" = true ]; then
    STEP9_ARGS="$STEP9_ARGS --test"
fi
if [ -n "$CONTAINER" ]; then
    STEP9_ARGS="$STEP9_ARGS --container $CONTAINER"
fi

STEP9_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_sg_slab_score.sh $STEP9_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP9_CMD"
    STEP9_JOB="12354"
else
    STEP9_JOB=$($STEP9_CMD 2>&1 | tail -1)
    echo "  ✓ Step 9 submitted: Job $STEP9_JOB"
    echo "Step9_SLABScore: $STEP9_JOB" >> "$PIPELINE_JOBS"
fi

fi # end GENE_DONE=false block

# ============================================================================
# Step 10: Pipeline Completion (skip if all expected feature spaces already complete)
# ============================================================================

# Determine which feature spaces are expected
EXPECTED_SPACES="gene"
[ "$RUN_SPACET" = true ] && EXPECTED_SPACES="gene,ct"

# Check if Step 10 needs to run
STEP10_JOB=""
STEP10_NEEDED=true
if [ -f "$OPTIMAL_CHECK/PIPELINE_COMPLETE.txt" ] && [ -f "$OPTIMAL_CHECK/feature_spaces.tsv" ]; then
    ALL_DONE=true
    for _s in $(echo "$EXPECTED_SPACES" | tr ',' ' '); do
        awk -F'\t' -v sp="$_s" 'NR>1 && $1==sp && $NF=="complete" {found=1} END {exit (found ? 0 : 1)}' "$OPTIMAL_CHECK/feature_spaces.tsv" 2>/dev/null || { ALL_DONE=false; break; }
    done
    if [ "$ALL_DONE" = true ]; then
        echo "[Step 10] All expected feature spaces complete ($EXPECTED_SPACES) — skipping"
        STEP10_NEEDED=false
    else
        echo "[Step 10] Re-running: not all expected spaces registered as complete ($EXPECTED_SPACES)"
    fi
fi

if [ "$STEP10_NEEDED" = true ]; then
    echo "[Step 10] Submitting pipeline completion..."
    # Dynamic dep: only from jobs that actually ran
    STEP10_DEPS=()
    [[ "$STEP9_JOB" =~ ^[0-9]+$ ]] && STEP10_DEPS+=("afterok:${STEP9_JOB}")
    [[ "$CT_DASLAB_JOB" =~ ^[0-9]+$ ]] && STEP10_DEPS+=("afterok:${CT_DASLAB_JOB}")
    # Fallback: if no feature-space jobs ran but tree just ran, wait for tree
    [ ${#STEP10_DEPS[@]} -eq 0 ] && [[ "$STEP7_JOB" =~ ^[0-9]+$ ]] && STEP10_DEPS+=("afterok:${STEP7_JOB}")
    STEP10_ARGS="--dataset $DATASET --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT --input-base $OUTPUT_BASE --mode $MODE_STR --num-svd $NUM_SVD --expected-spaces $EXPECTED_SPACES"
    if [ ${#STEP10_DEPS[@]} -gt 0 ]; then
        STEP10_DEP=$(IFS=','; echo "${STEP10_DEPS[*]}")
        STEP10_ARGS="$STEP10_ARGS --dependency $STEP10_DEP"
    fi
    if [ "$TEST_MODE" = true ]; then
        STEP10_ARGS="$STEP10_ARGS --test"
    fi

    STEP10_CMD="bash $WORKSPACE_ROOT/workflows/tumorspace_core/orchestration/run_pipeline_completion.sh $STEP10_ARGS"

    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: $STEP10_CMD"
        STEP10_JOB="12355"
    else
        STEP10_JOB=$($STEP10_CMD 2>&1 | tail -1)
        echo "  ✓ Step 10 submitted: Job $STEP10_JOB"
        echo "Step10_Completion: $STEP10_JOB" >> "$PIPELINE_JOBS"
    fi
fi

# Step 11: BayesSpace (optional — depends on Step 10; reads INPUT_DIR for spatial clustering)
BS_JOB="skipped"
if [ "$RUN_BAYESSPACE" = true ]; then
    echo "[Step 11] Submitting BayesSpace spatial clustering (after Step 10)..."
    BS_OUTDIR="$OUTPUT_BASE/bayesspace"
    mkdir -p "$BS_OUTDIR"
    BS_EXTRA=""
    if [ "$TEST_MODE" = true ]; then
        BS_EXTRA="--test"
    fi

    BS_DEP_ARG=""
    [[ "$STEP10_JOB" =~ ^[0-9]+$ ]] && BS_DEP_ARG="--dependency=afterok:${STEP10_JOB}"

    BS_SBATCH_CMD="sbatch \
        --account $ACCOUNT \
        --partition $PARTITION \
        --mem=16G \
        --time=30:00 \
        ${BS_DEP_ARG} \
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
            echo "  ✓ BayesSpace submitted: Job $BS_JOB (after $STEP10_JOB)"
            echo "Step11_BayesSpace: $BS_JOB" >> "$PIPELINE_JOBS"
        else
            echo "  ✗ BayesSpace submission failed: $BS_JOB"
            echo "Step11_BayesSpace: FAILED" >> "$PIPELINE_JOBS"
            BS_JOB="FAILED"
        fi
    fi
else
    echo "[Step 11] BayesSpace: skipped (not available or --no-bayesspace)"
fi

# Step 12: Pipeline Report (mandatory — depends on BayesSpace if it ran, else Step 10)
# Consolidates outputs from all features into Pipeline_Report.pdf + pipeline_summary.md
echo "[Step 12] Submitting pipeline report..."

# Determine dependency: use BS_JOB if it was submitted, otherwise STEP10_JOB
if [[ "$BS_JOB" =~ ^[0-9]+$ ]]; then
    REPORT_DEP="$BS_JOB"
else
    REPORT_DEP="$STEP10_JOB"
fi

STEP12_ARGS="--output-dir $OUTPUT_BASE/optimal --account $ACCOUNT --partition $PARTITION --workspace-root $WORKSPACE_ROOT"
[[ "$REPORT_DEP" =~ ^[0-9]+$ ]] && STEP12_ARGS="$STEP12_ARGS --dependency $REPORT_DEP"
if [ -n "$CONTAINER" ]; then
    STEP12_ARGS="$STEP12_ARGS --container $CONTAINER"
fi

# Add reference directory for test dataset
if [ "$DATASET" = "GSE213688_GSM6592057" ]; then
    REFERENCE_BASE="$(realpath $WORKSPACE_ROOT/benchmarks/$DATASET/expected_outputs 2>/dev/null)"
    if [ -n "$REFERENCE_BASE" ] && [ -d "$REFERENCE_BASE" ]; then
        STEP12_ARGS="$STEP12_ARGS --reference-dir $REFERENCE_BASE"
        echo "  Test dataset: Will validate against reference baseline"
    else
        echo "  Test dataset: No reference baseline yet (will note in report)"
    fi
fi

STEP12_CMD="bash $WORKSPACE_ROOT/workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh $STEP12_ARGS"

if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: $STEP12_CMD"
    STEP12_JOB="12356"
else
    STEP12_OUTPUT=$($STEP12_CMD 2>&1)
    STEP12_JOB=$(echo "$STEP12_OUTPUT" | grep -E '^[0-9]+$' | head -1)

    if echo "$STEP12_OUTPUT" | grep -i "error\|failed" > /dev/null; then
        echo "  ⚠ Step 12 warnings/errors detected:" >&2
        echo "$STEP12_OUTPUT" | grep -i "error\|failed" >&2
    fi

    if [[ "$STEP12_JOB" =~ ^[0-9]+$ ]]; then
        echo "  ✓ Step 12 submitted: Job $STEP12_JOB (after $REPORT_DEP)"
        echo "Step12_Pipeline_Report: $STEP12_JOB" >> "$PIPELINE_JOBS"
    else
        echo "  ✗ Step 12 submission failed: $STEP12_JOB"
        echo "  Full output:" >&2
        echo "$STEP12_OUTPUT" >&2
        echo "Step12_Pipeline_Report: FAILED" >> "$PIPELINE_JOBS"
    fi
fi

echo ""
echo "=============================================================================="
echo "All jobs submitted with dependency chain:"
echo "  Step 1  (Tree Build):      $STEP1_JOB"
echo "  Step 1b (Bootstrap):       $STEP1B_JOB  (after $STEP1_JOB)"
echo "  Step 2  (Node Extract):    $STEP2_JOB  (after $STEP1B_JOB)"
echo "  Step 3  (Ripley's K):      $STEP3_JOB  (after $STEP2_JOB)"
echo "  Step 4  (Hyperpar. Opt):   $STEP4_JOB  (after $STEP3_JOB)"
echo "  Step 5  (Tree Prune):      $STEP5_JOB  (after $STEP4_JOB)"
echo "  Step 6  (SVD Selection):   $STEP6_JOB  (after $STEP5_JOB)"
echo "  Step 7  (SG Identify):     $STEP7_JOB  (after $STEP6_JOB)"
echo "  SpaCET  (CT Deconvolution):$SPACET_JOB (independent)"
echo "  CT-DA-SLAB (CT analysis):  $CT_DASLAB_JOB (after Step 7 + SpaCET)"
echo "  Step 8  (Diff Abund):      $STEP8_JOB  (after $STEP7_JOB)"
echo "  Step 9  (SLAB Score):      $STEP9_JOB  (after $STEP8_JOB)"
echo "  Step 10 (Completion):      $STEP10_JOB  (after $STEP10_DEP)"
echo "  Step 11 (BayesSpace):      $BS_JOB (after $STEP10_JOB)"
echo "  Step 12 (Pipeline Report): $STEP12_JOB (after ${REPORT_DEP}) **MANDATORY**"
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
echo "  $OUTPUT_BASE/optimal/gene/DA_significant.txt (significant genes)"
echo "  $OUTPUT_BASE/optimal/gene/SLAB_scores.txt (spatial scores)"
echo "  $OUTPUT_BASE/optimal/ct/DA_significant.txt (significant cell types, if SpaCET ran)"
echo "  $OUTPUT_BASE/optimal/ct/SLAB_scores.txt (CT spatial scores, if SpaCET ran)"
echo "=============================================================================="