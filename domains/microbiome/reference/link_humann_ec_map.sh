#!/usr/bin/env bash
# Make HUMAnN's `uniref90_level4ec` regroup option available (biobakery_workflows
# wmgx STEP "humann_regroup_UniRef2EC" -> humann/regrouped/*_ecs.tsv).
#
# ROOT CAUSE (grounded in humann 3.9 source, tools/regroup_table.py:44-57):
# `humann_regroup_table --groups` choices are built DYNAMICALLY by scanning
# config.utility_mapping_database for known map files. `uniref90_level4ec` is a
# valid choice ONLY IF the file `map_level4ec_uniref90.txt.gz` is present there.
# Our utility_mapping dir has go/ko/pfam/eggnog but is MISSING that one file, so
# biobakery's unmodified command fails with "invalid choice: 'uniref90_level4ec'".
# This is a DATA gap, not a HUMAnN code change -- so we fix the data, not the code:
# find the map in the shared DB and symlink it in. biobakery's command then works
# verbatim (no workflow patch needed).
#
# Idempotent, non-fatal (EC table is auxiliary: warn + exit 0 so postinstall
# continues). Re-run after any env rebuild.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config/env.sh"   # SHARED_DB

PY="$ROOT/envs/biobakery_workflows/bin/python"
[ -x "$PY" ] || { echo "WARN: env python not found at $PY -- skipping EC map link" >&2; exit 0; }

MAP="map_level4ec_uniref90.txt.gz"
UMDIR="$("$PY" -c 'from humann import config; print(config.utility_mapping_database)' 2>/dev/null)"
if [ -z "${UMDIR:-}" ] || [ ! -d "$UMDIR" ]; then
  echo "WARN: HUMAnN utility_mapping dir not resolved ('$UMDIR') -- skipping." >&2
  exit 0
fi
echo "utility_mapping : $UMDIR"

# already present (real file or working symlink)?
if [ -e "$UMDIR/$MAP" ]; then
  echo "EC map already present: $UMDIR/$MAP"
  echo "  uniref90_level4ec is available; nothing to do."
  exit 0
fi

# locate the map anywhere in the shared DB tree
echo "searching shared DB for $MAP ..."
SRC="$(find "${SHARED_DB:-/gpfs/data/dfi-cores/biobakery/databases}" -maxdepth 6 -name "$MAP" -readable 2>/dev/null | head -1)"

if [ -z "$SRC" ]; then
  cat >&2 <<EOF
WARN: $MAP not found in the shared DB.
  -> uniref90_level4ec regrouping (the humann/regrouped/*_ecs.tsv table) will stay
     unavailable. This is the full utility_mapping level4->uniref90 map. Options:
       (a) obtain it (part of HUMAnN 'utility_mapping full') and drop it in:
             $UMDIR/
       (b) accept no EC table for now (core gene families + pathways are unaffected).
  Non-fatal -- continuing.
EOF
  exit 0
fi

ln -sfn "$SRC" "$UMDIR/$MAP"
echo "linked: $UMDIR/$MAP -> $SRC"
echo "verify (uniref90_level4ec should now be listed):"
"$PY" - <<'PY'
from humann.tools import regroup_table as r
print("  groups:", ", ".join(sorted(r.c_default_groups.keys())))
PY
echo "done."
