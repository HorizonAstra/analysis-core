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
from typing import Annotated

from pydantic import Field

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
