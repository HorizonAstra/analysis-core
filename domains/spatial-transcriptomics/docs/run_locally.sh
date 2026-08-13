#!/bin/bash
#
# docs/run_locally.sh
#
# TumorSPACE sequential (no-SLURM) execution reference.
#
# Runs the full TumorSPACE pipeline (Steps 1–8) sequentially in the foreground
# using `singularity exec` on a local workstation or any Linux machine without SLURM.
#
# ─── WHO THIS IS FOR ──────────────────────────────────────────────────────────
#   A computationally savvy user who:
#     • Has already built the containers (run ./setup.sh once first), AND
#     • Wants to run without SLURM, OR
#     • Wants to run / debug a single step interactively.
#
# ─── AUTHORITATIVE ARG REFERENCES ─────────────────────────────────────────────
#   Every script's full argument signature is documented in its own header.
#   Read them when debugging or adapting individual steps:
#
#     workflows/tumorspace_core/julia/phylo_tree_build.jl    Steps 1 & 1b
#     workflows/tumorspace_core/julia/phylo_node_extract.jl  Step 2
#     workflows/tumorspace_core/julia/spatial_optimize.jl    Step 3
#     workflows/tumorspace_core/julia/phylo_tree_prune.jl    Step 4
#     workflows/tumorspace_core/R/sg_identify_pairs.R        Step 6
#     workflows/tumorspace_core/julia/sg_diff_abundance.jl   Step 7
#     workflows/tumorspace_core/julia/sg_slab_score.jl       Step 8
#
# ─── HPC / SLURM PATH ─────────────────────────────────────────────────────────
#   For parallel HPC execution (job arrays, automatic dependencies):
#     bash run_benchmark.sh --account <account> --partition <partition>
#   or
#     bash run_pipeline.sh \
#         --dataset DATASET --account ACCOUNT --partition PARTITION \
#         --input-dir DIR --data-dir DIR --output-base DIR [OPTIONS]
#
# ─── USAGE ────────────────────────────────────────────────────────────────────
#   Edit the CONFIGURATION block below, then:
#     bash docs/run_locally.sh              # from repo root
#   or run a single step by calling the relevant function directly, e.g.:
#     source docs/run_locally.sh && step6_sg_identify   # not yet implemented as functions
#
# ─── NOTE ON RUNTIME ──────────────────────────────────────────────────────────
#   Steps run sequentially here; on HPC they run as parallel SLURM job arrays.
#   Steps 1 & 1b dominate wall time (SVD × bootstraps trees).  Runtime depends
#   entirely on dataset size (spots) and number of SVDs.  See docs/benchmarks.md
#   for dataset-specific timings.
#

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — lines marked [MODIFY] are the ones you will typically change
# ══════════════════════════════════════════════════════════════════════════════

# [MODIFY] Dataset name — used to label output subdirectories
DATASET="GSE213688_GSM6592057"

# Repo root — auto-detected from script location; change if running from elsewhere
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# [MODIFY] Input data directory.
#   Must contain: M.txt  barcodes.txt  genes.txt (or features.txt)  barcodes_positions.txt
#   This is typically the output of the acquisition step (local/datasets/.../input_data/)
#   or the committed benchmark directory.
INPUT_DIR="${WORKSPACE_ROOT}/local/datasets/${DATASET}/input_data"

# [MODIFY] Data directory — usually the same as INPUT_DIR; separate only if
#   your spatial position file (barcodes_positions.txt) lives elsewhere.
DATA_DIR="${INPUT_DIR}"

# [MODIFY] Base output directory (created automatically, timestamped)
OUTPUT_BASE="${WORKSPACE_ROOT}/local/outputs/${DATASET}/run_$(date +%Y%m%d_%H%M%S)"

# [MODIFY] Singularity SIF containing Julia 1.9 + gotree (built by setup.sh)
JULIA_SIF="${WORKSPACE_ROOT}/containers/julia_1.9_with_gotree.sif"

# [MODIFY] Singularity SIF containing R + TumorSPACE R packages (built by setup.sh)
R_SIF="${WORKSPACE_ROOT}/containers/tumorspace_r.sif"

# [MODIFY] SVD values to sweep.
#   Test mode — 3 values, fast validation (matches --test in run_pipeline.sh):
SVD_VALUES=(5 50 150)
#   Production — 30 values, full analysis.  Comment the line above and
#   uncomment the line below:
#SVD_VALUES=(5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100 \
#            105 110 115 120 125 130 135 140 145 150)

# [MODIFY] Bootstrap replicates per SVD run.
#   10 is the standard default; changing this affects Step 1b TBE reliability.
BOOTSTRAPS=10

