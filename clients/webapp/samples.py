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
for _p in ("infrastructure", "interfaces/data"):
    if str(_TREE / _p) not in sys.path:
        sys.path.insert(0, str(_TREE / _p))

import reference as _reference                                 # noqa: E402
from datasource import domains as _domains                     # noqa: E402

# How long a user's registry is held before it is read again. A registry only
# changes when a run is submitted or polled, and the panel that asks this is
# already refreshed on its own schedule, so a few seconds behind costs nothing
# and re-reading two files per row does not.
_SECONDS = 5.0
_SPECS: dict = {}


def _sites() -> list[str]:
    return [s.strip() for s in os.environ.get("ANALYSIS_SITES", "local").split(",")
            if s.strip()]


def _roles() -> frozenset:
    """Every role name any domain declares, so a role is never read as a sample.

    Asked of the domains rather than worked out here. This file used to read the
    declarations itself, which is one more copy of a question the data layer
    already answers.
    """
    return _domains.role_names()


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


def of(user: str, run: str) -> str:
    """Which sample a run is about, or "" when it is not about exactly one."""
    specs = _specs(user)
    return _reference.subject(specs.get(run) or {}, specs.get, _roles())


def by_run(user: str, run_ids) -> dict:
    """The sample of each of these runs, as run id -> sample.

    One read of the registry for the whole panel rather than one per row, and
    one memo across all of them, so the walk back through earlier runs is done
    once: a study's worth of runs all lead back to the same few harmonize runs.
    """
    specs, roles, memo = _specs(user), _roles(), {}
    for run in run_ids:
        if run not in memo:
            memo[run] = _reference.subject(specs.get(run) or {}, specs.get,
                                           roles, memo)
    return {run: memo[run] for run in run_ids}
