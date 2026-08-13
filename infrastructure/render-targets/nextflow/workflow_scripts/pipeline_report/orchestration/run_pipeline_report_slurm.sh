#!/bin/bash
#
# TumorSPACE AWS Pipeline - Pipeline Report SLURM Submission (Step 11)
# Generates pipeline_summary.md and Pipeline_Report.pdf for a completed run
# Runs automatically as Step 11 after BayesSpace (Step 10) completes
#
# Usage: bash run_pipeline_report_slurm.sh --output-dir DIR --account ACCOUNT --partition PARTITION [OPTIONS]
#
# Options:
#   --output-dir DIR           Pipeline output directory (required)
#   --account ACCOUNT          SLURM account (required)
#   --partition PARTITION      SLURM partition (required)
#   --reference-dir DIR        Reference baseline directory for test mode validation (optional)
#   --mem MEMORY               Memory allocation (default: 8G)
#   --time TIME                Time limit (default: 00:15:00)
#   --dependency JOB_ID        SLURM dependency job ID
#

set -e
set -o pipefail

# Load HPC cluster profile (exports module names; falls back to .example defaults)
_HPC_PROFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# ============================================================================
# Default Configuration
# ============================================================================

ACCOUNT=""
PARTITION=""
OUTPUT_DIR=""
REFERENCE_DIR=""
MEMORY="8G"
TIME_LIMIT="00:15:00"
DEPENDENCY=""
WORKSPACE_ROOT=""
CONTAINER=""

# ============================================================================
# Parse Command Line Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --reference-dir)
            REFERENCE_DIR="$2"
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
        --container)
            CONTAINER="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --output-dir DIR [--reference-dir DIR] [--workspace-root DIR] [OPTIONS]"
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
# Validate Required Arguments
# ============================================================================

if [ -z "$OUTPUT_DIR" ]; then
    echo "ERROR: Missing required argument --output-dir"
    echo ""
    echo "Required: --output-dir, --account, --partition"
    echo ""
    echo "Usage:"
    echo "  bash run_pipeline_report_slurm.sh --output-dir DIR --account ACCOUNT --partition PARTITION [OPTIONS]"
    echo ""
    echo "Run with --help for full documentation"
    exit 1
fi

if [ -z "$ACCOUNT" ] || [ -z "$PARTITION" ]; then
    echo "ERROR: Missing required SLURM parameters"
    echo "  --account ACCOUNT      (SLURM account to charge)"
    echo "  --partition PARTITION  (SLURM partition/queue)"
    echo ""
    echo "Usage:"
    echo "  bash run_pipeline_report_slurm.sh --output-dir DIR --account ACCOUNT --partition PARTITION [OPTIONS]"
    exit 1
fi

