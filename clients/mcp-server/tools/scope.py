"""Narrowing one server to the studies one conversation is about.

A user gets their own server, launched with their allowlist, and nothing outside
it exists in that process. That is the boundary between people and it is not
this. This is the boundary between one person's conversations: a chat is opened
about some studies, and the work in it should reach those and not the others.

That boundary was described and never enforced. The web app called a tool of
this name every turn, the tool did not exist, the call was skipped by a guard
that treats its absence as acceptable, and the only thing left holding the line
was a sentence in the standing brief asking the model to stay within scope. A
chat about one study could read any study its owner had.

Narrowing only. The set this is given is intersected with the one the server was
launched with, so a call naming studies the user cannot see grants nothing, and
a call naming none of them leaves a scope that allows nothing rather than
everything. Widening is not a thing this can express.

Not offered to the model. The client drives it at the start of every turn, and
the model is handed the tool list with this one removed: a conversation that
could set its own scope does not have one.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Annotated

from pydantic import Field

_TREE = Path(__file__).resolve().parents[3]
if str(_TREE / "infrastructure") not in sys.path:
    sys.path.insert(0, str(_TREE / "infrastructure"))

if str(_TREE / "interfaces" / "naming") not in sys.path:
    sys.path.insert(0, str(_TREE / "interfaces" / "naming"))

import reference as _reference                                 # noqa: E402
from datasource.refs import AT, study_parts                    # noqa: E402

# What this server was launched with, read once. Read live instead and each call
# would narrow against the result of the last one, so a chat about one study
# would ratchet the server down and the next chat would inherit it.
_OUTER_STUDIES = os.environ.get("ALLOWED_STUDIES")
_OUTER_DOMAINS = os.environ.get("ALLOWED_DOMAINS")

# Which runs one conversation may see. Not an allowlist of the same kind: there
# is no outer set to intersect with, because a user's whole store is theirs and
# the narrowing here is by conversation rather than by person.
#
# A store outlives the conversation that filled it, so without this the model is
# handed every run its user has ever made, in any chat, growing with use. That
# is not only someone else's conversation showing through; it is a listing that
# gets longer and less relevant every week, and a model reading it spends its
# attention deciding which of forty results is the one being discussed.
#
# Unset means unrestricted, which is a person at a terminal with one store and
# no conversations. Set and empty means nothing yet, which is a new chat.
CLEARED_CELLS = "CLEARED_CELLS"
ALLOWED_RUNS = "ALLOWED_RUNS"

# Which version of its data each sample is read from, as `<study>/<sample>=<version>`.
# Set by the client from what the person chose in the grid, and applied where a job
# is built, so a reference the model wrote without a version gets the chosen one.
#
# The model is never told any of this and has no way to ask. It has one set of
# data, it names a study and a sample the way it always has, and which version
# that is is not its question.
DATA_VERSIONS = "DATA_VERSIONS"


def allowed_runs() -> set[str] | None:
    """The runs in scope, or None where nothing narrowed them."""
    v = os.environ.get(ALLOWED_RUNS)
    if v is None:
        return None
    return {s.strip() for s in v.split(",") if s.strip()}


def also_allow(run: str) -> None:
    """Bring a run just submitted into scope, so this turn can go on to use it.

    The scope is set once when a turn starts, and a run submitted during that
    turn is not in it. Without this a model that starts an analysis cannot then
    ask what state it is in, which reads to it as the run having vanished.
    """
    if os.environ.get(ALLOWED_RUNS) is None or not run:
        return
    now = allowed_runs() or set()
    os.environ[ALLOWED_RUNS] = ",".join(sorted(now | {run}))


def at_chosen_version(value):
    """One input, with the version of the data the person chose written into it.

    The model names `study:<study>/<sample>` and never learns there is anything
    else to say. Which version of that data is in play is the person's choice,
    made in the grid, and it is applied here — at the moment a job is built —
    rather than put in the prompt, because a model that had to carry it would
    sometimes not.

    Written into the reference rather than kept beside it. The reference is both
    what the far machine resolves and what the run records as having read, so a
    version anywhere else leaves two runs over different data looking identical
    to anything comparing their inputs. That is exactly how re-use hands back a
    result computed from data that has since been replaced, and putting the
    version here is what closes it: nothing in re-use had to change, because it
    already folds the reference in as written.

    Here rather than beside one of the two tools that build jobs, because both of
    them do. A capability called on its own goes through one, a whole chain goes
    through the other, and a pin that only the first one honoured would be a pin
    that works until somebody asks for the chain.

    A reference that already names a version is left alone. Somebody who said
    which one they meant has said it.
    """
    text = str(value)
    if not text.startswith("study:") or AT in text.split("/", 1)[0]:
        return value
    parts = study_parts(text)
    if len(parts) < 2:
        return value
    version = data_versions().get(f"{parts[0]}/{parts[1]}")
    if not version:
        return value
    return f"study:{parts[0]}{AT}{version}/" + "/".join(parts[1:])


def was_cleared(qualified: str, inputs: dict, parameters: dict,
                subject: str = "") -> bool:
    """Whether the person emptied this cell, meaning: do it again.

    The grid names a cell `<subject>::<capability>`, and the subject of a run is
    the sample it is about. A caller that already knows says so; otherwise it is
    worked out by following what the run reads back to the data.

    Where even that cannot say — work built from several samples, or from a run
    this account no longer holds — the ask is honoured. Being wrong that way
    costs a recomputation of work that was going to be handed back; being wrong
    the other way ignores somebody who explicitly asked for it to be done again
    and leaves them no way to ask at all.

    Beside the version pins, and for the same reason they are here: a job is
    built in two places. Emptying a cell used to reach the one that runs a single
    capability and not the one that runs a chain, so the button worked until
    somebody asked for something that needed two steps — which is most of the
    interesting questions.
    """
    cells = {c for c in os.environ.get(CLEARED_CELLS, "").split(",") if c}
    if not cells:
        return False
    capability = qualified.split("/")[-1]
    mine = {c for c in cells if c.endswith(f"::{capability}")}
    if not mine:
        return False
    subjects = set()
    if subject:
        subjects.add(str(subject))
    else:
        # Followed back through the runs it reads, rather than read off its own
        # inputs. Most steps name no sample at all — they name the step before —
        # and giving up there meant every cleared cell of a capability counted
        # for every sample: emptying one sample's markers recomputed markers for
        # all nineteen, at seven minutes each.
        found = _reference.subject(inputs or {}, _run_inputs().get, _role_names())
        if found:
            subjects.add(found)
    for key in ("sample", "sample_id"):
        if (parameters or {}).get(key):
            subjects.add(str(parameters[key]))
    if not subjects:
        return True                     # cannot tell whose it is; honour the ask
    return any(f"{s}::{capability}" in mine for s in subjects)


def _run_inputs() -> dict:
    """Every run this account has, as its id -> the references it was given.

    Read from the registry files rather than asked of a machine: the question is
    what was submitted, and a cluster being unreachable is no reason to be unable
    to answer it.
    """
    from pathlib import Path as _Path
    out: dict = {}
    state = _Path(os.environ.get("ANALYSIS_STATE", _Path.home() / ".analysis-core"))
    for site in (s.strip() for s in
                 os.environ.get("ANALYSIS_SITES", "local").split(",") if s.strip()):
        try:
            import json
            records = json.loads((state / f"registry-{site}.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(records, dict):
            continue
        for run, record in records.items():
            got = ((record or {}).get("spec") or {}).get("inputs")
            if isinstance(got, dict):
                out[run] = got
    return out


def _role_names() -> frozenset:
    """The role names, so `study:<name>/<role>` is never read as a sample."""
    try:
        from datasource import domains as _domains
        return _domains.role_names()
    except Exception:                  # noqa: BLE001 - a role read as a sample
        return frozenset()             # only ever costs a recomputation


def data_versions() -> dict:
    """The chosen versions, as `<study>/<sample>` -> version.

    Read from the environment on every call rather than once, because the client
    sets it per turn and this process outlives the turn.
    """
    out = {}
    for pin in os.environ.get(DATA_VERSIONS, "").split(","):
        where, _, version = pin.strip().partition("=")
        if where and version:
            out[where] = version
    return out


def _outer(value: str | None) -> set[str] | None:
    """The launch allowlist as a set, or None where nothing was restricted."""
    if value is None or value.strip().lower() in ("*", "all"):
        return None
    return {s.strip() for s in value.split(",") if s.strip()}


def _narrow(asked: str, outer: set[str] | None) -> str:
    """What to set, given what was asked for and what was already permitted.

    An empty ask means no narrowing, which is what a caller with nothing to say
    about scope means by saying nothing. It is not the same as asking for
    nothing, and the data layer reads an empty allowlist as allowing nothing, so
    the two must not collapse into each other here.
    """
    wanted = {s.strip() for s in asked.split(",") if s.strip()}
    if not wanted:
        return "" if outer is None else ",".join(sorted(outer))
    if outer is not None:
        wanted &= outer
    # A scope that intersects to nothing stays nothing. Falling back to the
    # outer set would turn a request that granted nothing into full access.
    return ",".join(sorted(wanted))


def register(mcp) -> list[str]:
    """Offer the scope tool, when the client says it drives it."""
    if not os.environ.get("ENABLE_SCOPE_TOOL"):
        return []

    def set_study_scope(
        studies: Annotated[str, Field(
            description="Comma separated study names this conversation is about.")] = "",
        domains: Annotated[str, Field(
            description="Comma separated domains, where the conversation is about "
                        "fewer than the ones this server was launched with.")] = "",
        runs: Annotated[str, Field(
            description="Comma separated run ids this conversation has produced. "
                        "Always sent, empty for a conversation that has produced "
                        "none, since empty and absent mean different things.")] = "",
        cleared: Annotated[str, Field(
            description="Comma separated <subject>::<capability> cells the person "
                        "has emptied in the versions grid. Work matching one of "
                        "these is computed again rather than re-used, because "
                        "emptying a cell is how somebody asks for that.")] = "",
        data: Annotated[str, Field(
            description="Comma separated <study>/<sample>=<version> pins. A "
                        "reference naming that sample is resolved against that "
                        "version of the data rather than the newest.")] = "",
    ) -> str:
        """Narrow this server to the studies a conversation is about.

        Only ever narrows, within what the server was launched with.
        """
        os.environ[ALLOWED_RUNS] = ",".join(
            sorted({r.strip() for r in runs.split(",") if r.strip()}))
        # Sent every turn like runs, and for the same reason: a cell that was
        # cleared and then filled again has to stop being cleared, and only a
        # value that is always sent can say so.
        os.environ[CLEARED_CELLS] = ",".join(
            sorted({c.strip() for c in cleared.split(",") if c.strip()}))
        # Also every turn, and also for that reason: a pin that was removed has
        # to stop being a pin, and the way to say so is to send the set without it.
        os.environ[DATA_VERSIONS] = ",".join(
            sorted({d.strip() for d in data.split(",") if d.strip()}))
        outer_s, outer_d = _outer(_OUTER_STUDIES), _outer(_OUTER_DOMAINS)
        now_s = _narrow(studies, outer_s)
        if studies.strip() or outer_s is not None:
            os.environ["ALLOWED_STUDIES"] = now_s
        else:
            os.environ.pop("ALLOWED_STUDIES", None)
        now_d = _narrow(domains, outer_d)
        if domains.strip() or outer_d is not None:
            os.environ["ALLOWED_DOMAINS"] = now_d
        else:
            os.environ.pop("ALLOWED_DOMAINS", None)
        return (f"scope: {now_s or 'nothing'}"
                + (f"; domains: {now_d}" if now_d else ""))

    mcp.add_tool(set_study_scope, name="set_study_scope",
                 description=("Narrow this server to the studies one conversation is "
                              "about. Driven by the client, not by the model."))
    return ["set_study_scope"]
