#!/bin/bash
#
# TumorSPACE AWS Pipeline - Completion Marker & Summary Generator
# This is Step 10 in the pipeline - marks successful completion and generates summary
#
# Usage: bash run_pipeline_completion.sh [OPTIONS]
#
# Options:
#   --dataset DATASET          Dataset identifier (default: GSE213688_GSM6592057)
#   --account ACCOUNT          SLURM account (default: pi-araman)
#   --partition PARTITION      SLURM partition (default: caslake)
#   --input-base DIR           Base directory for output (default: test_output)
#   --mem MEMORY               Memory allocation (default: 2G)
#   --time TIME                Time limit (default: 00:10:00)
#   --test                     Enable test mode (shorter names, cleanup)
#   --dependency JOB_ID        SLURM dependency job ID
#

set -e

# ============================================================================
# Default Configuration
# ============================================================================

DATASET="GSE213688_GSM6592057"
ACCOUNT="pi-araman"
PARTITION="caslake"
INPUT_BASE="test_output"
MEMORY="2G"
TIME_LIMIT="00:10:00"
TEST_MODE=false
DEPENDENCY=""
MODE_STR=""
NUM_SVD=""
WORKSPACE_ROOT=""
EXPECTED_SPACES="gene"

# ============================================================================
# Parse Command Line Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --dataset)
            DATASET="$2"
            shift 2
            ;;
        --workspace-root)
            WORKSPACE_ROOT="$2"
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
        --mem)
            MEMORY="$2"
            shift 2
            ;;
        --time)
            TIME_LIMIT="$2"
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
        --expected-spaces)
            EXPECTED_SPACES="$2"
            shift 2
            ;;
        --mode)
            MODE_STR="$2"
            shift 2
            ;;
        --num-svd)
            NUM_SVD="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dataset DATASET] [--workspace-root DIR] [--account ACCOUNT] [--partition PARTITION] [--input-base DIR] [--mem MEMORY] [--time TIME] [--test] [--dependency JOB_ID]"
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

REPO_BASE="$WORKSPACE_ROOT"

# ============================================================================
# Directory Setup
# ============================================================================

