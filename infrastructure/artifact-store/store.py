"""Where results live, and how to ask what has been run.

Every run of every capability lands in one place, in one layout, with the record
that `run.py` already writes beside its outputs. Before this there were three
answers to "what produced this": a manifest per run here, a manifest per
artifact there, and a tab-separated log somewhere else. None could read
another's, so a result that crossed two of them had no single record.

There is deliberately no index file. What has been run is derived by reading the
manifests, so the answer cannot drift from the thing it describes. An index that
disagrees with the tree is worse than a scan that takes a moment, and the same
reasoning puts the code root in the catalog entry rather than in a config.

Layout, under a root the site names:

    <root>/<workspace>/<domain>/<capability>/<when>-<id>/
        run_manifest.json     what ran, from what, with which digests
        <output>              one file per declared output

The store also allocates that directory, which is why `submit` does not take an
output path. A caller naming its own destination is how results end up scattered
across whatever directory someone happened to be in, and that is precisely the
state this replaces.

It is usable as a command, so an executor working over ssh allocates a directory
by calling this on the far side rather than by reimplementing the layout:

    store.py --new-run <capability> [--workspace W] [--root R]
    store.py --list [--workspace W] [--capability C] [--limit N]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

_TREE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_TREE / "interfaces" / "catalog"))
import entry as C

# How a reference is read, and which sample a piece of work is about. An
# interface, because it is vocabulary rather than machinery: it depends on
# nothing, every partition speaks it, and this file has to speak it over ssh
# under whatever python3 a cluster provides, with no data layer to import.
sys.path.insert(0, str(_TREE / "interfaces" / "naming"))
import reference as _reference

MANIFEST = "run_manifest.json"


def _slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", str(s)).strip("-") or "unnamed"


class ArtifactStore:
    def __init__(self, root: str | Path):
        self.root = Path(os.path.expandvars(str(root))).expanduser()
        # What each run read, remembered while one listing runs. A chain asks for
        # the run below it, and a listing walks every step of every chain.
        self._read_cache: dict = {}

    # --- writing ----------------------------------------------------------
    def new_run(self, capability: str, workspace: str = "default",
                run_id: str | None = None) -> Path:
        """A fresh directory for one run. The store decides where, not the caller.

        The caller may name it, and an executor always does, passing the handle
        it gave back to whoever submitted. One run then has one identifier
        everywhere: in a client holding the handle, in the directory on disk, and
        in anything that later asks the store about it. Two identifiers for the
        same run means every reader needs a translation, and the one that forgets
        reports the run as missing rather than as a mistake.
        """
        domain, cap = (capability.split("/", 1) if "/" in capability
                       else ("unfiled", capability))
        when = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        name = _slug(run_id) if run_id else f"{when}-{uuid.uuid4().hex[:6]}"
        d = self.root / _slug(workspace) / _slug(domain) / _slug(cap) / name
        d.mkdir(parents=True, exist_ok=True)
        return d

    # --- reading ----------------------------------------------------------
    def _manifests(self, workspace: str | None = None):
        base = self.root / _slug(workspace) if workspace else self.root
        if not base.exists():
            return
        for path in sorted(base.rglob(MANIFEST), reverse=True):
            try:
                yield path, json.loads(path.read_text())
            except (OSError, json.JSONDecodeError):
                continue      # a run that died mid-write is not a reason to fail a listing

    @staticmethod
    def _same_capability(asked: str, recorded: str) -> bool:
        """Whether a filter names the capability a manifest recorded.

        One capability is spelled three ways by the time it reaches here: bare
        in the manifest, qualified by its domain in a catalog, and joined with
        an underscore as a tool name. A caller holding a tool reaches for the
        spelling it is holding, and matching only one of the three answered
        "nothing has ever been run" for a capability with a hundred runs, which
        is worse than an error because it is believable.
        """
        last = lambda s: s.replace("/", " ").replace("_", " ").split()[-1]   # noqa: E731
        return asked == recorded or asked.endswith(recorded) or last(asked) == last(recorded)

    @staticmethod
    def _on(manifest: dict) -> list[str]:
        """What a run was run on, in as few words as name it.

        A listing that says a bundle exists and not which sample it is for
        leaves the only question worth asking unanswered, and the next move is
        to build a second one. Derived from the inputs the manifest already
        records: the folder each came from, which for data kept per sample is
        the sample.
        """
        seen: list[str] = []
        for spec in (manifest.get("inputs") or {}).values():
            path = str((spec or {}).get("path") or "").rstrip("/")
            if not path:
                continue
            name = path.rsplit("/", 2)[-2] if "/" in path else path
            if name and name not in seen:
                seen.append(name)
        return seen[:4]

    def _reads(self, run: str):
        """What one finished run was given, by its id, or None if it is not here.

        Cached for the length of a listing, because a chain asks for the run
        below it and a listing walks the whole chain for every step of it.
        """
        if run in self._read_cache:
            return self._read_cache[run]
        found = None
        for path, m in self._manifests():
            if path.parent.name == run:
                found = self._referenced(m)
                break
        self._read_cache[run] = found
        return found

    def _referenced(self, manifest: dict) -> dict:
        """A run's inputs as references, however the manifest recorded them.

        Runs made since the manifest carried the reference say what they read
        outright. Older ones recorded only the path it resolved to, so the
        reference is reconstructed: a path inside this store is an earlier run,
        and anything else is data, whose enclosing folder is the sample where
        data is kept per sample. Reconstructed rather than given up on, because
        the results that exist now are the ones people are asking about.
        """
        out = {}
        for name, spec in (manifest.get("inputs") or {}).items():
            spec = spec or {}
            if spec.get("ref"):
                out[name] = spec["ref"]
                continue
            path = str(spec.get("path") or "").rstrip("/")
            if not path:
                continue
            inside = self._within_root(path)
            out[name] = (f"run:{inside}" if inside else
                         f"study:_/{path.rsplit('/', 2)[-2]}" if "/" in path else path)
        return out

    def _within_root(self, path: str) -> str:
        """The run a path belongs to, when the path is one of this store's own."""
        try:
            rel = Path(path).resolve().relative_to(self.root.resolve())
        except (ValueError, OSError):
            return ""
        # <workspace>/<domain>/<capability>/<run>/<output...>
        return rel.parts[3] if len(rel.parts) >= 4 else ""

    def _sample(self, manifest: dict) -> str:
        """Which sample a run is about, following what it read back to the data.

        Only the first stage of a chain is handed anything that names a sample;
        every stage after it names the stage before. So a listing that reads only
        its own inputs can say which sample a harmonise was for and not which
        sample a tree came from, which is the half that matters — and a reader
        given that listing counts by guessing.

        The walk itself is not written here. It is the same question the results
        panel and the recompute decision ask, and it used to have a different
        answer in each of them.
        """
        return _reference.subject(self._referenced(manifest), self._reads)

    def runs(self, workspace: str | None = None, capability: str | None = None,
             limit: int = 50) -> list[dict]:
        """What has been run, newest first."""
        out = []
        for path, m in self._manifests(workspace):
            cap = m.get("capability", "?")
            if capability and not self._same_capability(capability, cap):
                continue
            rel = path.parent.relative_to(self.root)
            out.append({
                "run": path.parent.name,
                "capability": cap,
                # Which sample, said outright. `on` names everything it read and
                # leaves the sample buried among run ids for a reader to pick
                # out, which is a guess, and a reader that guesses reports "at
                # least a couple of samples" for work covering nineteen.
                "sample": self._sample(m),
                "on": self._on(m),
                "version": m.get("contract_version"),
                "site": m.get("profile"),
                "workspace": rel.parts[0] if rel.parts else "default",
                "finished": m.get("finished"),
                "reproducible": m.get("reproducible"),
                "freeze_check": m.get("freeze_check"),
                "path": str(path.parent),
                "outputs": sorted(m.get("outputs", {})),
            })
            if len(out) >= limit:
                break
        return out

    def find(self, run: str) -> tuple[Path, dict] | None:
        """Where one run's results are, and what it recorded.

        Looked up along the path the store itself lays out, workspace / domain /
        capability / run, rather than by walking everything under the root until
        a directory name matches. Both reach the same place. The difference is
        cost: the walk grows with everything the user has ever run and reads and
        parses each manifest it passes, and this is asked once per row and twice
        per reference resolved, so a panel took half a minute and a chain spent
        longer finding its inputs than running. This opens one file.
        """
        for path in self.root.glob(f"*/*/*/{_slug(run)}/{MANIFEST}"):
            try:
                return path.parent, json.loads(path.read_text())
            except (OSError, json.JSONDecodeError):
                continue      # as in _manifests: a half-written run is not an error
        return None

    def outputs(self, run: str) -> dict[str, str]:
        """The outputs of a run that are allowed to leave the machine.

        The domain decides, per output, in its catalog entry. The store enforces
        that decision because it is the last thing to touch a result before a
        client sees it.
        """
        found = self.find(run)
        if not found:
            raise KeyError(f"no run called {run} under {self.root}")
        d, m = found
        stays = self._stays(m)
        return {n: str(d / n) for n in sorted(m.get("outputs", {})) if n not in stays}

    def _declared(self, manifest: dict) -> dict[str, dict]:
        """What the domain said each output is, by name.

        An output is often written without a file extension, so the name on
        disk cannot say whether it is a table. The entry already says, and
        asking it is the same rule that puts the code root in the entry rather
        than in a config.
        """
        cap = manifest.get("capability")
        if not cap:
            return {}
        for path in (_TREE / "domains").glob(f"*/catalog/{cap}.json"):
            return {o["name"]: o for o in C.load(path).get("outputs", [])}
        return {}

    def _stays(self, manifest: dict) -> set[str]:
        """Outputs the domain declared unable to leave the machine."""
        return {n for n, o in self._declared(manifest).items()
                if o.get("returnable") is False}

    # A path is not an answer. Something has to read a result back, or the
    # store is write-only and the only way to use a number is to already know
    # it. Kept to a head read: no parsing library, and nothing written back
    # beside the result.

    # A declared format, as (separator, has a header row). Anything absent is
    # read as text, which is the safe way to be wrong.
    _TABLES = {"tsv": ("\t", True), "csv": (",", True),
               "tsv_one_column": ("\t", True), "dense_tsv_no_header": ("\t", False)}
    _IMAGES = {"png", "jpg", "jpeg", "svg", "pdf"}
    _COUNTABLE = 8 * 1024 * 1024      # above this, counting rows means reading it all

    # A preview is for working out what something is, not for reading it. Rows
    # were bounded and nothing else was, which in this field is the wrong half:
    # a spot-by-gene matrix is twenty rows of thirty thousand columns, and a
    # Newick tree is one line holding the whole tree. Either one alone can fill a
    # conversation's entire context, and the reader learns nothing from the
    # thirty thousandth column that they did not know at the fortieth.
    #
    # Nothing is lost by cutting them. Whatever was cut is still in the file, the
    # true counts are reported next to what was kept, and anything that needs to
    # compute over the whole thing reads the file rather than this.
    _COLUMNS = 40                     # columns of a table described before it is cut
    _CELL = 200                       # characters of one value
    _LINE = 2000                      # characters of one line of text
    _INSIDE = 3                       # lines shown per file when listing a directory

    @classmethod
    def _format(cls, declared: dict, name: str) -> str:
        """The entry's word for what an output is, or the filename's."""
        return (declared.get("format") or Path(name).suffix.lstrip(".")).lower()

    @classmethod
    def kind_of(cls, declared: dict, name: str) -> str:
        """What an output is, from what the domain declared. Nothing is opened.

        Public, and the only place this decision is made. A caller that wants to
        draw a list needs the kind without paying to read every file, and the
        obvious way to give it one is to let it check the same two tables — which
        is two implementations of "what is a .tsv", and they drift the first time
        a format is added to one of them.

        `_one` calls this too, and may then disagree with it after actually
        reading: a file the entry called a table can turn out to be unreadable
        bytes. That is not a second opinion about the same question. This answers
        what the output was declared to be, which is what a list needs; `_one`
        answers what it turned out to be, which needs the file.
        """
        if (declared.get("type") or "").lower() == "directory":
            return "directory"
        fmt = cls._format(declared, name)
        if fmt in cls._IMAGES:
            return "image"
        if fmt in cls._TABLES:
            return "table"
        return "text"

    def preview(self, run: str, name: str | None = None, rows: int = 20) -> list[dict]:
        """The returnable outputs of a run, with enough of each one to read.

        Naming one output gives that one alone, which is how a caller asks for
        more rows of the table it cares about without dragging the rest along.
        """
        available = self.outputs(run)
        if name is not None and name not in available:
            raise KeyError(f"{run} has no returnable output called {name}. "
                           f"It has: {', '.join(available) or 'none'}")
        found = self.find(run)
        declared = self._declared(found[1]) if found else {}
        chosen = [name] if name else sorted(available)
        return [self._one(n, Path(available[n]), rows, declared.get(n, {}))
                for n in chosen]

    _LISTING = 40      # files of a directory output described before it is cut short

    def _one(self, name: str, path: Path, rows: int, declared: dict) -> dict:
        out: dict = {"name": name, "path": str(path)}
        if declared.get("description"):
            out["what"] = declared["description"]
        if not path.exists():
            return {**out, "kind": "missing"}

        if path.is_dir():
            # An output can be a whole directory, and for a capability whose
            # result is "whatever it wrote" that listing is the answer. Each
            # file is described the same way a lone output would be, since the
            # entry cannot have declared a format for something it did not name.
            # Fewer lines per file than a lone output gets. A listing answers
            # what is in here, and forty files read as deeply as one would be
            # forty times the answer to a question nobody asked. Naming one
            # output reads it properly.
            found = sorted(p for p in path.rglob("*") if p.is_file())
            return {**out, "kind": "directory",
                    "file_count": len(found),
                    "files": [self._one(str(p.relative_to(path)), p,
                                        min(rows, self._INSIDE), {})
                              for p in found[:self._LISTING]],
                    "truncated": len(found) > self._LISTING}

        size = path.stat().st_size
        out["bytes"] = size

        # The entry's word first, the filename only when it said nothing.
        fmt = self._format(declared, path.name)
        if self.kind_of(declared, path.name) == "image":
            # Handed back as a reference. A client that can show an image goes
            # and gets it; one that cannot should not be made to carry it.
            return {**out, "kind": "image"}

        head: list[str] = []
        try:
            with open(path, errors="replace") as fh:
                for i, line in enumerate(fh):
                    if i > rows:
                        break
                    head.append(line.rstrip("\n"))
        except (OSError, UnicodeDecodeError):
            return {**out, "kind": "binary"}
        if not head:
            return {**out, "kind": "empty"}

        total = None
        if size <= self._COUNTABLE:
            with open(path, "rb") as fh:
                total = sum(1 for _ in fh)

        if fmt in self._TABLES:
            sep, header = self._TABLES[fmt]
            body = head[1:rows + 1] if header else head[:rows]
            width = len(head[0].split(sep))
            count = (total - 1 if header else total) if total is not None else None
            named = (head[0].split(sep) if header
                     else [f"c{i + 1}" for i in range(width)])
            return {**out, "kind": "table",
                    "columns": self._cut(named),
                    "rows": [self._cut(ln.split(sep)) for ln in body],
                    "row_count": count,
                    "column_count": width,
                    "truncated": count is None or count > len(body),
                    "columns_truncated": width > self._COLUMNS}
        return {**out, "kind": "text",
                "lines": [self._clip(ln, self._LINE) for ln in head[:rows]],
                "line_count": total, "truncated": total is None or total > rows}

    @classmethod
    def _cut(cls, values: list) -> list:
        """One row, narrowed to what can be read."""
        return [cls._clip(v, cls._CELL) for v in values[:cls._COLUMNS]]

    @staticmethod
    def _clip(value: str, most: int) -> str:
        """One value, with what was dropped said rather than silently missing."""
        return value if len(value) <= most else value[:most] + f"...[{len(value)} chars]"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.environ.get("ANALYSIS_RESULTS", "~/.analysis-core/results"))
    # No default: a listing with no workspace named means every workspace, and
    # defaulting it to one of them answered a question nobody asked while
    # hiding everything filed anywhere else.
    ap.add_argument("--workspace", default=None)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--new-run", metavar="CAPABILITY")
    ap.add_argument("--run-id", help="Name the run directory, so a caller's "
                                     "handle and the directory are one id.")
    g.add_argument("--list", action="store_true")
    g.add_argument("--outputs", metavar="RUN")
    g.add_argument("--preview", metavar="RUN")
    ap.add_argument("--capability")
    ap.add_argument("--name", help="With --preview: one output rather than all of them.")
    ap.add_argument("--rows", type=int, default=20)
    ap.add_argument("--limit", type=int, default=50)
    a = ap.parse_args()

    store = ArtifactStore(a.root)
    if a.new_run:
        print(store.new_run(a.new_run, a.workspace or "default", a.run_id))
    elif a.list:
        print(json.dumps(store.runs(a.workspace, a.capability, a.limit), indent=2))
    elif a.preview:
        print(json.dumps(store.preview(a.preview, a.name, a.rows), indent=2))
    else:
        print(json.dumps(store.outputs(a.outputs), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
