"""Child entrypoint for the subprocess execution backend (see sandbox.py).

Reads a JSON request {study, code, rank} on stdin, runs the scratch code in this
isolated process, and writes the JSON result dict to the path given as argv[1]. Stdout is
left for the request/diagnostics; the result never goes through stdout, so library
chatter can't corrupt it.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# same path setup as mcp_server.py: src/ (analysis, provenance, datasource) and this dir
_HERE = Path(__file__).resolve().parent          # src/McpServer
_SRC = _HERE.parent                              # src
for _p in (str(_SRC), str(_HERE)):
    if _p not in sys.path:
        sys.path.insert(0, _p)
os.environ.setdefault("MPLBACKEND", "Agg")


def main() -> None:
    out_path = sys.argv[1]
    req = json.loads(sys.stdin.read())
    try:
        from tools.platform.scratch import execute_run
        res = execute_run(req["study"], req["code"], req.get("rank", "species"))
    except Exception:  # noqa: BLE001 - any failure becomes a clean result the parent can read
        import traceback
        res = {"status": "error", "stdout": "", "artifacts_created": [], "presented": [],
               "error": traceback.format_exc()[-3000:]}
    with open(out_path, "w") as f:
        json.dump(res, f, default=str)


if __name__ == "__main__":
    main()
