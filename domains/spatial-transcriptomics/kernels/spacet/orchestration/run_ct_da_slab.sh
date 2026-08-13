#!/bin/bash
#
# run_ct_da_slab.sh
#
# CT Feature-Space DA + SLAB (TumorSPACE_AWS)
#
# Single SLURM job that runs three sequential steps for the cell-type proportion
# feature space derived from SpaCET:
#
#   1. prepare_ct_matrix.R  — reshape Spacet_Matrix.txt → standard DA interface
#   2. sg_diff_abundance.jl — Wilcoxon DA on CT proportions across SG pairs
#   3. sg_slab_score.jl     — SLAB scores for DA cell types
#
# All outputs written to {input-base}/optimal/ct/
# Appends an entry to {input-base}/optimal/feature_spaces.tsv on success.
#
# Usage:
#   bash run_ct_da_slab.sh \
#     --dataset DATASET \
#     --account ACCOUNT \
#     --partition PARTITION \
#     --spacet-dir DIR \
#     --input-base DIR \
#     --input-dir DIR \
#     [OPTIONS]
#
# Required Arguments:
#   --dataset DATASET       Dataset name (e.g., 23-1-875-2)
#   --account ACCOUNT       SLURM account
#   --partition PARTITION   SLURM partition
#   --spacet-dir DIR        Directory containing Spacet_Matrix.txt
#   --input-base DIR        Base directory containing optimal/ subdirectory
#   --input-dir DIR         Raw Visium data directory (barcodes_positions.txt)
#
# Optional Arguments:
#   --workspace-root DIR    Repo root [default: auto-derived from script location]
#   --container DIR         containers/ directory (enables Singularity mode)
#   --num-shuffle N         Number of DA permutations [default: 100]
#   --dependency JOB_ID     SLURM job to wait for before starting
#   --mem SIZE              Memory allocation [default: 8G]
#   --time LIMIT            Time limit [default: 00:30:00]
#
# Outputs in {input-base}/optimal/ct/:
#   M.txt, barcodes.txt, genes.txt, barcodes_positions.txt
#   OptimalTree_pruned_node_compare_{list,leaves}.txt  (symlinks)
#   DA_results.txt, DA_significant.txt
#   SLAB_scores.txt, SLAB_barcodes.txt
#   ct_slab_done.txt
#
# {input-base}/optimal/feature_spaces.tsv updated with CT entry on success.
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
SPACET_DIR=""
INPUT_BASE=""
INPUT_DIR=""
CONTAINER_DIR=""
NUM_SHUFFLE=100
MEM="8G"
TIME_LIMIT="00:30:00"
DEPENDENCY=""
WORKSPACE_ROOT=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dataset)        DATASET="$2";        shift 2;;
        --account)        ACCOUNT="$2";        shift 2;;
        --partition)      PARTITION="$2";      shift 2;;
        --spacet-dir)     SPACET_DIR="$2";     shift 2;;
        --input-base)     INPUT_BASE="$2";     shift 2;;
        --input-dir)      INPUT_DIR="$2";      shift 2;;
        --workspace-root) WORKSPACE_ROOT="$2"; shift 2;;
        --container)      CONTAINER_DIR="$2";  shift 2;;
        --num-shuffle)    NUM_SHUFFLE="$2";    shift 2;;
        --mem)            MEM="$2";            shift 2;;
        --time)           TIME_LIMIT="$2";     shift 2;;
        --dependency)     DEPENDENCY="$2";     shift 2;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$DATASET" ] || [ -z "$ACCOUNT" ] || [ -z "$PARTITION" ] || \
   [ -z "$SPACET_DIR" ] || [ -z "$INPUT_BASE" ] || [ -z "$INPUT_DIR" ]; then
    echo "ERROR: Missing required arguments"
    echo ""
    echo "Required: --dataset, --account, --partition, --spacet-dir, --input-base, --input-dir"
    echo ""
    echo "Usage:"
    echo "  bash run_ct_da_slab.sh --dataset DATASET --account ACCOUNT --partition PARTITION \\"
    echo "                         --spacet-dir DIR --input-base DIR --input-dir DIR [OPTIONS]"
    exit 1
