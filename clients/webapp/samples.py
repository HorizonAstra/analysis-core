"""Which sample a run is about.

Almost every capability in the spatial domain works on one sample. A study has
nineteen of them, so a person who has ingested a study and clustered it has
sixty runs in a flat list, and finding the one they want means reading every
row. Grouped by sample it is nineteen rows, and the one they are working on is
the one they open.

Nothing new is recorded to make this work. A run's inputs are already kept as
*references* rather than paths, because a reference is resolved by the machine
that does the work rather than by the client that asks for it:

    study:NSCLC-Neoadjuvant/1N          one sample of a study
    run:harmonize-28d87c0e/matrix       an output of an earlier run
    site:tumorspace                     something the machine itself provides

So the sample is already there, and the rule is simply: **a run is about the
sample of whatever it was made from.** `harmonize` names one directly.
`bayesspace` names one directly. `de_analysis` names no sample at all, but it
was made from a harmonize run and a bayesspace run, and both of those are about
`1N`, so it is about `1N` too.

Read from the references rather than from the parameters, though several
capabilities happen to carry a `sample` parameter as well. A parameter is named
by whoever wrote the catalog entry and means whatever that kernel wants it to
mean, so keying off one would be guessing at names; a reference has one meaning
across the whole product. The two agree everywhere they overlap, which is what
gives any confidence that this is reading the right thing.

Two rules keep it honest:

  * **Everything it was made from has to agree.** A run built out of two samples
    is not about either of them, and a cohort run built out of nineteen is not
    about any. Those get no sample and stay where they are, rather than being
    filed under whichever input happened to be read first.
  * **A role is not a sample.** `study:<name>/<x>` is a sample when `<x>` is a
    sample and a role when it is a role, and the two are the same shape. The
    roles are read from the domains themselves, so this knows `counts` and
    `positions` are roles without a list of them being written here.

A run whose sample cannot be worked out is not an error. It gets `""`, the panel
leaves it at the top level, and nothing else changes.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import paths

_TREE = Path(os.environ.get("ANALYSIS_CORE", Path(__file__).resolve().parents[2]))
if str(_TREE / "infrastructure") not in sys.path:
    sys.path.insert(0, str(_TREE / "infrastructure"))

from datasource import refs as _refs                           # noqa: E402

# How long a user's registry is held before it is read again. A registry only
# changes when a run is submitted or polled, and the panel that asks this is
# already refreshed on its own schedule, so a few seconds behind costs nothing
# and re-reading two files per row does not.
_SECONDS = 5.0
_SPECS: dict = {}


def _sites() -> list[str]:
    return [s.strip() for s in os.environ.get("ANALYSIS_SITES", "local").split(",")
            if s.strip()]


_ROLES: set | None = None


def _roles() -> set:
    """Every role name any domain declares, read from the domains themselves.

    `study:NSCLC-Neoadjuvant/counts` and `study:NSCLC-Neoadjuvant/1N` are the
    same shape, and only the declarations tell them apart. Read rather than
    listed here, so a domain that adds a role does not have to remember this
    file exists.

    Read once. These are files that ship with the tree and do not change while
    the server is up.
    """
    global _ROLES
    if _ROLES is None:
        found = set()
        for path in sorted(_TREE.glob("domains/*/study.json")):
            try:
                spec = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            for shape in (spec.get("datasets") or [spec]):
                found.update((shape.get("roles") or {}).keys())
        _ROLES = found
    return _ROLES


def _specs(user: str) -> dict:
    """Every run this user has submitted, as run id -> its input references.

    Read straight from the registry files rather than through an executor,
    because the question is about what was asked for and not about what any
    machine is doing now. That matters beyond speed: a cluster that is
    unreachable would otherwise take the grouping down with it, and a panel that
    rearranges itself when the VPN drops looks like the product losing track of
    the user's work.
    """
    hit = _SPECS.get(user)
    if hit and (time.monotonic() - hit[0]) < _SECONDS:
        return hit[1]
    state = Path(paths.user_state_root(user))
    out: dict = {}
    for site in _sites():
        try:
            records = json.loads((state / f"registry-{site}.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(records, dict):
            continue
        for run, record in records.items():
            spec = (record or {}).get("spec") or {}
            inputs = spec.get("inputs") or {}
            if isinstance(inputs, dict):
                out[run] = inputs
    _SPECS[user] = (time.monotonic(), out)
    return out


def _named_by(ref: str) -> str:
    """The sample a `study:` reference names, or "" for anything else.

    `study:<study>/<sample>` and everything under it name one. `study:<study>`
    alone names a whole study, and `study:<study>/<role>` names a role of one,
    and neither is a sample.
    """
    parts = _refs.study_parts(ref)
    if len(parts) < 2:
        return ""
    return "" if parts[1] in _roles() else parts[1]


def of(user: str, run: str) -> str:
    """Which sample a run is about, or "" when it is not about exactly one."""
    return _resolve(run, _specs(user), {}, set())


def _resolve(run: str, specs: dict, memo: dict, walking: set) -> str:
    """The sample of one run, following what it was made from.

    `memo` holds runs already worked out and `walking` holds the ones being
    worked out right now. The two are different things and conflating them is a
    bug: four of a capability's five inputs commonly name the same harmonize
    run, and a single "already visited" set would answer the first of them with
    the sample and the rest with nothing, making the result depend on the order
    a dictionary happened to be in.

    `walking` exists only to stop a cycle. One cannot arise from legitimate use,
    since a run's inputs are submitted before the run exists, but a hand-edited
    registry is not worth hanging the panel over.
    """
    if run in memo:
        return memo[run]
    if run in walking:
        return ""
    inputs = specs.get(run)
    if inputs is None:
        return ""                      # not this user's, or aged out of the registry
    walking.add(run)
    found = set()
    for ref in inputs.values():
        if not isinstance(ref, str):
            continue
        if ref.startswith("run:"):
            earlier = ref[len("run:"):].strip("/").split("/")[0]
            name = _resolve(earlier, specs, memo, walking)
        else:
            name = _named_by(ref)
        if name:
            found.add(name)
        if len(found) > 1:
            break                      # built from more than one, so about neither
    walking.discard(run)
    answer = found.pop() if len(found) == 1 else ""
    memo[run] = answer
    return answer


def by_run(user: str, run_ids) -> dict:
    """The sample of each of these runs, as run id -> sample.

    One read of the registry for the whole panel rather than one per row, and
    one memo across all of them, so the walk back through earlier runs is done
    once: a study's worth of runs all lead back to the same few harmonize runs.
    """
    specs, memo = _specs(user), {}
    return {run: _resolve(run, specs, memo, set()) for run in run_ids}