# Validate dependency if provided
if [ -n "$DEPENDENCY" ]; then
    if ! [[ "$DEPENDENCY" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Invalid dependency format: $DEPENDENCY"
        echo "Dependency must be a numeric SLURM job ID"
        exit 1
    fi
fi

# Validate container if provided
if [ -n "$CONTAINER" ]; then
    # Pipeline Report uses R container (tumorspace_r.sif)
    if [ -d "$CONTAINER" ]; then
        CONTAINER="$CONTAINER/tumorspace_r.sif"
    fi
    CONTAINER=$(realpath "$CONTAINER")
    if [ ! -f "$CONTAINER" ]; then
        echo "Error: Container SIF file not found: $CONTAINER"
        echo "Expected containers/tumorspace_r.sif"
        exit 1
    fi
fi

# Convert to absolute paths
# Handle case where directory doesn't exist yet (will be created by Step 9)
if [[ "$OUTPUT_DIR" = /* ]]; then
    # Already absolute
    :
else
    # Relative path - make absolute relative to workspace root
    OUTPUT_DIR="${WORKSPACE_ROOT}/${OUTPUT_DIR}"
fi

# Auto-generate Pipeline Report directory
# Pipeline reports go into the RUN directory (parent of optimal/), not inside optimal/
# This prevents them from being deleted when Step 5 recreates optimal/
RUN_DIR=$(dirname "$OUTPUT_DIR")
PIPELINE_REPORT_DIR="${RUN_DIR}/pipeline_reports"

# Extract dataset name for display/logging (best effort)
# Try organized path first, then fallback to basename
if [[ "$OUTPUT_DIR" =~ /benchmarks/([^/]+)/ ]]; then
    DATASET="${BASH_REMATCH[1]}"
else
    DATASET=$(basename "$(dirname "$OUTPUT_DIR")")
fi

# Resolve reference directory if provided
if [ -n "$REFERENCE_DIR" ]; then
    if [ -d "$REFERENCE_DIR" ]; then
        REFERENCE_DIR=$(realpath "$REFERENCE_DIR")
    else
        echo "Warning: Reference directory not found: $REFERENCE_DIR"
        REFERENCE_DIR=""
    fi
fi

echo "================================================================================"
echo "TumorSPACE Pipeline Report (Step 11)"
echo "================================================================================"
echo "Dataset:              ${DATASET}"
echo "Output dir:           ${OUTPUT_DIR}"
echo "Pipeline report dir:  ${PIPELINE_REPORT_DIR}"
if [ -n "$REFERENCE_DIR" ]; then
    echo "Reference dir:   ${REFERENCE_DIR} (TEST MODE)"
fi
if [ -n "$DEPENDENCY" ]; then
    echo "Dependency:      ${DEPENDENCY}"
fi
echo ""

# ============================================================================
# Generate SLURM Script
# ============================================================================

# Note: OUTPUT_DIR (optimal/) may not exist yet since this script runs at submission time
# Step 9 (completion) will create it before Step 10 runs
# We'll create pipeline_reports/ inside the SLURM job, not at submission time

# Validate the run directory exists
if [ ! -d "$RUN_DIR" ]; then
    echo "ERROR: Run directory does not exist: $RUN_DIR" >&2
    echo "Check pipeline output-base path" >&2
    exit 1
fi

SLURM_SCRIPT="${RUN_DIR}/slurm_pipeline_report.sh"
echo "Generating SLURM script: $SLURM_SCRIPT" >&2

cat > "$SLURM_SCRIPT" << 'SLURM_EOF'
#!/bin/bash
#SBATCH --job-name=PLACEHOLDER_JOB_NAME
#SBATCH --account=PLACEHOLDER_ACCOUNT
#SBATCH --partition=PLACEHOLDER_PARTITION
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=PLACEHOLDER_MEMORY
#SBATCH --time=PLACEHOLDER_TIME
#SBATCH --output=PLACEHOLDER_RUN_DIR/pipeline_report_%j.out
#SBATCH --error=PLACEHOLDER_RUN_DIR/pipeline_report_%j.err

set -e

echo "=========================================================================="
echo "TumorSPACE Pipeline Report Generation"
echo "=========================================================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"
echo "Start time: $(date)"
echo ""

WORKSPACE_ROOT="PLACEHOLDER_WORKSPACE_ROOT"
OUTPUT_DIR="PLACEHOLDER_OUTPUT_DIR"
RUN_DIR="PLACEHOLDER_RUN_DIR"
PIPELINE_REPORT_DIR="PLACEHOLDER_PIPELINE_REPORT_DIR"
REFERENCE_DIR="PLACEHOLDER_REFERENCE_DIR"

# Validate OUTPUT_DIR exists (Step 9 should have created it)
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "ERROR: Output directory does not exist: $OUTPUT_DIR"
    echo "Step 9 (completion) may have failed to create optimal/ directory"
    exit 1
fi

# Validate required input files exist
REQUIRED_FILES=("OptimalTree_preprune.nw" "OptimalTree_pruned.nw" "DA_significant.txt" "OptimalTree_pruned_node_compare_list.txt" "SLAB_scores.txt")
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$OUTPUT_DIR/$file" ]; then
        echo "ERROR: Required file missing: $OUTPUT_DIR/$file"
        echo "Pipeline may have failed before Pipeline Report generation"
        exit 1
    fi
done

echo "Validation passed: All required files present"
echo ""

# Create pipeline reports directory
echo "Creating pipeline report directory: $PIPELINE_REPORT_DIR"
mkdir -p "$PIPELINE_REPORT_DIR"

# Run Pipeline Report
PLACEHOLDER_RSCRIPT_CMD

# Create symlink to latest report
LINK_NAME="${RUN_DIR}/latest_report"
ln -sfn "$PIPELINE_REPORT_DIR" "$LINK_NAME"

echo ""
echo "=========================================================================="
echo "Pipeline Report Complete!"
echo "=========================================================================="
echo "Report location: $PIPELINE_REPORT_DIR"
echo "Symlink: $LINK_NAME"
echo "Completion time: $(date)"
echo ""

SLURM_EOF

# ============================================================================
# Substitute Placeholders
# ============================================================================

JOB_NAME="pipeline_report"

sed -i "s|PLACEHOLDER_JOB_NAME|${JOB_NAME}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_ACCOUNT|${ACCOUNT}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_PARTITION|${PARTITION}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_MEMORY|${MEMORY}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_TIME|${TIME_LIMIT}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_WORKSPACE_ROOT|${REPO_BASE}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_OUTPUT_DIR|${OUTPUT_DIR}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_RUN_DIR|${RUN_DIR}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_PIPELINE_REPORT_DIR|${PIPELINE_REPORT_DIR}|g" "$SLURM_SCRIPT"
sed -i "s|PLACEHOLDER_REFERENCE_DIR|${REFERENCE_DIR}|g" "$SLURM_SCRIPT"
# Remove the placeholder line
sed -i '/PLACEHOLDER_RSCRIPT_CMD/d' "$SLURM_SCRIPT"

# Append the mode-specific execution block
if [ -n "$CONTAINER" ]; then
    cat >> "$SLURM_SCRIPT" << EOF
# Container execution
${HPC_LOAD_SINGULARITY}

export SINGULARITYENV_R_LIBS_USER="/usr/local/lib/R/site-library"
export SINGULARITYENV_R_LIBS="/usr/local/lib/R/site-library:/usr/lib/R/site-library:/usr/lib/R/library"

echo "Generating pipeline report..."
if [ -n "\$REFERENCE_DIR" ]; then
    echo "TEST MODE: Including reference validation (Plot 5)"
    singularity exec --no-home --cleanenv \\
        --bind "\$OUTPUT_DIR":"\$OUTPUT_DIR" \\
        --bind "\$PIPELINE_REPORT_DIR":"\$PIPELINE_REPORT_DIR" \\
        $CONTAINER \\
        Rscript /opt/workflows/R/generate_qc_single_run.R "\$OUTPUT_DIR" "\$PIPELINE_REPORT_DIR" "\$REFERENCE_DIR"
else
    echo "PRODUCTION MODE: No reference validation"
    singularity exec --no-home --cleanenv \\
        --bind "\$OUTPUT_DIR":"\$OUTPUT_DIR" \\
        --bind "\$PIPELINE_REPORT_DIR":"\$PIPELINE_REPORT_DIR" \\
        $CONTAINER \\
        Rscript /opt/workflows/R/generate_qc_single_run.R "\$OUTPUT_DIR" "\$PIPELINE_REPORT_DIR"
fi
EOF
else
    cat >> "$SLURM_SCRIPT" << EOF
# Native HPC execution
${HPC_LOAD_R}

cd "\$WORKSPACE_ROOT"

echo "Generating pipeline report..."
if [ -n "\$REFERENCE_DIR" ]; then
    echo "TEST MODE: Including reference validation (Plot 5)"
    Rscript workflows/pipeline_report/R/generate_qc_single_run.R "\$OUTPUT_DIR" "\$PIPELINE_REPORT_DIR" "\$REFERENCE_DIR"
else
    echo "PRODUCTION MODE: No reference validation"
    Rscript workflows/pipeline_report/R/generate_qc_single_run.R "\$OUTPUT_DIR" "\$PIPELINE_REPORT_DIR"
fi
EOF
fi

chmod +x "$SLURM_SCRIPT"

# ============================================================================
# Submit Job
# ============================================================================

echo "Submitting Pipeline Report job..." >&2
echo "  Script: $SLURM_SCRIPT" >&2
if [ -n "$DEPENDENCY" ]; then
    echo "  Dependency: afterok:${DEPENDENCY}" >&2
fi
echo "" >&2

if [ -n "$DEPENDENCY" ]; then
    JOB_ID=$(sbatch --dependency=afterok:${DEPENDENCY} --parsable "$SLURM_SCRIPT" 2>&1)
else
    JOB_ID=$(sbatch --parsable "$SLURM_SCRIPT" 2>&1)
fi

# Extract numeric job ID from output (sbatch may include verification messages)
JOB_ID=$(echo "$JOB_ID" | grep -E '^[0-9]+$' | tail -1)

# Validate job ID
if ! [[ "$JOB_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: sbatch submission failed. Could not extract numeric job ID" >&2
    exit 1
fi

echo "$JOB_ID"

# ============================================================================
# Output Summary
# ============================================================================

if [ -n "$DEPENDENCY" ]; then
    echo "# Dependency: afterok:${DEPENDENCY}" >&2
fi
echo "# Pipeline report will be in: $PIPELINE_REPORT_DIR" >&2
echo "# Symlink: $(dirname "$PIPELINE_REPORT_DIR")/latest_report" >&2