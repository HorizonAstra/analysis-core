#!/usr/bin/env bash
# Start the web client on this machine.
#
#   ./run.sh              http://127.0.0.1:8000
#   PORT=9000 ./run.sh    somewhere else
#   DEV_RELOAD=1 ./run.sh restart on edit
#
# For development and for a single-user workstation. A shared deployment runs the
# image instead (see clients/Dockerfile), which is the same application with the
# port, secrets, data mount and state volume supplied from outside.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -x clients/.venv/bin/python ]]; then
  echo "The client environment is not built yet. Run ./setup.sh first." >&2
  exit 1
fi
if [[ ! -f clients/.env ]]; then
  echo "clients/.env is missing. Run ./setup.sh, then add an API key to it." >&2
  exit 1
fi

# Started from clients/ because that is where the app resolves its own state,
# and exec'd so that Ctrl-C reaches the server rather than this script.
cd clients
exec .venv/bin/python webapp/server.py
