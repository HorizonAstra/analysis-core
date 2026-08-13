"""Which version of each thing is the one in play.

A study is worked on for weeks. A sample gets harmonised, clustered, clustered
again with a different k, and somewhere in there the instrument output is
replaced. By then "the clusters for 1N" names three different things and nobody
can say which one the last figure was drawn from.

So the work is laid out as a grid — samples down, capabilities across — and each
cell holds the versions that exist, with one of them chosen. Nothing here is a
new record: the grid is read out of the runs that already happened.

    a cell     one sample and one capability, or one member set and one
               capability for work that spans samples
    a version  an identity, not a run

That second line is the whole design. A version is everything that decides what
a run produces: the capability, its pinned kernel and images, its parameters and
what it reads, with a run reference replaced by the identity of the run it names.
Seven runs that harmonise the same sample the same way are one version, because
they are one answer. Measured on real work: 97 completed runs, 85 identities.

Keyed that way, three things fall out that a run-per-version scheme cannot give:

  * A cell offers a choice only when there is one. Seven identical runs offer
    nothing to choose between and are shown as what they are.
  * Re-use and versioning are the same question. "Has this been done" and "does
    this version exist" are one lookup, so re-use can never mint a duplicate.
  * A forced recomputation of unchanged work lands on the version it already
    had, which is the honest answer: same inputs, same code, same result.

What the model sees of any of this: nothing. The selection is a filter on which
run the data listing reports for each thing, so the model keeps naming a run the
way it always has and never learns the word version. A cleared cell is reported
with no run and a reason, so it reads as "nothing chosen" rather than as the
sample not existing.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import chats
import paths
import samples

_TREE = Path(os.environ.get("ANALYSIS_CORE", Path(__file__).resolve().parents[2]))
for _p in ("interfaces/run", "infrastructure/executors"):
    if str(_TREE / _p) not in sys.path:
        sys.path.insert(0, str(_TREE / _p))

import reuse as _reuse                                        # noqa: E402
from registry import JobRegistry                              # noqa: E402
from protocol import JobState                                 # noqa: E402

# Work that spans samples sits under this instead of a sample name. Not a sample
# and not pretending to be one: a cohort is a different kind of subject, and the
# row that holds it is named for its members rather than for the word "cohort",
# because two cohorts over different samples are two different things.
ACROSS = ""


def _sites() -> list[str]:
    return [s.strip() for s in os.environ.get("ANALYSIS_SITES", "local").split(",")
            if s.strip()]


def _records(user: str) -> dict:
    """Every run this user has, by id, across every site."""
    state = Path(paths.user_state_root(user))
    out: dict = {}
    for site in _sites():
        try:
            out.update({r.job_id: r for r in
                        JobRegistry(str(state / f"registry-{site}.json")).all()})
        except Exception:                  # noqa: BLE001 - a missing site is not fatal
            continue
    return out


def cell_of(record, sample: str) -> tuple:
    """Which cell a run belongs in: (subject, capability)."""
    return (sample or ACROSS, record.spec.capability.split("/")[-1])


def grid(user: str) -> dict:
    """Every cell, with the versions in it, newest first.

    Only completed runs. A version is something you can choose and read; one
    that failed is neither, and one still going becomes a version when it lands.
    """
    records = _records(user)
    sample_of = samples.by_run(user, list(records))
    cells: dict = {}
    for run, record in records.items():
        if record.state is not JobState.COMPLETED:
            continue
        try:
            ident = _reuse.identity(records, record.spec)
        except Exception:                  # noqa: BLE001 - an unreadable entry is not fatal
            continue
        cell = cell_of(record, sample_of.get(run, ""))
        versions = cells.setdefault(cell, {})
        # One version, and the runs that produced it. Several runs is not several
        # answers: it is the same answer computed more than once, which is worth
        # keeping visible because it is the thing re-use exists to stop.
        entry = versions.setdefault(ident, {"identity": ident, "runs": [],
                                            "parameters": dict(record.spec.parameters or {}),
                                            "inputs": dict(record.spec.inputs or {}),
                                            "at": record.submitted_at or ""})
        entry["runs"].append(run)
        if (record.submitted_at or "") > entry["at"]:
            entry["at"] = record.submitted_at or ""
    out = {}
    for cell, versions in cells.items():
        ordered = sorted(versions.values(), key=lambda v: v["at"], reverse=True)
        for v in ordered:
            v["run"] = _newest(v["runs"], records)
        out[cell] = _labelled(ordered)
    # Now that every cell is numbered, say which version of an upstream thing a
    # version was built on, rather than which run id. "on bayesspace v2" is the
    # sentence somebody choosing between two of these needs; a run id is a fact
    # about a directory and answers nothing.
    where = {run: (cell, v["ordinal"])
             for cell, versions in out.items() for v in versions for run in v["runs"]}
    for versions in out.values():
        for v in versions:
            v["label"] = _upstream_named(v["label"], where)
    return out


def _upstream_named(label: str, where: dict) -> str:
    """A label with any run id in it replaced by the version it belongs to."""
    for run, (cell, ordinal) in where.items():
        if run in label:
            label = label.replace(run, f"{cell[1]} v{ordinal}")
    return label


def _newest(runs: list, records: dict) -> str:
    """Which run of a version to hand out.

    Newest, because when the same answer was computed several times the most
    recent copy is the one least likely to have been tidied away since.
    """
    return max(runs, key=lambda r: records[r].submitted_at or "")


def _labelled(ordered: list) -> list:
    """Version rows, each carrying what makes it different from its siblings.

    A timestamp says when and never says what, which is the question somebody
    choosing between two versions actually has. So the label is whatever differs
    across the versions of this cell — a parameter that changed, or the version
    of something upstream — and time is left as the tiebreaker rather than made
    the name.
    """
    if len(ordered) < 2:
        for n, v in enumerate(ordered):
            v["ordinal"] = len(ordered) - n
            v["label"] = ""
        return ordered
    keys = sorted({k for v in ordered for k in v["parameters"]})
    varies = [k for k in keys
              if len({str(v["parameters"].get(k)) for v in ordered}) > 1]
    for n, v in enumerate(ordered):
        v["ordinal"] = len(ordered) - n
        # A parameter one version set and another did not is a difference worth
        # naming, and the one that did not set it took the default. Saying so
        # beats falling through to a timestamp, which describes neither.
        parts = [f"{k}={v['parameters'][k]}" if k in v["parameters"]
                 else f"{k}=default" for k in varies]
        if not parts:
            # Same parameters throughout, so what differs is what it was built
            # from. Named by the run rather than left blank: blank rows in a
            # chooser are indistinguishable, which is the one thing a chooser
            # may not be.
            upstream = sorted(x.split("/")[0].replace("run:", "")
                              for x in v["inputs"].values()
                              if isinstance(x, str) and x.startswith("run:"))
            parts = [f"on {upstream[0]}"] if upstream else [v["at"][:16].replace("T", " ")]
        v["label"] = " · ".join(parts)
    return ordered


# ── what is chosen ──────────────────────────────────────────────────────
# Kept against the conversation rather than against the user. Two chats can sit
# on different versions without disturbing each other, which is the same rule the
# results panel follows, and it means changing what you are looking at in one
# place cannot silently change somebody else's answer in another.
def _key(cell: tuple) -> str:
    return f"{cell[0]}::{cell[1]}"


def panel(user: str, chat_id: str) -> dict:
    """The grid, shaped for drawing: rows, columns, and what is in each cell.

    Two sections, because they hold two kinds of subject. Samples are rows of the
    first. Work that spans samples cannot share that axis — a cohort is not a
    sample, and two cohorts over different sample sets are two different things —
    so it gets its own rows, named for what went into each version rather than
    for the word cohort.
    """
    built = grid(user)
    picked = chosen(user, chat_id)
    columns = sorted({c[1] for c in built})
    rows = sorted({c[0] for c in built if c[0]})

    def cell(subject: str, capability: str) -> dict:
        versions = built.get((subject, capability))
        if not versions:
            return {"versions": []}
        want = picked.get((subject, capability))
        active_id = ("" if want == "" else
                     (want if any(v["identity"] == want for v in versions)
                      else versions[0]["identity"]))
        return {
            "active": active_id,
            "cleared": want == "",
            "newest": versions[0]["identity"],
            "versions": [{"identity": v["identity"], "ordinal": v["ordinal"],
                          "label": v["label"], "at": v["at"],
                          "run": v["run"], "runs": len(v["runs"])}
                         for v in versions],
        }

    return {
        "columns": columns,
        "rows": [{"subject": s, "label": s,
                  "cells": {c: cell(s, c) for c in columns}} for s in rows],
        # Named for its members, which is the only honest answer to "what is
        # this row". Empty today, and that is the truth rather than a gap.
        "across": [{"subject": ACROSS, "label": _members(built, c),
                    "cells": {c: cell(ACROSS, c)}}
                   for c in columns if (ACROSS, c) in built],
    }


def _members(built: dict, capability: str) -> str:
    """What a cross-sample version was built out of, said as its members."""
    versions = built.get((ACROSS, capability)) or []
    if not versions:
        return "across samples"
    upstream = [x for x in versions[0]["inputs"].values()
                if isinstance(x, str) and x.startswith("run:")]
    return f"across {len(upstream)} inputs" if upstream else "across samples"


def chosen(user: str, chat_id: str) -> dict:
    """The versions this chat has picked, as cell -> identity or "" for cleared.

    Absent means nothing has been picked, which is not the same as cleared: the
    first is "newest, because nobody said otherwise" and the second is "none, on
    purpose".
    """
    c = chats.get_chat(user, chat_id) if hasattr(chats, "get_chat") else None
    picked = (c or {}).get("versions") or {}
    return {tuple(k.split("::", 1)): v for k, v in picked.items()
            if "::" in k}


def active(user: str, chat_id: str) -> dict:
    """One run per cell, as the model should be told about it.

    The whole of versioning, as far as anything outside this file is concerned.
    A cell resolves to the run of its chosen version, to the newest when nothing
    was chosen, or to nothing when it was cleared on purpose — and the third is
    reported rather than omitted, so what reads it can tell "you have not run
    this" from "this sample does not exist".
    """
    picked = chosen(user, chat_id)
    out = {}
    for cell, versions in grid(user).items():
        want = picked.get(cell)
        if want == "":
            out[cell] = {"run": "", "why": "cleared, so nothing is selected"}
            continue
        hit = next((v for v in versions if v["identity"] == want), None) if want else None
        chosen_version = hit or (versions[0] if versions else None)
        if chosen_version:
            out[cell] = {"run": chosen_version["run"],
                         "identity": chosen_version["identity"],
                         "newest": chosen_version is versions[0]}
    return out
