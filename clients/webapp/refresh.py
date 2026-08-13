"""Keeping a view current without anyone remembering to ask.

A person clusters a sample again and does not think about the picture of it.
Most people never think about the picture's inputs at all: they assume that
having done the work, looking at it shows the work. So a view that only updates
when someone asks is a view that is quietly wrong most of the time, and wrong
while looking finished is worse than absent.

Which runs matter is not a list kept here. An output says which viewer opens it
and an input says which capability produces it, so "this finishing makes that
view out of date" falls out of the entries, and a domain adding a second viewer
is covered without this file learning about it.

Two things it will not do. It does not rebuild what did not change: a view newer
than the run that finished is already showing it. And it does not re-run
anything behind the view, only the assembling step, wired to the newest run of
each thing that feeds it. Rebuilding is arranging, not computing.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import paths
import render

_TREE = Path(os.environ.get("ANALYSIS_CORE", Path(__file__).resolve().parents[2]))
for _p in ("interfaces/run", "interfaces/catalog", "infrastructure/graph",
           "infrastructure/sites", "infrastructure/executors",
           "infrastructure/artifact-store", "infrastructure"):
    if str(_TREE / _p) not in sys.path:
        sys.path.insert(0, str(_TREE / _p))

import plan as P                                            # noqa: E402
import reachable as _reachable                              # noqa: E402
from datasource import refs as _refs                        # noqa: E402
from protocol import JobSpec                                # noqa: E402


def _about(executor, run: str, seen: set | None = None) -> tuple:
    """Which study and sample a run was about, or (None, None).

    Read from what was submitted rather than from what was written. A manifest
    records resolved paths, and taking a study name back out of a path means
    knowing someone's directory layout. The references a caller passed say it
    outright.

    A step several deep names earlier runs rather than a study, so those are
    followed. The set of visited runs is what stops a cycle turning this into a
    loop; there should not be one, and this does not depend on that.
    """
    seen = seen if seen is not None else set()
    if run in seen:
        return None, None
    seen.add(run)
    rec = executor.registry.get(run)
    if rec is None:
        return None, None
    later = []
    for value in rec.spec.inputs.values():
        text = str(value)
        named = _refs.study_parts(text)
        if named:
            if len(named) >= 2:
                return named[0], named[1]
        elif text.startswith("run:"):
            later.append(text[len("run:"):].strip("/").split("/")[0])
    for earlier in later:
        study, sample = _about(executor, earlier, seen)
        if study:
            return study, sample
    return None, None


def _newest(executor, capability: str, study: str, sample: str) -> str:
    """The most recent finished run of one capability for one sample.

    Most recent, because a sample clustered three times has three answers and
    the view shows one. The newest is what someone means by "the view", and the
    run that made it is recorded in the bundle's manifest, so which one is being
    looked at is always answerable.
    """
    best, when = "", ""
    for rec in executor.list_jobs():
        if rec.spec.capability != capability or rec.state.value != "completed":
            continue
        if _about(executor, rec.job_id) != (study, sample):
            continue
        if (rec.submitted_at or "") >= when:
            best, when = rec.job_id, rec.submitted_at or ""
    return best


def _already_current(executor, target: str, study: str, sample: str,
                     since: str) -> bool:
    """Whether a view of this sample is already newer than what just finished."""
    have = _newest(executor, target, study, sample)
    if not have:
        return False
    rec = executor.registry.get(have)
    return bool(rec and (rec.submitted_at or "") > since)


def after(user: str, run: str) -> list:
    """Rebuild whatever views this finished run has just made out of date.

    Returns the runs it started, which is empty in the ordinary case where the
    run fed no view.
    """
    import runs as _runs
    started = []
    targets = P.viewer_targets()
    for site, executor in _runs._executors(user).items():
        rec = executor.registry.get(run)
        if rec is None:
            continue
        wants = [t for t, feeders in targets.items()
                 if rec.spec.capability in feeders]
        if not wants:
            return []
        study, sample = _about(executor, run)
        if not study or not sample:
            return []
        holds = _holds(executor, study, sample)
        for target in wants:
            if _already_current(executor, target, study, sample,
                                rec.submitted_at or ""):
                continue
            have = {c: _newest(executor, c, study, sample)
                    for c in targets[target]}
            try:
                step = P.compose(target, study=study, sample=sample, holds=holds,
                                 have={k: v for k, v in have.items() if v})
            except P.Impossible:
                # Not everything it needs exists yet. Not a failure: the view is
                # built when the rest of it has been.
                continue
            fresh = executor.submit(JobSpec(
                capability=step.capability, version=_version(step.capability),
                inputs=step.inputs, parameters=step.parameters,
                workspace=rec.spec.workspace, site=site))
            started.append({"run": fresh.job_id, "capability": step.capability,
                            "label": render.capability_title(step.capability),
                            "sample": sample})
    return started


def _version(qualified: str) -> str:
    return P.catalog()[qualified]["version"]


def _holds(executor, study: str, sample: str) -> set:
    """What that sample holds, from the survey the product already keeps.

    This used to ask the executor directly, which for a cluster is a walk of the
    whole study tree over ssh — twenty-six seconds — and it was asked once per
    finished run. A conversation with a cohort's worth of work behind it spent
    minutes in ssh before the model said anything.

    `reachable` already holds that survey behind a timed cache that serves the
    previous answer immediately and fetches the new one on a thread. Going to the
    executor stepped straight past all of it. So the fix is to ask the thing that
    already knows rather than to build a second cache in front of the same
    question: two caches over one fact is how they end up disagreeing.
    """
    for row in _reachable.datasets():
        if row.get("study") == study:
            return P.holdings(row, sample)
    return set()
