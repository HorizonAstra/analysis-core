#!/usr/bin/env bash
# Make the MetaPhlAn package's DEFAULT database location resolve to our shared DB.
#
# WHY: we run `metaphlan` with explicit --db_dir/--index/--offline, so it never
# touches the default location. But StrainPhlAn's sample2markers.py / strainphlan
# default to "latest", which reads <pkg>/metaphlan_databases/mpa_latest -- and in
# the shared DB that file is owned by another user (ramanujam), mode rw-r-----,
# so we can't even read it. Result: "default MetaPhlAn database cannot be found".
#
# FIX: in the package's default dir, write OUR OWN readable mpa_latest naming the
# vJan25 index, and symlink the world-readable index files from the shared DB.
# Every metaphlan-family tool that relies on the default now resolves it.
#
# Idempotent. envs/ is gitignored, so RE-RUN after any conda env rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config/env.sh"   # MPA_DB_DIR (shared DB dir) + MPA_INDEX

PY="$ROOT/envs/biobakery_workflows/bin/python"
[ -x "$PY" ] || { echo "ERROR: env python not found at $PY" >&2; exit 1; }

SRC="${MPA_DB_DIR:?set MPA_DB_DIR in config/env.sh}"
INDEX="${MPA_INDEX:?set MPA_INDEX in config/env.sh}"
DEST="$("$PY" -c 'import os,metaphlan; print(os.path.join(os.path.dirname(metaphlan.__file__),"metaphlan_databases"))')"

[ -d "$DEST" ] || mkdir -p "$DEST"
echo "shared DB : $SRC"
echo "index     : $INDEX"
echo "default   : $DEST"

# clear any previous version's symlinks so switching MetaPhlAn DB versions stays clean
find "$DEST" -maxdepth 1 -type l -name 'mpa_*' -delete 2>/dev/null || true

n=0
for f in "$SRC/${INDEX}"*; do
  [ -e "$f" ] || continue
  ln -sfn "$f" "$DEST/$(basename "$f")"; n=$((n+1))
done
[ "$n" -gt 0 ] || { echo "ERROR: no '${INDEX}*' files found under $SRC" >&2; exit 1; }

# our own readable mpa_latest (shared one is owned by another user, unreadable)
printf '%s\n' "$INDEX" > "$DEST/mpa_latest"

echo "linked $n index files; verify:"
ls -la "$DEST/mpa_latest" "$DEST/${INDEX}.pkl"
echo "mpa_latest -> $(cat "$DEST/mpa_latest")"
echo "done."
