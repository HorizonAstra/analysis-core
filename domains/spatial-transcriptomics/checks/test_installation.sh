#!/bin/bash
#
# test_installation.sh - One-button validation for TumorSPACE installation
#
# Usage:
#   bash test_installation.sh                    # Quick check + submit test pipeline
#   bash test_installation.sh --wait             # Wait for completion and validate outputs
#   bash test_installation.sh --validate-run DIR # Validate existing run directory
#
# Exit codes:
#   0 = PASS - All checks passed
#   1 = FAIL - One or more checks failed
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
WAIT_FOR_COMPLETION=false
VALIDATE_RUN_DIR=""
ACCOUNT=""
PARTITION=""
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASET="GSE213688_GSM6592057"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --wait)
            WAIT_FOR_COMPLETION=true
            shift
            ;;
        --validate-run)
            VALIDATE_RUN_DIR="$2"
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
        -h|--help)
            echo "Usage: bash test_installation.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --wait                 Wait for pipeline completion and validate outputs"
            echo "  --validate-run DIR     Validate an existing run directory (no re-run)"
            echo "  --account ACCOUNT      SLURM account (required for new runs)"
            echo "  --partition PART       SLURM partition (required for new runs)"
            echo "  -h, --help             Show this help message"
            echo ""
            echo "Examples:"
            echo "  # Quick test - submit pipeline and exit"
            echo "  bash test_installation.sh --account pi-araman --partition caslake"
            echo ""
            echo "  # Full test - wait for completion and validate"
            echo "  bash test_installation.sh --account pi-araman --partition caslake --wait"
            echo ""
            echo "  # Validate existing run - get binary PASS/FAIL for completed run"
            echo "  bash test_installation.sh --validate-run benchmarks/GSE213688_GSM6592057/runs/install_test_*"
            exit 0
            ;;
        *)
            echo -e "${RED}ERROR: Unknown option: $1${NC}"
            echo "Run 'bash test_installation.sh --help' for usage information"
            exit 1
            ;;
    esac
done

# Check required arguments
if [ -z "$VALIDATE_RUN_DIR" ]; then
    if [ -z "$ACCOUNT" ]; then
        echo -e "${RED}ERROR: --account is required (unless using --validate-run)${NC}"
        echo "Run 'bash test_installation.sh --help' for usage information"
        exit 1
    fi

    if [ -z "$PARTITION" ]; then
        echo -e "${RED}ERROR: --partition is required (unless using --validate-run)${NC}"
        echo "Run 'bash test_installation.sh --help' for usage information"
        exit 1
    fi
fi

cd "$WORKSPACE_ROOT"

# Handle validate-run mode
if [ -n "$VALIDATE_RUN_DIR" ]; then
    echo "================================================================================"
    echo -e "${BLUE}TumorSPACE Run Validation${NC}"
    echo "================================================================================"
    echo "Mode:      Validate existing run"
    echo "Run dir:   $VALIDATE_RUN_DIR"
    echo ""
    
    if [ ! -d "$VALIDATE_RUN_DIR" ]; then
        echo -e "${RED}ERROR: Run directory does not exist: $VALIDATE_RUN_DIR${NC}"
        exit 1
    fi
    
    RUN_DIR="$VALIDATE_RUN_DIR"
    VALIDATION_FAILED=0
    
    # Skip to Phase 4: Output Validation
else
    # Normal mode: run pre-flight checks and submit pipeline
    echo "================================================================================"
    echo -e "${BLUE}TumorSPACE Installation Test${NC}"
    echo "================================================================================"
    echo "Workspace: $WORKSPACE_ROOT"
    echo "Dataset:   $DATASET"
    echo "Account:   $ACCOUNT"
    echo "Partition: $PARTITION"
    echo ""

    FAILED_CHECKS=0

# =============================================================================
# PHASE 1: Pre-flight Checks
# =============================================================================
echo -e "${BLUE}[PHASE 1] Pre-flight Checks${NC}"
echo "--------------------------------------------------------------------------------"

