#!/usr/bin/env bash
# Turn a fresh clone into a working installation. Safe to re-run.
#
#   ./setup.sh
#
# Deliberately the only thing anyone has to be told. What it builds is decided by
# the catalog rather than by this file, so a new domain needs no change here.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for python in python3.12 python3.11 python3; do
  if command -v "$python" >/dev/null 2>&1; then
    # 3.10 or newer: the tree uses `X | Y` annotations at runtime.
    if "$python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
      exec "$python" infrastructure/setup/install.py "$@"
    fi
  fi
done

echo "No python3.10 or newer found on this machine, and the tree needs one." >&2
echo "Install Python 3.12, then run ./setup.sh again." >&2
exit 1
