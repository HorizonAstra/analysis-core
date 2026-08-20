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

import access
import chats
import paths
import render
import samples

_TREE = Path(os.environ.get("ANALYSIS_CORE", Path(__file__).resolve().parents[2]))
for _p in ("interfaces/run", "infrastructure/executors", "infrastructure"):
    if str(_TREE / _p) not in sys.path:
        sys.path.insert(0, str(_TREE / _p))

import reuse as _reuse                                        # noqa: E402
from registry import JobRegistry                              # noqa: E402
from protocol import JobState                                 # noqa: E402
from datasource.refs import AT                                # noqa: E402

# Work that spans samples sits under this instead of a sample name. Not a sample
# and not pretending to be one: a cohort is a different kind of subject, and the
# row that holds it is named for its members rather than for the word "cohort",
# because two cohorts over different samples are two different things.
ACROSS = ""

# The one column that is not a capability. Everything else in the grid is a
# result someone asked for; this is what those results were computed from, and it
# belongs in the same grid for the reason the grid exists: "which clusters am I
# looking at" and "which data were they computed from" are one question, and
# answering them in two places is how they stop agreeing.
#
# It behaves like the others on purpose. A version can be chosen, and clearing
# the cell means the same thing it means anywhere else — nothing is selected, so
# work here has to be asked for again rather than re-used.
DATA = "data"

# A domain that declares nothing about its input, so asking one that is not there
# reads the same as asking one that is.
class _Nothing:
    input_label = ""


_EMPTY = _Nothing()


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


def _is_scratch(record) -> bool:
    """Whether a run is working material rather than an answer to choose between.

    A version is one of several answers to the same question, and code written
    for one question is not that: two runs of it are two different pieces of
    work that happen to share a capability, so offering them as versions of each
    other is offering a choice that means nothing. Same rule the results panel
    uses, asked in the same place, so the two cannot come to disagree.
    """
    import render
    return render.is_working_material(record.spec.capability or "")


def applies(user: str, domains=None) -> bool:
    """Whether this chat's domains keep their work in versions.

    A domain says so itself, in its study.json, because whether versions are a
    thing here is a fact about the science and not about what happens to be on
    disk today. Spatial transcriptomics runs the same pipeline over nineteen
    samples and reruns it as parameters settle, so a person genuinely has to say
    which run is the one in play. A microbiome study is analysed once per
    question; there is nothing to choose between, and a grid offering the choice
    is a control that cannot do its job.

    Deriving this from the data instead was tried twice and was wrong both
    times. "Anything finished" showed the control to somebody with one result.
    "More than one version of something" would show it the moment a run was
    repeated, which is not the same as the domain working that way.
    """
    from datasource import domains as _domains
    chosen = list(domains) if domains else list(access.allowed_domains(user) or [])
    return any((_domains.spec(d).versioned if _domains.spec(d) else False)
               for d in chosen)


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
        if record.state is not JobState.COMPLETED or _is_scratch(record):
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


def data_grid(user: str) -> dict:
    """Cells for the data itself: per sample, the versions of its study it is in.

    Read from what each machine reported holding rather than from any run, which
    is what makes this column different from every other one. A sample nothing
    has been run on yet still gets a row, and that is the point: a study should
    appear in the grid the day it arrives, with every result cell empty and its
    data cell already answering.

    A study with no version layer still appears, as the one version it has. It
    was left out at first, on the grounds that a single entry is not a choice —
    but the column is not only a chooser. It is the left end of the row, and what
    every result to the right of it was computed from. Leaving it blank made the
    grid start at the first thing anybody ran and say nothing about what went in,
    which reads as the instrument's output being missing rather than as there
    being one of it.

    Never waits on a machine to answer. What a cluster holds is a round trip, and
    on a cold process that is half a minute; the rest of this grid is read from
    a registry on disk and takes fifty milliseconds. Making the whole card wait
    on the one column that decorates it is how a panel that was instant becomes a
    panel people stop opening. The column fills in on the next look instead.
    """
    cells: dict = {}
    for row in access.accessible_data(user, wait=False):
        # One unnamed version, for a study whose data is not kept in versions.
        # Named for the study, since that is the only true thing there is to say
        # about it, and it is what the row is about.
        kept = row.get("versions") or [{"name": "", "samples": row.get("samples") or []}]
        for version in kept:
            named = version["name"]
            for sample in version.get("samples") or []:
                cells.setdefault((sample, DATA), []).append(
                    {"identity": f"{row['study']}{AT}{named}" if named else row["study"],
                     "study": row["study"], "at": named,
                     "label": named or row["study"], "run": "", "runs": []})
    for versions in cells.values():
        versions.sort(key=lambda v: v["at"], reverse=True)
        studies = {v["study"] for v in versions}
        for n, v in enumerate(versions):
            v["ordinal"] = len(versions) - n
            # Two studies can name a sample the same, and then one cell holds
            # versions of both. Saying which study is the difference between a
            # choice and a guess.
            if len(studies) > 1:
                v["label"] = f"{v['study']} · {v['label']}"
    return cells


