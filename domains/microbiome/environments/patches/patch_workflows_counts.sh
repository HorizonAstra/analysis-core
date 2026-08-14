#!/usr/bin/env bash
# Fix biobakery_workflows' get_counts_from_humann_logs.py for HUMAnN 3.9 logs
# (wmgx STEP "humann_count_alignments_species" -> humann/counts/humann_read_and_species_count_table.tsv).
#
# ROOT CAUSE (grounded in a real run11 log, not guessed): HUMAnN 3.9 captures the
# bowtie2 nucleotide-alignment stderr into ONE timestamped DEBUG line, e.g.
#   ... humann.utilities - DEBUG: b'[WARNING] Failed to launch ...\n641530 reads; of these:\n ...'
# The total-reads parser matches TOTAL_COUNT_TAG ("reads; of these:") on THIS line
# and does `int(line.split()[7][2:])` with NO try/except. Token [7] is `b'[WARNING]`
# -> int("[WARNING]") -> uncaught ValueError -> the whole script CRASHES. (Older
# HUMAnN put "N reads; of these:" on its own line where token 7 WAS the count.)
# The other parsed fields (species, unaligned %) are fine against 3.9.
#
# FIX: extract the count with a regex anchored on the tag -- robust to the line's
# prefix, and if it ever fails to match it falls through to the existing "NA"
# default instead of crashing.
#
# Idempotent, reversible (<file>.orig). envs/ is gitignored: re-run after rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/envs/biobakery_workflows/bin/python"
[ -x "$PY" ] || { echo "ERROR: env python not found at $PY" >&2; exit 1; }

"$PY" - <<'PY'
import sys, os, shutil

def _safe_write(path, text):
    # temp + atomic rename -> fresh inode; don't corrupt conda's hardlinked pkg cache
    tmp = path + ".patchtmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)

# setup.py installs scripts/*py as standalone scripts into the env bin/ (NOT under
# site-packages), so resolve it next to this interpreter; fall back to PATH.
path = os.path.join(os.path.dirname(sys.executable), "get_counts_from_humann_logs.py")
if not os.path.exists(path):
    path = shutil.which("get_counts_from_humann_logs.py") or path
if not os.path.exists(path):
    sys.exit(f"ERROR: get_counts_from_humann_logs.py not found (looked beside {sys.executable} and on PATH)")
OLD = '''            if TOTAL_COUNT_TAG in line:
                data[1]=int(line.split()[7][2:])'''
NEW = '''            if TOTAL_COUNT_TAG in line:
                import re as _re
                _m=_re.search(r"(\\d+) reads; of these:", line)
                if _m: data[1]=int(_m.group(1))'''
s = open(path).read()
if NEW in s:
    print("already patched:", path); sys.exit(0)
n = s.count(OLD)
if n != 1:
    sys.exit(f"ERROR: expected 1 occurrence of the total-reads block, found {n} in {path} - biobakery_workflows changed; re-inspect.")
bak = path + ".orig"
if not os.path.exists(bak):
    shutil.copy2(path, bak); print("backup:", bak)
_safe_write(path, s.replace(OLD, NEW))
print("patched:", path, "(total-reads now regex-extracted from the bowtie2 DEBUG line)")
PY
echo "done."
