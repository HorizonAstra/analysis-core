"""What is running, and how to stop it.

A run outlives the turn that started it. A cluster job queues, then runs, and
the conversation has moved on long before it lands. So the state of a run is not
something the conversation can be relied on to know, and the product asks the
machines directly.

Deliberately no model involved. A run's state is a fact about a machine, held in
a registry on disk and answered by an executor. Spending a model turn to look it
up would cost tokens and count against the step budget of the very conversation
the user is trying to have, to learn something the filesystem already knows.

The executors here are the same classes the server uses, constructed against the
same registry file. That is why the registry takes a lock across processes: this
polls while the server submits.
"""

from __future__ import annotations

import json
import os
import sys
import concurrent.futures
import threading
import time
from pathlib import Path

import paths
import render

_TREE = Path(os.environ.get("ANALYSIS_CORE", Path(__file__).resolve().parents[2]))
for _p in ("interfaces/run", "interfaces/catalog", "infrastructure/sites",
           "infrastructure/executors"):
    if str(_TREE / _p) not in sys.path:
        sys.path.insert(0, str(_TREE / _p))

import profile as P                                            # noqa: E402
from local import LocalExecutor                                # noqa: E402
from registry import JobRegistry                               # noqa: E402
from slurm_ssh import SlurmSshExecutor                         # noqa: E402

import artifacts                                               # noqa: E402

# A state that is not terminal is one worth showing. The rest are history and
# belong in the results panel instead.
LIVE = {"submitted", "running", "pending"}
_STATE_CACHE_SECONDS = 3.0
_cache: dict[str, tuple[float, list]] = {}


def _sites() -> list[str]:
    return [s.strip() for s in os.environ.get("ANALYSIS_SITES", "local").split(",")
            if s.strip()]


# Executors, kept for a moment rather than rebuilt on every question. Each one
# caches what its machine holds "for the life of this executor", and the life of
# an executor was one call — so the cache never survived, and asking a cluster
# what data it has meant an ssh round trip every time. The panel polls every two
# seconds and a turn that rebuilds views asks once per finished run, so a chat
# with a cohort's worth of work behind it spent minutes in ssh before the model
# said anything.
#
# Held briefly and keyed by user, so one person's executors are never handed to
# another. The registry underneath re-reads its file on every access, so a
# cached executor still sees runs submitted since.
#
# Five minutes rather than seconds, because the expensive thing behind it is a
# walk of the whole study tree on shared storage, and that measures in tens of
# seconds. Study data is added by hand and rarely; a sample that appears while
# someone is mid-conversation showing up a few minutes later is not a cost
# anybody can perceive, and paying it per question is.
_EXECUTORS: dict = {}
_EXECUTORS_SECONDS = 300.0


def _executors(user: str) -> dict:
    hit = _EXECUTORS.get(user)
    if hit and (time.monotonic() - hit[0]) < _EXECUTORS_SECONDS:
        return hit[1]
    built = _build_executors(user)
    _EXECUTORS[user] = (time.monotonic(), built)
    return built


def _build_executors(user: str) -> dict:
    """One executor per reachable site, against this user's own state and results.

    The registry has to be the same file this user's MCP server writes, or the
    panel polls an empty one; and it has to be a different file from every other
    user's, or one person's running work is listed to another and a handle out
    of that listing can be cancelled by them. Both come from `paths`, which is
    also what the server passes down as ANALYSIS_STATE.
    """
    state = Path(paths.user_state_root(user))
    out = {}
    for site in _sites():
        try:
            prof = P.load_profile(site)
        except SystemExit:
            continue
        registry = JobRegistry(str(state / f"registry-{site}.json"))
        if (prof.get("executor") or {}).get("scheduler"):
            host = os.environ.get(f"ANALYSIS_SSH_{site.upper().replace('-', '_')}",
                                  os.environ.get("RANDI_SSH_HOST", site))
            out[site] = SlurmSshExecutor(ssh_host=host, site=site, registry=registry)
        else:
            store = artifacts.ArtifactStore(paths.user_outputs_root(user))
            out[site] = LocalExecutor(site=site, registry=registry, store=store)
    return out


def _describe(record, site: str) -> dict:
    """One run, in a reader's terms. No identifiers beyond the handle itself."""
    started = record.submitted_at or ""
    return {
        "run": record.job_id,
        "label": render.capability_title(record.spec.capability),
        "state": record.state.value,
        "site": site,
        "started": started,
        "elapsed": _elapsed(started),
        "workspace": record.spec.workspace,
    }


