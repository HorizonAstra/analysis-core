"""Make a fresh clone of this repository into a working installation.

Everything here is something a person previously had to be told. That is the
whole reason it exists: a checkout that runs only after someone explains four
undocumented steps is not a checkout that runs, and the explanation is never
where the person is looking.

Nothing below knows the name of a domain, a capability or an environment. Each
catalog entry already declares what it needs and how to build it:

    "activation": {"kind": "venv", "path": "environments/py",
                   "ready_when": "bin/python", "restore_with": "bash ../restore.sh"}

so this asks the catalog what is missing and runs what the catalog says. A new
domain arriving with its own environment is installed by this file without being
mentioned in it.

Idempotent. Anything already built is left alone, so this is safe to re-run after
pulling, which is exactly when an environment tends to have moved.

What it deliberately does NOT do:

  * install language runtimes. If R or conda is absent this reports the
    capabilities that will be unavailable and carries on, because a person who
    wants only the spatial pipeline should not be made to install R first.
  * touch a cluster. Reaching one needs an account, a key and a copy of this
    tree on the far side, none of which belong in a script that runs here. It
    prints what to do instead, which is the honest half of the job.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
CLIENTS = TREE / "clients"

# Colourless, because this runs in logs and over ssh as often as in a terminal.
OK, MISS, WARN = "  ok  ", " todo ", " note "


def say(mark: str, line: str) -> None:
    print(f"{mark}  {line}", flush=True)


def run(command, cwd: Path) -> tuple[bool, str]:
    """A build step, with its output kept for the failure and hidden otherwise.

    A restore prints hundreds of lines of package resolution that mean nothing
    when it works and everything when it does not.
    """
    try:
        done = subprocess.run(command, cwd=str(cwd), shell=isinstance(command, str),
                              capture_output=True, text=True, timeout=3600)
    except (OSError, subprocess.SubprocessError) as e:
        return False, f"{type(e).__name__}: {e}"
    if done.returncode == 0:
        return True, ""
    return False, (done.stderr or done.stdout or "").strip()[-800:]


# --- the client -----------------------------------------------------------

def client_env() -> bool:
    """The virtual environment the web client and its tools run in."""
    venv = CLIENTS / ".venv"
    python = venv / "bin" / "python"
    if python.is_file():
        say(OK, f"client environment already built at {venv.relative_to(TREE)}")
        return True
    say(MISS, "building the client environment (this takes a minute)")
    made, why = run([sys.executable, "-m", "venv", str(venv)], CLIENTS)
    if not made:
        say(MISS, f"could not create {venv}: {why}")
        return False
    ok, why = run([str(python), "-m", "pip", "install", "--quiet", "--upgrade", "pip"], CLIENTS)
    ok, why = run([str(python), "-m", "pip", "install", "--quiet", "-r", "requirements.txt"],
                  CLIENTS)
    if not ok:
        say(MISS, f"installing client requirements failed:\n{why}")
        return False
    say(OK, "client environment built")
    return True


def client_settings() -> bool:
    """The one file holding this deployment's own settings, never committed.

    Copied from the example rather than generated, so the comments in the
    example are what the person reads when they fill it in.
    """
    env, example = CLIENTS / ".env", CLIENTS / ".env.example"
    if env.is_file():
        say(OK, ".env is present")
    elif example.is_file():
        shutil.copyfile(example, env)
        say(OK, f"created {env.relative_to(TREE)} from the example")
    else:
        say(MISS, "no .env.example to copy; the client has no settings file")
        return False
    text = env.read_text()
    key = [ln for ln in text.splitlines()
           if ln.startswith(("ANTHROPIC_API_KEY", "GEMINI_API_KEY")) and "=" in ln
           and ln.split("=", 1)[1].strip() not in ("", "sk-ant-...")]
    if not key:
        say(WARN, f"add an API key to {env.relative_to(TREE)} before starting the client")
    return True


# --- what the domains declare ---------------------------------------------

def declared_environments() -> dict:
    """Every environment the catalog asks for, as path -> how to build it.

    Keyed by path because several capabilities share one environment and it is
    built once. The entries that name no activation need nothing, which is why
    they are absent rather than listed as ready.
    """
    wanted: dict = {}
    for entry in sorted(TREE.glob("domains/*/catalog/*.json")):
        try:
            contract = json.loads(entry.read_text())
        except (OSError, ValueError):
            continue
        act = ((contract.get("environment") or {}).get("activation")) or {}
        if not act.get("path") or not act.get("restore_with"):
            continue
        where = (entry.parent.parent / act["path"]).resolve()
        wanted.setdefault(where, {"restore_with": act["restore_with"],
                                  "ready_when": act.get("ready_when") or ".",
                                  "kind": act.get("kind") or "?",
                                  "capabilities": []})
        wanted[where]["capabilities"].append(contract.get("id") or entry.stem)
    return wanted


def toolchain_for(restore_with: str) -> str | None:
    """The program a restore needs, when it needs one this machine may not have.

    Only the first word matters, and only for the runtimes that are genuinely
    optional here. A missing one is reported against the capabilities that
    wanted it rather than as a failure of the install.
    """
    first = restore_with.strip().split()[0]
    return first if first in ("Rscript", "conda", "mamba") else None


def domain_environments() -> list:
    """Build what the catalog declares. Returns the ones still unavailable."""
    unavailable = []
    for where, need in sorted(declared_environments().items()):
        caps = ", ".join(sorted(need["capabilities"]))
        short = where.relative_to(TREE) if where.is_relative_to(TREE) else where
        if (where / need["ready_when"]).exists():
            say(OK, f"{short} ready  ({caps})")
            continue
        tool = toolchain_for(need["restore_with"])
        if tool and shutil.which(tool) is None:
            say(WARN, f"{short} needs {tool}, which is not on this machine. "
                      f"Unavailable until then: {caps}")
            unavailable.append((str(short), caps, f"install {tool}, then re-run this"))
            continue
        say(MISS, f"building {short}  ({caps})")
        # Run from the environment's own directory, because that is what the
        # declared command is written relative to: `bash ../restore.sh` means the
        # restore script beside the environment. The directory is created first
        # when it does not exist, since for a venv the thing being built *is*
        # the directory, and a command cannot be run from inside nothing.
        where.mkdir(parents=True, exist_ok=True)
        built, why = run(need["restore_with"], where)
        if not built:
            say(MISS, f"{short} did not build:\n{why}")
            unavailable.append((str(short), caps, need["restore_with"]))
            continue
        say(OK, f"{short} built")
    return unavailable


# --- sites ----------------------------------------------------------------

def sites() -> None:
    """What this installation can reach, and what reaching more would take.

    A cluster cannot be set up from here. It needs an account, a key, and a copy
    of this tree on the far side, and the client refuses to submit until the copy
    matches. Saying so is the useful thing; pretending otherwise is how someone
    ends up debugging a digest mismatch instead of copying a directory.
    """
    profiles = sorted(p.stem for p in (TREE / "infrastructure" / "sites").glob("*.json"))
    say(OK, f"site profiles available: {', '.join(profiles)}")
    remote = [p for p in profiles if p != "local"]
    if remote:
        say(WARN, "a remote site also needs ssh access to it and a copy of this tree "
                  "there. See `install_root` in its profile for where the copy goes.")


def main() -> int:
    print(f"\nanalysis-core, installing into {TREE}\n")
    essential = client_env() and client_settings()
    print()
    unavailable = domain_environments()
    print()
    sites()

    print()
    if not essential:
        say(MISS, "the client cannot start yet. Fix the above and re-run.")
        return 1
    say(OK, "the client can start:  ./run.sh")
    if unavailable:
        print()
        say(WARN, f"{len(unavailable)} environment(s) not built. "
                  f"Everything else works; these capabilities are simply not offered:")
        for short, caps, how in unavailable:
            print(f"        {short}: {caps}")
            print(f"          to fix: {how}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
