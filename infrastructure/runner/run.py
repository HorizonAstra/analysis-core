#!/usr/bin/env python3
"""Run a capability from its contract, with named arguments.

This is the adapter. It exists because the Julia kernels read fixed filenames
out of one directory instead of taking arguments, so something has to assemble
that directory. The contract records the mapping; this script performs it.

The kernel is invoked unchanged. Nothing here decides a number.

    run.py <contract.json> --<input> <path> ... --outdir <dir> [--<param> <value>]
    run.py <contract.json> ... --dry-run       show the plan, execute nothing
    run.py <contract.json> ... --keep-stage    leave the staging tree in place
    run.py <contract.json> ... --resume        continue a partly finished run

Every run writes run_manifest.json into the output directory, recording the
contract, the kernel digests, the seed, and the inputs by content hash, so a
result can be traced back to exactly what produced it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

# The catalog reader lives with the schema it reads; profiles live with sites.
_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_ROOT / "interfaces" / "catalog"))
sys.path.insert(0, str(_ROOT / "infrastructure" / "sites"))
sys.path.insert(0, str(_ROOT / "infrastructure"))      # datasource, as a package
import entry as C
import profile as P
from datasource import refs as _refs


def _list_arg(text: str) -> list:
    """An array parameter given on a command line.

    A fan out repeats over the values of a list parameter, so a list that
    arrived as the string "[5, 50, 150]" would fan out once, over that string.
    The contract default is a real list and nothing overrode it until an
    executor started passing parameters through, which is when this would have
    become a silent single-candidate run rather than an error.
    """
    text = text.strip()
    # JSON first, because that is what a bracketed list usually is and a parser
    # gets the quoting right. Splitting on commas by hand kept the quotes as
    # part of the value: `["cefepime_exposed"]` arrived as the name
    # `'cefepime_exposed'`, MaAsLin looked for a column called that, did not
    # find one, and stopped. The failure named the column, with its quotes, and
    # still read as the caller having asked for a column that does not exist.
    if text.startswith("[") and text.endswith("]"):
        try:
            loaded = json.loads(text)
            if isinstance(loaded, list):
                return loaded
        except ValueError:
            pass          # not JSON: a bare list like [5, 50], handled below
    out = []
    for part in text.strip("[]").split(","):
        part = part.strip()
        # A value written with quotes means the text inside them, here as
        # anywhere else. Only a matching pair, so a name that genuinely contains
        # one is left alone.
        if len(part) >= 2 and part[0] == part[-1] and part[0] in "\"'":
            part = part[1:-1]
        if not part:
            continue
        out.append(int(part) if re.fullmatch(r"-?\d+", part) else
                   float(part) if re.fullmatch(r"-?\d*\.\d+", part) else part)
    return out


def _stage_by_role(src: Path, dst: Path) -> None:
    """Stage a study so its tables carry the names its domain gives them.

    A study on disk is named for whoever assembled it — `Leukemia_events.csv`,
    `Leukemia_samples.csv` — and a kernel written against those names works for
    exactly one study. The domain already recognises which file fills which
    role, so the file arrives as `events.csv` and the kernel is written once,
    against the role.

    Files the domain has no role for keep their own names and are staged
    anyway. They are real data, and a capability that was handed a whole study
    should not be the one deciding that two of its seven tables do not exist.
    """
    from datasource import domains as _domains

    dst.mkdir(parents=True, exist_ok=True)
    domain = _domains.detect_domain(str(src)) or ""
    by_role = {}
    if domain:
        try:
            by_role = {os.path.abspath(p): r
                       for r, p in (_domains.match_roles(str(src), domain) or {}).items()}
        except Exception:                       # noqa: BLE001 - name it plainly instead
            by_role = {}
    for name in sorted(os.listdir(src)):
        here = src / name
        if name.startswith("."):
            continue
        role = by_role.get(os.path.abspath(str(here)))
        target = dst / (f"{role}{here.suffix}" if role and here.is_file() else name)
        if here.is_dir():
            shutil.copytree(here, target, dirs_exist_ok=True)
        else:
            shutil.copy2(here, target)


def build_parser(contract: dict) -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog=contract["id"],
        description=contract.get("summary", contract["title"]),
    )
    for i in contract["inputs"]:
        ap.add_argument(f"--{i['name']}", required=i.get("required", True),
                        metavar="PATH", help=i.get("description", ""))
    for p in contract.get("parameters", []):
        kind = {"integer": int, "number": float, "boolean": bool,
                "array": _list_arg}.get(p["type"], str)
        ap.add_argument(f"--{p['name']}", type=kind, default=None,
                        help=p.get("description", ""))
    ap.add_argument("--outdir", required=True, metavar="DIR")
    ap.add_argument("--stage-dir", default=None,
                    help="Where to assemble the kernel's directory. Defaults to a temp tree.")
    ap.add_argument("--profile", default=os.environ.get("ANALYSIS_SITE", "local"),
                    help="Execution profile: how to launch on this host. A name "
                         "under profiles/, or a path. Reads ANALYSIS_SITE, "
                         "else local. Set it once per host; randi is the cluster target.")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--keep-stage", action="store_true")
    ap.add_argument("--resume", action="store_true",
                    help="Skip the steps a previous run already finished in this "
                         "staging tree. Requires --stage-dir, and refuses if "
                         "anything that decides the numbers has changed since.")
    ap.add_argument("--allow-unpinned", action="store_true",
                    help="Run even though the freeze check failed. The escape hatch "
                         "exists because a blocked run during development gets worked "
                         "around, and a worked-around check is one nobody reinstates. "
                         "The manifest records that it was used and what had moved, so "
                         "the result cannot later be mistaken for a verified one.")
    return ap


def content_digest(path: Path, patterns: list[str]) -> str:
    """Hash of a file with declared volatile lines removed.

    Some outputs stamp themselves with a wall clock time. That one line makes
    the file different on every run, so a byte comparison of it always fails and
    the comparison stops meaning anything, which is worse than not comparing.

    Removing those lines is only safe because the contract has to name them, one
    regular expression at a time, and the manifest records what was removed. A
    blanket rule that skipped anything looking like a date would eventually skip
    a result.
    """
    import re as _re
    rx = [_re.compile(p) for p in patterns]
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for raw in fh:
            line = raw.decode("utf-8", "replace")
            if not any(r.search(line) for r in rx):
                h.update(raw)
    return h.hexdigest()


def digest(path: Path) -> str:
    """Content hash of a file, or of a directory's entire contents.

    A directory hashes as the hash of its files' relative names and digests, so
    two directories match when every file in them matches. Some capabilities
    take a sample directory rather than a set of named files, and those need to
    be identifiable by content like anything else.
    """
    h = hashlib.sha256()
    if path.is_dir():
        for child in sorted(p for p in path.rglob("*") if p.is_file()):
            h.update(str(child.relative_to(path)).encode())
            h.update(digest(child).encode())
        return h.hexdigest()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- resume ---------------------------------------------------------------
#
# A capability with eight stages is a long run, and the failures seen so far
# have all been in the adapter rather than the kernel: a wrong image name, a
# missing project flag. Losing forty minutes of correct computation to fix a
# one line mistake is the cost this removes.
#
# Resume is only sound while the run is the same run. The identity below is
# everything that decides a number, so if any of it moved, continuing would
# silently produce a result that half belongs to each version.

STATE_FILE = "run_state.json"

# What the entry said each output is, copied into the manifest so the result can
# say it for itself.
#
# A result travels. It is computed where the data is, which for anything large
# means a cluster, and it is read somewhere else — a panel, a chat, a second
# analysis on a third machine. Everything that read one had to answer "is this a
# table, what is it called, may it leave this machine" by going and finding the
# domain's catalog entry, which put the whole of `domains/` behind the act of
# showing a file. That held only because every machine happens to carry an
# identical copy of this tree, and it made a run's own record incomplete: the
# entry can be edited afterwards, so an output could become returnable, or stop
# being one, for a run that finished last month.
#
# Recorded at the moment of the run, from the entry that actually ran, which is
# the only version of it that was ever true of this result.
DECLARED = ("type", "format", "description", "returnable")


def run_identity(contract: dict, params: dict, staged: list) -> dict:
    return {
        "capability": contract["id"],
        "contract_version": contract["version"],
        "kernel_sha256": contract["kernel"]["sha256"],
        "image_digests": contract["environment"].get("digests"),
        "pinned_env": contract["environment"].get("pinned_env"),
        "parameters": params,
        "inputs": {name: digest(src) for name, src, _ in staged},
    }


def identity_changed(before: dict, now: dict) -> list[str]:
    """Which parts of the run's identity no longer match, in words."""
    label = {
        "capability": "the capability",
        "contract_version": "the contract version",
        "kernel_sha256": "a kernel file",
        "image_digests": "a container image",
        "pinned_env": "the pinned environment",
        "parameters": "a parameter",
        "inputs": "an input file",
    }
    out = []
    for key, text in label.items():
        old, new = before.get(key), now.get(key)
        if old == new:
            continue
        if isinstance(old, dict) and isinstance(new, dict):
            for k in sorted(set(old) | set(new)):
                if old.get(k) != new.get(k):
                    out.append(f"{text} changed: {k}")
        else:
            out.append(f"{text} changed: {old!r} -> {new!r}")
    return out


