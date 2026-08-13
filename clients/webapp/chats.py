"""Per-user chat persistence — minimal, file-based.

One JSON file per user under CHATS_ROOT, holding their chats: each chat's messages (for
display on reload) and which result artifacts belong to it (for per-chat results scoping).
Enough to survive restarts; a database swaps in behind these functions later.

Note: this is the *display* history. The model's own history (native provider blocks)
lives in conversations.py, one file per chat, and is what lets a chat be continued after a
restart. The two are deliberately separate and are not convertible: this one holds
rendered HTML for redrawing the page, while the model's blocks have to round-trip
byte-exact to be replayed.
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from pathlib import Path

import paths

_ROOT = paths.CHATS_ROOT
_LOCK = threading.Lock()


def _now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def _path(user: str) -> Path:
    # the user -> directory rule lives in paths.py; a second copy here is how a user ends
    # up with their chats under one spelling and their artifacts under another
    return paths.user_chats_file(user)


def _load(user: str) -> dict:
    """This user's chats. A file we cannot read is quarantined rather than ignored.

    Every writer here is read-modify-write, so treating an unreadable file as "no chats"
    means the next write persists that emptiness: one bad read silently destroys the
    user's entire history, with no error anywhere. Renaming the file aside keeps the bytes
    recoverable and makes the loss visible in the log instead of invisible on disk.
    """
    p = _path(user)
    if not p.is_file():
        return {"chats": []}
    try:
        data = json.loads(p.read_text())
    except Exception as e:  # noqa: BLE001
        quarantine = p.with_suffix(f".corrupt-{int(time.time())}.json")
        try:
            os.replace(p, quarantine)
        except Exception:  # noqa: BLE001
            pass
        print(f"[store] unreadable chat file for {user} ({type(e).__name__}: {e}); "
              f"moved to {quarantine.name} and starting empty", flush=True)
        return {"chats": []}
    return data if isinstance(data, dict) and isinstance(data.get("chats"), list) else {"chats": []}


def _save(user: str, data: dict) -> None:
    _ROOT.mkdir(parents=True, exist_ok=True)
    tmp = _path(user).with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, default=str))
    os.replace(tmp, _path(user))


def _find(data: dict, cid: str) -> dict | None:
    return next((c for c in data["chats"] if c["id"] == cid), None)


def list_chats(user: str) -> list[dict]:
    with _LOCK:
        data = _load(user)
    chats = sorted(data["chats"], key=lambda c: c.get("updated_at", ""), reverse=True)
    return [{"id": c["id"], "title": c.get("title") or "New chat", "updated_at": c.get("updated_at")}
            for c in chats]


def create_chat(user: str, title: str = "New chat") -> str:
    with _LOCK:
        data = _load(user)
        cid = uuid.uuid4().hex
        data["chats"].append({"id": cid, "title": title, "created_at": _now(),
                              "updated_at": _now(), "messages": [], "runs": []})
        _save(user, data)
    return cid


def get_chat(user: str, cid: str) -> dict | None:
    with _LOCK:
        return _find(_load(user), cid)


def delete_chat(user: str, cid: str) -> None:
    with _LOCK:
        data = _load(user)
        data["chats"] = [c for c in data["chats"] if c["id"] != cid]
        _save(user, data)


def rename_chat(user: str, cid: str, title: str) -> None:
    with _LOCK:
        data = _load(user)
        c = _find(data, cid)
        if not c:
            return
        new = (title or "").strip()[:80]
        if new:
            c["title"] = new
            c["updated_at"] = _now()
            _save(user, data)


def append_message(user: str, cid: str, msg: dict, set_title_from: str | None = None) -> None:
    with _LOCK:
        data = _load(user)
        c = _find(data, cid)
        if not c:
            return
        c["messages"].append(msg)
        c["updated_at"] = _now()
        if set_title_from and (c.get("title") in (None, "", "New chat")):
            c["title"] = set_title_from.strip()[:60] or "New chat"
        _save(user, data)


def add_runs(user: str, cid: str, run_ids) -> None:
    """Record which runs this chat started.

    A run rather than a file: one run may produce a table, a figure and a note,
    and they belong to the chat together because they came from one thing the
    user asked for. What each one produced is the store's to say, not this
    file's, so nothing here has to be kept in step with what a capability emits.
    """
    with _LOCK:
        data = _load(user)
        c = _find(data, cid)
        if not c:
            return
        have = {r["run"] for r in c.get("runs", [])}
        at = len(c.get("messages", []))     # the point in the thread that started it
        for run in run_ids:
            if run not in have:
                c.setdefault("runs", []).append({"run": run, "at": at})
                have.add(run)
        c["updated_at"] = _now()
        _save(user, data)


def truncate_messages(user: str, cid: str, index: int) -> list[dict]:
    """Drop the message at `index` and everything after it.

    Editing a message rewrites history from that point: the turns that followed were
    answers to the old text and would be incoherent under the new one. Kept deliberately
    linear — one thread, no branches — so what is on screen is always exactly what the
    model was told. Returns the artifact records that went with the removed turns, for the
    caller to retire.""" 
    with _LOCK:
        data = _load(user)
        c = _find(data, cid)
        if not c:
            return
        cut = max(0, index)
        c["messages"] = c.get("messages", [])[:cut]
        # Artifacts produced by the removed turns go with them. Left behind, the model
        # reads them back on the next turn and answers from results the user just undid,
        # which is worse than losing them: the transcript and the reasoning disagree.
        kept, dropped = [], []
        for a in c.get("artifacts", []):
            (kept if a.get("at", 0) < cut else dropped).append(a)
        c["artifacts"] = kept
        c["updated_at"] = _now()
        _save(user, data)
    return dropped


def set_chat_studies(user: str, cid: str, studies: list[str] | None) -> None:
    """Set which studies a chat is scoped to. None (or an empty list) means every study
    the user can access, which is the default a new chat starts from."""
    with _LOCK:
        data = _load(user)
        c = _find(data, cid)
        if not c:
            return
        if studies:
            c["studies"] = sorted({str(s) for s in studies})
        else:
            c.pop("studies", None)
        c["updated_at"] = _now()
        _save(user, data)


def chat_studies(user: str, cid: str) -> list[str] | None:
    """The chat's stored study selection, or None for "everything I can access". The
    caller still intersects this with live access: a selection saved before access
    changed must never grant more than the user has now."""
    c = get_chat(user, cid)
    return (c or {}).get("studies") or None


def set_chat_domains(user: str, cid: str, domains: list[str] | None) -> None:
    """Set the domains a chat works in. Chosen once, at the start, and not changed after:
    the domains decide the standing context the model was briefed with, so switching them
    mid-conversation would leave earlier turns briefed on a different data shape. Empty or
    None clears the choice, which is the state a chat starts in."""
    with _LOCK:
        data = _load(user)
        c = _find(data, cid)
        if not c:
            return
        if domains:
            c["domains"] = sorted({str(d) for d in domains})
        else:
            c.pop("domains", None)
        c.pop("domain", None)          # supersedes the single-domain field
        c["updated_at"] = _now()
        _save(user, data)


def chat_domains(user: str, cid: str) -> list[str] | None:
    """The chat's stored domains, or None if none were chosen. Chats saved before domains
    could be plural carry a single `domain` string; it is read as a one-element list so an
    existing conversation keeps working. As with studies, the caller intersects this with
    live access rather than trusting it."""
    c = get_chat(user, cid) or {}
    if c.get("domains"):
        return list(c["domains"])
    return [c["domain"]] if c.get("domain") else None


def record_usage(user: str, cid: str, usage: dict) -> None:
    """Accumulate one turn's token usage onto the chat record.

    Tokens are stored, not money: prices change and vary per model, so the durable
    record is the count and any costing is done at read time. `turns` counts the user
    turns that contributed, which is what makes an average per turn meaningful.
    """
    if not usage:
        return
    with _LOCK:
        data = _load(user)
        c = _find(data, cid)
        if not c:
            return
        total = c.setdefault("usage", {})
        for field, count in usage.items():
            total[field] = total.get(field, 0) + int(count or 0)
        total["turns"] = total.get("turns", 0) + 1
        c["updated_at"] = _now()
        _save(user, data)


def chat_runs(user: str, cid: str) -> list[str]:
    """The runs this chat started, oldest first."""
    c = get_chat(user, cid)
    return [r["run"] for r in (c.get("runs", []) if c else [])]


def runs_untold(user: str, cid: str) -> list[str]:
    """Runs whose outcome the model has not been told about yet.

    A run outlives the turn that started it, so the model that submitted it is
    long done by the time it lands. Rather than have the model ask repeatedly
    whether it has finished — which spends a turn per question to learn
    something the machine already knows — the outcome is carried into the next
    turn as a fact. This is which ones are still owed.
    """
    c = get_chat(user, cid)
    return [r["run"] for r in (c.get("runs", []) if c else []) if not r.get("told")]


def mark_told(user: str, cid: str, run_ids) -> None:
    """Record that the model has been given these outcomes, so it is told once."""
    ids = set(run_ids)
    if not ids:
        return
    with _LOCK:
        data = _load(user)
        c = _find(data, cid)
        if not c:
            return
        for r in c.get("runs", []):
            if r["run"] in ids:
                r["told"] = True
        _save(user, data)
