"""Make a remote site ready to run work, without anybody doing it by hand.

`install.py` turns a fresh clone into a working installation on the machine it
runs on. Nothing did the same for a machine reached over ssh, so getting the
cluster ready meant somebody copying a tree there, remembering to build the
environments, and remembering again after every change. A project that needs a
person to set it up by hand is not finished, however good the parts are, and the
gap showed: `install.py` printed a warning saying a remote site "needs a copy of
this tree there" and stopped, which is a note rather than an installation.

    ./setup.sh --site randi        put the code there and build it
    ./setup.sh --site randi --dry-run   say what it would do, touch nothing

What it does, in order:

    clone the repository there, or fetch and fast forward what is already there
    check out the branch this client is on
    run that copy's own ./setup.sh, under the site's module preamble

Three things it refuses to do rather than doing them cleverly.

It will not convert a directory that is not a checkout. `install_root` holding a
copy somebody made by hand is the situation this replaces, and turning it into a
checkout means deciding what to do with whatever is in it. It says what it found
and stops.

It will not fast forward over local edits on the far side. Somebody editing the
cluster copy directly is doing something this cannot see the reason for, and
discarding it silently is the one unrecoverable move available here.

It will not merge. `--ff-only`, so the far copy is either exactly a commit that
exists here or the run fails saying it is not.

The site profile already carries everything this needs, so nothing is written
down twice: `install_root` says where the tree goes, `preamble` says which
modules a shell there must load before python exists, and the ssh host is
resolved the way `reachable` resolves it, because two answers to "which machine
is randi" is how a client and an installer end up talking to different hosts.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(TREE / "infrastructure" / "sites"))

import profile as P                                             # noqa: E402

OK, MISS, WARN = "  ok  ", " todo ", " note "


def say(mark: str, line: str) -> None:
    print(f"{mark}  {line}", flush=True)


def ssh_host(site: str) -> str:
    """Which host this site is, answered the way the executor answers it.

    `reachable._build` reads ANALYSIS_SSH_<SITE> and falls back to the site's
    own name. Copying that rule rather than importing it would be a second
    answer to the same question, so this is the same two lines and no more; the
    executor cannot be imported here without dragging a registry and a store
    into an installer that needs neither.
    """
    return os.environ.get(f"ANALYSIS_SSH_{site.upper().replace('-', '_')}", site)


def here_now() -> tuple[str, str]:
    """The repository this client came from, and the branch it is on."""
    def git(*args: str) -> str:
        done = subprocess.run(["git", "-C", str(TREE), *args],
                              capture_output=True, text=True)
        return done.stdout.strip() if done.returncode == 0 else ""
    return git("remote", "get-url", "origin"), git("rev-parse", "--abbrev-ref", "HEAD")


class Remote:
    """Commands on the far side, with the site's modules loaded first."""

    def __init__(self, host: str, preamble: list, dry_run: bool = False):
        self.host, self.dry_run = host, dry_run
        self.preamble = "; ".join(preamble) if preamble else ""
        self._expanded: dict = {}

    def _ssh(self, command: str, modules: bool,
             merge: bool = True) -> tuple[int, str]:
        full = (self.preamble + "; " + command) if (modules and self.preamble) else command
        done = subprocess.run(["ssh", "-T", self.host, full], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True)
        out = (done.stdout or "")
        # A failure wants everything; an answer wants only what was asked for.
        # This host prints a nine line acceptable-use banner on every login, and
        # it arrives on standard error, so a question that read both came back
        # with the install path followed by the university's legal notice, and
        # then compared that string against a directory name.
        if merge:
            out += (done.stderr or "")
        return done.returncode, out.strip()

    def run(self, command: str, *, modules: bool = False) -> tuple[int, str]:
        """Something that changes the far side. Suppressed by a dry run."""
        if self.dry_run:
            print(f"         would run: {command}")
            return 0, ""
        return self._ssh(command, modules)

    def ask(self, command: str) -> str:
        """A question. Runs even under a dry run, because it changes nothing.

        The first version skipped these too, and the dry run then reported a
        path with `${ANALYSIS_CORE:-...}` still in it, said it would clone into
        that, and never noticed that the directory already existed or that
        somebody had edited it. A dry run whose answers are all empty strings
        describes a machine nobody has looked at, which is worse than not
        offering one: it is a plan made against imaginary facts.
        """
        return self._ssh(command, False, merge=False)[1]

    def expand(self, value: str) -> str:
        """One of the site's paths as it reads over there, asked once each.

        A profile writes ${USER} and ${ANALYSIS_CORE} on purpose so one file
        serves every account on the machine, and only the machine can say what
        those come out as. Every path taken from a profile has to come through
        here: `install_root` did and `stage_root` did not, so the build was
        told to write its log to a directory with a literal ${USER} in the
        name, which is not a place, and the submission failed before the
        scheduler ever saw it.
        """
        if "$" not in value:
            return value
        if value not in self._expanded:
            self._expanded[value] = self.ask(f'printf %s "{value}"') or value
        return self._expanded[value]

    def root(self, install_root: str) -> str:
        """Where this tree is installed over there."""
        return self.expand(install_root)


