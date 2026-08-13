#!/usr/bin/env bash
# Per-study run wrapper. Copy into a study dir and edit STUDY + paths:
#   cp templates/study-run.sh /gpfs/data/dfi-cores/rijul/studies/<study>/run.sh
#   # edit run.sh, then:
#   bash /gpfs/data/dfi-cores/rijul/studies/<study>/run.sh
set -euo pipefail

TOOL=/gpfs/data/dfi-cores/rijul/biobakery
STUDY=CHANGE_ME                                   # <- name this study
BASE=/gpfs/data/dfi-cores/rijul/studies/$STUDY    # <- or point elsewhere; paths are free

# submit_wmgx.sh batch-submits the run (survives disconnects). Run from a login node.
bash "$TOOL/bin/submit_wmgx.sh" \
  --study   "$STUDY" \
  --input   "$BASE/input" \
  --output  "$BASE/output" \
  --scratch "/scratch/${USER}/biobakery/$STUDY/$(date +%Y%m%d_%H%M%S)"
