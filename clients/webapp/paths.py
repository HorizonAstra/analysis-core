"""Where a user's data lives on disk. One home for the user -> directory mapping.

`safe_user` used to exist twice — once in engine.py, once in store.py, byte-identical with
a comment admitting the copy. That is not a tidiness problem. This function decides the
directory name for a user's artifacts, their chat file, and their retired work, so if the
two copies ever diverged one half of the app would write `outputs/a_b` while the other
read `outputs/a-b`, and a user would silently lose access to their own results. A rule
about where data lives has to have exactly one implementation.

The roots are env-overridable so the whole layout can move onto a mounted volume without
touching code. `RETIRED_BASE` sits outside the artifact store on purpose: undone work must
not be reachable by anything that lists the store.
"""

from __future__ import annotations

import os
import uuid
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent

# One artifact store, outputs/<user>/: the data is shared read-only, but everything a user
# derives is physically their own folder. The per-user MCP server is launched with
# OUTPUTS_ROOT pointed at it, so the model can only ever write into the signed-in user's
# own store. There used to be a second tree, results/, holding copies of whatever had been
# "presented", and it was the only one the panel read — so every curated tool result and
# every intermediate was unreachable from the UI. Presentation is now a flag on an
# artifact's manifest (see provenance/results.py) and there is one place things live.
OUTPUTS_BASE = os.environ.get("OUTPUTS_ROOT") or str(_REPO / "outputs")

# where undone work goes; outside the store so nothing stale is ever served
RETIRED_BASE = os.environ.get("RETIRED_ROOT") or str(_REPO / ".retired")

# one JSON file per user, holding their chats (see store.py)
CHATS_ROOT = Path(os.environ.get("CHATS_ROOT") or (_REPO / ".userdata" / "chats"))

# Where a client keeps its record of what it submitted. One per user, for the
# same reason the artifact store is: it was a single file per site, shared by
# everyone, so one person's list of running work was everyone's, and a run id
# from it could be polled or cancelled by whoever held it. Separation is by
# filesystem rather than by filtering on read, because a filter is one forgotten
# call away from not being applied.
STATE_BASE = os.environ.get("ANALYSIS_STATE_ROOT") or str(_REPO / ".userdata" / "state")


def safe_user(user: str) -> str:
    """A user identifier as a single safe path segment.

    Email-shaped ids are the common case, so `@`, `.`, `-` and `_` pass through and
    everything else collapses to `_`. Never empty: an empty result would put a user's data
    at the root of the store.
    """
    return "".join(c if (c.isalnum() or c in "._-@") else "_" for c in user) or "user"


def user_outputs_root(user: str) -> str:
    """The artifact store for one user. What their MCP server gets as OUTPUTS_ROOT."""
    return os.path.join(OUTPUTS_BASE, safe_user(user))


def user_chats_file(user: str) -> Path:
    """The JSON file holding one user's chats."""
    return CHATS_ROOT / (safe_user(user) + ".json")


def user_state_root(user: str) -> str:
    """Where one user's run registry lives. Their MCP server gets it as ANALYSIS_STATE."""
    return os.path.join(STATE_BASE, safe_user(user))


def retire_dir(user: str, chat_id: str) -> str:
    """A fresh directory to move undone work into. The random suffix means retiring the
    same chat twice never collides, so nothing is overwritten and nothing is lost."""
    return os.path.join(RETIRED_BASE, safe_user(user), f"{chat_id}-{uuid.uuid4().hex[:8]}")