def place(remote: Remote, root: str, origin: str, branch: str) -> bool:
    """Get the far copy to this branch, or say why it cannot be."""
    quoted = shlex.quote(root)
    state = remote.ask(f"if [ ! -e {quoted} ]; then echo absent; "
                       f"elif [ -d {quoted}/.git ]; then echo checkout; "
                       f"else echo occupied; fi") or "absent"

    if state == "occupied":
        say(MISS, f"{root} exists and is not a git checkout.")
        say(WARN, "That is a copy somebody placed by hand, which is what this "
                  "replaces. Move it aside and run this again; nothing here will "
                  "delete it for you.")
        return False

    if state == "absent":
        if not origin:
            say(MISS, "this tree has no origin remote, so there is nothing to clone from")
            return False
        say(WARN, f"cloning {origin} into {root}")
        code, out = remote.run(f"git clone {shlex.quote(origin)} {quoted}", modules=True)
        if code != 0:
            say(MISS, f"clone failed: {out[-400:]}")
            say(WARN, "The far side needs its own access to that repository. An "
                      "agent forwarding a key is a person doing it by hand again.")
            return False
        say(OK, "cloned")

    # Whether a file is executable is not something every filesystem stores.
    # This lab share carries default ACLs that drop the bit as git writes the
    # file, so a clone that has just been made reports every script in the tree
    # as modified, and the next step then refuses to touch a checkout that
    # nobody has edited. Told not to watch the bit, git agrees the tree is
    # clean, and the scripts are invoked through their interpreter anyway.
    # Set on every pass rather than only after a clone: a copy placed before
    # this existed will not have it either.
    remote.run(f"git -C {quoted} config core.fileMode false")

    dirty = remote.ask(f"git -C {quoted} status --porcelain 2>/dev/null | head -5")
    if dirty:
        say(MISS, f"{root} has uncommitted changes, so it will not be moved:")
        for line in dirty.splitlines():
            print(f"           {line}")
        return False

    code, out = remote.run(
        f"git -C {quoted} fetch --quiet origin && "
        f"git -C {quoted} checkout --quiet {shlex.quote(branch)} && "
        f"git -C {quoted} merge --ff-only --quiet origin/{shlex.quote(branch)}",
        modules=True)
    if code != 0:
        say(MISS, f"could not put {root} on {branch}: {out[-400:]}")
        return False

    at = remote.ask(f"git -C {quoted} rev-parse --short HEAD")
    say(OK, f"{root} is on {branch}" + (f" at {at}" if at else ""))
    return True


