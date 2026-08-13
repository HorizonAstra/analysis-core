#!/usr/bin/env bash
# Runs the biobakery whole-metagenome workflow over a directory of reads.
#
#   run_wmgx.sh --input DIR --output DIR --scratch DIR [--mode wmgx|taxonomy]
#
# What stays here is what belongs to this science: which MetaPhlAn database each
# mode may use, why taxonomy-only is allowed to use the newer one, and which
# profiling steps a mode bypasses.
#
# What used to be here and is not any more:
#
#   the SLURM partition, account, job count, thread count and memory ceiling.
#     Those describe a machine. They now arrive as ANALYSIS_* variables that the
#     runner fills in from the site file, so this pipeline no longer carries a
#     description of one cluster and a second cluster costs nothing here.
#
#   activating the conda environment.
#     The catalog entry declares which environment this needs; the runner enters
#     it. Where conda is installed is a property of the machine.
#
#   the login node refusal.
#     The runner refuses on any host a site names as a login node, so the rule
#     now protects every domain rather than whichever script remembered it.
#
#   writing a provenance file and appending to runs.tsv.
#     The run record is written by the artifact store, once, in one format.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the domain
source "$HERE/environments/env.sh"                        # database versions

MODE=wmgx        # wmgx = QC, taxonomy, function and strains, on the COMPAT database
                 # taxonomy = QC and taxonomy only, on the newer LATEST database
INPUT="" OUTPUT="" SCRATCH=""
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)    INPUT="$2";   shift 2 ;;
    --output)   OUTPUT="$2";  shift 2 ;;
    --scratch)  SCRATCH="$2"; shift 2 ;;
    --mode)     MODE="$2";    shift 2 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

: "${INPUT:?--input is required}"
: "${OUTPUT:?--output is required}"
: "${SCRATCH:?--scratch is required}"
[[ -d "$INPUT" ]] || { echo "input dir not found: $INPUT" >&2; exit 1; }
command -v biobakery_workflows >/dev/null || {
  echo "biobakery_workflows is not on PATH: the environment did not activate" >&2; exit 1; }

# What the machine permits. Defaults keep this runnable outside a scheduler.
QUEUE="${ANALYSIS_QUEUE:-}"
ACCOUNT="${ANALYSIS_ACCOUNT:-}"
JOBS="${ANALYSIS_MAX_CONCURRENT:-20}"
THREADS="${ANALYSIS_CORES:-8}"
MEM_MAX="${ANALYSIS_MEMORY_MB:-96000}"

# Which MetaPhlAn database a mode may use, and why. Taxonomy-only may take the
# newer markers precisely because it drops HUMAnN and StrainPhlAn, the two steps
# that force the compatible database. Bypassing them is what makes it safe, so
# the bypass is set here rather than left to the caller.
case "$MODE" in
  wmgx)
    RUN_INDEX="$MPA_INDEX_COMPAT";  RUN_DB_DIR="$MPA_DB_DIR_COMPAT" ;;
  taxonomy)
    RUN_INDEX="$MPA_INDEX_LATEST";  RUN_DB_DIR="$MPA_DB_DIR_LATEST"
    EXTRA+=( --bypass-functional-profiling --bypass-strain-profiling ) ;;
  *) echo "--mode must be wmgx or taxonomy, got '$MODE'" >&2; exit 1 ;;
esac

mkdir -p "$OUTPUT" "$SCRATCH"

GRID_ARGS=()
if [[ -n "$QUEUE" ]]; then
  # Deliberately no --grid-options=--mem: a forced memory value wins sbatch's
  # last-wins rule and would disable the per-task escalation that --grid-mem-max
  # caps, which is the only lever that lets HUMAnN grow when it needs to.
  GRID_ARGS=( --grid slurm --grid-jobs "$JOBS" --grid-partition "$QUEUE"
              --grid-scratch "$SCRATCH" --grid-mem-max "$MEM_MAX" )
  [[ -n "$ACCOUNT" ]] && GRID_ARGS+=( "--grid-options=--account=$ACCOUNT" )
fi

set -x
biobakery_workflows wmgx \
  --input  "$INPUT" \
  --output "$OUTPUT" \
  --threads "$THREADS" \
  --remove-intermediate-output \
  --taxonomic-profiling-options "--db_dir $RUN_DB_DIR --index $RUN_INDEX --offline" \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  ${GRID_ARGS[@]+"${GRID_ARGS[@]}"}