def _elapsed(started: str) -> str:
    """How long it has been going, said the way a person would say it."""
    from datetime import datetime, timezone
    try:
        began = datetime.fromisoformat(started)
    except (TypeError, ValueError):
        return ""
    if began.tzinfo is None:
        began = began.replace(tzinfo=timezone.utc)
    seconds = int((datetime.now(timezone.utc) - began).total_seconds())
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h {(seconds % 3600) // 60}m"


def live(user: str, chat_runs: list[str] | None = None) -> list[dict]:
    """Runs still going, newest first.

    Not scoped to one conversation by default. Someone who starts a long
    analysis and then opens another chat has not stopped caring about it, and a
    progress indicator only visible in the conversation that happens to be on
    screen is one they will miss.

    Polled at most every few seconds: a browser asking often is cheap here, but
    an ssh round trip per ask is not.
    """
    hit = _cache.get(user)
    if hit and (time.monotonic() - hit[0]) < _STATE_CACHE_SECONDS:
        found = hit[1]
    else:
        found = []
        for site, executor in _executors(user).items():
            try:
                if not executor.available():
                    continue
                live = [r for r in executor.list_jobs() if r.state.value in LIVE]
                # One question about all of them where the site can answer that
                # way. Asked one at a time this is a round trip per run, and a
                # study's worth of runs takes longer to ask about than the
                # refresh interval, so the sweeps overlap and stack up.
                many = getattr(executor, "poll_many", None)
                if many is not None:
                    try:
                        live = many([r.job_id for r in live])
                    except Exception:      # noqa: BLE001 - fall back to one by one
                        many = None
                if many is None:
                    fresh = []
                    for record in live:
                        try:
                            fresh.append(executor.poll(record.job_id))
                        except Exception:  # noqa: BLE001 - a stale handle is not fatal
                            fresh.append(record)
                    live = fresh
                found.extend(_describe(r, site) for r in live
                             if r.state.value in LIVE)
            except Exception:              # noqa: BLE001 - an unreachable site is not fatal
                continue
        found.sort(key=lambda r: r.get("started") or "", reverse=True)
        _cache[user] = (time.monotonic(), found)
    if chat_runs is None:
        return found
    keep = set(chat_runs)
    return [r for r in found if r["run"] in keep]


def outcomes(user: str, run_ids: list[str]) -> list[dict]:
    """Which of these runs have finished, and how they ended.

    Asked of the machines, once, at the moment the answer is needed. Nothing is
    kept waiting: a run that is still going is simply absent from the result and
    will appear the next time someone asks.
    """
    if not run_ids:
        return []
    wanted, done = set(run_ids), []
    for site, executor in _executors(user).items():
        try:
            if not executor.available():
                continue
        except Exception:                  # noqa: BLE001 - an unreachable site is not fatal
            continue
        for run in list(wanted):
            record = executor.registry.get(run)
            if record is None:
                continue
            try:
                record = executor.poll(run)
            except Exception:              # noqa: BLE001 - a stale handle is not fatal
                continue
            wanted.discard(run)
            if record.state.value in LIVE:
                continue
            # It has landed somewhere. Start pulling it to where this machine
            # can show it, without making whoever asked wait for the transfer,
            # and rebuild any view it has just made out of date.
            if record.state.value == "completed":
                _bring_back_later(user, run)
                for fresh in _refresh_views(user, run):
                    done.append({"run": fresh["run"], "state": "submitted",
                                 "label": fresh["label"],
                                 "detail": f"rebuilt for {fresh['sample']}, "
                                           f"because what it draws has changed"})
            done.append({"run": run, "state": record.state.value,
                         "label": render.capability_title(record.spec.capability),
                         "detail": record.detail or ""})
    return done


# Runs already brought back, or being brought back now, so a second ask does not
# start a second copy of the same transfer.
_FETCHED: set[str] = set()
_FETCH_GUARD = threading.Lock()


def _absent(store, run: str) -> list | None:
    """Which of a run's outputs are not on this machine yet.

    `None` when the run is not here at all, and an empty list when it is here in
    full, so the caller can tell "fetch everything" from "fetch nothing".

    Asked of the manifest rather than of the directory. The directory is made,
    and the manifest written into it, before the first output is fetched, so its
    existence is no evidence that anything is in it. Two ordinary things leave
    one half filled: a transfer interrupted part way, and a record written by
    hand. Both used to be permanent, because the question asked was whether the
    directory was there rather than whether the results were, and once it was
    there nothing looked again. A run that is half here is now simply a run with
    outputs still to fetch, and the next ask finishes it.

    What the domain said must stay on its machine does not count as absent. It is
    not coming, and counting it would refetch the whole run on every ask.
    """
    if not store.find(run):
        return None
    return [name for name, path in store.outputs(run).items()
            if not os.path.exists(path)]


def bring_back(user: str, run: str) -> bool:
    """Copy a finished run's results onto this machine, if they are not here.

    The panel reads a store on this machine and the viewer serves files from
    one, so a run that happened on a cluster was invisible in both: recorded
    against the chat, listed as finished, and then nothing to open. For a user
    whose work all runs on a cluster that was every result they had.

    Only what the domain said may leave its machine comes back, because that is
    what `collect` answers. An output that must stay put stays put, and the
    panel names it rather than showing it.
    """
    store = artifacts.ArtifactStore(paths.user_outputs_root(user))
    absent = _absent(store, run)
    if absent == []:
        return True
    with _FETCH_GUARD:
        if run in _FETCHED:
            return False                      # already in flight, or already tried
        _FETCHED.add(run)
    try:
        for site, executor in _executors(user).items():
            rec = executor.registry.get(run)
            if rec is None:
                continue
            if rec.state.value != "completed":
                # Nothing to fetch. A failed run will never have anything, so it
                # stays marked and is never asked about again; one still going
                # will, so it is unmarked and tried again when someone next
                # looks. Without this a single failed run costs a network round
                # trip on every request that so much as lists the bundles.
                if rec.state.value in LIVE:
                    with _FETCH_GUARD:
                        _FETCHED.discard(run)
                return False
            result = executor.collect(run)    # raises unless it finished cleanly
            outdir = Path(store.new_run(rec.spec.capability, rec.spec.workspace, run))
            (outdir / artifacts.MANIFEST).write_text(
                json.dumps(executor.manifest(run), indent=2))
            for name in result.outputs:
                if absent is not None and name not in absent:
                    continue          # already here; a retry only fills the gaps
                executor.fetch(run, name, str(outdir / name))
            return True
    except Exception as e:                    # noqa: BLE001 - reported, not raised
        print(f"[bring-back] {run}: {type(e).__name__}: {e}", flush=True)
        with _FETCH_GUARD:
            _FETCHED.discard(run)             # so a later attempt can retry
    return False


# Transfers run here rather than on a thread each. One thread per run is fine
# when a run finishes on its own, and it is not fine when the panel is drawn:
# every result the person has that is not on this machine yet is noticed at the
# same moment, and each one opened its own ssh. Fifty at once is not fifty
# transfers, it is a login node applying MaxStartups and refusing most of them,
# which surfaces as the cluster being unreachable and leaves the panel empty for
# the reason it was trying to fix.
#
# Two at a time, because this is a shared machine that other people are also
# reaching, and nobody is waiting on any single one of these — the work is
# already done and this is only fetching it.
_TRANSFERS = concurrent.futures.ThreadPoolExecutor(
    max_workers=2, thread_name_prefix="bring-back")


def _bring_back_later(user: str, run: str) -> None:
    """Queue the copy without holding up whatever noticed the run had finished."""
    try:
        _TRANSFERS.submit(bring_back, user, run)
    except RuntimeError:                      # interpreter shutting down
        pass


def _refresh_views(user: str, run: str) -> list:
    """Rebuild any view this run has made out of date, reported like any run.

    Reported rather than done quietly: something appearing in the results panel
    that nobody asked for is confusing, and the person is owed the reason.
    """
    try:
        import refresh
        return refresh.after(user, run)
    except Exception as e:                    # noqa: BLE001 - reported, not raised
        print(f"[refresh] {run}: {type(e).__name__}: {e}", flush=True)
        return []


def cancel(user: str, run: str) -> dict:
    """Stop a run. Whatever it already wrote stays where it is."""
    for site, executor in _executors(user).items():
        try:
            if executor.registry.get(run) is None:
                continue
            record = executor.cancel(run)
            _cache.pop(user, None)
            return {"run": run, "state": record.state.value, "detail": record.detail}
        except Exception as e:             # noqa: BLE001 - reported, not raised
            return {"run": run, "error": str(e)}
    return {"run": run, "error": "no such run"}
