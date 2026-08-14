#!/usr/bin/env bash
# Assert the env is actually usable — the CLI must START, which for HAllA means its rpy2
# bridge resolved XICOR and eva too. Both build.sh and restore.sh end here, and the image
# build runs it, so a broken env fails at build time instead of at a user's first request.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R_LIBS_USER="$HERE/rlib" "$HERE/.venv/bin/halla" --help >/dev/null 2>&1 \
  && echo "halla env OK ($("$HERE/.venv/bin/halla" --version 2>/dev/null | tail -1))" \
  || { echo "FAIL: halla CLI cannot start (check rpy2 / XICOR / eva)"; exit 1; }
