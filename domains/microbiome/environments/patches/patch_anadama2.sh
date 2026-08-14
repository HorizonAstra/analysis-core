#!/usr/bin/env bash
# Harden AnADAMA2's SLURM grid layer on Randi. SIX idempotent string patches to
# slurm.py + grid.py, two concerns:
#  (a) on-OOM memory auto-escalation (resubmit the task with 2x memory) -- bugs 1-3.
#  (b) "busy Randi" resilience: when the scheduler is under load, sbatch/sacct calls
#      time out; the retry path is broken so a transient error crashes the whole run
#      instead of retrying -- bugs 4-6.
#
# (a) On an OOM, AnADAMA2 should resubmit with 2x memory (grid.py run_task_command).
# THREE bugs defeat that on Randi; all are needed. Evidence: failed runs' anadama.log + sacct.
#
# --- anadama2/grid/slurm.py ---
# BUG 1 (truncated sacct State): refresh_queue_status runs `sacct -o JobID,State,...`;
#   the default State width truncates "OUT_OF_MEMORY" -> "OUT_OF_ME+", and
#   job_memkill does an EXACT match. FIX: State -> State%20.
# BUG 2 (stderr OOM pattern): when the rc-file appears the poll breaks while sacct
#   still says "Pending" (accounting lag); the fallback get_job_status_from_stderr
#   should reclassify, but its patterns don't match Randi's message
#   "slurmstepd: error: Detected 1 oom_kill event ... OOM Killed." FIX: also treat
#   any "oom" in the slurm errors as a memory kill.
#
# --- anadama2/grid/grid.py ---
# BUG 3 (list doubling): memory is a 2-element list [requested, max] e.g.
#   [24576, 96000]. The escalation does `memory*2`, which DUPLICATES the list
#   ([24576,96000,24576,96000]) instead of doubling the value, so mem[0] stays
#   24576 and every retry re-requests 24G. FIX: double mem[0], keep the ceiling.
#   (Same bug for time; fixed too.)
#
# Idempotent, reversible (backup at <file>.orig). envs/ is gitignored, so RE-RUN
# after any conda env rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PY="$ROOT/envs/biobakery_workflows/bin/python"
[ -x "$PY" ] || { echo "ERROR: env python not found at $PY (build the conda env first)" >&2; exit 1; }

"$PY" - <<'PY'
import sys, os, shutil
import anadama2.grid.slurm as S, anadama2.grid.grid as G

patches = {
    S.__file__: [
        ("widen sacct State (fix OUT_OF_MEMORY truncation)",
         'JobID,State,AllocCPUs,Elapsed,MaxRSS',
         'JobID,State%20,AllocCPUs,Elapsed,MaxRSS'),
        ("detect SLURM oom_kill/OOM-Killed stderr (fix memkill classification)",
         'for i in ["memory","killed"]]):',
         'for i in ["memory","killed"]]) or any("oom" in x.lower() for x in slurm_errors):'),
    ],
    G.__file__: [
        ("escalate memory value, not duplicate the [req,max] list",
         'memory = "({})*2".format(memory) if isinstance(memory,str) else memory*2',
         'memory = "({})*2".format(memory) if isinstance(memory,str) else ([memory[0]*2]+list(memory[1:]) if isinstance(memory,(list,tuple)) else memory*2)'),
        ("escalate time value, not duplicate the [req,max] list",
         'time = "({})*2".format(time) if isinstance(time,str) else time*2',
         'time = "({})*2".format(time) if isinstance(time,str) else ([time[0]*2]+list(time[1:]) if isinstance(time,(list,tuple)) else time*2)'),
        # --- "busy Randi" transient-error resilience (grid command retry path) ---
        # BUG 4 (py2 exception): the submit-callable path catches `except StandardError`,
        #   which does not exist in Python 3 -> NameError (crash) instead of catching.
        ("py3-safe exception in submit path (StandardError is Python 2 only)",
         '            except StandardError as err:\n                error=err.output',
         '            except Exception as err:\n                error=getattr(err,"output",None) or str(err)'),
        # BUG 5 (retries once): run_grid_command_resubmit uses `if` not `while`, so it
        #   retries a timed-out command only ONCE despite timeout_retry_max=3.
        ("retry transient grid errors up to timeout_retry_max times (was a single 'if')",
         '        if timeout_error and resubmissions < self.timeout_retry_max:',
         '        while timeout_error and resubmissions < self.timeout_retry_max:'),
        # BUG 6 (narrow detection): only the exact "Socket timed out on send/recv" string
        #   triggers a retry; other scheduler-overload messages are treated as hard fails.
        ("detect more transient scheduler-overload errors for retry (busy Randi)",
         '        if error and "error" in error and "Socket timed out on send/recv operation" in error:',
         '        if error and any(_p in error.lower() for _p in ["socket timed out","connection timed out","temporarily unavailable","slurm_load_jobs error"]):'),
    ],
}

def _safe_write(path, text):
    # write via temp + atomic rename so `path` becomes a FRESH inode. conda
    # hardlinks package files from the shared pkg cache into the env; an in-place
    # open('w') would truncate the shared inode and corrupt the cache's copy too
    # (-> SafetyError on rebuild). rename breaks the hardlink, leaving the cache pristine.
    tmp = path + ".patchtmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)

for path, plist in patches.items():
    s = open(path).read()
    changed = False
    for name, OLD, NEW in plist:
        if NEW in s:
            print("  already applied:", name); continue
        n = s.count(OLD)
        if n != 1:
            sys.exit(f"ERROR: expected 1 occurrence for '{name}' in {os.path.basename(path)}, found {n} - anadama2 changed; re-inspect.")
        if not changed:  # back up the pristine original on the first real change
            bak = path + ".orig"
            if not os.path.exists(bak):
                shutil.copy2(path, bak); print("backup:", bak)
        s = s.replace(OLD, NEW); changed = True
        print("  applied:", name)
    if changed:
        _safe_write(path, s)
    print("done:", path)
print("OK - all three escalation fixes in place.")
PY