fi

# Auto-derive workspace root if not provided
if [ -z "$WORKSPACE_ROOT" ]; then
    WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../.. && pwd)"
fi

if [ ! -d "$WORKSPACE_ROOT" ]; then
    echo "Error: Workspace root directory not found: $WORKSPACE_ROOT"
    exit 1
fi

# Determine execution mode
if [ -n "$CONTAINER_DIR" ]; then
    MODE="CONTAINER"
    if [ ! -d "$CONTAINER_DIR" ]; then
        echo "Error: Container directory not found: $CONTAINER_DIR"
        exit 1
    fi
    R_CONTAINER="$CONTAINER_DIR/tumorspace_r.sif"
    JULIA_CONTAINER="$CONTAINER_DIR/julia_1.9_with_gotree.sif"
    if [ ! -f "$R_CONTAINER" ]; then
        echo "Error: R container not found: $R_CONTAINER"
        exit 1
    fi
    if [ ! -f "$JULIA_CONTAINER" ]; then
        echo "Error: Julia container not found: $JULIA_CONTAINER"
        exit 1
    fi
else
    MODE="HPC"
    R_CONTAINER=""
    JULIA_CONTAINER=""
fi

# Convert to absolute paths
INPUT_BASE=$(realpath "$INPUT_BASE")
INPUT_DIR=$(realpath "$INPUT_DIR")
SPACET_DIR=$(realpath "$SPACET_DIR")

# Key derived paths
OPTIMAL_DIR="$INPUT_BASE/optimal"
CT_DIR="$OPTIMAL_DIR/ct"
SPACET_MATRIX="$SPACET_DIR/Spacet_Matrix.txt"

# Native script paths
NATIVE_PREPARE_SCRIPT="$WORKSPACE_ROOT/workflows/spacet/R/prepare_ct_matrix.R"
NATIVE_DA_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia/sg_diff_abundance.jl"
NATIVE_SLAB_SCRIPT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia/sg_slab_score.jl"
JULIA_PROJECT="$WORKSPACE_ROOT/workflows/tumorspace_core/julia"

# Container script paths (inside .sif)
CONTAINER_PREPARE_SCRIPT="/opt/workflows/R/prepare_ct_matrix.R"
CONTAINER_DA_SCRIPT="/opt/workflows/julia/sg_diff_abundance.jl"
CONTAINER_SLAB_SCRIPT="/opt/workflows/julia/sg_slab_score.jl"

# Validate input existence (skip checks when using --dependency)
if [ -z "$DEPENDENCY" ]; then
    if [ ! -f "$SPACET_MATRIX" ]; then
        echo "ERROR: Spacet_Matrix.txt not found: $SPACET_MATRIX"
        exit 1
    fi
    if [ ! -d "$OPTIMAL_DIR" ]; then
        echo "ERROR: optimal/ directory not found: $OPTIMAL_DIR"
        echo "Make sure you have run SVD selection (Step 6) first"
        exit 1
    fi
    for tree_file in "OptimalTree_pruned_node_compare_list.txt" \
                     "OptimalTree_pruned_node_compare_leaves.txt"; do
        if [ ! -f "$OPTIMAL_DIR/$tree_file" ]; then
            echo "ERROR: $tree_file not found in $OPTIMAL_DIR"
            echo "Make sure you have run SG identification (Step 7) first"
            exit 1
        fi
    done
    if [ ! -f "$INPUT_DIR/barcodes_positions.txt" ]; then
        echo "ERROR: barcodes_positions.txt not found in $INPUT_DIR"
        exit 1
    fi
fi

