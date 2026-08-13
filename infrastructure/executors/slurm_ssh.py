"""Run work on a scheduler reached over the network.

This is the executor a client on a laptop uses to run work on a cluster. It
knows SLURM and ssh, and nothing else. It does not know what a capability is,
which domain it came from, or what any of its arguments mean.

How a run is launched is not decided here either. The job script is rendered
from the catalog entry and the site file, by the same renderer that produces
every other surface, so this file never assembles a command line for any
particular pipeline. What it does is put that script on the far side, submit it,
and answer questions about it afterwards.

Only submission and inspection cross the network: sbatch, sacct, squeue,
scancel. The work itself runs on compute nodes, which is also what the site's
own login-node rule requires.
"""

from __future__ import annotations

import hashlib
import json
import shlex
import subprocess
import sys
import uuid
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

_TREE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_TREE / "interfaces" / "run"))
sys.path.insert(0, str(_TREE / "interfaces" / "catalog"))
sys.path.insert(0, str(_TREE / "infrastructure" / "sites"))
from protocol import Executor, JobRecord, JobSpec, JobState, Result, WriteScope
import entry as C
import profile as P

from registry import JobRegistry
import failure as _failure
import reuse as _reuse

# What the scheduler says when it has nothing to add. Reported as nothing rather
# than repeated, because "Reason: None" reads as an answer and is not one.
_NO_REASON = {"", "none", "unknown"}


def _note(reason: str) -> str:
    """The scheduler's own reason, when it has one worth saying."""
    reason = (reason or "").strip()
    return "" if reason.lower() in _NO_REASON else reason

RENDER = _TREE / "infrastructure" / "render-targets" / "render.py"

# See the note beside the same name in local.py.
_REACH_LIMIT = 5000

