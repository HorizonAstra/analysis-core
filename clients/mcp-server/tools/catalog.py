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
import time
from pathlib import Path
from typing import Annotated, Any, Literal

from pydantic import Field

_TREE = Path(__file__).resolve().parents[3]
for _p in (_TREE / "interfaces" / "catalog", _TREE / "interfaces" / "run",
           _TREE / "infrastructure" / "sites", _TREE / "infrastructure" / "executors",
           _TREE / "infrastructure"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import entry as C
from protocol import JobSpec

from . import scope

_JSON_TYPE = {"string": str, "integer": int, "number": float,
              "boolean": bool, "array": list}


def _settled(executor, record):
    """The run's state once it has had the moment its site says it deserves.

    Work that queues is never waited on: a scheduler cannot say when it will
    start, and asking costs a round trip. Work that runs here either finishes
    almost at once or is genuinely long, and telling those apart is the whole
    difference between "your answer is ready" and "come back later" — which was
    being said about results that had already landed, because the answer was
    written before anyone looked.

    Bounded by the executor and never by a capability: how long a machine takes
    to start work is the machine's business, and a capability that happens to be
    slow today should not teach this to wait longer for everything.
    """
    budget = float(getattr(executor, "settles_in", 0.0) or 0.0)
    if budget <= 0 or record.state.terminal:
        return record
    deadline = time.monotonic() + budget
    # Often at first, then less so. Work that finishes in a moment is answered
    # in a moment, and work that takes two minutes is not asked about eight
    # hundred times to find that out.
    wait = 0.05
    while time.monotonic() < deadline:
        time.sleep(min(wait, max(0.0, deadline - time.monotonic())))
        wait = min(wait * 1.6, 2.0)
        try:
            record = executor.poll(record.job_id)
        except Exception:                    # noqa: BLE001 - a poll that fails is not an answer
            return record
        if record.state.terminal:
            break
    return record


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


def entries(**which) -> list[dict]:
    """Every catalog entry in the tree, or the ones asked for.

    `which` goes straight to the catalog interface: `domains=[...]` names the
    ecosystems wanted, `general=True|False` selects the general engines or the
    sciences. A session that only needs one science asks for one science and its
    engines, rather than being handed all nineteen tools and told to pick.
    """
    return C.entries(_TREE, **which)


def _tool_for(contract: dict, candidates: list) -> Any:
    """One capability, as a callable whose signature is the catalog entry.

    Bound to every machine that can run it rather than to one, because which
    one should run it is not knowable until the inputs are named. A capability
    whose environment is built here and whose data is on a cluster would
    otherwise run here and die resolving a study it cannot see.
    """
    fields: list[tuple[str, type, Any, str]] = []
    for i in contract["inputs"]:
        # What an input is called and what it says are the catalog's answer, not
        # this file's. This built its own wording, and so did the MCP render
        # target, and the two came apart: only one of them told a caller that an
        # input is a reference rather than a path.
        fields.append((i["name"], str, ... if i.get("required", True) else "",
                       C.input_note(i)))
    for p in contract.get("parameters", []):
        # A parameter with a fixed set of values is offered as that set, so the
        # schema refuses a wrong one before anything is submitted. Prose saying
        # which values are allowed is a caller's problem to obey; a Literal is
        # the host's problem to enforce, and only one of those stops a run being
        # started that cannot work.
        kind = (Literal[tuple(p["values"])] if p.get("values")
                else _JSON_TYPE.get(p["type"], str))
        # A parameter the entry marks required has no default to fall back to,
        # so it is demanded here exactly as a required input is. Without this a
        # capability that cannot work without one was offered as though it could,
        # and said so only in prose.
        fields.append((p["name"], kind,
                       ... if p.get("required") else p.get("default", ...),
                       p.get("description", "")))
    fields.append(("workspace", str, "default", C.WORKSPACE_NOTE))

    qualified = C.qualified_id(contract)

    def impl(**kwargs):
        given = {k: v for k, v in kwargs.items() if v not in (None, "")}
        workspace = given.pop("workspace", "default")
        names = {i["name"] for i in contract["inputs"]}
        inputs = {k: scope.at_chosen_version(v) for k, v in given.items() if k in names}
        site, executor = _where(candidates, inputs.values())
        parameters = {k: v for k, v in given.items() if k not in names}
        record = executor.submit(JobSpec(
            capability=qualified,
            version=contract["version"],
            inputs=inputs,
            parameters=parameters,
            workspace=workspace,
            site=site,
            fresh=scope.was_cleared(qualified, inputs, parameters),
        ))
        scope.also_allow(record.job_id)
        reused = record.state.value == "completed"
        record = _settled(executor, record)
        # Done, one way or the other: handed back because an identical run had
        # already finished, or run here and finished before this was answered.
        # Either way the note below is wrong — it tells the reader to leave it
        # running and come back, which is the one thing not to say about a result
        # that is sitting there.
        if record.state.value == "completed":
            why = ("This had already been done, so nothing was run. Same inputs, "
                   "same parameters, same pinned code, so the result is the same "
                   "result." if reused else
                   "This ran here and has already finished. It was quick; not "
                   "everything is.")
            return json.dumps({
                "run": record.job_id,
                "state": "completed",
                "capability": qualified,
                "site": site,
                "note": (why + " It is available now — read it and answer. Do not "
                         "say it is running, do not say it is in the background, "
                         "and do not offer to come back later." +
                         (" If the person needs it computed again rather than "
                          "re-used, say so plainly and ask, because re-running it "
                          "changes nothing." if reused else "")),
            }, indent=2)
        # Over before it began, which happens when an input does not resolve or
        # the kernel refuses what it was given. Said as a failure, because the
        # note below is about work still going and reads as reassurance: the
        # answer used to carry `state: failed` and "leave it running and come
        # back" in the same breath, and what came back was a promise to report
        # on a run that had already stopped.
        if record.state.value in ("failed", "cancelled"):
            return json.dumps({
                "run": record.job_id,
                "state": record.state.value,
                "capability": qualified,
                "site": site,
                "detail": record.detail or "",
                "note": ("This did not run. It is not in progress and nothing will "
                         "land later, so do not say it is running and do not offer "
                         "to check back. `detail` says what went wrong; read it, say "
                         "what happened in plain terms, and either fix the thing it "
                         "names and submit again or ask for what you need."),
            }, indent=2)
        # Still going on a machine that does not queue, so it started the moment
        # it was asked for and is simply taking a little longer than the moment
        # spent waiting. The note below is about work that sits in a queue and
        # cannot be waited on; said about this, it produced the exact failure it
        # was written to prevent — a run that failed seven seconds in, described
        # to somebody as running in the background and coming back later.
        if float(getattr(executor, "settles_in", 0.0) or 0.0) > 0:
            return json.dumps({
                "run": record.job_id,
                "state": record.state.value,
                "capability": qualified,
                "site": site,
                "note": ("Started here, and still going after a moment. Nothing "
                         "queues on this machine, so it is running now and will "
                         "finish or fail shortly. Read the result before you "
                         "answer. Do not describe it as running in the "
                         "background, do not tell them to come back later, and "
                         "do not summarise what it found until you have read "
                         "it — it may have failed."),
            }, indent=2)
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
        mcp.add_tool(_tool_for(contract, able), name=name,
                     description=C.describe(contract))
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
            description="One output by name, for more of it. Omit for all of "
                        "them. When an output is a directory, name a file "
                        "inside it — `results/printed.txt`, `results/cohort.tsv` "
                        "— to read that file properly. Naming the directory "
                        "lists what is in it and shows only the first few lines "
                        "of each, however large `rows` is, because a listing is "
                        "for finding the file and not for reading it.")] = "",
        rows: Annotated[int, Field(
            description="How many rows or lines of the file named in `output`. "
                        "Has no effect on a directory listing; name the file to "
                        "read more of it.")] = 20,
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
                              "code that produced it was verified unchanged. `on` names "
                              "what the run read: a sample name where the data is kept "
                              "per sample, and the id of each earlier run it followed. "
                              "Count from the rows rather than estimating, and if you "
                              "cannot tell which sample a run was for, say so instead "
                              "of guessing how many there were."))
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