# Create logs directory
mkdir -p logs

# Generate timestamp for this run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create SLURM batch script
SBATCH_SCRIPT="./logs/ct_da_slab_sbatch_${TIMESTAMP}.sh"

cat > "$SBATCH_SCRIPT" << 'HEREDOC_END'
#!/bin/bash
#SBATCH --job-name=ct_da_slab
#SBATCH --output=logs/ct_da_slab_%j.out
#SBATCH --error=logs/ct_da_slab_%j.err
#SBATCH --time=__TIME_LIMIT__
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --account=__ACCOUNT__
#SBATCH --partition=__PARTITION__
#SBATCH --mem=__MEM__

echo "=================================================="
echo "TumorSPACE CT Feature-Space: DA + SLAB"
echo "=================================================="
echo "Dataset:      __DATASET__"
echo "Mode:         __MODE__"
echo "Num shuffle:  __NUM_SHUFFLE__"
echo "Start time:   $(date)"
echo "Hostname:     $(hostname)"
echo "=================================================="
echo

OPTIMAL_DIR="__OPTIMAL_DIR__"
CT_DIR="__CT_DIR__"
SPACET_MATRIX="__SPACET_MATRIX__"
INPUT_DIR="__INPUT_DIR__"
INPUT_BASE="__INPUT_BASE__"
NUM_SHUFFLE="__NUM_SHUFFLE__"

echo "Optimal dir:    $OPTIMAL_DIR"
echo "CT output dir:  $CT_DIR"
echo "SpaCET matrix:  $SPACET_MATRIX"
echo ""

# Create CT output directory
mkdir -p "$CT_DIR"

# Pre-copy external inputs into CT_DIR so the container only needs --bind INPUT_BASE
cp "$SPACET_MATRIX" "$CT_DIR/Spacet_Matrix.txt"
cp "$INPUT_DIR/barcodes_positions.txt" "$CT_DIR/barcodes_positions.txt"
echo "Pre-copy: Spacet_Matrix.txt + barcodes_positions.txt staged into $CT_DIR"

# Mode-specific function definitions are injected here by run_ct_da_slab.sh
FUNCTION_DEFS_PLACEHOLDER

echo "=================================================="
echo "Step 1: Prepare CT matrix"
echo "=================================================="
MODE_PREPARE_PLACEHOLDER

echo ""
echo "Verify CT matrix prepared..."
for f in M.txt barcodes.txt genes.txt barcodes_positions.txt; do
    if [ -f "$CT_DIR/$f" ]; then
        echo "  ✓ $f"
    else
        echo "  ✗ ERROR: $f not found in $CT_DIR"
        exit 1
    fi
done
echo ""

echo "=================================================="
echo "Step 2: CT Differential Abundance (${NUM_SHUFFLE} shuffles)"
echo "=================================================="
MODE_DA_PLACEHOLDER

echo ""
if [ -f "$CT_DIR/DA_significant.txt" ]; then
    N_SIG=$(tail -n +2 "$CT_DIR/DA_significant.txt" | wc -l)
    echo "  ✓ DA_significant.txt  ($N_SIG significant cell types)"
else
    echo "  ✗ ERROR: DA_significant.txt not produced"
    exit 1
fi
echo ""

echo "=================================================="
echo "Step 3: CT SLAB Scoring"
echo "=================================================="
MODE_SLAB_PLACEHOLDER

echo ""
if [ -f "$CT_DIR/SLAB_scores.txt" ]; then
    N_SLAB=$(tail -n +2 "$CT_DIR/SLAB_scores.txt" | wc -l)
    echo "  ✓ SLAB_scores.txt  ($N_SLAB cell-type/direction pairs)"
else
    echo "  ✗ ERROR: SLAB_scores.txt not produced"
    exit 1
fi
if [ -f "$CT_DIR/SLAB_barcodes.txt" ]; then
    echo "  ✓ SLAB_barcodes.txt"