def visible_runs(user: str, chat_id: str) -> list:
    """Which runs a chat is working with: its own, and the version chosen per cell.

    The one answer to "what is this chat looking at", read by everything that has
    to know: the model, the results panel, and the viewers. They each used to
    answer it themselves, all three with "the runs this chat started", which is
    why a new chat opened onto nothing at all — no results, and every viewer
    greyed out — while the grid beside it listed nineteen samples of finished
    work. The work is the user's; the conversation is where it is being talked
    about, and those are different things.

    Its own runs first and in order, because a conversation follows what it
    started. Then one run per cell, which is what the grid selects: pinned to an
    older version where somebody pinned one, and absent where somebody emptied
    the cell, so emptying a cell hides the result everywhere rather than only
    from the model.
    """
    seen = list(chats.chat_runs(user, chat_id))
    known = set(seen)
    # Only from a domain that keeps versions. Work another conversation did is
    # that conversation's, and the reason to make an exception is narrow: a
    # cluster pipeline run over a study costs hours, and starting a new chat
    # about the same study should not mean running it again. That reasoning is
    # exactly what `versioned` declares, and it does not extend to a domain
    # where each question is answered once — there, another chat's tables
    # turning up is a leak, not a convenience.
    for (_, capability), cell in active(user, chat_id).items():
        run = cell.get("run")
        if not run or run in known:
            continue
        from datasource import domains as _domains
        spec = _domains.spec(render.domain_of(str(capability)))
        if not (spec and spec.versioned):
            continue
        seen.append(run)
        known.add(run)
    return seen


def data_label(user: str) -> str:
    """What to head the data column with, in the words the domain uses.

    Not written here, because "the thing every analysis starts from" has a
    different name in every domain and this file has no business knowing any of
    them. Each domain says so beside its own shapes. Only when they agree: two
    domains on screen at once have no shared word for it, and "Data" is the
    honest fallback rather than one of them borrowing the other's.
    """
    from datasource import domains as _domains
    said = {(_domains.spec(row.get("domain")) or _EMPTY).input_label
            for row in access.accessible_data(user, wait=False)}
    said.discard("")
    return said.pop() if len(said) == 1 else "Data"


def data_pins(user: str, chat_id: str) -> list[str]:
    """Which version each sample's data should be read from: `<study>/<sample>=<version>`.

    Sent to the tool server, which rewrites any reference naming that sample so
    it names the version too. In the reference rather than beside it, because the
    reference is both what the far machine resolves and what the run records as
    having read. A version kept anywhere else would leave two runs over different
    data looking identical to anything comparing what they read, which is exactly
    how re-use hands back a result built from data that has since been replaced.

    Only what was chosen. A sample nobody has chosen for reads the newest, which
    is what a bare reference already means — so sending a pin for it would change
    nothing today and pin it against tomorrow's data.
    """
    out = []
    for (subject, column), want in sorted(chosen(user, chat_id).items()):
        if column != DATA or not want or AT not in want:
            continue
        study, _, version = want.partition(AT)
        out.append(f"{study}/{subject}={version}")
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
    built = {**data_grid(user), **grid(user)}
    picked = chosen(user, chat_id)
    # Data first, and it is not sorted in with the rest. It is what everything to
    # the right of it was computed from, so reading the row left to right reads
    # in the order the work happened.
    columns = ([DATA] if any(c[1] == DATA for c in built) else []) \
        + sorted({c[1] for c in built if c[1] != DATA})
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
            # Emptying a cell means "do this again", and data is not something
            # anything can do again: it is on disk or it is not. So this column
            # offers the choice and not the clearing, rather than offering a
            # gesture that would have to be given a second meaning here.
            "clearable": capability != DATA,
            "versions": [{"identity": v["identity"], "ordinal": v["ordinal"],
                          "label": v["label"], "at": v["at"],
                          "run": v["run"], "runs": len(v["runs"])}
                         for v in versions],
        }

    return {
        "columns": columns,
        # Said rather than assumed. The client has to treat this column
        # differently in three places, and a name spelled out on both sides is a
        # name that can drift on one of them.
        "data_column": DATA,
        "data_label": data_label(user),
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
    return f"{len(upstream)} inputs" if upstream else "across samples"


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
