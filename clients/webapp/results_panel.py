"""The results panel: reading a user's work back out, and undoing it.

The unit here is a run. Something was asked for, it happened somewhere, it took
time, and it produced outputs. That is how a person remembers their own work, and
it is also what the store records, so the panel and the store agree without
anything having to be translated between them.

Two rules it enforces, both about access rather than display:

* **Everything a chat produced is the user's.** The panel shows more than what
  the model put forward: an output not mentioned in the answer is often the full
  table a presented top-30 was drawn from, and there is no version of "you cannot
  open your own results" that is correct.
* **Reads are re-authorized every time.** A regular user sees the current chat's
  runs; admin may read any user's store through an owner-prefixed ref. The check
  runs at read time rather than when the run was recorded, so what someone sees
  is governed by who they are now.

What may be read at all is not this file's decision. A domain marks an output as
unable to leave the machine it was computed on, and the store applies that, so an
output that must stay put never appears here to be asked for.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

import access
import artifacts
import paths
import render
import chats

_MIME = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
         "svg": "image/svg+xml", "webp": "image/webp", "csv": "text/csv",
         "tsv": "text/tab-separated-values", "json": "application/json", "txt": "text/plain",
         "md": "text/markdown", "markdown": "text/markdown", "html": "text/html",
         "pdf": "application/pdf", "newick": "text/plain",
         "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}

_TEXT_PREVIEW_CHARS = 200_000
_ROWS_IN_PANEL = 200
# A browser draws one element per cell, so what it can survive is a count of
# cells rather than a count of rows. Two hundred rows of a spot-by-gene matrix is
# six million of them, which does not render slowly: it takes the tab down, and
# the person loses the conversation next to it as well.
#
# Held here as well as in the store, and deliberately so. The store trims what it
# hands out and this trims what is drawn, and neither is entitled to assume the
# other did its job. A number nobody anticipated only has to get past one of them
# to cost someone their session.
_CELLS_IN_PANEL = 20_000


# ── reaching a user's store ─────────────────────────────────────────────
def _store_for(user: str):
    return artifacts.ArtifactStore(paths.user_outputs_root(user))


def _resolve(user: str, ref: str):
    """(store, run) for a ref, or (None, None).

    Admin refs are owner-prefixed (`<owner>::<run>`) so admin can reach any
    user's store; everyone else stays in their own.
    """
    if access.is_admin(user) and "::" in ref:
        owner, run = ref.split("::", 1)
        if owner in {paths.safe_user(u) for u in access.ACCESS}:
            return artifacts.ArtifactStore(os.path.join(paths.OUTPUTS_BASE, owner)), run
        return None, None
    return _store_for(user), ref


# ── what a run produced, flattened to things that can be opened ─────────
def _leaves(entry: dict, prefix: str = "") -> list[dict]:
    """One output, as the openable things inside it.

    Most outputs are a single file. A capability whose result is a directory —
    a viewer bundle, or whatever submitted code chose to save — is listed as its
    contents instead, because a folder is not something a reader can look at.
    """
    name = prefix + entry["name"]
    if entry.get("kind") != "directory":
        return [{**entry, "name": name}]
    return [leaf for child in entry.get("files", [])
            for leaf in _leaves(child, prefix=name + "/")]


def _outputs(st, run: str) -> list[dict]:
    try:
        return [leaf for entry in st.preview(run, rows=1) for leaf in _leaves(entry)]
    except (KeyError, OSError):
        return []


def _run_rows(st, run_ids, prefix: str, label_prefix: str,
              user: str | None = None) -> list[dict]:
    out = []
    for run in run_ids:
        found = st.find(run)
        if not found:
            # Finished somewhere else and not copied here yet. Start that, and
            # leave it out of this answer rather than holding the panel open for
            # a transfer; it appears on the next poll.
            if user:
                import runs as _runs
                _runs._bring_back_later(user, run)
            continue
        directory, manifest = found
        capability = manifest.get("capability", "")
        items = [{
            "name": o["name"],
            "kind": o.get("kind"),
            "description": o.get("what", ""),
            "ref": prefix + run,
        } for o in _outputs(st, run)]

        declared = st._declared(manifest)
        # An output the domain said may not leave its machine is named rather
        # than omitted. Silence there reads as the analysis having produced
        # nothing, which is a different and wrong thing to believe.
        stays = [n for n in sorted(manifest.get("outputs", {}))
                 if declared.get(n, {}).get("returnable") is False]
        # And one it says a viewer can open is offered as something to open,
        # without this file knowing which capability produced it or which
        # viewer that is.
        viewer = next((declared[n]["viewer"] for n in sorted(manifest.get("outputs", {}))
                       if declared.get(n, {}).get("viewer")), "")
        if not items and not stays:
            continue
        out.append({
            "stays": stays,
            "viewer": viewer,
            "key": prefix + run,
            "label": label_prefix + render.capability_title(capability),
            "finished": manifest.get("finished"),
            "site": manifest.get("profile"),
            # Whether the frozen surface still matched when this ran, and
            # whether the same inputs would give the same answer. A reader
            # asking "can I rely on this" is asking about the run rather than
            # about the table, and both facts are already in the manifest.
            "verified": manifest.get("freeze_check") in ("passed", "ok", True, None),
            "reproducible": bool(manifest.get("reproducible")),
            "items": items,
        })
    out.sort(key=lambda r: r.get("finished") or "", reverse=True)
    return out


def tree(user: str, chat_id: str) -> dict:
    """Every run this chat produced, newest first, with what each one made."""
    if access.is_admin(user):
        rows = []
        mine = paths.safe_user(user)
        for u in access.ACCESS:
            st = artifacts.ArtifactStore(paths.user_outputs_root(u))
            tag = paths.safe_user(u)
            # Whose work it is, said only when it is not the reader's own.
            # An admin looking at their own results does not need every row to
            # tell them who they are.
            rows += _run_rows(st, [r["run"] for r in st.runs(limit=200)],
                              tag + "::", "" if tag == mine else tag + " · ")
        rows.sort(key=lambda r: r.get("finished") or "", reverse=True)
        return {"topics": rows}
    return {"topics": _run_rows(_store_for(user), chats.chat_runs(user, chat_id),
                                "", "", user)}


def bundle_for(user: str, run: str):
    """Where a run's viewer bundle is, for someone entitled to it, else None.

    The viewer asks this and nothing else. It has no business knowing about
    stores or chats, and the entitlement question is the product's rather than
    the viewer's, so it is answered here.

    Not scoped to one chat: a bundle is opened from a link that may be followed
    long after the conversation that made it, and the run being the user's own
    is the thing that matters.
    """
    # The same unwrapping every other read here does: an admin's ref carries the
    # owner it belongs to, and a viewer link is built from exactly that ref.
    st, plain = _resolve(user, run)
    if st is None:
        return None
    if not access.is_admin(user) and plain not in set(_all_runs(user)):
        return None
    found = st.find(plain)
    if not found:
        # The viewer serves files from this machine, so a bundle built on a
        # cluster has to come here before it can be opened. Waited for rather
        # than started and abandoned: someone has just asked to look at it, and
        # an empty viewer is worse than a pause.
        import runs as _runs
        if _runs.bring_back(user, plain):
            found = st.find(plain)
    return found[0] if found else None


def _all_runs(user: str) -> list[str]:
    """Every run this user started, across their chats."""
    return [r for c in chats.list_chats(user)
            for r in chats.chat_runs(user, c["id"])]


# What a viewer key naming a whole conversation looks like. One sample per run is
# how bundles are built, and the viewer only compares samples it loaded together,
# so a person who prepared nineteen samples has nineteen views of one sample each
# and no way to see the cohort.
#
# The answer is not to build a nineteenth-of-a-gigabyte copy of all of them
# joined up. Joining directories computes nothing, and a merged artifact would
# hold a second copy of every sample and have to be rebuilt whenever any one of
# them changed. It is a question of what is served, so it is answered here.
CHAT_KEY = "chat:"


# Which bundles a key names, remembered for a moment. A viewer asks for its
# files one at a time and a spatial one asks for hundreds, and every one of those
# requests used to re-read the whole chat: each run's manifest, each output, and
# a full walk of every bundle directory to describe what was in it. So opening a
# view did that work once per file rather than once, which is slow enough to look
# broken and, because it runs on the event loop, slow enough to stop the rest of
# the app answering at all.
#
# Held briefly rather than indefinitely. What a key names changes only when a run
# finishes, and a few seconds late for a bundle that has just landed is not
# something anyone can perceive.
_BUNDLES: dict = {}
_BUNDLES_SECONDS = 5.0


def bundles_for(user: str, kind: str, key: str) -> list:
    """Every bundle directory a viewer key names, newest first."""
    import time
    now = time.monotonic()
    hit = _BUNDLES.get((user, kind, key))
    if hit and (now - hit[0]) < _BUNDLES_SECONDS:
        return hit[1]
    found = _bundles_for(user, kind, key)
    _BUNDLES[(user, kind, key)] = (now, found)
    return found


def _bundles_for(user: str, kind: str, key: str) -> list:
    """Every bundle directory a viewer key names, newest first.

    A run id names one. `chat:<id>` names every bundle of that kind the
    conversation has built, which is what "show me this study" means to the
    person asking. Newest first because a sample prepared twice should be seen
    as it is now.

    Filtered by kind, because two viewers draw different things and a bundle
    built for one is not a bundle for the other.
    """
    if not key.startswith(CHAT_KEY):
        one = bundle_for(user, key)
        return [one] if one else []
    # Read from each run's manifest rather than from the results panel's view of
    # it. The panel describes what every run produced, which for a directory
    # output means walking every file in it, and a spatial bundle is tens of
    # thousands of files. None of that is wanted here: the only question is which
    # viewer a run declared, and the manifest answers it without touching the
    # bundle at all.
    st = _store_for(user)
    out = []
    for run in reversed(chats.chat_runs(user, key[len(CHAT_KEY):])):
        found = st.find(run)
        if not found:
            continue
        directory, manifest = found
        declared = st._declared(manifest)
        viewer = next((declared[n]["viewer"] for n in sorted(manifest.get("outputs", {}))
                       if declared.get(n, {}).get("viewer")), "")
        if viewer == kind and (Path(directory) / "bundle").is_dir():
            out.append(directory)
    return out


# Words a title leaves lowercase unless they open it. Everything else takes a
# capital, which is the product's rule for anything that names a thing.
_SMALL = {"a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on",
          "or", "the", "to", "with"}


def _titled(text: str) -> str:
    """A title with its words capitalized, leaving anything already shouting."""
    words = text.split()
    return " ".join(
        w if w[:2].isupper() else
        (w.capitalize() if i == 0 or w.lower() not in _SMALL else w.lower())
        for i, w in enumerate(words))


def _viewer_kinds(user: str | None = None) -> dict:
    """Every viewer the catalog knows about: its name, what produces one, and
    which domain it belongs to.

    Read from the entries rather than listed here, so a domain that adds a
    second one appears without this file learning what it is. What each is
    called in front of a reader is the producing capability's title, which is
    already what the rest of the app calls it.

    Narrowed to the domains a user was granted when one is given. A viewer
    belongs to the science that produces it, so somebody working on microbiome
    data has no use for a tissue viewer and should not be shown a control that
    could only ever tell them it has nothing to open.

    What they were granted, not what has data on a reachable machine right now.
    Those differ the moment a cluster is unreachable, and a viewer that
    disappears because a network is down looks like the product losing a feature
    rather than the network being down. Admin is granted everything, which is
    what `None` means here.
    """
    import json
    import glob
    granted = access.allowed_domains(user) if user else None
    allowed = set(granted) if granted is not None else None
    tree_root = os.environ.get("ANALYSIS_CORE",
                               str(Path(__file__).resolve().parents[2]))
    out: dict = {}
    for path in sorted(glob.glob(os.path.join(tree_root, "domains", "*",
                                              "catalog", "*.json"))):
        try:
            entry = json.loads(Path(path).read_text())
        except (OSError, ValueError):
            continue
        domain = Path(path).parents[1].name
        if allowed is not None and domain not in allowed:
            continue
        for o in entry.get("outputs", []):
            if o.get("viewer") and o["viewer"] not in out:
                out[o["viewer"]] = {
                    "label": _titled(render.capability_title(f"{domain}/{entry['id']}")),
                    "domain": domain,
                }
    return out


def viewers(user: str, chat_id: str) -> dict:
    """Every viewer, and the newest result in this chat that opens in it.

    Listed whether or not there is something to open, because a control that
    appears only once it works cannot be discovered before then. One that is not
    ready says what would make it ready instead of simply being absent.

    Scoped to the chat, like the panel beside it. A run belongs to the
    conversation that asked for it.
    """
    import viewer as _viewer
    can_serve = _viewer.installed()
    rows = tree(user, chat_id)["topics"]
    newest: dict = {}
    for r in rows:                                   # newest first, so first wins
        if r.get("viewer") and r["viewer"] not in newest:
            newest[r["viewer"]] = r
    out = []
    for kind, about in _viewer_kinds(user).items():
        hit = newest.get(kind)
        ready = bool(hit) and kind in can_serve
        out.append({
            "viewer": kind,
            "label": about["label"],
            "ready": ready,
            # The conversation rather than the one run that happens to be
            # newest. Bundles are built a sample at a time and the viewer only
            # compares what it loaded together, so opening one run would show
            # one sample and quietly hide the other eighteen.
            "run": f"{kind}/{CHAT_KEY}{chat_id}" if ready else "",
            "samples": sum(1 for r in rows if r.get("viewer") == kind),
            # The row already names the thing, so this says why it is not
            # available rather than repeating what it is.
            "why": ("" if ready else
                    ("Nothing in this chat has produced one yet. Ask for it on a "
                     "sample." if not hit else
                     "Not installed on this server.")),
        })
    return {"viewers": out}


def running(user: str) -> dict:
    """Work still going, wherever in the conversation it was started.

    Read from the executors rather than asked of the model: a run's state is a
    fact about a machine, and spending a model turn to look it up would cost
    tokens to learn something the filesystem already knows.
    """
    import runs
    return {"running": runs.live(user)}


# ── one output ──────────────────────────────────────────────────────────
def _may_read(user: str, chat_id: str, ref: str):
    st, run = _resolve(user, ref)
    if st is None:
        return None, None
    if not access.is_admin(user) and run not in chats.chat_runs(user, chat_id):
        return None, None
    return st, run


def item(user: str, chat_id: str, ref: str, name: str) -> dict:
    """One output, shaped for inline viewing — only if this user may read it."""
    st, run = _may_read(user, chat_id, ref)
    if st is None:
        return {"error": "not found"}
    entry = next((o for o in _outputs(st, run) if o["name"] == name), None)
    if entry is None:
        return {"error": "not found"}

    # Re-read the one output that was asked for, now with enough rows to show.
    top = name.split("/", 1)[0]
    detailed = next((o for o in
                     (leaf for e in st.preview(run, top, rows=_ROWS_IN_PANEL)
                      for leaf in _leaves(e))
                     if o["name"] == name), entry)

    desc = detailed.get("what", "")
    out = {"name": name, "kind": detailed.get("kind"),
           "description": desc,
           "description_html": render.render_markdown(render.format_description(desc)),
           "bytes": detailed.get("bytes")}

    kind = detailed.get("kind")
    if kind == "image":
        out["view"] = "image"
        out["src"] = render.file_url(chat_id, ref, name)
    elif kind == "table":
        columns = detailed.get("columns", [])
        rows = detailed.get("rows", [])
        # Whichever way it is large, it is cut to something a browser can draw.
        # The true shape is reported beside it, so a table that was cut says so
        # rather than looking like a small table.
        wide = len(columns) or 1
        keep = max(1, _CELLS_IN_PANEL // wide)
        out["view"] = "table"
        out["columns"] = columns
        out["rows"] = [r[:wide] for r in rows[:keep]]
        out["shape"] = [detailed.get("row_count"),
                        detailed.get("column_count", len(columns))]
        out["truncated"] = bool(detailed.get("truncated")) or len(rows) > keep
        out["columns_truncated"] = bool(detailed.get("columns_truncated"))
    elif kind == "text":
        text = "\n".join(detailed.get("lines", []))
        if len(text) > _TEXT_PREVIEW_CHARS:
            text = text[:_TEXT_PREVIEW_CHARS] + "\n\n...(truncated; download for the full file)"
        out["view"], out["text"] = "text", text
        out["html"] = render.render_markdown(text)
        out["truncated"] = bool(detailed.get("truncated"))
    else:
        out["view"] = "file"
        out["src"] = render.file_url(chat_id, ref, name)
    return out


def file_bytes(user: str, chat_id: str, ref: str, name: str):
    """(path, media_type) for an output's bytes — only if this user may read it."""
    st, run = _may_read(user, chat_id, ref)
    if st is None:
        return None, None
    entry = next((o for o in _outputs(st, run) if o["name"] == name), None)
    if entry is None or not entry.get("path") or not os.path.isfile(entry["path"]):
        return None, None
    ext = os.path.splitext(entry["path"])[1].lstrip(".").lower()
    return entry["path"], _MIME.get(ext, "application/octet-stream")


# ── retiring runs ───────────────────────────────────────────────────────
# Undoing a turn or deleting a chat has to take that work with it, or the model
# reads it back later and answers from results the user removed. Runs are moved
# rather than deleted: the moment you want to look at what was thrown away is
# exactly the moment it is gone. The destination is outside the results tree and
# unindexed, so nothing stale is ever served and nothing is silently lost.
def retire(user: str, chat_id: str, run_ids) -> int:
    """Move a chat's run directories aside. Returns how many moved.

    Failures count as not-moved rather than raising: losing one directory is not
    a reason to fail the request that triggered the cleanup.
    """
    if not run_ids:
        return 0
    st = _store_for(user)
    dest_root = paths.retire_dir(user, chat_id)
    moved = 0
    for run in run_ids:
        found = st.find(run)
        if not found:
            continue
        src = str(found[0])
        dest = os.path.join(dest_root, os.path.relpath(src, str(st.root)))
        try:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.move(src, dest)
            moved += 1
        except OSError:
            pass
    return moved


def retire_chat(user: str, chat_id: str) -> int:
    """Everything a chat produced, on chat deletion."""
    return retire(user, chat_id, chats.chat_runs(user, chat_id))