# [MODIFY] Support threshold for tree pruning (0.0–1.0).
#   Branches with TBE support < threshold are collapsed to polytomies.
#   0.5 is the standard default.  Lower → keep more branches.
SUPPORT_THRESHOLD=0.5

# ══════════════════════════════════════════════════════════════════════════════
# END CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

JL_DIR="${WORKSPACE_ROOT}/workflows/tumorspace_core/julia"
R_DIR="${WORKSPACE_ROOT}/workflows/tumorspace_core/R"

mkdir -p "${OUTPUT_BASE}/logs"

# ─── Helper functions ─────────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Execute a Julia script inside the Julia+gotree container.
# The full workspace root is bind-mounted so scripts can read/write relative paths.
julia_exec() {
    singularity exec --no-home --cleanenv \
        -B "${WORKSPACE_ROOT}" \
        "${JULIA_SIF}" \
        julia "$@"
}

# Execute an R script inside the R container.
r_exec() {
    singularity exec --no-home --cleanenv \
        -B "${WORKSPACE_ROOT}" \
        "${R_SIF}" \
        Rscript "$@"
}

# Run the gotree binary embedded in the Julia container.
# Usage: gotree_exec <gotree args...>
gotree_exec() {
    singularity exec --no-home --cleanenv \
        -B "${WORKSPACE_ROOT}" \
        "${JULIA_SIF}" \
        sh -c 'export LD_LIBRARY_PATH=/usr/local/julia/lib/julia:$LD_LIBRARY_PATH && gotree '"$*"
}

# ─── Pre-flight checks ────────────────────────────────────────────────────────

if [[ ! -f "${JULIA_SIF}" ]]; then
    echo "ERROR: Julia container not found: ${JULIA_SIF}"
    echo "  Run ./setup.sh from the repo root to build containers first."
    exit 1
fi
if [[ ! -f "${R_SIF}" ]]; then
    echo "ERROR: R container not found: ${R_SIF}"
    echo "  Run ./setup.sh from the repo root to build containers first."
    exit 1
fi
if [[ ! -f "${INPUT_DIR}/M.txt" ]]; then
    echo "ERROR: Input data not found at ${INPUT_DIR}/M.txt"
    echo "  Acquire the dataset first:"
    echo "    bash workflows/acquisition/orchestration/run_geo_discovery.sh --download ${DATASET}"
    echo "  or update INPUT_DIR at the top of this script."
    exit 1
fi

log "════════════════════════════════════════════════════"
log "TumorSPACE — Local (no-SLURM) Execution"
log "  Dataset     : ${DATASET}"
log "  Input dir   : ${INPUT_DIR}"
log "  Output base : ${OUTPUT_BASE}"
log "  SVD values  : ${SVD_VALUES[*]}"
log "    (${#SVD_VALUES[@]} runs × ${BOOTSTRAPS} bootstraps)"
log "════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# Steps 1 & 1b — Tree building + bootstrap TBE support
#
# For each SVD dimension value:
#   1a) Build original tree (boot=0) + BOOTSTRAPS replicates (boot=1..N).
#       Each call produces Tree_<boot>.nw in the SVD run directory.
#   1b) Concatenate bootstrap trees → Tree_Bootstrap.nw, then
#       run gotree to compute TBE support → Tree_support.nw.
#
# Tree_support.nw is the key output — required by all downstream steps.
# ══════════════════════════════════════════════════════════════════════════════
log ""
log "Steps 1 & 1b — Building trees and computing bootstrap support..."

for i in "${!SVD_VALUES[@]}"; do
    SVD_VALUE="${SVD_VALUES[$i]}"
    SVD_RUN=$((i + 1))
    SVD_DIR="${OUTPUT_BASE}/svd_run_${SVD_RUN}"
    mkdir -p "${SVD_DIR}"

    log "  SVD run ${SVD_RUN}/${#SVD_VALUES[@]}  svd_value=${SVD_VALUE}"

    # Step 1a: build original tree (boot=0) then each bootstrap replicate
    for BOOT in $(seq 0 "${BOOTSTRAPS}"); do
        log "    phylo_tree_build  boot=${BOOT} ..."
        julia_exec "${JL_DIR}/phylo_tree_build.jl" \
            --dataset    "${DATASET}" \
            --input-dir  "${INPUT_DIR}" \
            --output-dir "${SVD_DIR}" \
            --svd-run    "${SVD_RUN}" \
            --svd-value  "${SVD_VALUE}" \
            --boot       "${BOOT}" \
            >> "${OUTPUT_BASE}/logs/step1_svdrun${SVD_RUN}_boot${BOOT}.log" 2>&1
    done

    # Step 1b: concatenate bootstrap trees, then compute TBE support
    BOOT_FILE="${SVD_DIR}/Tree_Bootstrap.nw"
    rm -f "${BOOT_FILE}"
    for b in $(seq 1 "${BOOTSTRAPS}"); do
        cat "${SVD_DIR}/Tree_${b}.nw" >> "${BOOT_FILE}"
    done

    log "    gotree TBE support..."
    gotree_exec \
        -i "${SVD_DIR}/Tree_0.nw" \
        -b "${BOOT_FILE}" \
        -o "${SVD_DIR}/Tree_support.nw" \
        -@ 4 \
        -a tbe \
        >> "${OUTPUT_BASE}/logs/step1b_svdrun${SVD_RUN}.log" 2>&1

    log "  ✓ Run ${SVD_RUN} trees complete"
