#!/usr/bin/env bash
# Point HUMAnN's database config at OUR references/ (rename-proof).
#
# WHY: HUMAnN stores ABSOLUTE db paths in humann.cfg (nucleotide=chocophlan,
# protein=uniref, utility_mapping). After renaming the repo dir these still point
# at the old .../biobakery/references/... (dead) -> a functional humann run can't
# find its DBs. We reset them to $ROOT/references/{chocophlan,uniref,utility_mapping}
# (symlinks to the shared DB), so the values track the repo's own location.
#
# humann_config rewrites humann.cfg IN PLACE; conda hardlinks that file from the
# shared pkg cache, so we break the hardlink first (copy + rename -> fresh inode)
# to keep the cache pristine (same lesson as the patch scripts).
#
# Idempotent. Re-run after any env rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/envs/biobakery_workflows/bin/python"
HC="$ROOT/envs/biobakery_workflows/bin/humann_config"
[ -x "$PY" ] && [ -x "$HC" ] || { echo "ERROR: env humann not found (build the env first)" >&2; exit 1; }

REF="$ROOT/references"
for sub in chocophlan uniref utility_mapping; do
  [ -e "$REF/$sub" ] || { echo "WARN: $REF/$sub missing -- skipping humann db config" >&2; exit 0; }
done

# break the humann.cfg hardlink to the pkg cache before humann_config edits it
CFG="$("$PY" -c 'import os,humann; print(os.path.join(os.path.dirname(humann.__file__),"humann.cfg"))')"
[ -f "$CFG" ] && { cp -p "$CFG" "$CFG.hltmp" && mv -f "$CFG.hltmp" "$CFG"; }

"$HC" --update database_folders nucleotide      "$REF/chocophlan"
"$HC" --update database_folders protein         "$REF/uniref"
"$HC" --update database_folders utility_mapping "$REF/utility_mapping"

echo "HUMAnN db folders now:"
"$HC" --print | grep -i "database_folders"
echo "done."