else
    echo "  ✗ ERROR: SLAB_barcodes.txt not produced"
    exit 1
fi
echo ""

echo "=================================================="
echo "Finalising"
echo "=================================================="

# Write done marker
touch "$CT_DIR/ct_slab_done.txt"
echo "  ✓ ct_slab_done.txt written"

# Update feature_spaces.tsv manifest
FSTSV="$OPTIMAL_DIR/feature_spaces.tsv"
if [ ! -f "$FSTSV" ]; then
    printf "name\ttype\tn_features\tda_sig_path\tslab_path\tstatus\n" > "$FSTSV"
fi
N_CT=$(tail -n +2 "$CT_DIR/genes.txt" | wc -l)
printf "ct\tcell_type_proportion\t%s\t%s\t%s\tcomplete\n" \
    "$N_CT" \
    "$CT_DIR/DA_significant.txt" \
    "$CT_DIR/SLAB_scores.txt" >> "$FSTSV"
echo "  ✓ feature_spaces.tsv updated  (ct, ${N_CT} cell types)"

echo ""
echo "=================================================="
echo "CT DA+SLAB complete"
echo "End time: $(date)"
echo "Outputs: $CT_DIR"
echo "=================================================="
HEREDOC_END

# Substitute placeholders
sed -i "s|__ACCOUNT__|$ACCOUNT|g"           "$SBATCH_SCRIPT"
sed -i "s|__PARTITION__|$PARTITION|g"       "$SBATCH_SCRIPT"
sed -i "s|__DATASET__|$DATASET|g"           "$SBATCH_SCRIPT"
sed -i "s|__MODE__|$MODE|g"                 "$SBATCH_SCRIPT"
sed -i "s|__OPTIMAL_DIR__|$OPTIMAL_DIR|g"   "$SBATCH_SCRIPT"
sed -i "s|__CT_DIR__|$CT_DIR|g"             "$SBATCH_SCRIPT"
sed -i "s|__SPACET_MATRIX__|$SPACET_MATRIX|g" "$SBATCH_SCRIPT"
sed -i "s|__INPUT_DIR__|$INPUT_DIR|g"       "$SBATCH_SCRIPT"
sed -i "s|__INPUT_BASE__|$INPUT_BASE|g"     "$SBATCH_SCRIPT"
sed -i "s|__NUM_SHUFFLE__|$NUM_SHUFFLE|g"   "$SBATCH_SCRIPT"
sed -i "s|__TIME_LIMIT__|$TIME_LIMIT|g"     "$SBATCH_SCRIPT"
sed -i "s|__MEM__|$MEM|g"                   "$SBATCH_SCRIPT"

# Write mode-specific function definitions to temp file, then inject before first call
if [ "$MODE" = "CONTAINER" ]; then
    cat > "${SBATCH_SCRIPT}.defs" << EOF
# ── Container execution (prepare_ct_matrix.R) ────────────────────────────────
_PREPARE_CT() {
${HPC_LOAD_SINGULARITY}
singularity exec --no-home --cleanenv \\
    --env R_LIBS_USER="/usr/local/lib/R/site-library" \\
    --bind "$INPUT_BASE":"$INPUT_BASE" \\
    "$R_CONTAINER" \\
    Rscript "$CONTAINER_PREPARE_SCRIPT" \\
    --spacet-matrix "$CT_DIR/Spacet_Matrix.txt" \\
    --optimal-dir "$OPTIMAL_DIR" \\
    --input-dir "$CT_DIR" \\
    --outdir "$CT_DIR"
}

# ── Container execution (sg_diff_abundance.jl) ───────────────────────────────
_DA_CT() {
singularity exec --no-home --cleanenv \\
    --env JULIA_DEPOT_PATH=/tmp/julia_depot:/opt/julia_depot \\
    --env JULIA_PKG_PRECOMPILE_AUTO=0 \\
    --bind "$INPUT_BASE":"$INPUT_BASE" \\
    "$JULIA_CONTAINER" \\
    julia --project=/opt/workflows/julia "$CONTAINER_DA_SCRIPT" \\
    "$CT_DIR" \\
    "$NUM_SHUFFLE"
}

