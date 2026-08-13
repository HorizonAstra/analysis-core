"""Every capability in every catalog, offered as a tool.

Nothing here is written per capability. A tool's name, its arguments, their
types and defaults, what each one means, and the caveats about reading the
answer all come out of the catalog entry. Adding a capability to a domain makes
it appear here, and adding a domain costs nothing at all.

What used to be here instead was one hand-written module per group of tools,
about 870 lines of it, most of which was restating argument lists the catalog
already declares.

Runs are long, so a capability tool submits and returns a handle. Two further
tools, `run_status` and `run_result`, answer for any run from any domain,
because polling and collecting are properties of the run interface rather than
of any science.
"""

from __future__ import annotations

import inspect
import json
import sys
from pathlib import Path
from typing import Annotated, Any

from pydantic import Field

_TREE = Path(__file__).resolve().parents[3]
for _p in (_TREE / "interfaces" / "catalog", _TREE / "interfaces" / "run",
           _TREE / "infrastructure" / "sites", _TREE / "infrastructure" / "executors"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import entry as C
from protocol import JobSpec

from . import scope

_JSON_TYPE = {"string": str, "integer": int, "number": float,
              "boolean": bool, "array": list}


def _where(candidates: list, values) -> tuple:
    """Which machine should run this, given what it was asked to read.

    Preference order decides between equals, so a capability whose environment
    is built in more than one place still lands where it was meant to. What
    breaks the tie is whether a machine can resolve every reference it was
    handed: one that cannot would start the work and fail on a name that exists
    somewhere else, which costs a submission to learn.

    Falls back to the first that can run it. A caller passing literal paths has
    said where things are, and nothing here should overrule that.
    """
    wanted = [str(v) for v in values if str(v).split(":", 1)[0] in ("study", "run")]
    if wanted:
        for site, executor in candidates:
            try:
                if all(executor.can_reach(ref) for ref in wanted):
                    return site, executor
            except Exception:              # noqa: BLE001 - a site that cannot say is not a no
                continue
    return candidates[0]


def entries() -> list[dict]:
    """Every catalog entry in the tree, in a stable order."""
    return [C.load(p) for p in sorted((_TREE / "domains").glob("*/catalog/*.json"))]


def _tool_for(contract: dict, candidates: list) -> Any:
    """One capability, as a callable whose signature is the catalog entry.

    Bound to every machine that can run it rather than to one, because which
    one should run it is not knowable until the inputs are named. A capability
    whose environment is built here and whose data is on a cluster would
    otherwise run here and die resolving a study it cannot see.
    """
    fields: list[tuple[str, type, Any, str]] = []
    for i in contract["inputs"]:
        note = i.get("description", "")
        if i.get("produced_by"):
            note += f" Produced by '{i['produced_by']}'."
        if i.get("type") != "text":
            # Said on every input rather than once in a brief, because this is
            # the moment the value is chosen. A caller that builds a path here
            # is a caller that can hand one machine's path to another machine.
            note += (" A reference: study:<study>/<role> from list_data, or "
                     "run:<id>/<output> from an earlier run. Not a file path.")
        fields.append((i["name"], str, ... if i.get("required", True) else "", note))
    for p in contract.get("parameters", []):
        fields.append((p["name"], _JSON_TYPE.get(p["type"], str),
                       p.get("default", ...), p.get("description", "")))
    # Not a destination: the store decides where a result lives, and a caller
    # naming its own is how results end up scattered. A workspace is a shelf to
    # find it on again.
    fields.append(("workspace", str, "default",
                   "Which workspace to file the result under, so it can be found again. "
                   "Use one per study or per line of work."))

    qualified = C.qualified_id(contract)

    def impl(**kwargs):
        given = {k: v for k, v in kwargs.items() if v not in (None, "")}
        workspace = given.pop("workspace", "default")
        names = {i["name"] for i in contract["inputs"]}
        inputs = {k: v for k, v in given.items() if k in names}
        site, executor = _where(candidates, inputs.values())
        record = executor.submit(JobSpec(
            capability=qualified,
            version=contract["version"],
            inputs=inputs,
            parameters={k: v for k, v in given.items() if k not in names},
            workspace=workspace,
            site=site,
        ))
        scope.also_allow(record.job_id)
        return json.dumps({
            "run": record.job_id,
            "state": record.state.value,
            "capability": qualified,
            "site": site,
            "note": ("Started. This runs on a machine, not in this process, and it "
                     "outlives this turn. Do not wait for it and do not check on "
                     "it. The person you are talking to can already see that it is "
                     "running. "
                     "Nothing wakes you when it lands: you are told at the start of "
                     "your next turn, which only happens once they say something. "
                     "So do not promise to come back or to let them know. Say what "
                     "you have started, tell them it runs without them and that the "
                     "panel shows it as it goes, and that they can leave and ask "
                     "again whenever they like."),
        }, indent=2)

    annotations = {f: Annotated[t, Field(description=d)] for f, t, _, d in fields}
    impl.__signature__ = inspect.Signature([
        inspect.Parameter(f, inspect.Parameter.KEYWORD_ONLY,
                          annotation=annotations[f],
                          default=(inspect.Parameter.empty if dv is ... else dv))
        for f, _, dv, _ in fields])
    impl.__annotations__ = annotations
    impl.__name__ = qualified.replace("/", "_")
    return impl


# What one invocation reasons about. Declared per entry, and worth saying out
# loud: without it a caller cannot tell whether an answer describes one sample
# or the set, and asking a per-sample capability a question about a cohort
# produces an answer that looks right and means something else. Derived from the
# entry rather than written into any brief, so it cannot go stale when a
# capability is added.
_SCOPE = {
    "per_sample": "Runs on one sample. The answer is about that sample and no other, "
                  "so comparing two samples means running it on each.",
    "cross_sample": "Reasons across samples in one go. The answer belongs to the set "
                    "rather than to any single sample in it.",
}


def describe(contract: dict) -> str:
    """What the model is told a capability is, and how to read its answer."""
    desc = contract.get("summary", contract["title"])
    reasons_about = _SCOPE.get(contract.get("scope", ""))
    if reasons_about:
        desc += " " + reasons_about
    det = contract["determinism"]
    if det["consumes_rng"] and not det.get("seeded_by_default"):
        desc += " Results vary between runs unless a seed is supplied."
    if contract.get("interpretation"):
        desc += "\n\nReading the result: " + contract["interpretation"]
    return desc


def register(mcp, *, sites, domain_allowed=lambda d: True) -> dict[str, str]:
    """Offer every capability that can run somewhere, routed when it is called.

    `sites` is an ordered mapping of site name to executor. Order is the
    preference: a capability whose environment is built here has no reason to
    cross a network, and one that needs a container image goes where the images
    are. Nothing about that choice is written per capability, which is why
    adding a machine changes no entry.

    Each site is asked whether it can run each capability, because only a
    machine can answer for itself. Offering one that cannot run invites the
    model to reach for an analysis that fails minutes later.
    """
    offered, routed = [], {}
    sites = {n: e for n, e in sites.items() if e.available()}
    for contract in entries():
        if not domain_allowed(C.domain(contract)):
            continue
        able = [(n, e) for n, e in sites.items() if e.can_run(contract)[0]]
        if not able:
            continue
        name = C.qualified_id(contract).replace("/", "_")
        mcp.add_tool(_tool_for(contract, able), name=name, description=describe(contract))
        offered.append(name)
        routed[name] = ", ".join(n for n, _ in able)

    # Polling and collecting belong to the run interface, so one pair of tools
    # answers for every run. Which executor owns a handle is bookkeeping, not
    # something a caller should have to know.
    def _submitted_to(run):
        return next((ex for ex in sites.values()
                     if ex.registry.get(run) is not None), None)

    def _read_from_any(run, name, rows):
        """(machine, outputs) for a run nothing here submitted, else (None, None).

        A registry records what went through this client. A store records
        results, and a result can be there without having been submitted from
        here: from a session that has ended, or from work done before any of
        this existed and recorded into the store afterwards. Those are readable,
        so they are findable, and the read that finds them is the read that
        answers, rather than a probe followed by a second round trip.
        """
        for ex in sites.values():
            try:
                return ex, ex.read(run, name, rows)
            except Exception:                # noqa: BLE001 - not this one, try the next
                continue
        return None, None

    def _in_scope(run: str) -> str:
        """A run this conversation may reach, or the same answer as one that is not there.

        A store belongs to a person and outlives any one conversation in it.
        Reaching across conversations is a thing to ask for deliberately, not
        the default, so a run from another one is refused here in the same words
        as a run that does not exist.
        """
        allowed = scope.allowed_runs()
        if allowed is not None and run not in allowed:
            raise KeyError(f"no run called {run} in this conversation")
        return run

    def run_status(run: Annotated[str, Field(description="The run id submit returned.")]):
        _in_scope(run)
        ex = _submitted_to(run)
        if ex is not None:
            rec = ex.poll(run)
            return json.dumps({"run": rec.job_id, "state": rec.state.value,
                               "detail": rec.detail, "updated": rec.updated_at}, indent=2)
        if _read_from_any(run, None, 1)[0] is None:
            raise KeyError(f"no run called {run}")
        # A finished result that this conversation did not start. The store
        # holds no unfinished ones, so there is nothing to wait for.
        return json.dumps({"run": run, "state": "completed",
                           "detail": "a result already on the machine, which this "
                                     "session did not start"}, indent=2)

    def run_result(
        run: Annotated[str, Field(description="The run id submit returned.")],
        output: Annotated[str, Field(
            description="One output by name, for more of it. Omit for all of them.")] = "",
        rows: Annotated[int, Field(description="How many rows or lines of each.")] = 20,
    ):
        _in_scope(run)
        ex = _submitted_to(run)
        if ex is not None:
            # Through collect, which is what refuses to hand back a run that has
            # not finished. A result already in a store has finished by
            # definition, so the same check has nothing to say about one.
            res = ex.collect(run)
            return json.dumps({"run": res.job_id, "manifest": res.manifest_path,
                               "outputs": ex.read(run, output or None, rows)}, indent=2)
        ex, found = _read_from_any(run, output or None, rows)
        if ex is None:
            raise KeyError(f"no run called {run}")
        return json.dumps({"run": run, "outputs": found}, indent=2)

    def cancel_run(run: Annotated[str, Field(description="The run id to stop.")]):
        _in_scope(run)
        ex = _submitted_to(run)
        if ex is None:
            raise KeyError(f"{run} was not started from this conversation, so there "
                           f"is nothing here to stop.")
        rec = ex.cancel(run)
        return json.dumps({"run": rec.job_id, "state": rec.state.value,
                           "detail": rec.detail}, indent=2)

    def list_runs(
        workspace: Annotated[str, Field(
            description="Only one workspace. Omit for all of them.")] = "",
        capability: Annotated[str, Field(
            description="Only runs of this capability, named as the entry names it "
                        "rather than as this tool is named. Omit to see everything, "
                        "which is usually cheaper than asking once per capability.")] = "",
        limit: Annotated[int, Field(description="How many, newest first.")] = 20,
    ):
        """Results held on every machine this client can reach.

        Asked of each machine rather than read from one filesystem, for the same
        reason data is: only a machine can answer for what is on it, and its
        store holds results that outlived the session that made them.
        """
        allowed = scope.allowed_runs()
        out = []
        for site, executor in sites.items():
            # Asked for more than will be shown, so that what is cut is cut here
            # with the whole picture in hand. A store holding a cohort's worth of
            # work fills any newest-first page with one capability, and a caller
            # then concludes the others were never run.
            for r in executor.runs(workspace or None, capability or None, max(limit * 8, 200)):
                if allowed is not None and r.get("run") not in allowed:
                    continue
                out.append({**r, "site": r.get("site") or site})
        out.sort(key=lambda r: r.get("finished") or "", reverse=True)
        totals: dict[str, int] = {}
        for r in out:
            totals[r["capability"]] = totals.get(r["capability"], 0) + 1
        shown = out[:limit]
        answer: dict = {"runs": shown}
        if len(out) > len(shown):
            answer["how_many_of_each"] = dict(sorted(totals.items()))
            answer["note"] = (f"{len(shown)} of {len(out)} shown, newest first. The counts "
                              f"above are of all of them, so a capability listed there has "
                              f"results whether or not one appears above. Name a capability "
                              f"to see its own.")
        return json.dumps(answer, indent=2)

    mcp.add_tool(run_status, name="run_status",
                 description="What state a submitted run is in. Cheap to call repeatedly.")
    mcp.add_tool(list_runs, name="list_runs",
                 description=("Results that already exist and what each one produced, "
                              "newest first, across every machine. Includes work done "
                              "before this conversation, which can be read and fed into "
                              "a further analysis without being run again. Each row "
                              "carries the capability, where it ran, and whether the "
                              "code that produced it was verified unchanged."))
    mcp.add_tool(run_result, name="run_result",
                 description=("The outputs of a finished run, read back: a table as its "
                              "columns and first rows, text as its first lines, a figure "
                              "as a reference. Name one output and raise `rows` to see "
                              "more of it. Outputs the domain marked as unable to leave "
                              "the machine are not listed. Read the result before saying "
                              "what it shows."))
    mcp.add_tool(cancel_run, name="cancel_run",
                 description=("Stop a run that is still going. Anything it already wrote "
                              "stays where it is."))
    for t in ("run_status", "run_result", "cancel_run", "list_runs"):
        routed[t] = "any"
    return routed