done

# ══════════════════════════════════════════════════════════════════════════════
# Step 2 — Node extraction
#
# Reads Tree_support.nw + barcodes_positions.txt.
# Positional args: <output_dir> <tree_support_file> <barcode_positions_file>
# Outputs: tree_nodes.tsv, tree_edges.tsv, allnodes_leaves.tsv,
#          allnodes_parents.tsv, spectral_dist_melt.tsv
# ══════════════════════════════════════════════════════════════════════════════
log ""
log "Step 2 — Node extraction..."

for i in "${!SVD_VALUES[@]}"; do
    SVD_RUN=$((i + 1))
    SVD_DIR="${OUTPUT_BASE}/svd_run_${SVD_RUN}"
    log "  SVD run ${SVD_RUN}..."
    julia_exec "${JL_DIR}/phylo_node_extract.jl" \
        "${SVD_DIR}" \
        "${SVD_DIR}/Tree_support.nw" \
        "${DATA_DIR}/barcodes_positions.txt" \
        >> "${OUTPUT_BASE}/logs/step2_svdrun${SVD_RUN}.log" 2>&1
    log "  ✓ Run ${SVD_RUN} done"
done

# ══════════════════════════════════════════════════════════════════════════════
# Step 3 — Spatial optimization (hyperparameter search)
#
# Runs Ripley's K spatial statistics + random grid search over (support
# threshold, spatial-clustering threshold, K-NN) to maximise NodeCor.
# Positional args: <step2_output_dir> <data_dir> <output_dir>
# Key output: cor_dat_all.tsv — first row = max NodeCor for this SVD run
# ══════════════════════════════════════════════════════════════════════════════
log ""
log "Step 3 — Spatial optimization..."

for i in "${!SVD_VALUES[@]}"; do
    SVD_RUN=$((i + 1))
    SVD_DIR="${OUTPUT_BASE}/svd_run_${SVD_RUN}"
    log "  SVD run ${SVD_RUN}..."
    julia_exec "${JL_DIR}/spatial_optimize.jl" \
        "${SVD_DIR}" \
        "${DATA_DIR}" \
        "${SVD_DIR}" \
        >> "${OUTPUT_BASE}/logs/step3_svdrun${SVD_RUN}.log" 2>&1
    log "  ✓ Run ${SVD_RUN} done"
done

# ══════════════════════════════════════════════════════════════════════════════
# Step 4 — Tree pruning
#
# Prunes branches with TBE support < SUPPORT_THRESHOLD using as_polytomy!
# Positional args: <step3_output_dir> <output_dir> <support_threshold>
# Outputs: OptimalTree_preprune.nw, OptimalTree_pruned*.nw, ..._node_*.txt
# ══════════════════════════════════════════════════════════════════════════════
log ""
log "Step 4 — Tree pruning (threshold=${SUPPORT_THRESHOLD})..."

for i in "${!SVD_VALUES[@]}"; do
    SVD_RUN=$((i + 1))
    SVD_DIR="${OUTPUT_BASE}/svd_run_${SVD_RUN}"
    log "  SVD run ${SVD_RUN}..."
    julia_exec "${JL_DIR}/phylo_tree_prune.jl" \
        "${SVD_DIR}" \
        "${SVD_DIR}" \
        "${SUPPORT_THRESHOLD}" \
        >> "${OUTPUT_BASE}/logs/step4_svdrun${SVD_RUN}.log" 2>&1
    log "  ✓ Run ${SVD_RUN} done"
done