# ── Container execution (sg_slab_score.jl) ───────────────────────────────────
_SLAB_CT() {
singularity exec --no-home --cleanenv \\
    --env JULIA_DEPOT_PATH=/tmp/julia_depot:/opt/julia_depot \\
    --env JULIA_PKG_PRECOMPILE_AUTO=0 \\
    --bind "$INPUT_BASE":"$INPUT_BASE" \\
    "$JULIA_CONTAINER" \\
    julia --project=/opt/workflows/julia "$CONTAINER_SLAB_SCRIPT" \\
    "$CT_DIR"
}
EOF
else
    cat > "${SBATCH_SCRIPT}.defs" << EOF
# ── Native HPC execution (prepare_ct_matrix.R) ───────────────────────────────
_PREPARE_CT() {
${HPC_LOAD_R}
Rscript "$NATIVE_PREPARE_SCRIPT" \\
    --spacet-matrix "$CT_DIR/Spacet_Matrix.txt" \\
    --optimal-dir "$OPTIMAL_DIR" \\
    --input-dir "$CT_DIR" \\
    --outdir "$CT_DIR"
}

# ── Native HPC execution (sg_diff_abundance.jl) ──────────────────────────────
_DA_CT() {
${HPC_LOAD_JULIA}
julia --project="$JULIA_PROJECT" "$NATIVE_DA_SCRIPT" \\
    "$CT_DIR" \\
    "$NUM_SHUFFLE"
}

# ── Native HPC execution (sg_slab_score.jl) ──────────────────────────────────
_SLAB_CT() {
julia --project="$JULIA_PROJECT" "$NATIVE_SLAB_SCRIPT" \\
    "$CT_DIR"
}
EOF
fi

# Inject function definitions at placeholder, then replace call-site placeholders
sed -i "/^FUNCTION_DEFS_PLACEHOLDER$/ {r ${SBATCH_SCRIPT}.defs
d}" "$SBATCH_SCRIPT"
rm "${SBATCH_SCRIPT}.defs"
sed -i 's/MODE_PREPARE_PLACEHOLDER/_PREPARE_CT/' "$SBATCH_SCRIPT"
sed -i 's/MODE_DA_PLACEHOLDER/_DA_CT/' "$SBATCH_SCRIPT"
sed -i 's/MODE_SLAB_PLACEHOLDER/_SLAB_CT/' "$SBATCH_SCRIPT"

# Make executable
chmod +x "$SBATCH_SCRIPT"

# Display submission info
echo "========================================"
echo "Submitting CT DA+SLAB job"
echo "========================================"
echo "Dataset:      $DATASET"
echo "Mode:         $MODE"
echo "Account:      $ACCOUNT"
echo "Partition:    $PARTITION"
echo "Input base:   $INPUT_BASE"
echo "SpaCET dir:   $SPACET_DIR"
echo "Optimal dir:  $OPTIMAL_DIR"
echo "CT out dir:   $CT_DIR"
echo "Num shuffle:  $NUM_SHUFFLE"
echo "Mem:          $MEM"
echo "Time:         $TIME_LIMIT"
if [ "$MODE" = "CONTAINER" ]; then
    echo "R container:  $R_CONTAINER"
    echo "Julia cont.:  $JULIA_CONTAINER"
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
echo "  tail -f logs/ct_da_slab_${JOB_ID}.out"
echo ""
echo "Expected outputs in $CT_DIR:"
echo "  DA_results.txt, DA_significant.txt"
echo "  SLAB_scores.txt, SLAB_barcodes.txt"
echo "  ct_slab_done.txt"
echo ""
