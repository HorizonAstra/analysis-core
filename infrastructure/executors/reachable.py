"""The machines this deployment can reach, and what they hold.

Which machines those are was decided in one place and then needed in two: the
tool server assembling a menu of capabilities, and the web app assembling a menu
of data. Both were building it, and only one of them was building it correctly,
so the web app read its own filesystem and reported the answer as the whole
world. A person whose data lives on a cluster then signed in to an empty product.

So the wiring lives here, once. A machine answers for itself, which is the rule
everywhere else: only it can say what it can run and what is on it.

    ANALYSIS_SITES      ordered, comma separated, `local` alone by default. The
                        order is the routing preference and nothing more.
    ANALYSIS_STATE      where this client keeps its own record of what it
                        submitted.
    ANALYSIS_RESULTS    one results root for everything, overriding each site's
                        own. A deployment serving several people sets it per
                        person, so results are separated by the filesystem.
    ANALYSIS_SSH_<SITE> how this account reaches a site that has a scheduler.
                        A site file describes a machine; how one account gets to
                        it is a property of the account.
"""

from __future__ import annotations

import os
import sys
import threading
import time
from pathlib import Path

_TREE = Path(__file__).resolve().parents[2]
for _p in ("interfaces/run", "interfaces/catalog", "infrastructure/sites",
           "infrastructure/artifact-store", "infrastructure/executors"):
    if str(_TREE / _p) not in sys.path:
        sys.path.insert(0, str(_TREE / _p))

import profile as P
from store import ArtifactStore

from local import LocalExecutor
from registry import JobRegistry
from slurm_ssh import SlurmSshExecutor


def names() -> list[str]:
    named = os.environ.get("ANALYSIS_SITES", "local")
    return [s.strip() for s in named.split(",") if s.strip()]


def is_remote(profile: dict) -> bool:
    """A site with a scheduler is somewhere else. A site without one is here."""
    return bool((profile.get("executor") or {}).get("scheduler"))


def state_dir() -> Path:
    return Path(os.environ.get("ANALYSIS_STATE", Path.home() / ".analysis-core"))


def owner() -> str:
    """Whose work this client is submitting, as one path segment, or nothing.

    A deployment with one person at a terminal has no owner and wants none: the
    results go where the site says. A deployment serving several people has to
    keep them apart on every machine, and a machine reached over a network is
    the one where that is easy to forget, because its results root is named in
    the site's own profile rather than by the client.
    """
    return os.environ.get("ANALYSIS_OWNER", "").strip()


# Executors, kept for a moment rather than rebuilt on every question. An
# executor caches what its machine can run and what it holds, and those answers
# are the expensive ones: each is an ssh, and listing what this deployment can do
# asks per capability per site. Rebuilding the executor each time threw the cache
# away before it could be used twice, so the capabilities listing cost twenty
# seconds of round trips on a cold process and did it again on the next one.
#
# Keyed by site and by who is asking, because both decide what an executor is
# pointed at. Short, because the things behind it are a machine being reachable
# and an environment being built, and both can change while a process is up.
_BUILT: dict[tuple, tuple[float, object]] = {}
_BUILT_SECONDS = 300.0


def executor(site: str):
    """One machine, as something that can be asked to run work and to answer."""
    key = (site, str(state_dir()), owner(), os.environ.get("ANALYSIS_RESULTS", ""))
    hit = _BUILT.get(key)
    if hit and (time.monotonic() - hit[0]) < _BUILT_SECONDS:
        return hit[1]
    built = _build(site)
    _BUILT[key] = (time.monotonic(), built)
    return built


def _build(site: str):
    profile = P.load_profile(site)
    registry = JobRegistry(state_dir() / f"registry-{site}.json")
    if is_remote(profile):
        host = os.environ.get(f"ANALYSIS_SSH_{site.upper().replace('-', '_')}", site)
        root = profile.get("artifact_root")
        who = owner()
        return SlurmSshExecutor(ssh_host=host, site=site, registry=registry,
                                artifact_root=(f"{root.rstrip('/')}/{who}"
                                               if root and who else None))
    store = ArtifactStore(os.environ.get("ANALYSIS_RESULTS")
                          or profile.get("artifact_root")
                          or (state_dir() / "results"))
    return LocalExecutor(site=site, registry=registry, store=store)


def sites() -> dict:
    """Every reachable machine, in preference order."""
    return {name: executor(name) for name in names()}


_CACHE: dict[str, tuple[float, list[dict]]] = {}
_REFRESHING: set[str] = set()
_GUARD = threading.Lock()
_TTL = float(os.environ.get("ANALYSIS_DATA_TTL", "300"))


def _refresh_later(key: str) -> None:
    """Ask again, on a thread, and leave the previous answer standing meanwhile.

    Asking a cluster means an ssh, and an ssh takes as long as the network and
    the far side decide. A web process serving several people cannot wait on
    that: doing it inline froze every request for every user until the machine
    answered, and if the machine was merely slow rather than down, that was
    minutes rather than seconds.

    So a stale answer is served immediately and replaced when the real one
    arrives. Being a few minutes behind on which studies exist is a small,
    self-correcting error. Being unable to open a page is not.
    """
    with _GUARD:
        if key in _REFRESHING:
            return
        _REFRESHING.add(key)

    def work() -> None:
        try:
            _survey(key)
        except Exception:                  # noqa: BLE001 - the old answer stands
            pass
        finally:
            with _GUARD:
                _REFRESHING.discard(key)

    threading.Thread(target=work, daemon=True, name=f"datasets-{key}").start()


def warm() -> list[dict]:
    """Ask now, so that the first person through the door is not the one waiting."""
    return _survey(",".join(names()))


def datasets(built=None, *, fresh: bool = False) -> list[dict]:
    """Every dataset every reachable machine holds, asked of each of them.

    A reference names no machine, and that is the point: a study exists or it
    does not, and whichever machine runs the work resolves it there. The site is
    reported alongside so a study reachable from only one place can be explained
    rather than silently failing, not so a caller has to choose.

    A machine being down is not a reason to answer for none of them. Its data is
    missing from the answer, which is the truthful thing to say, since work
    could not reach it either.

    Held briefly. Asking a cluster over ssh is a round trip, and a long lived
    web process asks on every page a person opens. Data does not appear and
    vanish between one question and the next, so a short hold is honest; it is
    short so that data added today shows up today. Once the hold expires the
    previous answer is still served, and the new one is fetched behind it.
    """
    if built is not None:
        return _merge(built)
    key = ",".join(names())
    if not fresh:
        seen = _CACHE.get(key)
        if seen:
            if time.monotonic() - seen[0] >= _TTL:
                _refresh_later(key)
            return seen[1]
    return _survey(key)


def _survey(key: str) -> list[dict]:
    out = _merge(sites())
    _CACHE[key] = (time.monotonic(), out)
    return out


def _merge(built: dict) -> list[dict]:
    """One answer from several machines, each asked for its own.

    A machine being down is not a reason to answer for none of them. Its data is
    simply absent from the answer, which is the truthful thing to say, since the
    work could not have reached it either.
    """
    found: dict[str, dict] = {}
    for name, ex in built.items():
        try:
            if not ex.available():
                continue
            here = ex.datasets()
        except Exception:                  # noqa: BLE001 - one site down is not fatal
            continue
        for row in here:
            key = row["study"]
            if key in found:
                # Two machines holding the same name is a real ambiguity, not
                # something to resolve quietly: they may not hold the same data.
                found[key].setdefault("also_on", []).append(name)
                continue
            found[key] = {**row, "site": row.get("site") or name}
    return [found[k] for k in sorted(found)]