# ══════════════════════════════════════════════════════════════════════════════
# Step 5 — SVD selection
#
# Reads the first data row of cor_dat_all.tsv from each SVD run (= max NodeCor
# for that run) and selects the run with the highest value.  Creates an
# "optimal" symlink and copies input files alongside the results so downstream
# scripts (Steps 6–8) can find them by relative path.
# ══════════════════════════════════════════════════════════════════════════════
log ""
log "Step 5 — Selecting optimal SVD by NodeCor..."

BEST_SVD=1
BEST_COR=""

for i in "${!SVD_VALUES[@]}"; do
    SVD_RUN=$((i + 1))
    COR_FILE="${OUTPUT_BASE}/svd_run_${SVD_RUN}/cor_dat_all.tsv"
    if [[ -f "${COR_FILE}" ]]; then
        COR=$(awk 'NR==2 {print $1}' "${COR_FILE}")
        if [[ -z "${BEST_COR}" ]] || awk "BEGIN {exit !(${COR} > ${BEST_COR})}"; then
            BEST_COR="${COR}"
            BEST_SVD="${SVD_RUN}"
        fi
    else
        log "  WARNING: cor_dat_all.tsv missing for SVD run ${SVD_RUN} — skipping"
    fi
done

log "  Selected: svd_run_${BEST_SVD}  NodeCor=${BEST_COR}"
echo "${BEST_SVD}  NodeCor=${BEST_COR}" > "${OUTPUT_BASE}/optimal_svd.txt"
ln -sfn "svd_run_${BEST_SVD}" "${OUTPUT_BASE}/optimal"

OPTIMAL_DIR="${OUTPUT_BASE}/svd_run_${BEST_SVD}"

# Copy input files into optimal dir — Steps 6–8 expect them alongside outputs
log "  Copying input files into optimal dir..."
for f in M.txt barcodes.txt genes.txt features.txt barcodes_positions.txt; do
    [[ -f "${INPUT_DIR}/${f}" ]] && cp "${INPUT_DIR}/${f}" "${OPTIMAL_DIR}/" || true
done

log "  ✓ Optimal: ${OUTPUT_BASE}/optimal -> svd_run_${BEST_SVD}"

# ══════════════════════════════════════════════════════════════════════════════
# Step 6 — Spatial Group (SG) identification  [R]
#
# Reads pruned tree + node files from OPTIMAL_DIR.
# Args: <output_dir> <input_tree_dir>  (both are OPTIMAL_DIR here)
# Outputs: OptimalTree_pruned_node_compare_list.txt,
#          OptimalTree_pruned_node_compare_leaves.txt
# ══════════════════════════════════════════════════════════════════════════════
log ""
log "Step 6 — Spatial Group identification (R)..."

r_exec "${R_DIR}/sg_identify_pairs.R" \
    "${OPTIMAL_DIR}" \
    "${OPTIMAL_DIR}" \
    >> "${OUTPUT_BASE}/logs/step6.log" 2>&1

log "  ✓ Step 6 done"

# ══════════════════════════════════════════════════════════════════════════════
# Step 7 — Differential abundance
#
# Wilcoxon rank-sum tests (with permutation FDR) between SG pairs.
# Arg: <output_dir>  (reads M.txt, barcodes.txt, genes.txt from there)
# Outputs: DA_results.txt, DA_significant.txt
# ══════════════════════════════════════════════════════════════════════════════
log ""
log "Step 7 — Differential abundance..."

julia_exec "${JL_DIR}/sg_diff_abundance.jl" \
    "${OPTIMAL_DIR}" \
    >> "${OUTPUT_BASE}/logs/step7.log" 2>&1

log "  ✓ Step 7 done"

# ══════════════════════════════════════════════════════════════════════════════
# Step 8 — SLAB scoring
#
# Computes Spatially Localized Abundance Bias scores per DA gene.
# Arg: <output_dir>  (reads barcodes_positions.txt and DA outputs from there)
# Outputs: SLAB_scores.txt, SLAB_barcodes.txt
# ══════════════════════════════════════════════════════════════════════════════
log ""
log "Step 8 — SLAB scoring..."

julia_exec "${JL_DIR}/sg_slab_score.jl" \
    "${OPTIMAL_DIR}" \
    >> "${OUTPUT_BASE}/logs/step8.log" 2>&1

log "  ✓ Step 8 done"

# ══════════════════════════════════════════════════════════════════════════════
# Complete
# ══════════════════════════════════════════════════════════════════════════════
log ""
log "════════════════════════════════════════════════════"
log "Pipeline complete!"
log "  Optimal SVD : svd_run_${BEST_SVD}  (NodeCor=${BEST_COR})"
log "  Results     : ${OPTIMAL_DIR}"
log "  Step logs   : ${OUTPUT_BASE}/logs/"
log "════════════════════════════════════════════════════"
