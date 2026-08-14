#!/usr/bin/env bash
# Build this domain's environment on this machine, from the pin beside it.
# The pin travels with the domain; what it builds does not.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 -m venv py
./py/bin/python -m pip install --quiet --upgrade pip
./py/bin/python -m pip install --quiet -r requirements.txt
MPLBACKEND=Agg ./py/bin/python -c "import matplotlib, seaborn, pandas; print('visualization environment ready')"
