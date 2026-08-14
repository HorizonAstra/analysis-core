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

import json
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


def _index(st) -> dict:
    """Every run a store holds, as run id -> (directory, manifest).

    One walk, answering for all of them. The store's own `find` walks the tree
    to answer about one run, which is right for one question and quadratic for
    a panel: a run's directory is named for the run, so the walk that finds one
    has already found all of them.
    """
    return {path.parent.name: (path.parent, manifest)
            for path, manifest in st._manifests()}


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


# ── describing a run without reading it ─────────────────────────────────
# The panel draws a collapsed list: a name, an icon, and a tooltip, per output.
# It used to get that by previewing every output of every run — opening each
# file, reading its head, counting its rows, and walking a directory output to
# the bottom. For an 89-run chat that was 4.7 seconds before anything appeared,
# spent working out what things are in order to draw a list of what they are
# called.
#
# None of it was needed. The domain already declares each output's name, type,
# format and description in its catalog entry, which is the same place `preview`
# gets them from before it goes and reads the file anyway. So a row is drawn from
# what is already written down, and the file is opened when somebody opens it.
#
# What this costs is precision in one place: the icon comes from the declared
# format rather than from the bytes. A file whose format the entry did not
# declare gets the plain document icon and opens correctly regardless, because
# `item()` still previews properly on click.

# What an output is, asked of the store rather than worked out here. The panel
# needs the answer without paying to read the file, which is exactly what
# `kind_of` is, so there is one implementation and no chance of this file and
# the store disagreeing about what a `.tsv` is.
_kind_of = artifacts.ArtifactStore.kind_of


# How many files of a directory output are named before the list is cut. A
# capability whose result is "whatever the code wrote" can write a lot, and a
# panel is a list to scan rather than a file manager.
_INSIDE_LIMIT = 60


def _listed(st, directory, manifest: dict) -> list[dict]:
    """Every openable output of a run, named and typed, with nothing read.

    A directory output is treated one of two ways, and which one is already
    written down: whether a viewer opens it.

      * A viewer's bundle is one thing. It holds tens of thousands of files
        arranged for an application to read, listing them was the slowest part
        of drawing this panel, and nobody has ever wanted to open one of them by
        hand. The viewer is offered instead, beside the row.
      * A directory with no viewer *is* its listing. That is what a capability
        whose result is "whatever the code wrote" produces, and saying only
        "results" about it answers nothing.
    """
    declared = st._declared(manifest)
    stays = st._stays(manifest)
    out = []
    for name in sorted(manifest.get("outputs", {})):
        if name in stays:
            continue
        about = declared.get(name, {})
        path = directory / name
        # One stat each, so an output that never arrived is not offered as
        # something to open. Cheap enough to be worth the accuracy: a few
        # hundred stats is well under a millisecond, and the alternative is a
        # row that answers a click with an error.
        if not path.exists():
            out.append({"name": name, "kind": "missing",
                        "what": about.get("description", "")})
            continue
        kind = _kind_of(about, name)
        if kind == "directory" and not about.get("viewer"):
            out += _inside(path, name)
            continue
        out.append({"name": name, "kind": kind,
                    "what": about.get("description", "")})
    return out


def _inside(path, prefix: str) -> list[dict]:
    """The files of a directory output, named by where they sit inside it.

    A walk rather than a read: the name and the extension are enough to draw a
    row, and what a file holds is a question for the moment somebody opens it.
    """
    found = []
    try:
        for p in sorted(path.rglob("*")):
            if p.is_file():
                found.append(p)
            if len(found) > _INSIDE_LIMIT:
                break
    except OSError:
        return []
    return [{"name": f"{prefix}/{p.relative_to(path)}",
             "kind": _kind_of({}, p.name),
             "what": ""} for p in found[:_INSIDE_LIMIT]]


# The kernel's own bookkeeping, written beside the results of every run: the list
# of what was saved, what was printed, what was marked as an answer, and the
# traceback if it stopped. Useful, and not a result. This is the whole of the
# clutter that filled the panel with rows called `saved.json`, and hiding these
# four is all that was ever needed — hiding every run of submitted code took the
# cohort tables somebody asked for with it.
_BOOKKEEPING = frozenset({"saved.json", "printed.txt", "presented.json", "error.txt"})


