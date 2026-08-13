"""Subprocess execution backend for run_code — the portable production isolation.

In-process `exec` is fine for dev (Desktop / CLI / local single user). For a shared
deployment, set RUN_CODE_EXECUTOR=subprocess and each scratch execution runs in a
separate, short-lived Python process so model-written code cannot crash the server,
spin forever, fill the disk, or read the server's secrets.

What this boundary IS: portable (needs only Python — works anywhere), a wall-clock
timeout, POSIX CPU-time and file-size limits, a scrubbed environment (no API keys), and
crash isolation (a segfault/OOM kills the child, not the server).

What it is NOT: a hardened multi-tenant boundary. For untrusted multi-tenant use, slot a
container / microVM backend behind this same seam at deploy time — callers don't change.

Two deliberate non-restrictions, because the brief is "don't restrict capabilities":
  * Network is left available, so the model's legitimate reach (e.g. fetching a
    reference) is not cut off. Restrict it at the network/container layer if needed.
  * No hard virtual-memory cap by default. RLIMIT_AS reliably breaks numpy/BLAS/DuckDB,
    which reserve large *virtual* (not resident) address space; a low cap turns healthy
    analysis into spurious MemoryErrors. Memory is best bounded by cgroups at deploy
    time. Opt in with RUN_CODE_MEM_MB if your host really needs an address-space cap.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

_HERE = Path(__file__).resolve().parent          # src/McpServer
_RUNNER = str(_HERE / "run_sandbox.py")

# environment the child keeps: paths + locale + plotting backend; everything else
# (notably *_API_KEY / secrets) is dropped.
_KEEP = {"PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TEMP", "TMP",
         "PYTHONPATH", "DATA_ROOT", "OUTPUTS_ROOT", "DATASOURCE_CACHE",
         "RUN_CODE_MEM_MB", "MPLBACKEND"}


def _child_env() -> dict:
    env = {k: v for k, v in os.environ.items() if k in _KEEP}
    env["MPLBACKEND"] = "Agg"                     # headless plotting in the child
    return env


def _apply_limits() -> None:
    """POSIX preexec: CPU-time and file-size caps; address space only if asked."""
    import resource  # POSIX-only; guarded by os.name check at the call site

    cpu = int(os.environ.get("RUN_CODE_CPU_SEC", "900"))   # generous: 15 min of CPU time
    fsize = int(os.environ.get("RUN_CODE_FSIZE_MB", "512")) * 1024 * 1024
    limits = [(resource.RLIMIT_CPU, cpu), (resource.RLIMIT_FSIZE, fsize)]
    mem_mb = os.environ.get("RUN_CODE_MEM_MB")    # opt-in address-space cap
    if mem_mb:
        m = int(mem_mb) * 1024 * 1024
        limits.append((resource.RLIMIT_AS, m))
    for res, lim in limits:
        try:
            resource.setrlimit(res, (lim, lim))
        except (ValueError, OSError):
            pass


def subprocess_run(study: str, code: str, rank: str = "species") -> dict:
    """Run one scratch execution in an isolated child and return its result dict."""
    timeout = int(os.environ.get("RUN_CODE_TIMEOUT", "900"))   # generous: 15 min wall clock
    req = json.dumps({"study": study, "code": code, "rank": rank})
    out_fd, out_path = tempfile.mkstemp(suffix=".json")
    os.close(out_fd)
    preexec = _apply_limits if os.name == "posix" else None
    try:
        proc = subprocess.run(
            [sys.executable, _RUNNER, out_path], input=req, text=True,
            capture_output=True, timeout=timeout, env=_child_env(), preexec_fn=preexec,
        )
        try:
            with open(out_path) as f:
                return json.load(f)
        except Exception:  # noqa: BLE001 - no result file means the child died hard
            tail = (proc.stderr or "")[-3000:]
            return {"status": "error", "stdout": "", "artifacts_created": [], "presented": [],
                    "error": tail or "the analysis process exited without producing a result"}
    except subprocess.TimeoutExpired:
        return {"status": "error", "stdout": "", "artifacts_created": [], "presented": [],
                "error": f"the analysis exceeded the {timeout}s time limit and was stopped"}
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass
