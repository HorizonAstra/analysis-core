#!/usr/bin/env bash
# Make biobakery_workflows 3.1's StrainPhlAn flow work with MetaPhlAn 4.2.
#
# biobakery_workflows 3.1 wired StrainPhlAn for MetaPhlAn 3.0. Grounded in the
# MetaPhlAn 4.2.5 source, five things drifted (all in tasks/shotgun.py):
#   1. sample2markers.py now writes <stem>.json.bz2, not <stem>.pkl
#      (utils/sample2markers.py:190; suffix is '' unless --clades is passed,
#      confirmed :442 -- biobakery doesn't pass it, so the name matches the target)
#   2/3. strainphlan --samples globs must therefore match *.json.bz2, not *.pkl
#   4. extract_markers.py renamed --clade -> --clades (plural) in 4.x
#   5. the hardcoded MetaPhlAn-3.0 DB (mpa_v30_CHOCOPhlAn_201901.pkl) must become
#      the current SGB DB -- read it from the default-dir mpa_latest our
#      link_metaphlan_db.sh writes, so this stays correct across DB-version changes.
#
# NOTE: this makes the strain path structurally 4.2-compatible; it was designed
# entirely from source, no run required. FINAL validation still needs real
# MULTI-SAMPLE data (a strain tree biologically needs >=4 samples sharing a
# strain) -- a single-sample smoke will produce clades but no tree, which is
# expected, not a failure.
#
# Idempotent, reversible (<file>.orig), per-site assert-count. envs/ is
# gitignored: re-run after any env rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/envs/biobakery_workflows/bin/python"
[ -x "$PY" ] || { echo "ERROR: env python not found at $PY" >&2; exit 1; }

"$PY" - <<'PY'
import sys, os, shutil, biobakery_workflows
path = os.path.join(os.path.dirname(biobakery_workflows.__file__), "tasks", "shotgun.py")

def _safe_write(path, text):
    # temp + atomic rename -> fresh inode; don't corrupt conda's hardlinked pkg cache
    tmp = path + ".patchtmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
subs = [
 ('subfolder="strainphlan", extension="pkl", create_folder=True',
  'subfolder="strainphlan", extension="json.bz2", create_folder=True'),
 ('--samples [args[0]]/*/*.pkl --output_dir [args[1]] ',
  '--samples [args[0]]/*/*.json.bz2 --output_dir [args[1]] '),
 ('--samples [args[0]]/*/*.pkl --output_dir [args[0]] --print_clades_only',
  '--samples [args[0]]/*/*.json.bz2 --output_dir [args[0]] --print_clades_only'),
 ('"--clade [args[0]] --output_dir [args[1]]"',
  '"--clades [args[0]] --output_dir [args[1]]"'),
 ('                strainphlan_pkl=os.path.join(os.path.dirname(metaphlan.__file__),"metaphlan_databases","mpa_v30_CHOCOPhlAn_201901.pkl")',
  '                _mpadir=os.path.join(os.path.dirname(metaphlan.__file__),"metaphlan_databases")\n'
  '                strainphlan_pkl=os.path.join(_mpadir, open(os.path.join(_mpadir,"mpa_latest")).read().strip()+".pkl")'),
]
s = open(path).read()
changed = 0
for i,(old,new) in enumerate(subs,1):
    if new in s and old not in s:
        continue                     # this site already patched
    n = s.count(old)
    if n != 1:
        sys.exit(f"ERROR: site {i}: expected 1 occurrence, found {n} in {path} - biobakery_workflows changed; re-inspect.")
    s = s.replace(old, new); changed += 1
if changed == 0:
    print("already patched:", path); sys.exit(0)
bak = path + ".orig"
if not os.path.exists(bak):
    shutil.copy2(path, bak); print("backup:", bak)
_safe_write(path, s)
print(f"patched {changed} site(s):", path, "(StrainPhlAn now speaks MetaPhlAn 4.2)")
PY
echo "done."