def build(remote: Remote, root: str, profile: dict | None = None) -> bool:
    """Run the far copy's own setup, so one script decides what an install is.

    On a machine with a scheduler the setup is submitted rather than run where
    the ssh landed. Building an installation is minutes of pip and conda, and a
    login node is shared by everyone on the cluster and exists to submit work
    rather than to do it — the same rule the runner already enforces for a
    capability, applied to the one piece of work that was still exempt from it.
    The job carries the site's own preamble, because a compute node starts with
    nothing loaded and the setup needs a python newer than the system one, and
    it calls the setup through bash rather than running it: the same default
    ACLs that make a fresh clone look modified also drop the executable bit, so
    the script is there and refuses to start.
    """
    where = shlex.quote(root)
    scheduler = ((profile or {}).get("executor") or {})
    if scheduler.get("scheduler") != "slurm":
        say(WARN, "building environments there; this takes a while the first time")
        code, out = remote.run(f"cd {where} && bash ./setup.sh", modules=True)
    else:
        say(WARN, "submitting the build to the scheduler; login nodes are for "
                  "submitting, not for building")
        inner = "; ".join((remote.preamble.split("; ") if remote.preamble else [])
                          + [f"cd {where}", "bash ./setup.sh"])
        scratch = remote.expand((profile or {}).get("stage_root") or "/tmp")
        base = f"{scratch.rstrip('/')}/analysis-core-setup"
        remote.run(f"mkdir -p {shlex.quote(scratch)}")
        parts = [f"cd {where} &&", "jid=$(sbatch --parsable --wait",
                 f"--job-name=analysis-core-setup",
                 f"--account={shlex.quote(str(scheduler.get('account') or ''))}"
                 if scheduler.get("account") else "",
                 f"--partition={shlex.quote(str(scheduler.get('partition') or ''))}"
                 if scheduler.get("partition") else "",
                 "--nodes=1 --ntasks=1 --cpus-per-task=4 --mem=8G --time=02:00:00",
                 # Not in the tree. A scheduler writes the job's output where it
                 # is told, and told nowhere it writes into the working
                 # directory — which is a git checkout, so the log makes the
                 # tree dirty and the next install refuses to move a checkout
                 # somebody appears to have edited.
                 f"--output={shlex.quote(base + '-%j.out')}",
                 f"--wrap={shlex.quote(inner)})",
                 f'&& cat "{base}-$jid.out"']
        code, out = remote.run(" ".join(x for x in parts if x))
    for line in (out or "").splitlines()[-30:]:
        print(f"         {line}")
    if code != 0:
        if not (out or "").strip():
            say(MISS, "setup did not finish there, and said nothing about why. "
                      "The submission itself failed, so there is no job log to read.")
        else:
            say(MISS, "setup did not finish there")
        return False
    say(OK, "environments built")
    return True


def ready(site: str, dry_run: bool = False) -> int:
    profile = P.load_profile(site)
    root = profile.get("install_root")
    if not root:
        say(MISS, f"site '{site}' does not say where this tree is installed on it. "
                  f"Add \"install_root\" to its profile.")
        return 1

    host = ssh_host(site)
    origin, branch = here_now()
    print(f"\npreparing {site} ({host})\n")
    say(WARN, f"install_root {root}")
    if not branch:
        say(MISS, "this tree is not a git checkout, so there is no branch to match")
        return 1

    remote = Remote(host, profile.get("preamble") or [], dry_run)
    if remote._ssh("true", False)[0] != 0:
        say(MISS, f"cannot reach {host} over ssh")
        say(WARN, f"Set ANALYSIS_SSH_{site.upper().replace('-', '_')} if it answers "
                  f"to a different name in your ssh config.")
        return 1

    where = remote.root(root)
    if where != root:
        say(WARN, f"which is {where} on that machine")
    if not place(remote, where, origin, branch):
        return 1
    if dry_run:
        print()
        say(WARN, "dry run: nothing was changed and nothing was built")
        return 0
    if not build(remote, where, profile):
        return 1

    print()
    say(OK, f"{site} is ready. ANALYSIS_SITES={site} to use it.")
    return 0

