#!/bin/bash
# Extracted verbatim from workflows/tumorspace_core/orchestration/run_svd_selection.sh,
# lines 192-352, which is the body of the heredoc that script writes out and then
# submits with sbatch.
#
# Why this file exists: the SVD selection has no callable form. Its logic lives
# only as text inside a submitter, interleaved with #SBATCH directives, so the
# only way to run it is to submit a job. That makes it unreachable from anything
# that is already inside an allocation, which is where a capability runs.
#
# Four edits, none of which touch the selection:
#   - the three PLACEHOLDER assignments become arguments
#   - $SLURM_JOB_ID becomes ${SLURM_JOB_ID:-none}, since set -u would abort on it
#     outside a scheduler, and it is only echoed
#   - the #SBATCH directives are dropped, being scheduler metadata rather than logic
#   - DATASET_PLACEHOLDER, in the provenance header of optimal_svd.txt, becomes a
#     fourth argument. The submitter filled that token in with sed; anything else
#     running this step wrote the literal word DATASET_PLACEHOLDER into its own
#     record of which dataset the result came from
#
# Everything below those lines is byte for byte what SLURM would have run.
#
# One deliberate difference, in the default rather than the code. The original
# defaults KEEP_ALL to false, which rm -rf's every non-optimal svd_run_N
# directory once the best one is chosen. That is a disk space measure for the
# repository's persistent output layout. Here the staging tree is temporary and
# is removed on success anyway, so there is nothing to reclaim, and deleting
# those directories would make a run impossible to resume from any later stage.
# The default below is therefore true. Pass false as the third argument to get
# the original behaviour; the branch itself is unchanged.
#
# Usage: select_optimal_svd.sh <input_base> <num_svd> [keep_all] [dataset]

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: select_optimal_svd.sh <input_base> <num_svd> [keep_all] [dataset]"
    exit 1
fi

INPUT_BASE="$1"
NUM_SVD="$2"
KEEP_ALL="${3:-true}"
DATASET="${4:-unspecified}"
# Print job information
echo "=============================================================================="
echo "SVD Selection: Find Optimal SVD by Maximum NodeCor"
echo "=============================================================================="
echo "Job ID:       ${SLURM_JOB_ID:-none}"
echo "Node:         $(hostname)"
echo "Started:      $(date)"
echo "Input Base:   $INPUT_BASE"
echo "Num SVDs:     $NUM_SVD"
echo "Keep All:     $KEEP_ALL"
echo "=============================================================================="
echo

# Record start time
START_TIME=$(date +%s)

# Find optimal SVD by maximum NodeCor
echo "[1/3] Scanning SVD runs for NodeCor values..."
BEST_SVD=""
BEST_NODECOR=-1
BEST_SUPPORT=""
BEST_SPATIAL=""
BEST_KNN=""

for i in $(seq 1 $NUM_SVD); do
    COR_FILE="$INPUT_BASE/svd_run_${i}/cor_dat_all.tsv"
    
    if [ ! -f "$COR_FILE" ]; then
        echo "  ⚠ Warning: cor_dat_all.tsv not found for SVD $i, skipping"
        continue
    fi
    
    # Extract first data row (row 2): NodeCor, Run, SVD_end, KNN_spatial_run, Prune, Spatial, KNN
    DATA_ROW=$(head -2 "$COR_FILE" | tail -1)
    NODECOR=$(echo "$DATA_ROW" | cut -f1)
    SUPPORT=$(echo "$DATA_ROW" | cut -f5)
    SPATIAL=$(echo "$DATA_ROW" | cut -f6)
    KNN=$(echo "$DATA_ROW" | cut -f7)
    
    echo "  SVD $i: NodeCor = $NODECOR"
    
    # Compare NodeCor values (using bc for floating point comparison)
    if (( $(echo "$NODECOR > $BEST_NODECOR" | bc -l) )); then
        BEST_SVD=$i
        BEST_NODECOR=$NODECOR
        BEST_SUPPORT=$SUPPORT
        BEST_SPATIAL=$SPATIAL
        BEST_KNN=$KNN
    fi
done

if [ -z "$BEST_SVD" ]; then
    echo "ERROR: No valid SVD runs found with cor_dat_all.tsv"
    exit 1
fi

echo ""
echo "Selected optimal SVD: $BEST_SVD"
echo "  NodeCor (correlation):    $BEST_NODECOR"
echo "  Support threshold:        $BEST_SUPPORT"
echo "  Spatial threshold:        $BEST_SPATIAL"
echo "  K nearest neighbors:      $BEST_KNN"
echo ""