# What sacct and squeue call a state, and what this interface calls it. Anything
# unlisted becomes UNKNOWN rather than a guess, because a wrong terminal state
# is worse than an honest missing one.
_STATES = {
    "PENDING": JobState.SUBMITTED, "CONFIGURING": JobState.SUBMITTED,
    "RUNNING": JobState.RUNNING, "COMPLETING": JobState.RUNNING,
    "COMPLETED": JobState.COMPLETED,
    "FAILED": JobState.FAILED, "TIMEOUT": JobState.FAILED,
    "OUT_OF_MEMORY": JobState.FAILED, "NODE_FAIL": JobState.FAILED,
    "CANCELLED": JobState.CANCELLED,
}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class SlurmSshExecutor(Executor):
    name = "slurm-ssh"

    def __init__(self, *, ssh_host: str, site: str, registry: JobRegistry,
                 write_scope: WriteScope | None = None, ssh_timeout: int = 120,
                 artifact_root: str | None = None):
        self.ssh_host = ssh_host
        self.site = site
        self.registry = registry
        self.profile = P.load_profile(site)
        # Where results go on the far side. The site's own answer unless a
        # caller narrows it, which is how a deployment serving several people
        # keeps them apart on a machine whose results root the client does not
        # own. A local site is narrowed the same way, by the store it is built
        # with; this is the remote equivalent.
        self.artifact_root = artifact_root or self.profile.get("artifact_root")
        self.write_scope = write_scope
        self.ssh_timeout = ssh_timeout
        self._expanded: dict[str, str] = {}
        self._built: dict[str, bool] = {}
        self._reachable: bool | None = None
        self._datasets: list | None = None
        # Capabilities whose catalog entry has been checked against the far
        # side this session. One check each, not one per submission.
        self._agreed: set = set()

    # --- talking to the far side ------------------------------------------
    # Every one of these closes its standard input, and none of them can afford
    # not to. ssh reads its own standard input and sends it to the far side, so
    # an ssh that inherits ours quietly swallows whatever was arriving on it.
    # When this runs inside a tool server, what arrives on standard input is the
    # protocol: the first request from a client is eaten by a reachability
    # probe, the server never answers, and it looks like a hang with no error
    # anywhere. capture_output does not cover this. It redirects what comes out.
    def _ssh(self, command: str) -> str:
        proc = subprocess.run(["ssh", self.ssh_host, command],
                              stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=self.ssh_timeout)
        if proc.returncode != 0:
            raise RuntimeError(f"ssh to {self.ssh_host} failed ({proc.returncode}): "
                               f"{(proc.stderr or proc.stdout).strip()[-400:]}")
        return proc.stdout

    def _tail(self, log_path: str | None) -> str:
        """The end of a run's log, read on the machine that holds it.

        Never raises. This is called while reporting a failure, and an ssh that
        times out here would replace the reason for the failure with a complaint
        about not reading the reason.

        `tail` rather than `cat`, on the far side rather than here, so a log that
        ran to gigabytes costs its last page over the network and not all of it.
        """
        if not log_path:
            return ""
        try:
            return self._ssh(f"tail -c {_failure.TAIL_BYTES} {shlex.quote(log_path)} 2>/dev/null || true")
        except (RuntimeError, subprocess.SubprocessError, OSError):
            return ""

    def _agree(self, capability: str, contract: Path) -> None:
        """Refuse to submit when the two sides hold different catalog entries.

        The entry is the contract: it names the kernel, pins it by digest, lists
        the inputs and their flags, and is what the job script is rendered from.
        The client renders the script from its copy; the far side runs its own
        copy of the runner against its own copy of the entry. When the two
        differ, the job queues, waits, starts, and fails minutes later for a
        reason that has nothing to do with the science — which is what happened
        twice to tree_bundle after the entry changed here and not there.

        Compared by digest of the bytes, so any difference at all is caught, and
        the answer is remembered per capability because a chain submits several
        in a row and they mostly share a domain.

        An unreachable or unreadable far copy is not a refusal. This is a guard
        against the two sides disagreeing, not a second liveness check, and a
        site that cannot answer will fail the submission a moment later anyway
        with an error about the thing that was actually wrong.
        """
        if capability in self._agreed:
            return
        mine = hashlib.sha256(contract.read_bytes()).hexdigest()
        domain, cap = capability.split("/", 1)
        # Both of these reach the far side — working out the install root expands
        # the site's ${...} over there — so both are inside the same guard. With
        # only the digest read covered, an unreachable host was reported as a
        # contract disagreement, which is a confident answer to a question that
        # was never asked.
        try:
            remote = f"{self._install_root()}/domains/{domain}/catalog/{cap}.json"
            out = self._ssh(f"sha256sum {shlex.quote(remote)} 2>/dev/null "
                            f"|| shasum -a 256 {shlex.quote(remote)} 2>/dev/null "
                            f"|| echo missing").strip()
        except (RuntimeError, subprocess.SubprocessError, OSError):
            self._agreed.add(capability)
            return
        theirs = out.split()[0] if out and out != "missing" else ""
        if not theirs:
            raise RuntimeError(
                f"{self.site} has no catalog entry for {capability} at {remote}. "
                f"The installed copy there is out of date: sync the tree to "
                f"{self._install_root()} and try again.")
        if theirs != mine:
            raise RuntimeError(
                f"{capability} is not the same on both sides. This client has "
                f"{mine[:12]} and {self.site} has {theirs[:12]}. The entry names "
                f"the kernel and pins it, so submitting would run something other "
                f"than what was asked for. Sync the tree to "
                f"{self._install_root()} and try again.")
        self._agreed.add(capability)

    def available(self) -> bool:
        """Whether the far side answers, asked once and remembered.

        A machine that is down should remove its capabilities from the menu
        rather than accept work that cannot start. The timeout is short because
        this runs while a client is starting up.
        """
        if self._reachable is None:
            probe = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                 self.ssh_host, "true"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True)
            self._reachable = probe.returncode == 0
        return self._reachable

    def can_run(self, contract) -> tuple[bool, str]:
        """Whether the environment is built over there, asked over there.

        The local filesystem cannot answer this. Results are cached by path
        because capabilities in a domain share one environment, so fourteen
        entries cost two or three round trips rather than fourteen.
        """
        env = contract.get("environment") or {}
        if contract.get("executes_submitted_code") and \
                self.profile.get("submitted_code") is False:
            return False, f"{self.site} does not run code that arrives with a request"
        if env.get("images") and not self.profile.get("image_root"):
            return False, f"{self.site} has no image store, and this needs a container"

        act = env.get("activation") or {}
        if not act.get("path") or not act.get("ready_when"):
            return True, ""      # nothing declared to check, same as the local rule

        root = self._expand(self._install_root())
        domain = C.domain(contract)
        probe = f"{root}/domains/{domain}/{act['path']}/{act['ready_when']}"
        if probe not in self._built:
            out = self._ssh(f"test -e {shlex.quote(probe)} && echo yes || echo no")
            self._built[probe] = out.strip() == "yes"
        if not self._built[probe]:
            return False, (f"the environment at {act['path']} is not built on "
                           f"{self.site}. Build it there with {act.get('restore_with')}.")
        return True, ""

    def datasets(self) -> list[dict]:
        """What is on the far side, asked over there.

        The same discovery code that answers locally, run on the machine it is
        answering about. Cached for the life of this executor: a client asks
        while assembling a menu, and data does not appear and vanish between
        one question and the next.
        """
        if self._datasets is None:
            root = self.profile.get("data_root")
            if not root:
                self._datasets = []
                return self._datasets
            out = self._ssh_python(
                f"cd {shlex.quote(self._expand(self._install_root()))} && "
                f"python3 infrastructure/datasource/discover.py "
                f"--root {shlex.quote(self._expand(root))}")
            try:
                found = json.loads(out[out.index("["):])
            except (ValueError, json.JSONDecodeError):
                found = []
            self._datasets = [{**d, "site": self.site} for d in found]
        return self._datasets

    def _expand(self, value: str) -> str:
        """A site path as it reads on the far side.

        A site file writes ${USER} and ${ANALYSIS_CORE} on purpose, so that one
        file serves every account on the machine. Only the machine can say what
        those come out as, so ask it once rather than guessing here.
        """
        if "$" not in value:
            return value
        if value not in self._expanded:
            self._expanded[value] = self._ssh(f'printf %s "{value}"').strip()
        return self._expanded[value]

    def _ssh_python(self, command: str) -> str:
        """A command needing this site's interpreter, run the way the site says.

        A rendered job script loads the site's modules because the site file
        lists them. Anything this executor runs directly needs the same
        treatment, or it gets whatever interpreter the login shell happens to
        have, which on a module-based cluster is the wrong one.
        """
        preamble = "; ".join(self.profile.get("preamble") or [])
        return self._ssh((preamble + "; " if preamble else "") + command)

    def _install_root(self) -> str:
        root = self.profile.get("install_root")
        if not root:
            raise RuntimeError(f"site '{self.site}' does not say where this tree is "
                               f"installed on it. Add \"install_root\".")
        return self._expand(root)

    def _depends_on(self, after: tuple) -> str:
        """The sbatch flag that holds this job until the ones before it succeed.

        The scheduler does the waiting, so a chain can be submitted in one go
        and nothing has to stay alive to advance it. `kill-on-invalid-dep` is
        what stops a chain sitting in the queue forever after a step failed:
        without it the rest of the jobs are never runnable and never cleared,
        and each one occupies a slot while being unable to use it.

        A predecessor this executor did not submit is not one the scheduler can
        wait for, so it is refused here rather than dropped, which would run the
        step early against an input that is not there yet.
        """
        if not after:
            return ""
        ids = []
        for earlier in after:
            rec = self.registry.get(earlier)
            if rec is None or not rec.native_id:
                raise KeyError(f"cannot wait for {earlier}: this site did not run it")
            ids.append(rec.native_id)
        return f"--dependency=afterok:{':'.join(ids)} --kill-on-invalid-dep=yes "

    # --- the four operations ----------------------------------------------
    def submit(self, spec: JobSpec) -> JobRecord:
        # Already done? A run's identity is what decides what it produces,
        # so an identical one that finished is this one's answer. Checked here
        # rather than in each caller because every caller wants it and the
        # check needs the registry, which is this executor's.
        done = _reuse.finished_match(self.registry, spec)
        if done is not None:
            return done

        domain, cap = spec.capability.split("/", 1)
        # Decided here so the store over there names the run with it, leaving one
        # identifier for a caller, a directory, and anything asking about either.
        job_id = f"{cap}-{uuid.uuid4().hex[:8]}"
        # The store on the far side allocates the directory, by running the same
        # store code that is installed there. Computing the layout here instead
        # would be a second implementation of it, and the two would drift.
        if not spec.output_path:
            root = self.artifact_root
            if not root:
                raise RuntimeError(f"site '{self.site}' does not say where results live. "
                                   f"Add \"artifact_root\".")
            outdir = self._ssh_python(
                f"cd {shlex.quote(self._install_root())} && "
                f"python3 infrastructure/artifact-store/store.py --root {shlex.quote(root)} "
                f"--workspace {shlex.quote(spec.workspace)} "
                f"--run-id {shlex.quote(job_id)} "
                f"--new-run {shlex.quote(spec.capability)}").strip().splitlines()[-1]
            spec = replace(spec, output_path=outdir,
                           scratch_path=spec.scratch_path or outdir)
        if self.write_scope:
            self.write_scope.check(output_path=spec.output_path,
                                   scratch_path=spec.scratch_path)

        contract = _TREE / "domains" / domain / "catalog" / f"{cap}.json"
        if not contract.is_file():
            raise FileNotFoundError(f"no catalog entry for {spec.capability}")
        self._agree(spec.capability, contract)

        script = subprocess.run(
            [sys.executable, str(RENDER), str(contract), "--as", "slurm",
             "--profile", self.site],
            stdin=subprocess.DEVNULL,
            capture_output=True, text=True, check=True).stdout

        remote_dir = f"{self._expand(self.profile['stage_root'])}/_jobs"
        remote_script = f"{remote_dir}/{job_id}.sbatch"

        # The script is written by the same renderer everywhere, so what runs on
        # the cluster is what --as slurm shows locally, character for character.
        self._ssh(f"mkdir -p {shlex.quote(remote_dir)} && cat > {shlex.quote(remote_script)}"
                  f" <<'ANALYSIS_CORE_EOF'\n{script}\nANALYSIS_CORE_EOF")

        argv = []
        for name, path in spec.inputs.items():
            argv += [f"--{name}", str(path)]
        for name, value in (spec.parameters or {}).items():
            argv += [f"--{name}", str(value)]
        if spec.seed is not None:
            argv += ["--seed", str(spec.seed)]
        argv += ["--outdir", spec.output_path, "--profile", self.site]

        out = self._ssh(f"cd {shlex.quote(self._install_root())} && "
                        f"sbatch --parsable {self._depends_on(spec.after)}"
                        f"{shlex.quote(remote_script)} "
                        + " ".join(shlex.quote(a) for a in argv))
        native = out.strip().splitlines()[-1].split(";")[0]

        rec = JobRecord(job_id=job_id, spec=spec, executor=self.name,
                        native_id=native, state=JobState.SUBMITTED,
                        submitted_at=_now(), updated_at=_now(),
                        log_path=f"{self._install_root()}/{cap}_{native}.out")
        self.registry.put(rec)
        return rec

    def poll(self, job_id: str) -> JobRecord:
        rec = self.registry.get(job_id)
        if rec is None:
            raise KeyError(f"no run called {job_id}")
        if rec.state.terminal:
            return rec

        # State, and beside it the two things the scheduler knows that a log
        # cannot say: what it exited with, and why the scheduler itself ended it.
        # OUT_OF_MEMORY and TIMEOUT are whole answers, and a traceback printed
        # underneath one of them is a consequence rather than a cause.
        out = self._ssh(f"sacct -j {shlex.quote(rec.native_id)} "
                        f"--format=State,ExitCode,Reason --noheader --parsable2 | head -1")
        fields = (out.strip().split("|") + ["", "", ""])[:3] if out.strip() else ["", "", ""]
        raw = fields[0].strip().split()[0] if fields[0].strip() else ""
        rec.state = _STATES.get(raw.replace("+", ""), JobState.UNKNOWN)
        if rec.state is JobState.FAILED:
            # Read the log on the machine that has it. One ssh, on failure only,
            # once: the record is terminal from here and poll returns early on a
            # terminal record. Without this the whole report was the word
            # "FAILED" and a path on a cluster, and what read it next was a model
            # that could reach neither — so it guessed, repeatedly.
            rec.detail = _failure.described(
                raw, fields[1].strip(), _note(fields[2]), self._tail(rec.log_path))
        else:
            rec.detail = raw or "no scheduler record yet"
        rec.updated_at = _now()
        self.registry.put(rec)
        return rec

    def cancel(self, job_id: str) -> JobRecord:
        rec = self.registry.get(job_id)
        if rec is None:
            raise KeyError(f"no run called {job_id}")
        if not rec.state.terminal:
            self._ssh(f"scancel {shlex.quote(rec.native_id)}")
            rec.state, rec.detail = JobState.CANCELLED, "cancelled by request"
            rec.updated_at = _now()
            self.registry.put(rec)
        return rec

    def collect(self, job_id: str) -> Result:
        rec = self.poll(job_id)
        if rec.state is not JobState.COMPLETED:
            raise RuntimeError(f"{job_id} is {rec.state.value}, so there is nothing "
                               f"to collect. Poll until it is completed.")

        manifest_path = f"{rec.spec.output_path}/run_manifest.json"
        manifest = json.loads(self._ssh(f"cat {shlex.quote(manifest_path)}"))

        # What may come back is the domain's decision, recorded per output in the
        # catalog. An executor enforces it and does not interpret it.
        domain, cap = rec.spec.capability.split("/", 1)
        contract = C.load(_TREE / "domains" / domain / "catalog" / f"{cap}.json")
        stays = {o["name"] for o in contract.get("outputs", [])
                 if o.get("returnable") is False}

        outputs = {name: f"{rec.spec.output_path}/{name}"
                   for name in manifest.get("outputs", {}) if name not in stays}
        return Result(job_id=job_id, outputs=outputs, manifest_path=manifest_path)

    def read(self, job_id: str, name: str | None = None, rows: int = 20) -> list[dict]:
        """Read the result where it is, by running the store's own reader there.

        The alternative is to pull whole outputs across the network to look at
        twenty rows of one of them, which for a spot-by-gene matrix is a
        transfer measured in gigabytes to answer a question about its shape.
        """
        run = self._finished_dir(job_id)
        cmd = (f"cd {shlex.quote(self._expand(self._install_root()))} && "
               f"python3 infrastructure/artifact-store/store.py "
               f"--root {shlex.quote(self._expand(self.artifact_root or ''))} "
               f"--preview {shlex.quote(run)} --rows {int(rows)}")
        if name:
            cmd += f" --name {shlex.quote(name)}"
        found = json.loads(self._ssh_python(cmd))
        # A path over there is not somewhere the caller can look, so say where
        # it is. Anything that has to be shown comes back through fetch.
        return [{**f, "site": self.site} for f in found]

    def fetch(self, job_id: str, name: str, dest: str) -> str:
        rec = self.poll(job_id)
        if name not in self.collect(job_id).outputs:
            raise KeyError(f"{job_id} has no returnable output called {name}")
        target = Path(dest)
        target.parent.mkdir(parents=True, exist_ok=True)
        remote = f"{rec.spec.output_path}/{name}"
        # Recursive, because an output can be a directory: a viewer's bundle is
        # one, and it is exactly the kind that has to come back whole.
        proc = subprocess.run(["scp", "-q", "-r", f"{self.ssh_host}:{remote}", str(target)],
                              stdin=subprocess.DEVNULL,
                              capture_output=True, text=True,
                              timeout=max(self.ssh_timeout, 900))
        if proc.returncode != 0:
            raise RuntimeError(f"could not fetch {name} from {self.site}: "
                               f"{(proc.stderr or proc.stdout).strip()[-300:]}")
        return str(target)

    def manifest(self, job_id: str) -> dict:
        """Read over there, because that is where the run happened."""
        rec = self.registry.get(job_id)
        where = rec.spec.output_path if rec is not None else self._finished_dir(job_id)
        out = self._ssh(f"cat {shlex.quote(where)}/run_manifest.json")
        return json.loads(out)

    def runs(self, workspace: str | None = None, capability: str | None = None,
             limit: int = 50) -> list[dict]:
        """What the store over there holds, listed over there.

        Not derived from this client's registry. The machine's store is the
        record, and it holds results this client never submitted: work from an
        earlier session, and work done before any of this existed and recorded
        into it afterwards.
        """
        root = self.artifact_root
        if not root:
            return []
        cmd = (f"cd {shlex.quote(self._expand(self._install_root()))} && "
               f"python3 infrastructure/artifact-store/store.py "
               f"--root {shlex.quote(self._expand(root))} --list --limit {int(limit)}")
        if workspace:
            cmd += f" --workspace {shlex.quote(workspace)}"
        if capability:
            cmd += f" --capability {shlex.quote(capability)}"
        try:
            out = self._ssh_python(cmd)
            found = json.loads(out[out.index("["):])
        except (ValueError, RuntimeError, json.JSONDecodeError):
            return []      # one machine unreachable is not a reason to answer for none
        return [{**r, "site": r.get("site") or self.site} for r in found]


    def can_reach(self, reference: str) -> bool:
        """Whether a reference names something this machine holds.

        A study is checked against what it reported holding, a run against its
        own store. Anything that is not a reference is a path, and a path is not
        this layer's to judge.
        """
        ref = str(reference or "")
        scheme, _, rest = ref.partition(":")
        name = rest.strip("/").split("/", 1)[0]
        if scheme == "study":
            return any(d.get("study") == name for d in self.datasets())
        if scheme == "run":
            return any(r.get("run") == name for r in self.runs(limit=_REACH_LIMIT))
        return True

    def _finished_dir(self, job_id: str) -> str:
        """The store's name for a run, whether or not this client submitted it.

        A registry holds what went through it; the store holds results, and a
        run recorded there by any other route is readable too. Its directory is
        named by the run id, so the store can be asked for it directly.
        """
        if self.registry.get(job_id) is None:
            return job_id
        rec = self.poll(job_id)
        if rec.state is not JobState.COMPLETED:
            raise RuntimeError(f"{job_id} is {rec.state.value}, so there is nothing to "
                               f"read. Poll until it is completed.")
        return rec.spec.output_path.rstrip("/").rsplit("/", 1)[-1]

    def list_jobs(self) -> list[JobRecord]:
        return self.registry.all()