# Check 1: Container exists
echo -n "Checking for Julia container... "
CONTAINER_PATH="containers/julia_1.9_with_gotree.sif"
if [ -f "$CONTAINER_PATH" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    echo "  Found: $CONTAINER_PATH"
else
    echo -e "${RED}✗ FAIL${NC}"
    echo "  Container not found: $CONTAINER_PATH"
    echo "  Run: bash setup.sh"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi

# Check 2: Benchmark data exists
echo -n "Checking for benchmark data... "
DATA_DIR="benchmarks/$DATASET/input_data"
if [ -d "$DATA_DIR" ] && \
   [ -f "$DATA_DIR/M.txt" ] && \
   [ -f "$DATA_DIR/barcodes.txt" ] && \
   [ -f "$DATA_DIR/features.txt" ] && \
   [ -f "$DATA_DIR/barcodes_positions.txt" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    echo "  Found: $DATA_DIR with all required files"
else
    echo -e "${RED}✗ FAIL${NC}"
    echo "  Missing data files in: $DATA_DIR"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi

# Check 3: Workflows exist
echo -n "Checking for workflow scripts... "
if [ -d "workflows/tumorspace_core/julia" ] && [ -d "workflows/tumorspace_core/R" ] && [ -d "workflows/tumorspace_core/orchestration" ]; then
    JULIA_SCRIPTS=$(ls -1 workflows/tumorspace_core/julia/*.jl 2>/dev/null | wc -l)
    R_SCRIPTS=$(ls -1 workflows/tumorspace_core/R/*.R 2>/dev/null | wc -l)
    ORCH_SCRIPTS=$(find workflows/*/orchestration -name '*.sh' 2>/dev/null | wc -l)
    echo -e "${GREEN}✓ PASS${NC}"
    echo "  Found: $JULIA_SCRIPTS Julia scripts, $R_SCRIPTS core R scripts, $ORCH_SCRIPTS total orchestration scripts"
else
    echo -e "${RED}✗ FAIL${NC}"
    echo "  Workflow feature directories incomplete (expected workflows/tumorspace_core/{julia,R,orchestration})"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi

# Check 4: SLURM availability
echo -n "Checking SLURM availability... "
if command -v sbatch &> /dev/null; then
    echo -e "${GREEN}✓ PASS${NC}"
    echo "  sbatch found: $(which sbatch)"
else
    echo -e "${RED}✗ FAIL${NC}"
    echo "  sbatch not found - SLURM not available"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi

echo ""

if [ $FAILED_CHECKS -gt 0 ]; then
    echo -e "${RED}Pre-flight checks failed: $FAILED_CHECKS issue(s)${NC}"
    echo "Fix the above issues before running the pipeline"
    exit 1
fi

# =============================================================================
# PHASE 2: Run Test Pipeline
# =============================================================================
echo -e "${BLUE}[PHASE 2] Running Test Pipeline${NC}"
echo "--------------------------------------------------------------------------------"
echo "Submitting pipeline with --test flag (3 SVDs, fixed seeds)..."
echo ""

OUTPUT_BASE="benchmarks/$DATASET/runs/install_test"

# Clean up old test runs
if ls benchmarks/$DATASET/runs/install_test_container_test_* 1> /dev/null 2>&1; then
    echo "Cleaning up old test runs..."
    rm -rf benchmarks/$DATASET/runs/install_test_container_test_*
    echo ""
fi

# Submit pipeline
PIPELINE_OUTPUT=$(bash workflows/tumorspace_core/orchestration/run_pipeline_full.sh \
    --dataset "$DATASET" \
    --account "$ACCOUNT" \
    --partition "$PARTITION" \
    --input-dir "benchmarks/$DATASET/input_data" \
    --data-dir "benchmarks/$DATASET/input_data" \
    --output-base "$OUTPUT_BASE" \
    --container "$CONTAINER_PATH" \
    --test 2>&1)

echo "$PIPELINE_OUTPUT"
echo ""

# Extract output directory
RUN_DIR=$(echo "$PIPELINE_OUTPUT" | grep "Output Base:" | awk '{print $NF}' || echo "")
if [ -z "$RUN_DIR" ]; then
    # Try to find most recent directory
    RUN_DIR=$(ls -td benchmarks/$DATASET/runs/install_test_container_test_* 2>/dev/null | head -1)
fi

if [ -z "$RUN_DIR" ]; then
    echo -e "${RED}✗ FAIL: Could not determine output directory${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Pipeline submitted successfully${NC}"
echo "  Output directory: $RUN_DIR"
echo ""

# Extract job IDs
if [ -f "$RUN_DIR/pipeline_jobs.txt" ]; then
    echo "Job IDs:"
    cat "$RUN_DIR/pipeline_jobs.txt" | grep -E "^Step" | while read line; do
        echo "  $line"
    done
    echo ""
    
    # Get final job ID for monitoring
    FINAL_JOB=$(grep "Step11_Pipeline_Report:" "$RUN_DIR/pipeline_jobs.txt" | awk '{print $NF}')
else
    echo -e "${YELLOW}Warning: pipeline_jobs.txt not found${NC}"
    FINAL_JOB=""
fi

if [ "$WAIT_FOR_COMPLETION" = false ]; then
    echo "================================================================================"
    echo -e "${GREEN}QUICK TEST: PASS${NC}"
    echo "================================================================================"
    echo ""
    echo "Pre-flight checks passed and pipeline submitted successfully."
    echo ""
    echo "To monitor progress:"
    echo "  squeue -u \$USER"
    if [ -n "$FINAL_JOB" ]; then
        echo "  sacct -j $FINAL_JOB --format=JobID,State,ExitCode,Elapsed"
    fi
    echo ""
    echo "To validate outputs after completion:"
    echo "  bash test_installation.sh --account $ACCOUNT --partition $PARTITION --wait"
    echo ""
    exit 0
fi

# =============================================================================
# PHASE 3: Wait for Completion (only if --wait flag set)
# =============================================================================
echo -e "${BLUE}[PHASE 3] Waiting for Pipeline Completion${NC}"
echo "--------------------------------------------------------------------------------"

if [ -z "$FINAL_JOB" ]; then
    echo -e "${RED}✗ FAIL: Could not extract final job ID${NC}"
    exit 1
fi

echo "Monitoring final job: $FINAL_JOB (Pipeline Report)"
echo "This may take 15-60 minutes depending on cluster load..."
echo ""

count=0
max_iterations=360  # 1 hour max wait
while [ $count -lt $max_iterations ]; do
    # Query job state
    state=$(sacct -j "$FINAL_JOB" --format=State --noheader 2>/dev/null | head -1 | tr -d ' ')
    
    if [ "$state" = "COMPLETED" ]; then
        echo -e "${GREEN}✓ Pipeline completed successfully${NC}"
        break
    elif [ "$state" = "FAILED" ] || [ "$state" = "CANCELLED" ] || [ "$state" = "TIMEOUT" ]; then
        echo -e "${RED}✗ Pipeline failed with state: $state${NC}"
        echo ""
        echo "Check logs in: $RUN_DIR"
        exit 1
    elif [ "$state" = "PENDING" ] || [ "$state" = "RUNNING" ]; then
        elapsed=$((count * 10))
        mins=$((elapsed / 60))
        echo -ne "\r  Status: $state | Elapsed: ${mins}m ... "
        sleep 10
        count=$((count + 1))
    else
        # Job might not be in sacct yet
        sleep 10
        count=$((count + 1))
    fi
done

if [ $count -ge $max_iterations ]; then
    echo -e "${RED}✗ TIMEOUT: Pipeline did not complete within 1 hour${NC}"
    exit 1
fi

echo ""
fi  # End of normal mode (else block) - closes the else that started after validate-run check

# =============================================================================
# PHASE 4: Validate Outputs (runs for both normal --wait and --validate-run)
# =============================================================================
echo -e "${BLUE}[PHASE 4] Validating Outputs${NC}"
echo "--------------------------------------------------------------------------------"
echo "Checking for required output files..."
echo ""

if [ -z "$VALIDATION_FAILED" ]; then
    VALIDATION_FAILED=0
fi

# Check for optimal directory
echo -n "Checking for optimal/ directory... "
if [ -d "$RUN_DIR/optimal" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
else
    echo -e "${RED}✗ FAIL${NC}"
    VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
fi

# Check for key output files
echo -n "Checking for tree files... "
if [ -f "$RUN_DIR/optimal/OptimalTree_pruned.nw" ] && [ -f "$RUN_DIR/optimal/OptimalTree_preprune.nw" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
else
    echo -e "${RED}✗ FAIL${NC}"
    VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
fi

# Check for SLAB scoring results (main outputs)
echo -n "Checking for SLAB scores... "
if [ -f "$RUN_DIR/optimal/SLAB_scores.txt" ] && [ -f "$RUN_DIR/optimal/SLAB_barcodes.txt" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
else
    echo -e "${RED}✗ FAIL${NC}"
    VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
fi

# Check for differential abundance results
echo -n "Checking for differential abundance... "
if [ -f "$RUN_DIR/optimal/DA_significant.txt" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
else
    echo -e "${RED}✗ FAIL${NC}"
    VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
fi

# Check for pipeline completion marker
echo -n "Checking for completion marker... "
if [ -f "$RUN_DIR/optimal/PIPELINE_COMPLETE.txt" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
else
    echo -e "${RED}✗ FAIL${NC}"
    VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
fi

echo ""

# =============================================================================
# PHASE 5: Byte-Level Comparison to Expected Outputs
# =============================================================================
echo -e "${BLUE}[PHASE 5] Byte-Level Validation Against Reference Outputs${NC}"
echo "--------------------------------------------------------------------------------"
echo "Comparing outputs to expected reference (fixed seed ensures reproducibility)..."
echo ""

EXPECTED_DIR="benchmarks/$DATASET/expected_outputs"

if [ ! -d "$EXPECTED_DIR" ]; then
    echo -e "${YELLOW}⚠ WARNING: Expected outputs directory not found${NC}"
    echo "  Location: $EXPECTED_DIR"
    echo "  Skipping byte-level comparison"
    echo ""
else
    # Key files that must be byte-identical (deterministic outputs with fixed seed)
    CRITICAL_FILES=(
        "OptimalTree_pruned.nw"
        "OptimalTree_preprune.nw"
        "OptimalTree_pruned_node_compare_list.txt"
        "SLAB_scores.txt"
        "DA_significant.txt"
    )
    
    IDENTICAL_COUNT=0
    DIFFER_COUNT=0
    MISSING_COUNT=0
    
    for file in "${CRITICAL_FILES[@]}"; do
        ACTUAL_FILE="$RUN_DIR/optimal/$file"
        EXPECTED_FILE="$EXPECTED_DIR/$file"
        
        echo -n "  $file: "
        
        if [ ! -f "$ACTUAL_FILE" ]; then
            echo -e "${RED}MISSING (actual)${NC}"
            MISSING_COUNT=$((MISSING_COUNT + 1))
            VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
        elif [ ! -f "$EXPECTED_FILE" ]; then
            echo -e "${YELLOW}MISSING (reference)${NC}"
            MISSING_COUNT=$((MISSING_COUNT + 1))
        else
            # Byte-level comparison
            if cmp -s "$ACTUAL_FILE" "$EXPECTED_FILE"; then
                echo -e "${GREEN}BYTE-IDENTICAL ✓${NC}"
                IDENTICAL_COUNT=$((IDENTICAL_COUNT + 1))
            else
                echo -e "${RED}DIFFERS ✗${NC}"
                # Show detailed diff info
                ACTUAL_MD5=$(md5sum "$ACTUAL_FILE" | awk '{print $1}')
                EXPECTED_MD5=$(md5sum "$EXPECTED_FILE" | awk '{print $1}')
                echo "    Actual:   $ACTUAL_MD5"
                echo "    Expected: $EXPECTED_MD5"
                DIFFER_COUNT=$((DIFFER_COUNT + 1))
                VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
            fi
        fi
    done
    
    echo ""
    echo "Byte-level comparison results:"
    echo "  Identical: $IDENTICAL_COUNT"
    echo "  Differ:    $DIFFER_COUNT"
    echo "  Missing:   $MISSING_COUNT"
    
    if [ $DIFFER_COUNT -gt 0 ]; then
        echo ""
        echo -e "${RED}⚠ REPRODUCIBILITY ISSUE DETECTED${NC}"
        echo "  Expected: Byte-identical outputs with --test mode (fixed seed)"
        echo "  Actual:   $DIFFER_COUNT file(s) differ from reference"
        echo ""
        echo "  This indicates either:"
        echo "    1. Non-deterministic behavior despite fixed seed"
        echo "    2. Code changes affecting output format/values"
        echo "    3. Different Julia/R versions or dependencies"
        echo ""
        echo "  If changes are intentional, update reference outputs:"
        echo "    bash run_clean_e2e_workflow.sh"
    fi
fi

echo ""

# =============================================================================
# Final Summary
# =============================================================================
echo "================================================================================"
if [ $VALIDATION_FAILED -eq 0 ]; then
    echo -e "${GREEN}FULL TEST: PASS ✓${NC}"
    echo "================================================================================"
    echo ""
    echo "All validation checks passed:"
    echo "  ✓ Pipeline completed successfully"
    echo "  ✓ All expected output files present"
    echo "  ✓ Byte-identical to reference outputs (reproducibility confirmed)"
    echo ""
    echo "Results located in: $RUN_DIR/optimal/"
    echo ""
    echo -e "${GREEN}You are safe to push to main branch.${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}FULL TEST: FAIL ✗${NC}"
    echo "================================================================================"
    echo ""
    echo "$VALIDATION_FAILED validation check(s) failed."
    echo ""
    echo "Review outputs in: $RUN_DIR"
    echo "Check logs in: $RUN_DIR/../logs/"
    echo ""
    echo -e "${RED}Do NOT push to main branch until all tests pass.${NC}"
    echo ""
    exit 1
fi
