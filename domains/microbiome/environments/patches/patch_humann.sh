#!/usr/bin/env bash
# Fix HUMAnN's MetaPhlAn version check for MetaPhlAn 4.2 with a DB installed in
# the default location.
#
# ROOT CAUSE: humann/config.py's metaphlan_version parses `metaphlan --version`
# at line index -1 (the LAST non-empty line), column 2. That worked when the
# output was a single "MetaPhlAn version X.Y.Z ..." line. But once a DB exists in
# the default location (our link_metaphlan_db.sh), metaphlan --version prints a
# 2nd line "Installed databases: mpa_vJan25...", which becomes line -1. HUMAnN
# then int()s "mpa_..." -> ValueError -> "CRITICAL ERROR: Can not call software
# version for metaphlan", killing the run at startup.
#
# FIX: read the FIRST line (line 0) -- always the version line.
#
# Idempotent, reversible (<file>.orig). envs/ is gitignored: re-run after rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/envs/biobakery_workflows/bin/python"
[ -x "$PY" ] || { echo "ERROR: env python not found at $PY" >&2; exit 1; }

"$PY" - <<'PY'
import sys, os, shutil
import humann.config as c
path = c.__file__

def _safe_write(path, text):
    # temp + atomic rename -> fresh inode; don't corrupt conda's hardlinked pkg cache
    tmp = path + ".patchtmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
OLD = '''metaphlan_version={
    "flag" : "--version",
    "major" : 3,
    "minor" : 0,
    "line" : -1,
    "column" : 2}'''
NEW = OLD.replace('"line" : -1', '"line" : 0')
s = open(path).read()
if NEW in s:
    print("already patched:", path); sys.exit(0)
n = s.count(OLD)
if n != 1:
    sys.exit(f"ERROR: expected 1 occurrence of metaphlan_version block, found {n} in {path} - humann changed; re-inspect.")
bak = path + ".orig"
if not os.path.exists(bak):
    shutil.copy2(path, bak); print("backup:", bak)
_safe_write(path, s.replace(OLD, NEW))
print("patched:", path, "(metaphlan version check now reads line 0)")
PY
echo "done."