def read_state(stage_root: Path) -> dict | None:
    path = stage_root / STATE_FILE
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def write_state(stage_root: Path, identity: dict, completed: list) -> None:
    (stage_root / STATE_FILE).write_text(json.dumps(
        {"identity": identity, "completed": completed,
         "updated": datetime.now(timezone.utc).isoformat()}, indent=2) + "\n")


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1].startswith("-"):
        print(__doc__)
        return 2

    # A scheduler sends both streams to one file. Left block buffered, stdout
    # arrives in a lump at exit and the failure that matters appears above the
    # plan that preceded it, which is the opposite of how it happened.
    sys.stdout.reconfigure(line_buffering=True)

    contract_path = sys.argv[1]
    contract = C.load(contract_path)
    args = build_parser(contract).parse_args(sys.argv[2:])

    if args.resume and not args.stage_dir:
        print("--resume needs --stage-dir: without it the staging tree was a "
              "temporary directory and there is nothing left to continue from.\n"
              "A failed run prints the path it left behind; pass that.",
              file=sys.stderr)
        return 2

    profile = P.load_profile(args.profile)

    # The freeze check runs before anything else. A moved kernel means the
    # result would not be comparable to previous ones. It needs the profile
    # first, because which tree the kernel files live in is a profile setting:
    # checking them against this repository when they belong to another reports
    # every one of them missing.
    lines, ok = C.kernel_check(contract, C.code_root(contract))
    if not ok and not args.dry_run and not args.allow_unpinned:
        print("\n".join(lines))
        print("\nRefusing to run: the scientific surface is not fully pinned, "
              "or something that decides the numbers has moved.\n"
              "  --dry-run          inspect the plan anyway\n"
              "  render.py <c> --repin   accept the change and record the new digests\n"
              "  --allow-unpinned   run regardless; the manifest will say so",
              file=sys.stderr)
        return 1

    # An environment that has not been restored here is not a pinning failure,
    # so it is reported on its own terms and with the command that fixes it.
    env_lines, env_ok = C.environment_check(contract, C.code_root(contract))
    if not env_ok and not args.dry_run:
        print("\n".join(env_lines), file=sys.stderr)
        return 1

    # A site may name the hosts that exist to submit work rather than do it.
    # Checking here means the rule holds for every domain, instead of holding
    # only where a particular pipeline remembered to write the check itself.
    if not args.dry_run and profile.get("login_nodes"):
        import fnmatch, socket
        host = socket.gethostname().split(".")[0]
        if (any(fnmatch.fnmatch(host, pat) for pat in profile["login_nodes"])
                and os.environ.get("ANALYSIS_ALLOW_LOGIN_NODE") != "1"):
            print(f"{host} is a login node of site '{profile['id']}'. Submit the work "
                  f"instead, or request an allocation first.\n"
                  f"  ANALYSIS_ALLOW_LOGIN_NODE=1   run here anyway",
                  file=sys.stderr)
            return 1

    params = C.param_values(contract, vars(args))
    outdir = Path(args.outdir).resolve()

    # A profile may dictate where staging lives. On hosts where the default
    # temp directory is mounted noexec, as it is on randi, staging under it
    # would fail at the point a container tries to run.
    if args.stage_dir:
        stage_root = Path(args.stage_dir).resolve()
    elif profile.get("stage_root"):
        base = Path(os.path.expandvars(profile["stage_root"]))
        if args.dry_run:
            stage_root = base / f"{contract['id']}_XXXX"
        else:
            if not base.exists():
                raise SystemExit(
                    f"profile '{profile['id']}' stages under {base}, which does not "
                    f"exist on this host. Either you are not on {profile['id']}, or "
                    f"the directory needs creating.")
            stage_root = Path(tempfile.mkdtemp(prefix=f"{contract['id']}_", dir=base))
    elif args.dry_run:
        stage_root = Path(tempfile.gettempdir()) / f"{contract['id']}_XXXX"
    else:
        stage_root = Path(tempfile.mkdtemp(prefix=f"{contract['id']}_"))
    roots = C.layout(stage_root)

    def ref(p):
        """One parameter's text, as it goes into a shell command line.

        A template is a shell string rather than an argv list, which two kinds
        of value survive badly. A list rendered with str() arrives as a Python
        repr — brackets, quotes and all — and the kernel receives that verbatim.
        An empty string disappears entirely, so the next flag becomes the value
        of this one and the failure lands several arguments away from its cause.
        A value containing a space becomes two words, which fails the same way.
        None of these showed up while every parameter was a scalar without
        spaces, which is what every parameter was until a chart took a title.
        """
        v = params.get(p["name"], "")
        s = ",".join(str(x) for x in v) if isinstance(v, (list, tuple)) else str(v)
        return shlex.quote(s) if s != "" else "''"

    # --- plan -------------------------------------------------------------
    staging, missing = [], []
    # Inputs the contract asks to be linked rather than copied. A cohort
    # directory is the case: copying it would move more bytes than the analysis
    # reads. The source then sits outside the staging tree, so the container
    # needs it bound or the link resolves to nothing inside.
    linked: list = []
    # What each input was named as, kept beside what it resolved to. Only when it
    # was a reference: a literal path is already the path, and an inline text
    # input is its own content, which does not belong in a provenance record.
    asked: dict = {}
    for i in contract["inputs"]:
        supplied = getattr(args, i["name"], None)
        if supplied is None:
            continue
        if _refs.looks_like_reference(supplied):
            asked[i["name"]] = str(supplied)
        if i.get("type") == "text":
            # The value is the content rather than a path to it. Writing it out
            # here and then treating it as any other file is what makes the rest
            # of this hold: it is digested into the run's identity, staged the
            # same way, and recorded in the manifest, so a result carries the
            # exact text that produced it.
            inline = stage_root / "_inline" / i["name"]
            inline.parent.mkdir(parents=True, exist_ok=True)
            inline.write_text(supplied if isinstance(supplied, str) else str(supplied))
            supplied = inline
        # A reference says what the data is; this machine says where. Resolved
        # here rather than by whoever asked, because for a cluster job this is
        # already running on the cluster, so the reference travels unchanged and
        # nothing in between has to know one machine's layout from another's.
        # A plain path resolves to itself, so a person at a terminal is unaffected.
        # One precedence rule, the same one the store uses: what the environment
        # says, then what the site says. A deployment giving each person their
        # own results root sets it in the environment, and a reference has to
        # resolve against that root rather than against the site's shared one.
        try:
            src = _refs.resolve(
                supplied,
                data_root=os.environ.get("DATA_ROOT") or profile.get("data_root"),
                results_root=(os.environ.get("ANALYSIS_RESULTS")
                              or profile.get("artifact_root")),
                references=profile.get("references"))
        except Exception as e:                              # noqa: BLE001
            missing.append(f"--{i['name']}: {e}")
            continue
        if not src.exists():
            missing.append(f"--{i['name']}: {src}")
        elif i.get("stage_mode") == "link":
            linked.append(src)
        staging.append((i["name"], src,
                        Path(C.resolve(i["staged_as"], contract, roots, ref))))

    collect = [(o["name"], Path(C.resolve(o["staged_as"], contract, roots, ref)))
               for o in contract["outputs"]]

    env_extra = {k: v.replace("{stage_root}", str(stage_root))
                 for k, v in (contract["environment"].get("pinned_env") or {}).items()}
    for k, v in (profile.get("env") or {}).items():
        env_extra.setdefault(k, os.path.expandvars(v))
    for p in contract.get("parameters", []):
        if p.get("env_var") and params.get(p["name"]) is not None:
            env_extra[p["env_var"]] = str(params[p["name"]])

    # How a seed reaches the kernel differs by language. The Julia kernels read
    # an environment variable. An R script has no such hook, but R sources a
    # user profile before it runs anything, so a profile holding set.seed() puts
    # the interpreter in a known state before the script's first draw. Both are
    # wrapper mechanisms: neither edits a kernel.
    det = contract["determinism"]
    seed_env = det.get("seed_env")
    mechanism = det.get("seed_mechanism", "env")
    seed_value = params.get("seed")

    r_profile = None
    if mechanism == "r_profile" and seed_value is not None:
        r_profile = stage_root / "Rprofile"
        env_extra[seed_env or "R_PROFILE_USER"] = str(r_profile)

    unseeded = (det["consumes_rng"] and seed_env and seed_env not in env_extra)

    # Where the code being run lives. A contract's entrypoint is a repo relative
    # path, and this used to be derived from where run.py itself sits, which
    # quietly asserted that the runner and the kernels ship together. They do
    # not have to: the profile already names a code root because the Nextflow
    # render needed one, and honouring it here is what lets this runner execute
    # a capability belonging to some other repository.
    code_root = C.code_root(contract)

    # Where the code IS and where the process RUNS are two different questions,
    # and only the second one moves. Some environments are entered by running
    # from inside them rather than by being launched into: an renv project
    # activates through the .Rprofile in its own directory, and poetry and conda
    # have the same shape. A container is the other kind and the profile's
    # launcher handles it. Kernel paths stay relative to the code root either
    # way, so the freeze check and the entrypoint keep resolving against the
    # repository rather than against wherever the interpreter happened to start.
    act = contract["environment"].get("activation") or {}
    exec_cwd = code_root
    prelude = ""
    if act.get("kind") == "conda_prefix" and act.get("path"):
        # A conda environment is entered rather than launched into or sat in.
        # The domain says which environment; where conda itself is installed is
        # a property of the machine, so the site answers that and no capability
        # ever names a path on any host.
        base = profile.get("conda_base")
        if not base:
            print(f"capability needs a conda environment, but site "
                  f"'{profile['id']}' does not say where conda is installed.\n"
                  f"  add \"conda_base\" to the site file",
                  file=sys.stderr)
            return 1
        prefix = (code_root / act["path"]).resolve()
        prelude = (f"source {os.path.expandvars(base)}/etc/profile.d/conda.sh && "
                   f"conda activate {prefix} && ")
    if act.get("kind") == "venv" and act.get("path"):
        # A virtual environment is entered by putting its bin directory first on
        # PATH. Nothing else changes, which is why this is a line rather than a
        # mechanism, and why the capability still says only which environment it
        # needs rather than where any interpreter lives.
        venv_bin = (code_root / act["path"] / "bin").resolve()
        env_extra["PATH"] = f"{venv_bin}{os.pathsep}{os.environ.get('PATH', '')}"
    if act.get("kind") == "working_directory" and act.get("path"):
        exec_cwd = (code_root / act["path"]).resolve()
        # The entrypoint is written relative to the code root like every other
        # kernel path. Once the process starts somewhere else that path no longer
        # resolves, and making the contract spell out ../.. to climb back would
        # encode the depth of the activation directory into the capability.
        entry = contract["kernel"].get("entrypoint")
        if entry and not Path(entry).is_absolute():
            contract["kernel"]["entrypoint"] = str((code_root / entry).resolve())

    # Each entry is (stage, [(label, command), ...]). A fan out stage expands
    # into one command per value, each with its own working directory.
    subs = {"stage_root": str(stage_root), "repo": str(code_root),
            "env_file": str(stage_root / "env")}

    def wrapped(stage, cmd):
        return C.wrap(cmd, C.stage_image(stage, contract), profile, subs, linked)

    # Available to every stage, fan out or not: a stage that runs once may still
    # need to know how many iterations preceded it.
    base = {"fan_out_count": C.fan_out_count(contract, params)}

    # Not every kernel takes its seed the same way. Some read an environment
    # variable; others take it as an argument. A stage declares what it needs
    # through {when_seeded}, which expands only when a seed was actually
    # supplied, so an unseeded run is byte for byte the command it always was.
    # The fragment is itself a template, so it can carry {seed}: expand it here
    # rather than leaving a placeholder for the outer format to miss.
    seeded = seed_value is not None

    plan = []
    for s in C.stages(contract):
        fragment = s.get("when_seeded", "").format(seed=seed_value) if seeded else ""
        base = {**base, "when_seeded": fragment}
        values = C.fan_out_values(s, params)
        if values:
            steps = []
            for idx, val in enumerate(values, 1):
                loop = {**base, "run": idx, "item": val,
                        "run_dir": C.run_dir(roots, idx)}
                steps.append((f"{s['fan_out_over']}={val}",
                              wrapped(s, C.stage_command(s, contract, roots, ref, loop))))
        else:
            steps = [("", wrapped(s, C.stage_command(s, contract, roots, ref, base)))]
        plan.append((s, steps))

    # --- report -----------------------------------------------------------
    print(f"capability : {contract['id']} {contract['version']}")
    print(f"kernel     : {len(contract['kernel']['sha256'])} file(s) "
          + ("verified unchanged" if ok else "NOT FULLY PINNED, see below"))
    print(f"profile    : {profile['id']}"
          + ("  (no container; interpreters must be on PATH)"
             if not profile.get("launcher") else
             f"  images from {profile.get('image_root')}"))
    print(f"stage      : {stage_root}")
    print(f"outdir     : {outdir}")
    if params:
        print("parameters : " + ", ".join(f"{k}={v}" for k, v in params.items()))
    print("\nstaging:")
    for name, src, dst in staging:
        print(f"  {name:<18} {src}")
        print(f"  {'':<18}   -> {dst}")
    print("\nenvironment:")
    for k, v in env_extra.items():
        print(f"  {k}={v}")
    total = sum(len(steps) for _, steps in plan)
    if len(plan) > 1:
        print(f"\nstages ({len(plan)} stages, {total} invocations, run in order):")
        for n, (s, steps) in enumerate(plan, 1):
            tags = []
            if len(steps) > 1:
                tags.append(f"x{len(steps)} over {s['fan_out_over']}")
            if s.get("consumes_rng"):
                tags.append("draws RNG")
            tag = f"   [{', '.join(tags)}]" if tags else ""
            print(f"  {n}. {s['id']}{tag}")
            print(f"     {steps[0][1]}")
            if len(steps) > 1:
                print(f"     ... and {len(steps) - 1} more")
    else:
        print(f"\ncommand:\n  {plan[0][1][0][1]}")
    print("\ncollect:")
    for name, path in collect:
        print(f"  {path}  ->  {outdir / name}")

    if unseeded:
        print(f"\nWARNING: {contract['id']} draws from the RNG and no seed was given.")
        print(f"         This run will not reproduce. Pass --seed to make it comparable.")

    # Checked here rather than at the point of failure, because on a cluster
    # the point of failure is after the queue wait and after every stage that
    # came before it.
    hole_lines, holes_ok = C.placeholder_check(contract)
    call_lines, call_ok = C.arity_check(contract)
    path_lines, paths_ok = C.staging_check(contract)
    wire_lines, wire_ok = C.wiring_check(contract)
    path_lines += wire_lines
    paths_ok = paths_ok and wire_ok
    if not (call_ok and holes_ok and paths_ok):
        print("\ncalling convention:", file=sys.stderr)
        for line in hole_lines + call_lines + path_lines:
            if line.strip().startswith(("WRONG", "UNRESOLVED", "UNROOTED")):
                print(line, file=sys.stderr)
        print("\nRefusing to run: a stage would not reach its kernel correctly, "
              "and would fail once it got there.", file=sys.stderr)
        return 1

    # A kernel that derives a per-task seed from task indices has a capacity: the
    # strides between index terms bound how many tasks can be numbered before two
    # of them land on the same seed. Past that the run still succeeds and still
    # looks reproducible, and two replicates counted as independent draw identical
    # noise, so this refuses rather than warns. Only seeded runs are affected —
    # unseeded, the kernel never computes a derived seed at all.
    if seeded:
        over = [(s, s["seed_capacity"]) for s in C.stages(contract)
                if s.get("seed_capacity")
                and base["fan_out_count"] > s["seed_capacity"]["fan_out"]]
        if over:
            print("\nseed capacity:", file=sys.stderr)
            for s, cap in over:
                print(f"  {s['id']}: {base['fan_out_count']} values over "
                      f"{s['fan_out_over']}, but its derived seed is distinct for at "
                      f"most {cap['fan_out']}", file=sys.stderr)
                print(f"    {cap['because']}", file=sys.stderr)
            print("\nRefusing to run: this would produce colliding seeds, and the run "
                  "would not report it.", file=sys.stderr)
            return 1

    if missing:
        print("\nMissing inputs:", file=sys.stderr)
        for m in missing:
            print(f"  {m}", file=sys.stderr)
        return 1

    # Only reached on a dry run or under --allow-unpinned; the refusal above
    # returns before this in every other case. Stated rather than implied,
    # because a message saying a run cannot proceed, printed immediately before
    # one proceeds, is how a check stops being believed.
    if not ok:
        print("\nfreeze check:")
        print("\n".join(lines))
        print("Not pinned. This run is proceeding only because "
              + ("it is a dry run." if args.dry_run else "--allow-unpinned was given, "
                 "and its manifest will record that."))

    if args.dry_run:
        print("\ndry run: nothing executed")
        return 0

    # --- execute ----------------------------------------------------------
    stage_root.mkdir(parents=True, exist_ok=True)

    identity = run_identity(contract, params, staging)
    completed: list = []
    if args.resume:
        prior = read_state(stage_root)
        if prior is None:
            print(f"nothing to resume: no {STATE_FILE} under {stage_root}",
                  file=sys.stderr)
            return 1
        drift = identity_changed(prior["identity"], identity)
        if drift:
            print("Refusing to resume. This is no longer the same run:",
                  file=sys.stderr)
            for line in drift:
                print(f"  {line}", file=sys.stderr)
            print("\nContinuing would blend two versions of the computation into "
                  "one result. Start a fresh run instead.", file=sys.stderr)
            return 1
        completed = [list(x) for x in prior["completed"]]
        print(f"\nresuming: {len(completed)} step(s) already finished, "
              f"identity unchanged")

    for _, _, dst in staging:
        dst.parent.mkdir(parents=True, exist_ok=True)
    for _, path in collect:
        path.parent.mkdir(parents=True, exist_ok=True)
    for name, src, dst in staging:
        # On a resume the staged copy is already known to match, because the
        # input digest is part of the identity that was just checked.
        if args.resume and dst.exists():
            continue
        declared = next((i for i in contract["inputs"] if i["name"] == name), {})
        mode = declared.get("stage_mode", "copy")
        if declared.get("by_role") and src.is_dir():
            _stage_by_role(src, dst)
            continue
        if mode == "link":
            # The staged path becomes a link to the real thing. Nothing is
            # copied and nothing is written through it: every capability that
            # asks for this reads its input and writes elsewhere.
            if dst.is_symlink() or dst.exists():
                dst.unlink() if dst.is_symlink() else shutil.rmtree(dst)
            dst.symlink_to(src, target_is_directory=src.is_dir())
        elif src.is_dir():
            # A directory input is the whole staged directory. Copying rather
            # than linking keeps the staging tree self contained, so a container
            # only ever needs the one bind it already has.
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst)

    # A container gets the pinned variables through a file rather than the
    # ambient environment, so what the kernel sees does not depend on the shell
    # that launched it.
    Path(subs["env_file"]).write_text(
        "".join(f"{k}={v}\n" for k, v in env_extra.items()))

    if r_profile is not None:
        # R sources this before the script, so every draw the script makes,
        # including the ones it uses to pick its own internal seeds, follows
        # from here.
        r_profile.write_text(
            f"# written by contracts/bin/run.py; not part of the pipeline\n"
            f"set.seed({int(seed_value)})\n")

    for line in profile.get("preamble", []):
        subprocess.run(line, shell=True, cwd=exec_cwd, check=False)

    # What the machine permits, in names that mention no machine and no science.
    # A kernel that submits its own work, as a meta-scheduler does, needs the
    # queue and the size of an allocation; asking it to source a site file is
    # how one pipeline ends up carrying a description of one cluster.
    ex = profile.get("executor") or {}
    site_env = {k: str(v) for k, v in (
        ("ANALYSIS_SITE", profile["id"]),
        ("ANALYSIS_QUEUE", ex.get("partition")),
        ("ANALYSIS_ACCOUNT", ex.get("account")),
        ("ANALYSIS_SCRATCH", os.path.expandvars(str(ex.get("scratch") or ""))),
        ("ANALYSIS_MAX_CONCURRENT", ex.get("queue_size")),
    ) if v not in (None, "")}
    for name, root in (profile.get("reference_roots") or {}).items():
        site_env["ANALYSIS_REF_" + name.upper()] = os.path.expandvars(str(root))
    klass = (profile.get("resource_classes") or {}).get(contract["resources"]["bound_by"]) or {}
    if klass.get("cpus"):
        site_env["ANALYSIS_CORES"] = str(klass["cpus"])
    if klass.get("memory"):
        site_env["ANALYSIS_MEMORY"] = str(klass["memory"])

    env = {**os.environ, **site_env, **env_extra}

    # A site may need entries removed from a variable it inherits, not just
    # values set. Randi's default library path shadows the java inside any conda
    # environment, and no capability should have to know that.
    for var, drop in (profile.get("env_strip") or {}).items():
        if env.get(var):
            kept = [x for x in env[var].split(os.pathsep) if x and x not in drop]
            env[var] = os.pathsep.join(kept)
    started = datetime.now(timezone.utc)

    # A fan out stage is repeated serially here. Where the kernel derives its
    # seed from the task index, as tree_build does, serial and parallel give
    # identical results, so parallelism is a throughput decision for whichever
    # runner is driving rather than a property of the capability.
    # A step is identified by what it ran, not just by its name. Fixing the
    # command of a stage that has not run yet is the whole point of resuming;
    # changing one that already ran is a different computation wearing the same
    # label, and the outputs downstream of it would be attributed to the wrong
    # command. Only the second is refused.
    done = {(sid, label): cmd_sha for sid, label, cmd_sha in completed}

    skipped = 0
    for s, steps in plan:
        for label, cmd in steps:
            cmd_sha = hashlib.sha256(cmd.encode()).hexdigest()
            step = [s["id"], label, cmd_sha]
            previous = done.get((s["id"], label))
            if previous == cmd_sha:
                skipped += 1
                continue
            if previous is not None:
                print(f"\nRefusing to resume: step '{s['id']}"
                      + (f" [{label}]" if label else "") + "' already ran, but "
                      "its command has changed since.", file=sys.stderr)
                print(f"  it ran   {previous[:12]}", file=sys.stderr)
                print(f"  now says {cmd_sha[:12]}", file=sys.stderr)
                print("\nIts output is already on disk and everything after it "
                      "was derived from the old command. Start a fresh run.",
                      file=sys.stderr)
                return 1
            if len(plan) > 1:
                print(f"\n--- {s['id']}" + (f" [{label}]" if label else ""))
            proc = subprocess.run(prelude + cmd, shell=True, cwd=exec_cwd, env=env)
            if proc.returncode != 0:
                # Everything finished up to here is recorded, so the fix can be
                # made and the run continued rather than restarted.
                write_state(stage_root, identity, completed)
                print(f"\nstage '{s['id']}' exited {proc.returncode}; "
                      f"staging left at {stage_root}", file=sys.stderr)
                print(f"\n{len(completed)} step(s) completed before this. "
                      f"Once the cause is fixed, continue with:\n"
                      f"  --stage-dir {stage_root} --resume", file=sys.stderr)
                return proc.returncode
            completed.append(step)
            write_state(stage_root, identity, completed)

    if skipped:
        print(f"\nskipped {skipped} step(s) carried over from the earlier run")

    finished = datetime.now(timezone.utc)

    outdir.mkdir(parents=True, exist_ok=True)
    optional = {o["name"] for o in contract["outputs"]
                if not o.get("required", True)}
    volatile = {o["name"]: o["volatile"] for o in contract["outputs"]
                if o.get("volatile")}
    produced = {}
    for name, path in collect:
        if path.exists():
            # An output can be a whole directory, which the format has always
            # allowed and `digest` has always hashed. A capability whose result
            # is a set of files in a fixed layout, rather than one file, has
            # nothing else to hand back.
            if path.is_dir():
                shutil.copytree(path, outdir / name, dirs_exist_ok=True)
            else:
                shutil.copy2(path, outdir / name)
            produced[name] = (content_digest(outdir / name, volatile[name])
                              if name in volatile else digest(outdir / name))
        elif name in optional:
            # Some outputs exist only under a parameter setting. Saying so is
            # different from failing to produce something that was promised.
            print(f"note: optional output '{name}' was not produced; the "
                  f"parameters did not ask for it")
        else:
            print(f"WARNING: declared output '{name}' was not produced at {path}",
                  file=sys.stderr)

    manifest = {
        "capability": contract["id"],
        "contract_version": contract["version"],
        "kernel_sha256": contract["kernel"]["sha256"],
        "third_party": contract["kernel"].get("third_party", []),
        "parameters": params,
        "profile": profile["id"],
        "images": contract["environment"].get("images"),
        "image_digests": contract["environment"].get("digests"),
        "reproducible": not unseeded,
        # What identified the code that ran, and whether it checked out. A run
        # made with --allow-unpinned is still a real result and still worth
        # keeping; what it must never do is look like a verified one later.
        "anchored_by": C.anchors(contract),
        "freeze_check": "passed" if ok else "FAILED, overridden with --allow-unpinned",
        "started": started.isoformat(),
        "finished": finished.isoformat(),
        # A resumed run is not one continuous execution. The elapsed time above
        # covers only this invocation, and the skipped steps ran earlier under
        # an identity that was checked to be identical.
        "resumed_steps": skipped,
        # What was asked for as well as what it turned out to be. A path is one
        # machine's answer to a reference and cannot be turned back into it: it
        # cannot say which study, which version, or which earlier run, so
        # anything reading a finished run had to guess those from directory
        # names. Recording the reference costs a string and settles it.
        "inputs": {name: ({"ref": asked[name]} if name in asked else {})
                   | {"path": str(src), "sha256": digest(src)}
                   for name, src, _ in staging},
        "outputs": produced,
        # What each of those is, in the entry's own words. Every declared output
        # and not only the produced ones: an optional output that this run's
        # parameters did not ask for is still part of what this capability
        # offers, and a reader that sees the name elsewhere can say what it
        # would have been.
        "declared_outputs": {o["name"]: {k: o[k] for k in DECLARED if k in o}
                             for o in contract["outputs"]},
        # Which output digests were taken over a filtered file, and what was
        # filtered out. Without this the digests above would be unexplainable.
        "volatile_outputs": volatile,
    }
    (outdir / "run_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    if not args.keep_stage and not args.stage_dir:
        shutil.rmtree(stage_root, ignore_errors=True)

    print(f"\ndone in {(finished - started).total_seconds():.1f}s"
          f" -> {outdir}  ({len(produced)} output(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
