#!/usr/bin/env bash
# Apply ALL env-level fixups after building/rebuilding the conda env.
#
# envs/ is gitignored, so patches to the installed packages and the metaphlan DB
# link do NOT persist across a `conda create`. Run this once after building the
# env (and after any env rebuild). Every step is idempotent.
#
#   bash bin/postinstall.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== [1/7] anadama2 grid escalation fixes =="
bash "$ROOT/bin/patch_anadama2.sh"

echo; echo "== [2/7] humann metaphlan version-check fix =="
bash "$ROOT/bin/patch_humann.sh"

echo; echo "== [3/7] biobakery_workflows humann-counts log-parse fix =="
bash "$ROOT/bin/patch_workflows_counts.sh"

echo; echo "== [4/7] biobakery_workflows StrainPhlAn 4.2 compatibility =="
bash "$ROOT/bin/patch_workflows_strainphlan.sh"

echo; echo "== [5/7] metaphlan default DB link (for StrainPhlAn) =="
bash "$ROOT/bin/link_metaphlan_db.sh"

echo; echo "== [6/7] humann database folders (rename-proof) =="
bash "$ROOT/bin/config_humann_dbs.sh"

echo; echo "== [7/7] humann level4ec regroup map link (auxiliary EC table) =="
# non-fatal: EC table is auxiliary; a missing map must not block core env setup
bash "$ROOT/bin/link_humann_ec_map.sh" || echo "WARN: EC map step reported issues (non-fatal)"

echo; echo "ALL env fixups applied."