def _about(answers: list[dict]) -> str:
    """A heading for a run, from what it produced.

    The description the code gave, when it gave one, because that is a sentence
    written for a reader. Otherwise the file names, tidied: `metadata_cefepime`
    reads as "Metadata cefepime", which is worse than a title someone wrote and
    far better than the same word eleven times.
    """
    described = [a["description"] for a in answers if a.get("description")]
    if described:
        return described[0]
    names = [Path(a["name"]).stem.replace("_", " ").strip() for a in answers]
    names = [n for n in names if n]
    if not names:
        return ""
    head = ", ".join(names[:2]) + (f" and {len(names) - 2} more" if len(names) > 2 else "")
    return head[:1].upper() + head[1:]


def _answers(directory, manifest: dict) -> list[dict]:
    """What a run of submitted code produced that a person would want to see.

    Everything it saved, minus the bookkeeping above. Saving is the act of
    keeping something, and code that keeps a table has decided that table is
    worth keeping — so that is the default, and nothing has to be remembered for
    a result to appear.

    `present(obj, name, description)` still exists, and what it adds is the
    description and the ordering: a run that presented anything shows those
    first, said in the words the code chose. It is how a result is explained,
    not how it is made visible.

    Each row names a file inside the run's directory output, which is exactly
    what `run:<id>/<output>/<name>` addresses, so what the panel opens and what a
    later capability reads are the same thing said the same way.
    """
    rows: list[dict] = []
    for out_name in sorted((manifest.get("outputs") or {})):
        where = Path(directory) / out_name
        if not where.is_dir():
            continue
        described = {}
        marker = where / "presented.json"
        if marker.is_file():
            try:
                for entry in json.loads(marker.read_text()) or []:
                    if isinstance(entry, dict) and entry.get("name"):
                        described[entry["name"]] = entry.get("description") or ""
            except (OSError, ValueError):
                described = {}
        for name in sorted(p.name for p in where.iterdir() if p.is_file()):
            if name in _BOOKKEEPING:
                continue
            # No declaration to read: the domain never named these, because what
            # submitted code writes is not something an entry can promise. The
            # extension is all there is, and it is what `kind_of` falls back on.
            rows.append({"name": f"{out_name}/{name}",
                         "kind": _kind_of({}, name),
                         "description": described.get(name, ""),
                         "_first": name in described})
    rows.sort(key=lambda r: (not r.pop("_first"), r["name"]))
    return rows


def _run_rows(st, run_ids, prefix: str, label_prefix: str,
              user: str | None = None, owner: str | None = None) -> list[dict]:
    # Which sample each run is about, worked out once for the whole panel rather
    # than per row. `owner` rather than `user` because an admin reading someone
    # else's store has to resolve against that person's runs, not their own.
    import samples
    whose = owner or user
    sample_of = samples.by_run(whose, run_ids) if whose else {}
    # One walk of the store for the whole panel. `find` walks it to answer about
    # a single run, and this asked twice per run — once here and once inside the
    # preview — so a chat with 89 runs walked the same tree 178 times to read 89
    # files it had already found.
    held = _index(st)
    out = []
    for run in run_ids:
        found = held.get(run)
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
        # A capability that runs code written for the question shows what that
        # code presented, and nothing else. Everything it saved is kept and
        # stays readable; the panel is for what somebody asked for. Presenting
        # nothing is the ordinary case for a step whose job was to work
        # something out, and such a run is left out entirely rather than listed
        # as an empty folder.
        answers = None
        if render.is_working_material(capability):
            answers = _answers(directory, manifest)
            if not answers:
                continue
        items = answers if answers is not None else [{
            "name": o["name"],
            "kind": o.get("kind"),
            "description": o.get("what", ""),
            "ref": prefix + run,
        } for o in _listed(st, directory, manifest)]
        if answers is not None:
            for item in items:
                item["ref"] = prefix + run

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
            # A capability's title names what it does, which is the right heading
            # when the entry decides what comes out. For code written to answer
            # one question it names nothing: eleven runs all headed "Analyzing"
            # are eleven folders a person has to open to tell apart. What it
            # produced is the only thing that distinguishes them, so that is the
            # heading, and the capability's title is what it falls back to.
            "label": label_prefix + (_about(answers) if answers
                                     else render.capability_title(capability)),
            # Which sample this is about, so the panel can file it under one.
            # Empty for anything built from more than one sample or from none,
            # which the panel leaves where it is rather than inventing a group
            # to put it in.
            "sample": sample_of.get(run, ""),
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


def _seen_by(user: str, chat_id: str) -> list:
    """Which runs a chat is working with, as the versions grid decides it.

    Not "the runs this chat started". Work done on a cluster belongs to the
    person, not to the conversation they happened to ask in, so a new chat opens
    onto what they have rather than onto nothing. Which version of each thing is
    the chat's own choice, and it is made in one place.
    """
    try:
        import versions as _versions
        return _versions.visible_runs(user, chat_id)
    except Exception:                  # noqa: BLE001 - the panel must still draw
        return chats.chat_runs(user, chat_id)