# Convert to absolute path
if [[ "$INPUT_BASE" != /* ]]; then
    INPUT_BASE="${REPO_BASE}/${INPUT_BASE}"
fi

OUTPUT_DIR="${INPUT_BASE}"
OPTIMAL_DIR="${OUTPUT_DIR}/optimal"
COMPLETION_FILE="${OPTIMAL_DIR}/PIPELINE_COMPLETE.txt"

echo "================================================================================"
echo "TumorSPACE Pipeline - Completion Marker (Step 10)"
echo "================================================================================"
echo "Dataset:         ${DATASET}"
echo "Input base:      ${INPUT_BASE}"
echo "Optimal dir:     ${OPTIMAL_DIR}"
echo "Completion file: ${COMPLETION_FILE}"
echo "Test mode:       ${TEST_MODE}"
if [ -n "$DEPENDENCY" ]; then
    echo "Dependency:      ${DEPENDENCY}"
fi
echo ""

# ============================================================================
# Input Validation
# ============================================================================

# Check optimal directory exists (skip if using dependency)
if [ -z "$DEPENDENCY" ]; then
    if [ ! -d "$OPTIMAL_DIR" ]; then
        echo "ERROR: Optimal directory not found: $OPTIMAL_DIR"
        echo "Have you run Step 6 (svd_selection)?"
        exit 1
    fi
fi

# Check required files from previous steps exist (skip if using dependency)
if [ -z "$DEPENDENCY" ]; then
    REQUIRED_FILES=(
        "Tree_support.nw"
        "OptimalTree.nw"
        "OptimalTree_pruned_node_compare_list.txt"
        "gene/DA_significant.txt"
        "gene/SLAB_scores.txt"
    )

    MISSING_FILES=()
    for FILE in "${REQUIRED_FILES[@]}"; do
        if [ ! -f "${OPTIMAL_DIR}/${FILE}" ]; then
            MISSING_FILES+=("$FILE")
        fi
    done

    if [ ${#MISSING_FILES[@]} -gt 0 ]; then
        echo "ERROR: Missing required files in optimal/:"
        for FILE in "${MISSING_FILES[@]}"; do
            echo "  - $FILE"
        done
        echo ""
        echo "Please ensure all previous steps (1-8) completed successfully."
        exit 1
    fi
fi

# ============================================================================
# Test Mode Cleanup
# ============================================================================

if [ "$TEST_MODE" = true ]; then
    echo "TEST MODE: Cleaning previous completion marker..."
    rm -f "$COMPLETION_FILE"
    echo ""
fi

# ============================================================================
# Generate SLURM Script
# ============================================================================

SLURM_SCRIPT="${OUTPUT_DIR}/slurm_completion.sh"

cat > "$SLURM_SCRIPT" << 'SLURM_EOF'
#!/bin/bash
#SBATCH --job-name=PLACEHOLDER_JOB_NAME
#SBATCH --account=PLACEHOLDER_ACCOUNT
#SBATCH --partition=PLACEHOLDER_PARTITION
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=PLACEHOLDER_MEMORY
#SBATCH --time=PLACEHOLDER_TIME
#SBATCH --output=PLACEHOLDER_OUTPUT_DIR/completion_%j.out
#SBATCH --error=PLACEHOLDER_OUTPUT_DIR/completion_%j.err

set -e

echo "=========================================================================="
echo "TumorSPACE Pipeline - Completion Summary"
echo "=========================================================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"
echo "Start time: $(date)"
echo ""

OPTIMAL_DIR="PLACEHOLDER_OPTIMAL_DIR"
COMPLETION_FILE="PLACEHOLDER_COMPLETION_FILE"
OUTPUT_DIR="PLACEHOLDER_OUTPUT_DIR"
WORKSPACE_ROOT="PLACEHOLDER_WORKSPACE_ROOT"

# ============================================================================
# Wait for File I/O Completion (Prevent Race Condition)
# ============================================================================

echo "Waiting for file I/O completion..."
WAIT_COUNT=0
MAX_WAIT=30  # Maximum 30 seconds

# Critical files from Step 9 that must be fully written
CRITICAL_FILES=(
    "${OPTIMAL_DIR}/gene/SLAB_scores.txt"
    "${OPTIMAL_DIR}/gene/SLAB_barcodes.txt"
)

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    ALL_READY=true
    
    for file in "${CRITICAL_FILES[@]}"; do
        if [ ! -f "$file" ]; then
            ALL_READY=false
            break
        fi
        
        # Check if file has non-zero size
        if [ ! -s "$file" ]; then
            ALL_READY=false
            break
        fi
        
        # Check if file is still being written (size changes in 1 second)
        SIZE1=$(stat -c%s "$file" 2>/dev/null || echo "0")
        sleep 1
        SIZE2=$(stat -c%s "$file" 2>/dev/null || echo "0")
        
        if [ "$SIZE1" != "$SIZE2" ]; then
            ALL_READY=false
            break
        fi
    done
    
    if [ "$ALL_READY" = true ]; then
        echo "✓ All files ready"
        break
    fi
    
    echo "  Waiting for SLAB files to complete writing... ($WAIT_COUNT/$MAX_WAIT)"
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ $WAIT_COUNT -eq $MAX_WAIT ]; then
    echo "⚠ WARNING: Timeout waiting for files, continuing anyway"
fi

echo ""

# ============================================================================
# Extract Timing Data from SLURM Jobs
# ============================================================================

echo "Extracting timing data from SLURM accounting..."
TIMING_SUMMARY="${OUTPUT_DIR}/timing_summary.tsv"

# Check if pipeline_jobs.txt exists
if [ -f "${OUTPUT_DIR}/pipeline_jobs.txt" ]; then
    # Create timing summary header
    echo -e "Step\tJobID\tRuntime\tMemory_KB\tCPUTime\tState" > "$TIMING_SUMMARY"
    
    # Read job IDs and extract timing
    while read -r JOB_LINE; do
        # Skip comments and empty lines
        [[ "$JOB_LINE" =~ ^#.*$ ]] && continue
        [[ -z "$JOB_LINE" ]] && continue
        
        # Parse line format: "StepName: JOB_ID"
        STEP_NAME=$(echo "$JOB_LINE" | cut -d':' -f1 | tr -d ' ')
        JOB_ID=$(echo "$JOB_LINE" | cut -d':' -f2 | tr -d ' ')
        
        # Skip if no job ID
        [[ -z "$JOB_ID" ]] && continue
        
        # Query sacct for this job (get main job stats, not .batch/.extern)
        sacct -j "$JOB_ID" --format=JobID,Elapsed,MaxRSS,CPUTime,State --parsable2 --noheader | \
            grep -E "^${JOB_ID}(\.|_|$)" | head -1 | while IFS='|' read -r JOBID ELAPSED MAXRSS CPUTIME STATE; do
                # Only include if not a sub-job (.batch, .extern, etc.) or is array parent
                if [[ "$JOBID" == "$JOB_ID" ]] || [[ "$JOBID" =~ ^${JOB_ID}_[0-9]+$ ]]; then
                    echo -e "${STEP_NAME}\t${JOBID}\t${ELAPSED}\t${MAXRSS}\t${CPUTIME}\t${STATE}" >> "$TIMING_SUMMARY"
                fi
            done
    done < "${OUTPUT_DIR}/pipeline_jobs.txt"
    
    echo "Timing data written to: $TIMING_SUMMARY"
    
    # Aggregate to centralized database
    MODE_STR="PLACEHOLDER_MODE"
    SVD_COUNT="PLACEHOLDER_SVD_COUNT"
    
    if [ -f "$TIMING_SUMMARY" ] && [ -f "${WORKSPACE_ROOT}/benchmarking/aggregate_timing_data.sh" ]; then
        echo "Aggregating timing data to centralized database..."
        bash "${WORKSPACE_ROOT}/benchmarking/aggregate_timing_data.sh" \
            "$TIMING_SUMMARY" \
            "PLACEHOLDER_DATASET" \
            "$MODE_STR" \
            "$SVD_COUNT" || echo "Warning: Failed to aggregate timing data"
    fi
else
    echo "Warning: pipeline_jobs.txt not found, skipping timing extraction"
fi

echo ""

# ============================================================================
# Validate feature space registry
# ============================================================================

echo "Validating feature space registry..."
FSTSV="${OPTIMAL_DIR}/feature_spaces.tsv"
if [ ! -f "$FSTSV" ]; then
    echo "ERROR: feature_spaces.tsv not found at $FSTSV"
    echo "  One or more feature-space steps (Steps 8-9 or CT-DA-SLAB) may not have completed."
    exit 1
fi
REGISTRY_OK=true
for _space in $(echo "PLACEHOLDER_EXPECTED_SPACES" | tr ',' ' '); do
    if awk -F'\t' -v sp="${_space}" 'NR>1 && $1==sp && $NF=="complete" {found=1} END {exit (found ? 0 : 1)}' "$FSTSV" 2>/dev/null; then
        N_FEAT=$(grep -E "^${_space}\t" "$FSTSV" | cut -f3 | head -1)
        echo "  ✓ Feature space: ${_space} (${N_FEAT} features, complete)"
    else
        echo "  ✗ ERROR: Feature space '${_space}' not registered as complete in feature_spaces.tsv"
        echo "    Check: $FSTSV"
        echo "    Re-run the pipeline with --cancer-type to add SpaCET/CT-DA-SLAB, or check Steps 8-9."
        REGISTRY_OK=false
    fi
done
if [ "$REGISTRY_OK" = false ]; then
    exit 1
fi
echo "  ✓ All expected feature spaces complete: PLACEHOLDER_EXPECTED_SPACES"
echo ""

# ============================================================================
# Generate completion summary
echo "================================================================================" > "$COMPLETION_FILE"
echo "TumorSPACE Pipeline - Successful Completion" >> "$COMPLETION_FILE"
echo "================================================================================" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"
echo "Completion Time: $(date)" >> "$COMPLETION_FILE"
echo "Dataset: PLACEHOLDER_DATASET" >> "$COMPLETION_FILE"
echo "Job ID: $SLURM_JOB_ID" >> "$COMPLETION_FILE"
echo "Node: $SLURM_JOB_NODELIST" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"

# Count outputs from each step
echo "================================================================================" >> "$COMPLETION_FILE"
echo "Pipeline Outputs Summary" >> "$COMPLETION_FILE"
echo "================================================================================" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"

# Step 1: Tree files
TREE_FILES=$(ls -1 ${OPTIMAL_DIR}/Tree_*.nw 2>/dev/null | wc -l)
echo "Step 1 (Tree Building):" >> "$COMPLETION_FILE"
echo "  Tree files: ${TREE_FILES}" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"

# Step 2: Node extraction files
NODE_FILES=$(ls -1 ${OPTIMAL_DIR}/*nodes*.txt ${OPTIMAL_DIR}/*leaves*.txt 2>/dev/null | wc -l)
echo "Step 2 (Node Extraction):" >> "$COMPLETION_FILE"
echo "  Node relationship files: ${NODE_FILES}" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"

# Step 3: Ripley's K (allnodes_ripley.tsv lives in svd_run_N/, not optimal/)
OPTIMAL_SVD_NUM=$(grep "^SVD_Number:" "${OUTPUT_DIR}/optimal_svd.txt" 2>/dev/null | awk '{print $2}')
if [ -n "$OPTIMAL_SVD_NUM" ] && [ -f "${OUTPUT_DIR}/svd_run_${OPTIMAL_SVD_NUM}/allnodes_ripley.tsv" ]; then
    RIPLEY_STATUS="✓ (svd_run_${OPTIMAL_SVD_NUM}/allnodes_ripley.tsv)"
else
    RIPLEY_FILES=$(ls -1 ${OPTIMAL_DIR}/allnodes_ripley.tsv 2>/dev/null | wc -l)
    RIPLEY_STATUS=$([ $RIPLEY_FILES -gt 0 ] && echo '✓' || echo '⚠ not found')
fi
echo "Step 3 (Ripley's K):" >> "$COMPLETION_FILE"
echo "  allnodes_ripley.tsv: ${RIPLEY_STATUS}" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"

# Step 4: Hyperparameter Optimization
if [ -f "${OPTIMAL_DIR}/Tree_support.nw" ]; then
    echo "Step 4 (Hyperparameter Optimization):" >> "$COMPLETION_FILE"
    echo "  Tree support file: ✓" >> "$COMPLETION_FILE"
    echo "" >> "$COMPLETION_FILE"
fi

# Step 4: Tree pruning
if [ -f "${OPTIMAL_DIR}/OptimalTree.nw" ]; then
    echo "Step 5 (Tree Pruning):" >> "$COMPLETION_FILE"
    echo "  Optimal tree: ✓" >> "$COMPLETION_FILE"
    echo "" >> "$COMPLETION_FILE"
fi

# Step 6: SG identification
SG_FILES=$(ls -1 ${OPTIMAL_DIR}/OptimalTree_pruned_node_*.txt 2>/dev/null | wc -l)
echo "Step 7 (SG Identification):" >> "$COMPLETION_FILE"
echo "  SG definition files: ${SG_FILES}" >> "$COMPLETION_FILE"
if [ -f "${OPTIMAL_DIR}/OptimalTree_pruned_node_compare_list.txt" ]; then
    SG_PAIRS=$(tail -n +2 "${OPTIMAL_DIR}/OptimalTree_pruned_node_compare_list.txt" | wc -l)
    echo "  SG pairs identified: ${SG_PAIRS}" >> "$COMPLETION_FILE"
fi
echo "" >> "$COMPLETION_FILE"

# Step 7: Differential abundance
if [ -f "${OPTIMAL_DIR}/gene/DA_significant.txt" ]; then
    DA_GENES=$(tail -n +2 "${OPTIMAL_DIR}/gene/DA_significant.txt" | wc -l)
    echo "Step 8 (Differential Abundance):" >> "$COMPLETION_FILE"
    echo "  Significant DA genes: ${DA_GENES}" >> "$COMPLETION_FILE"
    echo "" >> "$COMPLETION_FILE"
fi

# Step 8: SLAB scoring
if [ -f "${OPTIMAL_DIR}/gene/SLAB_scores.txt" ]; then
    # Check file size to catch empty files from race conditions
    SLAB_SIZE=$(stat -c%s "${OPTIMAL_DIR}/gene/SLAB_scores.txt" 2>/dev/null || echo "0")
    if [ "$SLAB_SIZE" -gt 100 ]; then
        SLAB_ENTRIES=$(tail -n +2 "${OPTIMAL_DIR}/gene/SLAB_scores.txt" | wc -l)
        echo "Step 9 (SLAB Scoring):" >> "$COMPLETION_FILE"
        echo "  SLAB score entries: ${SLAB_ENTRIES}" >> "$COMPLETION_FILE"
    else
        echo "Step 9 (SLAB Scoring):" >> "$COMPLETION_FILE"
        echo "  ⚠ WARNING: SLAB_scores.txt is empty or incomplete (${SLAB_SIZE} bytes)" >> "$COMPLETION_FILE"
        echo "  This may indicate a race condition or Step 9 failure" >> "$COMPLETION_FILE"
    fi
    echo "" >> "$COMPLETION_FILE"
else
    echo "Step 9 (SLAB Scoring):" >> "$COMPLETION_FILE"
    echo "  ⚠ ERROR: SLAB_scores.txt not found" >> "$COMPLETION_FILE"
    echo "" >> "$COMPLETION_FILE"
fi

# File sizes
echo "================================================================================" >> "$COMPLETION_FILE"
echo "Output File Sizes" >> "$COMPLETION_FILE"
echo "================================================================================" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"

du -sh ${OPTIMAL_DIR}/*.txt ${OPTIMAL_DIR}/*.nw 2>/dev/null | \
    awk '{printf "  %-40s %10s\n", $2, $1}' >> "$COMPLETION_FILE"

echo "" >> "$COMPLETION_FILE"
echo "Total size: $(du -sh ${OPTIMAL_DIR} | cut -f1)" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"

# ============================================================================
# Timing Summary (if available)
# ============================================================================

if [ -f "${OUTPUT_DIR}/timing_summary.tsv" ]; then
    echo "================================================================================" >> "$COMPLETION_FILE"
    echo "Pipeline Timing Summary" >> "$COMPLETION_FILE"
    echo "================================================================================" >> "$COMPLETION_FILE"
    echo "" >> "$COMPLETION_FILE"
    
    # Calculate total wall time from first job start to last job end
    # Display per-step timing in human-readable format
    tail -n +2 "${OUTPUT_DIR}/timing_summary.tsv" | \
        awk -F'\t' '{printf "  %-30s %10s (%s)\n", $1, $3, $2}' >> "$COMPLETION_FILE"
    
    echo "" >> "$COMPLETION_FILE"
fi

# Next steps
echo "================================================================================" >> "$COMPLETION_FILE"
echo "Next Steps" >> "$COMPLETION_FILE"
echo "================================================================================" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"
echo "1. Review SLAB_scores.txt for biologically relevant genes" >> "$COMPLETION_FILE"
echo "2. Generate pipeline report (MANDATORY for validation):" >> "$COMPLETION_FILE"
echo "   # After completing BOTH native and container runs:" >> "$COMPLETION_FILE"
echo "   bash workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \\" >> "$COMPLETION_FILE"
echo "       --native-dir /path/to/native_run/optimal \\" >> "$COMPLETION_FILE"
echo "       --container-dir /path/to/container_run/optimal \\" >> "$COMPLETION_FILE"
echo "       --account PLACEHOLDER_ACCOUNT --partition PLACEHOLDER_PARTITION" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"
echo "   # For test mode runs with reference validation:" >> "$COMPLETION_FILE"
echo "   bash workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh \\" >> "$COMPLETION_FILE"
echo "       --native-dir native_test_run/optimal \\" >> "$COMPLETION_FILE"
echo "       --container-dir container_test_run/optimal \\" >> "$COMPLETION_FILE"
echo "       --reference-dir benchmarks/PLACEHOLDER_DATASET/expected_outputs \\" >> "$COMPLETION_FILE"
echo "       --account PLACEHOLDER_ACCOUNT --partition PLACEHOLDER_PARTITION" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"
echo "3. Extract top SLAB genes for downstream analysis" >> "$COMPLETION_FILE"
echo "" >> "$COMPLETION_FILE"

echo "Pipeline completion summary written to: $COMPLETION_FILE"
echo ""

# Display summary to console
cat "$COMPLETION_FILE"

echo ""
echo "=========================================================================="
echo "Pipeline Completed Successfully!"
echo "=========================================================================="
echo "Completion time: $(date)"
echo ""

SLURM_EOF

# ============================================================================
# Substitute Placeholders
# ============================================================================

JOB_NAME="completion"
if [ "$TEST_MODE" = true ]; then
    JOB_NAME="test_completion"
fi

# Determine mode from arguments first, then fallback to output path detection
if [ -z "$MODE_STR" ]; then
    if [[ "$OUTPUT_BASE" =~ (native|container)_(test|prod)_[0-9]{8}_[0-9]{6}$ ]]; then
        MODE_STR=$(echo "$OUTPUT_BASE" | grep -oP '(native|container)_(test|prod)_\d{8}_\d{6}$' | sed 's/_[0-9]*$//')
    elif [ "$TEST_MODE" = true ]; then
        MODE_STR="native_test"  # Fallback for test mode
    else
        MODE_STR="native_prod"  # Fallback for production mode
    fi
fi

# Determine SVD count from arguments first, then fallback to counting svd_run directories
if [ -z "$NUM_SVD" ]; then
    SVD_COUNT=$(find "${OUTPUT_DIR}" -maxdepth 1 -type d -name "svd_run_*" 2>/dev/null | wc -l)
    if [ "$SVD_COUNT" -eq 0 ]; then
        SVD_COUNT=3  # Default fallback
    fi
else
    SVD_COUNT="$NUM_SVD"
fi

sed -i "s|PLACEHOLDER_JOB_NAME|${JOB_NAME}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_ACCOUNT|${ACCOUNT}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_PARTITION|${PARTITION}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_MEMORY|${MEMORY}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_TIME|${TIME_LIMIT}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_OUTPUT_DIR|${OUTPUT_DIR}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_OPTIMAL_DIR|${OPTIMAL_DIR}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_COMPLETION_FILE|${COMPLETION_FILE}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_DATASET|${DATASET}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_WORKSPACE_ROOT|${REPO_BASE}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_MODE|${MODE_STR}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_SVD_COUNT|${SVD_COUNT}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_EXPECTED_SPACES|${EXPECTED_SPACES}|g" "$SLURM_SCRIPT"

chmod +x "$SLURM_SCRIPT"

# ============================================================================
# Submit Job
# ============================================================================

echo "Submitting completion marker job..."
echo ""

if [ -n "$DEPENDENCY" ]; then
    JOB_ID=$(sbatch --dependency="${DEPENDENCY}" --parsable "$SLURM_SCRIPT")
else
    JOB_ID=$(sbatch --parsable "$SLURM_SCRIPT")
fi

echo "Job submitted: $JOB_ID"
if [ -n "$DEPENDENCY" ]; then
    echo "Dependency: afterok:${DEPENDENCY}"
fi
echo ""

# ============================================================================
# Output Verification Instructions
# ============================================================================

echo "================================================================================"
echo "Expected Outputs"
echo "================================================================================"
echo ""
echo "Upon completion, the following will be generated:"
echo ""
echo "1. Completion marker:"
echo "   ${COMPLETION_FILE}"
echo ""
echo "2. Summary contents:"
echo "   - Pipeline completion timestamp"
echo "   - Output file counts from each step"
echo "   - File sizes"
echo "   - Next steps guidance"
echo ""
echo "================================================================================"
echo "Monitoring"
echo "================================================================================"
echo ""
echo "Check job status:"
echo "  squeue -j ${JOB_ID}"
echo ""
echo "View output log:"
echo "  cat ${OUTPUT_DIR}/completion_${JOB_ID}.out"
echo ""
echo "View completion summary:"
echo "  cat ${COMPLETION_FILE}"
echo ""
echo "================================================================================"

# Return job ID for chaining
echo "$JOB_ID"