#!/usr/bin/env bash
# Submit the wmgx orchestrator as a SLURM BATCH job, so the pipeline survives SSH
# disconnects and does NOT depend on tmux or which login node you land on.
#
# Run this FROM A LOGIN NODE — it only calls sbatch (lightweight, allowed there).
# The batch job runs run_wmgx.sh on a compute node; AnADAMA2 then submits the
# per-tool grid jobs. Everything keeps running if you close your laptop.
#
#   bash bin/submit_wmgx.sh --study NAME --input DIR --output DIR --scratch DIR [extra wmgx opts]
#
# Monitor:  squeue -u $USER          tail -f <output>/orchestrator_<jobid>.log
# Resume:   just re-submit the same command — AnADAMA2 skips completed tasks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config/site.sh"

# scan forwarded args for --study (job name) and --output (log location)
STUDY="job"; OUTPUT=""
args=("$@"); n=${#args[@]}
for ((i=0; i<n; i++)); do
  case "${args[i]}" in
    --study)  STUDY="${args[i+1]:-job}" ;;
    --output) OUTPUT="${args[i+1]:-}" ;;
  esac
done
: "${OUTPUT:?--output is required}"
mkdir -p "$OUTPUT"

# The orchestrator itself is light (it coordinates; the heavy tools run as separate
# grid jobs sized by AnADAMA2). Give it a long wall-time and modest memory.
jid=$(sbatch --parsable \
  -J "bbwmgx_${STUDY}" \
  -p "$SLURM_PARTITION" -A "$SLURM_ACCOUNT" \
  -t 2-00:00:00 --mem=8G -c 2 \
  -o "$OUTPUT/orchestrator_%j.log" \
  --wrap "bash '$ROOT/bin/run_wmgx.sh' $(printf '%q ' "$@")")

echo "submitted orchestrator job: $jid"
echo "  log:     $OUTPUT/orchestrator_${jid}.log"
echo "  monitor: squeue -u $USER    |    tail -f $OUTPUT/orchestrator_${jid}.log"
