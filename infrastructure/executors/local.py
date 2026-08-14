"""Run work on this machine, without blocking the caller.

The same four operations as any other executor, so nothing above has to know
which one it is talking to. A correlation on a small table finishes in seconds
and a cluster job takes hours, but a client should not have two ways of asking.

The process is detached and its exit status is written to a file rather than
waited on, because a run has to survive the process that asked for it. That is
also what makes a handle answerable after a restart, which is the whole reason
the registry is on disk.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import uuid
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

_TREE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_TREE / "interfaces" / "run"))
sys.path.insert(0, str(_TREE / "interfaces" / "catalog"))
from protocol import Executor, JobRecord, JobSpec, JobState, Result, WriteScope
import entry as C

sys.path.insert(0, str(_TREE / "infrastructure" / "artifact-store"))
sys.path.insert(0, str(_TREE / "infrastructure" / "sites"))
from store import ArtifactStore
import profile as P

from registry import JobRegistry
import failure as _failure

import reaching as _reaching

RUNNER = _TREE / "infrastructure" / "runner" / "run.py"


def _read_tail(path) -> str:
    """The end of a log file, or "" when there is nothing to read.

    Never raises. This runs while reporting a failure, and a second failure here
    would replace the reason with a stack trace about not finding the reason.
    """
    if not path:
        return ""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - _failure.TAIL_BYTES))
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""

def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class LocalExecutor(Executor):
    name = "local"
    # Nothing queues here: work starts the moment it is asked for, so a caller
    # can wait for it and usually should. "It is running in the background, come
    # back later" is a claim about a queue, and said about a subprocess on this
    # machine it is simply false — it was said about a run that failed seven
    # seconds later, and nobody found out.
    #
    # Long enough for the work this site is given, which is a table joined, a
    # cohort built, a model fitted on a few hundred rows. Past it the honest
    # answer changes from "here is your result" to "this is taking a while",
    # which is a different sentence and a true one.
    settles_in = 120.0

    def __init__(self, *, site: str = "local", registry: JobRegistry, store: ArtifactStore,
                 work_dir: str | None = None, write_scope: WriteScope | None = None):
        self.site = site
        self.store = store
        self.registry = registry
        self.write_scope = write_scope
        self.profile = P.load_profile(site)
        self.work_dir = Path(work_dir or (Path.home() / ".analysis-core" / "runs"))
        self.work_dir.mkdir(parents=True, exist_ok=True)

    def can_run(self, contract) -> tuple[bool, str]:
        """This machine's own filesystem, which is the one that will run it."""
        env = contract.get("environment") or {}
        if contract.get("executes_submitted_code") and \
                self.profile.get("submitted_code") is False:
            return False, f"{self.site} does not run code that arrives with a request"
        _, ok = C.environment_check(contract)
        if not ok:
            act = env.get("activation") or {}
            return False, (f"the environment at {act.get('path')} is not built on "
                           f"{self.site}. Build it with {act.get('restore_with')}.")
        if env.get("images") and not self.profile.get("image_root"):
            return False, f"{self.site} has no image store, and this needs a container"
        return True, ""

    def datasets(self) -> list[dict]:
        """This machine's own filesystem, which is the one the work will read."""
        sys.path.insert(0, str(_TREE / "infrastructure"))
        from datasource.discover import survey
        root = os.environ.get("DATA_ROOT") or self.profile.get("data_root") or "data"
        return [{**d, "site": self.site} for d in survey(root)]

    def _paths(self, job_id: str) -> tuple[Path, Path]:
        return self.work_dir / f"{job_id}.log", self.work_dir / f"{job_id}.status"

    def _wait_for(self, after: tuple, log: Path, status: Path) -> str:
        """Shell that holds this run until the ones before it have succeeded.

        There is no scheduler here to ask, so the wait is on the same status
        files this executor already writes, which means it survives a restart of
        whatever submitted the chain.

        A predecessor that failed ends this run rather than starting it. Running
        anyway would resolve an input against a run that produced nothing, and
        the error would name a missing output instead of the step that failed.
        """
        if not after:
            return ""
        lines = []
        for earlier in after:
            _, earlier_status = self._paths(earlier)
            lines.append(
                f"while [ ! -f '{earlier_status}' ]; do sleep 5; done; "
                f"if [ \"$(cat '{earlier_status}')\" != 0 ]; then "
                f"echo 'did not start: {earlier} failed' > '{log}'; "
                f"echo 1 > '{status}'; exit 1; fi; ")
        return "".join(lines)

    def submit(self, spec: JobSpec) -> JobRecord:
        # Deliberately no re-use here, unlike the remote executor. Re-use hands
        # back a run somebody may have started in another conversation, and the
        # rule for that is about what the work costs.
        #
        # Work on a cluster is queued, slow, and asked for on purpose, and there
        # is a bounded amount of it: a study has so many samples and a pipeline
        # so many stages. Repeating it wastes an afternoon, so it is shared.
        #
        # Work here is seconds long and unbounded — one conversation can ask for
        # fifty variations of a chart, and each one is a thing somebody wanted at
        # the time rather than a result to keep. Sharing those between
        # conversations would grow without limit and would leak one chat's
        # exploration into another's, for a saving measured in seconds.

        # The handle is decided first so the store can name the run with it. A
        # caller holding the handle can then ask the store directly, rather than
        # every reader needing to translate one id into the other.
        domain, cap = spec.capability.split("/", 1)
        job_id = f"{cap}-{uuid.uuid4().hex[:8]}"
        # The store decides where a result lives. Doing it here, before anything
        # is launched, is what makes every run findable afterwards.
        if not spec.output_path:
            outdir = self.store.new_run(spec.capability, spec.workspace, job_id)
            spec = replace(spec, output_path=str(outdir),
                           scratch_path=spec.scratch_path or str(outdir))
        if self.write_scope:
            self.write_scope.check(output_path=spec.output_path,
                                   scratch_path=spec.scratch_path)

        contract = _TREE / "domains" / domain / "catalog" / f"{cap}.json"
        if not contract.is_file():
            raise FileNotFoundError(f"no catalog entry for {spec.capability}")

        argv = [sys.executable, str(RUNNER), str(contract)]
        for name, path in spec.inputs.items():
            argv += [f"--{name}", str(path)]
        for name, value in (spec.parameters or {}).items():
            argv += [f"--{name}", str(value)]
        if spec.seed is not None:
            argv += ["--seed", str(spec.seed)]
        argv += ["--outdir", spec.output_path, "--profile", spec.site or self.site]

        log, status = self._paths(job_id)

        # The exit status goes to a file rather than being waited on, so that a
        # run outlives this process and a handle still means something after a
        # restart. setsid detaches it from our process group, which is also what
        # makes cancelling it a matter of signalling that group and nothing else.
        # shlex.quote rather than wrapping each argument in quotes by hand. An
        # argument holding a single quote closes the hand-written one and the
        # shell reads the rest as bare words: submitted code saying
        # `df[c] != 'Barcode'` arrived as `df[c] != Barcode` and died with
        # NameError on its first line. Every failure looked like the caller
        # writing bad code, which is why it survived so long. Any argument can
        # carry a quote, but code is the one that always does.
        quoted = " ".join(shlex.quote(a) for a in argv)
        started = subprocess.Popen(f"{self._wait_for(spec.after, log, status)}"
                                   f"{quoted} > {shlex.quote(str(log))} 2>&1; "
                                   f"echo $? > {shlex.quote(str(status))}",
                                   shell=True, start_new_session=True)

        # The child's own pid, which start_new_session has just made the id of
        # its process group. Recording this process's pid instead sends every
        # cancellation to the wrong group: the record is marked cancelled, the
        # caller is told it worked, and the analysis carries on running.
        rec = JobRecord(job_id=job_id, spec=spec, executor=self.name,
                        native_id=str(started.pid), state=JobState.RUNNING,
                        submitted_at=_now(), updated_at=_now(), log_path=str(log))
        self.registry.put(rec)
        return rec

    def poll(self, job_id: str) -> JobRecord:
        rec = self.registry.get(job_id)
        if rec is None:
            raise KeyError(f"no run called {job_id}")
        if rec.state.terminal:
            return rec

        _, status = self._paths(job_id)
        if status.exists():
            code = status.read_text().strip()
            rec.state = JobState.COMPLETED if code == "0" else JobState.FAILED
            # On failure, say what the log says rather than where the log is.
            # A path is only an answer to somebody holding a shell on the right
            # machine, and the thing that most often reads this is not.
            #
            # Read once: the record is terminal from here, and poll returns
            # early on a terminal record without reaching this line again.
            rec.detail = f"exit {code}" + (
                "" if code == "0" else f"\n{_failure.reason(_read_tail(rec.log_path))}".rstrip())
        else:
            rec.detail = "running"
        rec.updated_at = _now()
        self.registry.put(rec)
        return rec

    def cancel(self, job_id: str) -> JobRecord:
        rec = self.registry.get(job_id)
        if rec is None:
            raise KeyError(f"no run called {job_id}")
        if not rec.state.terminal:
            # Reported as it happened, not as it was intended. A cancellation
            # that could not reach the process has not stopped the analysis, and
            # saying otherwise leaves someone believing a machine is free when
            # it is still working.
            try:
                os.killpg(int(rec.native_id), signal.SIGTERM)
                rec.state, rec.detail = JobState.CANCELLED, "cancelled by request"
            except ProcessLookupError:
                rec.state, rec.detail = JobState.CANCELLED, "already finished"
            except (PermissionError, ValueError) as e:
                rec.detail = f"could not be stopped: {e}"
                rec.updated_at = _now()
                self.registry.put(rec)
                raise RuntimeError(f"{job_id} could not be stopped: {e}") from e
            rec.updated_at = _now()
            self.registry.put(rec)
        return rec

    def collect(self, job_id: str) -> Result:
        rec = self.poll(job_id)
        if rec.state is not JobState.COMPLETED:
            raise RuntimeError(f"{job_id} is {rec.state.value}, so there is nothing to "
                               f"collect. Poll until it is completed.")

        manifest_path = Path(rec.spec.output_path) / "run_manifest.json"
        manifest = json.loads(manifest_path.read_text())

        domain, cap = rec.spec.capability.split("/", 1)
        contract = C.load(_TREE / "domains" / domain / "catalog" / f"{cap}.json")
        stays = {o["name"] for o in contract.get("outputs", [])
                 if o.get("returnable") is False}

        outputs = {name: str(Path(rec.spec.output_path) / name)
                   for name in manifest.get("outputs", {}) if name not in stays}
        return Result(job_id=job_id, outputs=outputs, manifest_path=str(manifest_path))

    def runs(self, workspace: str | None = None, capability: str | None = None,
             limit: int = 50) -> list[dict]:
        return [{**r, "site": r.get("site") or self.site}
                for r in self.store.runs(workspace, capability, limit)]


    def can_reach(self, reference: str) -> bool:
        """Whether a reference names something this machine holds."""
        return _reaching.holds(self, reference)

    def read(self, job_id: str, name: str | None = None, rows: int = 20) -> list[dict]:
        return self.store.preview(self._name_of(job_id), name, rows)

    def _name_of(self, job_id: str) -> str:
        """The store's name for a run, whether or not this process submitted it.

        A registry holds what was submitted through it. A store holds results,
        including ones that arrived another way, and those are readable too: the
        run id is the directory name, so the store can be asked directly. Going
        through the registry first keeps the check that a submitted run has
        actually finished.
        """
        if self.registry.get(job_id) is not None:
            return self._run_dir(job_id).name
        if not self.store.find(job_id):
            raise KeyError(f"no run called {job_id}")
        return job_id

    def fetch(self, job_id: str, name: str, dest: str) -> str:
        """Already on this machine, so this is a copy rather than a transfer."""
        available = self.store.outputs(self._name_of(job_id))
        if name not in available:
            raise KeyError(f"{job_id} has no returnable output called {name}")
        target = Path(dest)
        target.parent.mkdir(parents=True, exist_ok=True)
        source = Path(available[name])
        if source.is_dir():
            shutil.copytree(source, target, dirs_exist_ok=True)
        else:
            shutil.copyfile(source, target)
        return str(target)

    def manifest(self, job_id: str) -> dict:
        found = self.store.find(self._name_of(job_id))
        if not found:
            raise KeyError(f"no run called {job_id}")
        return found[1]

    def _run_dir(self, job_id: str) -> Path:
        rec = self.poll(job_id)
        if rec.state is not JobState.COMPLETED:
            raise RuntimeError(f"{job_id} is {rec.state.value}, so there is nothing to "
                               f"read. Poll until it is completed.")
        return Path(rec.spec.output_path)

    def list_jobs(self) -> list[JobRecord]:
        return self.registry.all()
