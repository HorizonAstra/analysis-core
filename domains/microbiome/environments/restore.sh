#!/usr/bin/env bash
# RESTORE the HAllA environment exactly as the locks record it. This is what the image runs.
# It resolves nothing: no "latest", no version drift, same contents on a laptop and in a build.
#   bash envs/halla/restore.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.conf"

if command -v uv >/dev/null 2>&1; then
  uv venv "$HERE/.venv" --python "$PYTHON_VERSION" --allow-existing
  # sync, not install: the env ends up matching the lock exactly, extras removed
  VIRTUAL_ENV="$HERE/.venv" uv pip sync "$HERE/requirements.lock.txt"
else
  python3 -m venv "$HERE/.venv"
  "$HERE/.venv/bin/pip" install -q --upgrade pip
  "$HERE/.venv/bin/pip" install --no-deps -r "$HERE/requirements.lock.txt"
fi

# Exact versions from the lock, off the same dated snapshot the lock was authored against.
Rscript "$HERE/restore_r.R" "$HERE/rlib" "$HERE/r-requirements.lock.txt" "$CRAN_SNAPSHOT"

bash "$HERE/verify.sh"