def tree(user: str, chat_id: str) -> dict:
    """Every run this chat is working with, newest first, with what each one made."""
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
                              tag + "::", "" if tag == mine else tag + " · ",
                              owner=u)
        rows.sort(key=lambda r: r.get("finished") or "", reverse=True)
        return {"topics": rows}
    return {"topics": _run_rows(_store_for(user), _seen_by(user, chat_id),
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

# How a key names some of a conversation's samples rather than all of them:
#
#     chat:<id>            every sample this chat has prepared
#     chat:<id>~1N,2R      those two
#
# In the key rather than beside it, because the key is a path segment and a
# viewer's own requests are relative to it. A selection in a query string would
# be dropped by the first file the viewer asked for, and the sample it was told
# to leave out would load anyway.
#
# `~` because it survives encodeURIComponent unescaped and cannot occur in
# either half: a chat id is 32 hex characters and a sample name is a directory
# name from the study.
PICK = "~"


def _picked(key: str) -> tuple[str, set]:
    """A key split into what it names and which samples were asked for.

    An empty set means all of them, which is what a key with no selection means
    and also what an empty selection means. Opening a viewer on nothing would
    show a blank application and read as the product being broken.
    """
    if PICK not in key:
        return key, set()
    base, _, chosen = key.partition(PICK)
    return base, {s for s in chosen.split(",") if s}


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
    built for one is not a bundle for the other. And narrowed to the samples the
    key asked for, which is not only a convenience: a tissue viewer loads every
    sample it is given at once and in full, so nineteen of them is a gigabyte
    fetched before anything is drawn, and the tab dies before the person sees
    the one they wanted.
    """
    key, wanted = _picked(key)
    if not key.startswith(CHAT_KEY):
        one = bundle_for(user, key)
        return [one] if one else []
    # Read from each run's manifest rather than from the results panel's view of
    # it. The panel describes what every run produced, which for a directory
    # output means walking every file in it, and a spatial bundle is tens of
    # thousands of files. None of that is wanted here: the only question is which
    # viewer a run declared, and the manifest answers it without touching the
    # bundle at all.
    import samples
    st = _store_for(user)
    run_ids = list(reversed(_seen_by(user, key[len(CHAT_KEY):])))
    # Which sample each bundle is of, from the run that built it rather than by
    # looking inside: a bundle is built one sample at a time, and reading the
    # directory to find out would walk tens of thousands of files to learn a
    # name the run already recorded.
    sample_of = samples.by_run(user, run_ids) if wanted else {}
    out = []
    for run in run_ids:
        if wanted and sample_of.get(run) not in wanted:
            continue
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


def _viewer_kinds(user: str | None = None, within=None) -> dict:
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
    if within is not None:
        # A chat's own domains, which are narrower than what its owner may reach.
        # Someone granted two domains gets a tissue viewer offered in a chat
        # about neither, and it can only ever tell them it has nothing to open.
        allowed = set(within)
    else:
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
                    # Which capability builds one. Kept so that a viewer with
                    # nothing to open can tell "you have not run this" from "you
                    # have, and it has not reached this machine yet".
                    "capability": entry["id"],
                }
    return out


def _elsewhere(built: int) -> str:
    """Why a viewer has nothing to open when the work exists but is not here.

    A result is computed where the work runs and copied back afterwards, so
    there is a window in which it is finished, listed, and not yet openable.
    Saying nothing has produced one during that window is wrong in the way that
    costs the most: it reads as "run it again", and it is an hour of cluster
    time to learn that the answer was already on its way.
    """
    if not built:
        return ""
    return (f"{built} result{'' if built == 1 else 's'} finished, still being copied "
            f"to this machine. This opens once that lands.")


def viewers(user: str, chat_id: str) -> dict:
    """Every viewer, and the newest result in this chat that opens in it.

    Listed whether or not there is something to open, because a control that
    appears only once it works cannot be discovered before then. One that is not
    ready says what would make it ready instead of simply being absent.

    Scoped the same way the panel beside it is: what this chat is working with,
    which is its own runs and whatever the versions grid selects. Scoped to the
    runs a chat *started*, every viewer was greyed out in a new conversation
    while the grid next to it listed nineteen samples ready to open.
    """
    import viewer as _viewer
    can_serve = _viewer.installed()
    rows = tree(user, chat_id)["topics"]
    # What this chat can see, whether or not it has reached this machine. A row
    # exists only once a result has been copied back, and a viewer that says
    # "nothing has produced one yet" about work that finished last week sends
    # somebody off to run it again.
    built: dict = {}
    try:
        import versions as _versions
        seen = set(_seen_by(user, chat_id))
        for (_, capability), entries in _versions.grid(user).items():
            for v in entries:
                if v["run"] in seen:
                    built[capability] = built.get(capability, 0) + 1
    except Exception:                  # noqa: BLE001 - the list must still draw
        built = {}
    newest: dict = {}
    for r in rows:                                   # newest first, so first wins
        if r.get("viewer") and r["viewer"] not in newest:
            newest[r["viewer"]] = r
    out = []
    for kind, about in _viewer_kinds(user).items():
        hit = newest.get(kind)
        ready = bool(hit) and kind in can_serve
        # Which samples this viewer could be opened on, newest first and each
        # named once. A sample prepared twice is one thing to choose, not two.
        choices = list(dict.fromkeys(
            r["sample"] for r in rows if r.get("viewer") == kind and r.get("sample")))
        out.append({
            "viewer": kind,
            "label": about["label"],
            "ready": ready,
            # Offered so the person can open one sample instead of all of them.
            # Not a display detail: a tissue viewer fetches every sample it is
            # given in full and at once, so this is the difference between a
            # view that opens and a tab that dies.
            "choices": choices,
            # The conversation rather than the one run that happens to be
            # newest. Bundles are built a sample at a time and the viewer only
            # compares what it loaded together, so opening one run would show
            # one sample and quietly hide the other eighteen.
            "run": f"{kind}/{CHAT_KEY}{chat_id}" if ready else "",
            "samples": sum(1 for r in rows if r.get("viewer") == kind),
            # The row already names the thing, so this says why it is not
            # available rather than repeating what it is. Three reasons, and
            # they lead somewhere different: install it, wait for it, or run it.
            "why": ("" if ready else
                    "Not installed on this server." if hit else
                    _elsewhere(built.get(about.get("capability", ""), 0)) or
                    "Nothing has produced one yet. Ask for it on a sample."),
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

    # Read the one output that was asked for, and only now. The panel drew its
    # row from what the domain declared, without opening anything; this is the
    # click, so this is where the file is actually read.
    #
    # `name` is either an output or a path inside one, so the output to read is
    # its first segment. Matched against the flattened leaves first and then
    # against the outputs themselves, because a directory output is offered
    # whole when a viewer opens it and as its contents when nothing does.
    # Ask for exactly what was clicked. The store reads a file inside a
    # directory output properly when it is named; asking for the directory
    # instead returns its listing, which shows three lines of each file, and a
    # person who clicked one table got three rows of it however small it was.
    try:
        entries = st.preview(run, name, rows=_ROWS_IN_PANEL)
    except (KeyError, OSError):
        try:
            entries = st.preview(run, name.split("/", 1)[0], rows=_ROWS_IN_PANEL)
        except (KeyError, OSError):
            return {"error": "not found"}
    detailed = next((o for o in (leaf for e in entries for leaf in _leaves(e))
                     if o["name"] == name), None)
    if detailed is None:
        detailed = next((e for e in entries if e["name"] == name), None)
    if detailed is None:
        return {"error": "not found"}

    desc = detailed.get("what", "")
    out = {"name": name, "kind": detailed.get("kind"),
           "description": desc,
           "description_html": render.render_markdown(render.format_description(desc)),
           "bytes": detailed.get("bytes")}

    kind = detailed.get("kind")
    if kind == "directory":
        # A viewer's bundle. It is a directory arranged for an application to
        # read, so there is no file here to show and nothing to download; what
        # opens it is the control already sitting beside this row. Said in those
        # terms rather than handed over as a broken download link.
        n = detailed.get("file_count")
        out["view"] = "text"
        out["text"] = (f"This is a folder of {n:,} files prepared for a viewer."
                       if n else "This is a folder prepared for a viewer.") + \
                      "\n\nOpen it with the viewer offered beside this result, or " \
                      "from the Visualizers menu, where you can also choose which " \
                      "samples to load."
        out["html"] = render.render_markdown(out["text"])
        out["truncated"] = False
    elif kind == "image":
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
    # The named output only, like `item`. Serving one file used to describe
    # every output of the run first, which for a run holding a bundle meant
    # walking it to hand back something else entirely.
    try:
        entries = st.preview(run, name.split("/", 1)[0], rows=1)
    except (KeyError, OSError):
        return None, None
    entry = next((o for o in (leaf for e in entries for leaf in _leaves(e))
                  if o["name"] == name), None)
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
