"""Ask for a result and get everything it needs, in one call.

The capability tools each submit one thing. That is right, and for most work it
is all anyone wants. It is wrong for the results that sit four steps deep: an
interactive view of a sample needs the sample prepared, clustered, its marker
genes found, and only then assembled, and every one of those means reading the
handle out of the last call and threading it into the next. Nineteen samples is
seventy six calls, and each one is a chance to pass the wrong reference or drop
the optional input that fills the marker list. The failure is quiet, which is
the worst kind: the view builds, and every cluster says undefined.

None of that ordering is a judgement, so none of it is worth a person's or a
model's attention. The entries already say which capability produces each input,
which of them a sample can supply directly, and which parameter is the sample's
own name. `infrastructure/graph/plan.py` turns that into the chain. This submits
it.

Two things it does not do. It does not wait: every step is submitted at once and
the site is told to hold each one until the ones before it have succeeded, so
nothing has to stay alive for the chain to advance and a failure stops the rest
rather than feeding it an input that was never written. And it does not reuse an
earlier run, because a run that merely has the right name is not a run that had
the right inputs. Passing an existing result into a capability tool is still the
way to build on it deliberately.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Annotated

from pydantic import Field

_TREE = Path(__file__).resolve().parents[3]
for _p in (_TREE / "interfaces" / "catalog", _TREE / "interfaces" / "run",
           _TREE / "infrastructure" / "graph", _TREE / "infrastructure" / "executors"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import entry as C
import plan as P
from protocol import JobSpec

import datasource as D

from . import scope

# How many samples one call may start work for. A cohort is the point of this,
# so it is not small, but an unbounded call against a study nobody has looked at
# is a way to fill a queue by accident.
_MOST = 64


def _work(reference: str, rows: list) -> list:
    """What the work is about, as (study, sample, row). The sample may be empty.

    A study on its own means every sample in it, which is the whole reason this
    exists: a cohort is asked for once rather than once per sample.

    A study with no samples to name means the study itself, once. Not every
    domain's data is per sample — a microbiome study is a set of tables covering
    every sample at once, and its capabilities read the set rather than a member
    of it. This required a sample and fanned out over them, so for such a study
    it raised "that names no samples" and there was no way to ask for anything
    at all; the chain that would have prepared its tables was reachable only by
    writing the preparation out by hand instead.
    """
    out = []
    for one in [r.strip() for r in str(reference).split(",") if r.strip()]:
        named = D.study_parts(one)
        if not named:
            raise ValueError(f"'{one}' does not name data. Use study:<study> for a "
                             f"whole study, or study:<study>/<sample> for one sample "
                             f"of a study that has them.")
        study, sample = named[0], (named[1] if len(named) > 1 else "")
        row = next((r for r in rows if r["study"] == study), None)
        if row is None:
            raise KeyError(f"no study called {study} available here. There is: "
                           f"{', '.join(sorted(r['study'] for r in rows)) or 'none'}")
        members = row.get("samples") or []
        if sample:
            if sample not in members:
                raise KeyError(f"{study} has no sample called {sample}"
                               + ("; it is not organised into samples"
                                  if not members else ""))
            out.append((study, sample, row))
        elif members:
            out += [(study, name, row) for name in members]
        else:
            out.append((study, "", row))
    if not out:
        raise ValueError("that names no data")
    return out


def _site_for(study_row: dict, sites: dict):
    """Where a chain runs: the one machine that holds the data it starts from.

    One machine for the whole chain rather than per step, because each step
    reads the run before it, and a run is on the machine that made it.
    """
    name = study_row.get("site")
    if name and name in sites:
        return name, sites[name]
    return next(iter(sites.items()))


def register(mcp, *, sites, domain_allowed=lambda d: True) -> list:
    entries = {q: c for q, c in P.catalog(_TREE).items()
               if domain_allowed(C.domain(c))}
    if not entries:
        return []

    def prepare(
        capability: Annotated[str, Field(
            description="What you want, as the tool name of a capability, for "
                        "example spatial-transcriptomics_spatialview_bundle. "
                        "Everything it needs is worked out and run first.")],
        sample: Annotated[str, Field(
            description="What to run it on, from list_data. study:<study> on its "
                        "own is the usual answer: for a study organised into "
                        "samples that means every sample in it, and for one whose "
                        "data covers every sample at once it means the study, "
                        "once. study:<study>/<sample> names a single sample of "
                        "the first kind, and several can be separated by commas.")],
        parameters: Annotated[str, Field(
            description="Optional. A JSON object keyed by capability, for the "
                        "steps you want to set rather than leave at their "
                        "defaults, for example {\"bayesspace\": {\"q\": 10}}. "
                        "Anything not named here runs with the defaults its "
                        "entry declares. Only the parameters an entry declares "
                        "can be set. Inputs are worked out and filled in for "
                        "you, so naming one here is refused rather than "
                        "guessed at.")] = "",
        workspace: Annotated[str, Field(
            description="Which workspace to file the results under, so they can "
                        "be found again. Use one per study or per line of work.",
        )] = "default",
    ) -> str:
        """Run a capability on one sample, or on every sample of a study, running
        whatever it needs first.

        Use this when what you want is several steps past the data: it works out
        the chain from the catalog, fills the optional inputs it can, and submits
        the whole thing at once. Use a capability's own tool instead when its
        inputs already exist and you want exactly one run.

        Returns at once. Nothing here waits, and neither should you.
        """
        target = capability.replace("_", "/", 1) if "/" not in capability else capability
        if target not in entries:
            # Tool names flatten the separator, and a domain's name can itself
            # contain one, so a plain swap is not enough to name every entry.
            target = next((q for q in entries if q.replace("/", "_") == capability),
                          target)
        if target not in entries:
            raise KeyError(f"no capability called {capability}. There is: "
                           f"{', '.join(sorted(q.replace('/', '_') for q in entries))}")

        from executors import reachable
        rows = [r for r in reachable.datasets(sites)
                if D.study_allowed(r["study"]) and D.domain_allowed(r["domain"])]
        wanted = _work(sample, rows)
        if len(wanted) > _MOST:
            raise ValueError(f"that is {len(wanted)} samples, and this stops at "
                             f"{_MOST}. Name the ones you want.")

        by_capability = json.loads(parameters) if parameters.strip() else {}
        # Keyed by whatever the caller called it, so a bare id works as well as a
        # qualified one and neither has to match how the tool was named.
        by_capability = {
            next((q for q in entries
                  if q == k or q.split("/", 1)[1] == k or q.replace("/", "_") == k), k):
            v for k, v in by_capability.items()}

        started, plans = [], []
        for study, name, row in wanted:
            steps = P.plan(target, study=study, sample=name,
                           holds=P.holdings(row, name), entries=entries,
                           parameters=by_capability)
            site, executor = _site_for(row, sites)
            ids: dict = {}
            for step in steps:
                contract = entries[step.capability]
                spec = JobSpec(
                    capability=step.capability,
                    version=contract["version"],
                    # A step's inputs name the steps before it by capability. The
                    # run ids only exist once those have been submitted, which is
                    # why the substitution happens here and not in the plan.
                    #
                    # The chosen version of the data goes in at the same moment
                    # and for the same reason: this is where a reference stops
                    # being a plan and becomes what a machine will read.
                    inputs={k: scope.at_chosen_version(v.format(**{q: ids[q] for q in ids}))
                            for k, v in step.inputs.items()},
                    parameters=step.parameters,
                    workspace=workspace,
                    site=site,
                    after=tuple(ids[q] for q in step.after if q in ids),
                    # A step whose cell was emptied is computed again rather than
                    # handed back, exactly as it would be if it had been asked
                    # for on its own. Only that step: the rest of the chain is
                    # still re-used, which is the whole point of emptying one.
                    fresh=scope.was_cleared(step.capability, step.inputs,
                                            step.parameters, subject=name),
                )
                record = executor.submit(spec)
                # In scope for the rest of this conversation, like anything else
                # it started.
                scope.also_allow(record.job_id)
                ids[step.capability] = record.job_id
                # The state travels with the handle, as it does when a single
                # capability is submitted. Without it the client cannot tell a
                # step that has been started from one that has finished, so a
                # whole chain goes by with nothing shown for it.
                started.append({"sample": name or study, "capability": step.capability,
                                "run": record.job_id, "state": record.state.value,
                                "site": site})
            plans.append({"sample": name or study,
                          "order": [s.capability for s in steps], "site": site})

        return json.dumps({
            "started": started,
            "samples": len(wanted),
            "each_sample": plans[0]["order"] if plans else [],
            "site": plans[0]["site"] if plans else "",
            "note": ("Every step is submitted. Each one waits for the ones before "
                     "it, and a step that fails stops the rest rather than running "
                     "on a result that was never written. This runs on a machine, "
                     "not in this process, and it outlives this turn. Do not wait "
                     "for it and do not check on it. "
                     "Nothing wakes you when it lands: you are told at the start of "
                     "your next turn, which only happens once the person says "
                     "something. So do not promise to come back or to let them "
                     "know. Say what you have started, tell them it runs without "
                     "them and that the panel shows it as it goes, and that they "
                     "can leave and ask again whenever they like."),
        }, indent=2)

    mcp.add_tool(prepare, name="prepare",
                 description=("Run a capability on a study, or on one sample of one, "
                              "running whatever it needs first. For a result that "
                              "sits several steps past the data, where chaining the "
                              "calls by hand is the part that goes wrong — including "
                              "the shaping a statistical tool needs before it will "
                              "read a study at all. Submits the whole chain at once "
                              "and returns."))
    return ["prepare"]
