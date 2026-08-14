#!/usr/bin/env bash
# Build the client environment on this machine, from the pin beside it.
# Same shape as a domain's restore.sh: the pin travels, the build does not.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 -m venv py
./py/bin/python -m pip install --quiet --upgrade pip
./py/bin/python -m pip install --quiet -r requirements.txt
./py/bin/python - <<'PY'
import mcp, pydantic, pandas, fastapi          # noqa: F401
print("client environment ready")
PY
