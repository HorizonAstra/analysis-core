"""Durable model conversations: the history the model itself sees, one file per chat.

Not the same thing as the transcript in store.py, and the two are not interchangeable.
store.py keeps what the *user* sees (rendered HTML, artifact cards) so a chat can be
redrawn on reload. This keeps what the *model* sees, in the provider's own block form,
so a chat can be continued. A transcript cannot be converted into a history: the model's
blocks have to round-trip byte-exact (a thinking block carries a signature the API
verifies, a compaction block is what lets the API drop the summarized history), and none
of that survives being turned into HTML.

Kept out of the chat store on purpose. A history is large (full tool results, base64
images) and is read only on a cache miss, whereas the chat store is read on every page
load; putting them in one file would make listing chats pay for conversation bulk.

A file records the provider and model that produced it. Loading refuses on a mismatch:
Gemini blocks are not Claude blocks, and a thinking signature is bound to the model that
issued it, so replaying one under a different model is a rejected request rather than a
degraded answer.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

_ROOT = Path(os.environ.get("CONVERSATIONS_ROOT")
             or (Path(__file__).resolve().parents[1] / ".userdata" / "conversations"))


def _safe(name: str) -> str:                      # mirrors store._safe
    return "".join(c if (c.isalnum() or c in "._-@") else "_" for c in name) or "x"


def _path(user: str, cid: str) -> Path:
    return _ROOT / _safe(user) / (_safe(cid) + ".json")


def save(user: str, cid: str, provider: str, model: str, history: list) -> None:
    """Persist one chat's model history. Written to a temp file and moved into place, so a
    crash mid-write leaves the previous history intact rather than a truncated one."""
    if not history:
        return
    p = _path(user, cid)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps({"provider": provider, "model": model,
                                   "messages": history}, default=str))
        os.replace(tmp, p)
    except Exception as e:  # noqa: BLE001
        # Losing a save costs this chat its memory on the next restart; it must never cost
        # the user their turn, which has already happened by the time we get here.
        print(f"[conversation-save-failed] chat={cid} {type(e).__name__}: {e}", flush=True)


def load(user: str, cid: str, provider: str, model: str) -> list | None:
    """This chat's stored history, or None if there is none we can safely continue from.

    Returns None rather than raising for every failure mode (absent, unreadable, written
    by a different provider or model). The caller then starts the chat fresh, which is the
    behavior we already had; the point of this module is to make that the exception.
    """
    p = _path(user, cid)
    if not p.is_file():
        return None
    try:
        data = json.loads(p.read_text())
    except Exception as e:  # noqa: BLE001
        print(f"[conversation-load-failed] chat={cid} {type(e).__name__}: {e}", flush=True)
        return None
    if data.get("provider") != provider or data.get("model") != model:
        print(f"[conversation-skipped] chat={cid} stored={data.get('provider')}/"
              f"{data.get('model')} now={provider}/{model}", flush=True)
        return None
    msgs = data.get("messages")
    return msgs if isinstance(msgs, list) and msgs else None


def delete(user: str, cid: str) -> None:
    """Drop a chat's history. Called when the chat itself is deleted, so a deleted
    conversation does not leave the model's copy of it on disk."""
    try:
        _path(user, cid).unlink(missing_ok=True)
    except Exception as e:  # noqa: BLE001
        print(f"[conversation-delete-failed] chat={cid} {type(e).__name__}: {e}", flush=True)