# Copy outputs from optimal SVD to optimal/ directory
echo "[2/3] Copying outputs from optimal SVD to optimal directory..."
OPTIMAL_DIR="$INPUT_BASE/optimal"
SOURCE_DIR="$INPUT_BASE/svd_run_${BEST_SVD}"

# Remove existing optimal directory if present
if [ -e "$OPTIMAL_DIR" ]; then
    echo "  Removing existing optimal directory"
    rm -rf "$OPTIMAL_DIR"
fi

# Create fresh optimal directory
mkdir -p "$OPTIMAL_DIR"

# Copy key output files needed by downstream steps (only if they exist)
# From spatial analysis steps (always present)
cp "$SOURCE_DIR/OptimalTree.nw" "$OPTIMAL_DIR/" || true
cp "$SOURCE_DIR/OptimalTree_preprune.nw" "$OPTIMAL_DIR/" || true
cp "$SOURCE_DIR/SPI_Dist_mtx.txt" "$OPTIMAL_DIR/" || true

# From node analysis steps (usually present)
[ -f "$SOURCE_DIR/OptimalTree_labelpreprune.nw" ] && cp "$SOURCE_DIR/OptimalTree_labelpreprune.nw" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/tree_edges.tsv" ] && cp "$SOURCE_DIR/tree_edges.tsv" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/tree_nodes.tsv" ] && cp "$SOURCE_DIR/tree_nodes.tsv" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/allnodes_leaves.tsv" ] && cp "$SOURCE_DIR/allnodes_leaves.tsv" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/allnodes_parents.tsv" ] && cp "$SOURCE_DIR/allnodes_parents.tsv" "$OPTIMAL_DIR/" || true

# From tree pruning step (optional, only exists if prune step was run)
[ -f "$SOURCE_DIR/OptimalTree_pruned.nw" ] && cp "$SOURCE_DIR/OptimalTree_pruned.nw" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/OptimalTree_pruned_node_compare_list.txt" ] && cp "$SOURCE_DIR/OptimalTree_pruned_node_compare_list.txt" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/OptimalTree_pruned_node_compare_leaves.txt" ] && cp "$SOURCE_DIR/OptimalTree_pruned_node_compare_leaves.txt" "$OPTIMAL_DIR/" || true
[ -f "$SOURCE_DIR/OptimalTree_pruned_node_info.txt" ] && cp "$SOURCE_DIR/OptimalTree_pruned_node_info.txt" "$OPTIMAL_DIR/" || true

echo "  ✓ Copied outputs from svd_run_${BEST_SVD} to $OPTIMAL_DIR"

# Write optimal SVD info to file
OPTIMAL_INFO="$INPUT_BASE/optimal_svd.txt"
cat > "$OPTIMAL_INFO" << EOF
# Optimal SVD Selection Results
# Generated: $(date)
# Dataset: $DATASET

SVD_Number: $BEST_SVD
NodeCor: $BEST_NODECOR
Support_Threshold: $BEST_SUPPORT
Spatial_Threshold: $BEST_SPATIAL
KNN: $BEST_KNN

# NodeCor represents the correlation between predicted and actual spot locations.
# Higher values indicate better spatial clustering performance.
# Range: 0.0 (no correlation) to 1.0 (perfect correlation)
EOF

echo "  ✓ Wrote: $OPTIMAL_INFO"

# Optionally delete non-optimal SVD directories to save space
echo ""
if [ "$KEEP_ALL" = "false" ]; then
    echo "[3/3] Deleting non-optimal SVD directories..."
    DELETED=0
    for i in $(seq 1 $NUM_SVD); do
        if [ $i -ne $BEST_SVD ]; then
            SVD_DIR="$INPUT_BASE/svd_run_${i}"
            if [ -d "$SVD_DIR" ]; then
                rm -rf "$SVD_DIR"
                echo "  Deleted: svd_run_${i}"
                DELETED=$((DELETED + 1))
            fi
        fi
    done
    echo "  ✓ Deleted $DELETED non-optimal SVD directories"
else
    echo "[3/3] Keeping all SVD directories (--keep-all specified)"
fi

# Record completion
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "=============================================================================="
echo "SVD Selection Complete"
echo "=============================================================================="
echo "Elapsed time: ${ELAPSED}s"
echo "Optimal SVD:  $BEST_SVD (NodeCor = $BEST_NODECOR)"
echo "Output dir:   $OPTIMAL_DIR"
echo "Info file:    $OPTIMAL_INFO"
echo ""
echo "Next steps:"
echo "  - Use optimal/ directory for downstream analysis (Steps 6-8)"
echo "  - Read optimal_svd.txt for selected hyperparameters"
echo "=============================================================================="

