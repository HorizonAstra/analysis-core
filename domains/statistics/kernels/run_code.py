"""Run code that arrived with the request, against this domain's primitives.

Everything else in this catalog describes what it computes. This one cannot,
because what it computes is the argument. It exists anyway, and it is a
capability rather than something a client does, for one reason: a model asked to
analyse data will write code whether or not there is somewhere sanctioned to run
it. The choice is not between having this and not having it. It is between
knowing what was run and not knowing.

As a capability the code is an input, so it is digested into the run's identity
and written into the manifest beside the result. The earlier version of this ran
inside the tool server, where there was no boundary to record anything at, and
had to reconstruct what happened by intercepting every primitive call.

What bounds it
    The runner already starts this as its own process, in the domain's pinned
    environment, with the site's rules applied and a working directory it is
    meant to write to. That is the isolation. What this file adds is the part
    the runner cannot know it needs: a ceiling on cpu time and on the size of
    any file written, so a loop that never ends or a write that never stops
    fails here rather than on the machine.

    This is not a boundary against someone trying to break out of it. The
    catalog entry says so, and a site that holds data where that matters can
    decline to offer the capability at all.

Two deliberate non-restrictions, kept from the earlier version:
    Network stays open, because fetching a reference is legitimate work, and
    cutting it here would only push people to do the analysis somewhere with no
    record at all. Restrict it at the machine if a machine needs that.

    No address-space cap by default. numpy and its BLAS reserve large virtual
    ranges they never touch, so a low cap turns healthy analysis into spurious
    memory errors. Bound memory with cgroups where it has to be bounded.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import pandas as pd     # noqa: E402


def _limits() -> None:
    """A ceiling on cpu time and on file size, where the platform has them."""
    if os.name != "posix":
        return
    import resource
    for res, value in (
        (resource.RLIMIT_CPU, int(os.environ.get("RUN_CODE_CPU_SEC", "900"))),
        (resource.RLIMIT_FSIZE, int(os.environ.get("RUN_CODE_FSIZE_MB", "512")) * 2**20),
    ):
        try:
            resource.setrlimit(res, (value, value))
        except (ValueError, OSError):
            pass


def _read(path: str) -> pd.DataFrame:
    """A table, read with the separator it actually uses.

    Not the one its name suggests: an input is staged under a name this
    capability chose, so a comma-separated file arrives called table.tsv and
    reading it by extension puts every column into one. Nothing errors, and the
    caller is left holding a data frame of one column wondering why.
    """
    with open(path, newline="") as fh:
        head = fh.readline()
    sep = "," if head.count(",") > head.count("\t") else "\t"
    return pd.read_csv(path, sep=sep)


class Printed:
    """Standard output, shown as it happens and kept as it goes.

    A tee rather than a capture. Redirecting into a buffer alone would take the
    live output away from the job log, which is where a failure is read from,
    and a run that hangs would then show nothing at all until it stopped.
    """

    def __init__(self, through):
        self._through = through
        self._kept: list[str] = []

    def write(self, text: str) -> int:
        self._kept.append(text)
        return self._through.write(text)

    def flush(self) -> None:
        self._through.flush()

    def text(self) -> str:
        return "".join(self._kept)


def _announce(name: str, frame: pd.DataFrame) -> None:
    """Say what a table turned out to be, once, when it is first read.

    Written once and called for every table, because the alternative is this
    paragraph repeated per binding and drifting apart.
    """
    cols = [str(c) for c in frame.columns]
    print(f"{name}: {frame.shape[0]} rows, {len(cols)} columns")
    # Quoted, because this listing is read and copied straight into code.
    # Printed bare, a name like Barcode looks like an identifier rather than a
    # string, and the code that comes back says df[Barcode] and dies with
    # NameError on its first line.
    shown = ", ".join(repr(c) for c in cols[:25])
    rest = len(cols) - 25
    # Said out loud when the list is cut. Silently showing 25 of 36 invites code
    # that reaches for a column it was never told about.
    print(f"    {shown}" + (f", and {rest} more" if rest > 0 else ""))


class Bound(dict):
    """The names the submitted code runs against, with tables read on first use.

    A study is handed over whole, which is the only way a question spanning
    several of its tables can be answered in one run. Reading all of them up
    front would mean every run paid for every table, including the seventy
    megabyte one nobody asked about. So a name is bound to a table and the table
    is read when the code first mentions it — a study of any size costs only
    what the code actually touches.

    A dict subclass because that is what `exec` looks names up in, so this works
    for a bare mention at the top level and inside a function alike.
    """

    def __init__(self, base: dict, loaders: dict):
        super().__init__(base)
        self._loaders = loaders

    def __missing__(self, key):
        if key not in self._loaders:
            raise KeyError(key)
        frame = self._loaders[key]()
        _announce(key, frame)
        self[key] = frame
        return frame


def study_tables(directory: str) -> dict:
    """Every table a staged study holds, as name -> a function that reads it.

    The names are the roles the domain recognised, because the runner staged
    them that way; a file it had no role for keeps its own name and is here
    too. Nothing is opened.
    """
    loaders: dict = {}
    if not directory or not os.path.isdir(directory):
        return loaders
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if name.startswith(".") or not os.path.isfile(path):
            continue
        stem = os.path.splitext(name)[0]
        loaders[stem] = (lambda p=path: _read(p))
    return loaders


def namespace(out: Path, tables: dict[str, pd.DataFrame]) -> dict:
    """What the code can reach.

    The primitives are importable by name rather than pre-imported one by one.
    A list of names here would be a second place to update every time the domain
    gains a function, and it would be wrong the first time someone forgot.
    """
    import numpy as np

    saved: list[str] = []
    shown: list[dict] = []

    def save(obj, name: str) -> str:
        """Write a result out. Anything not saved does not survive the run."""
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        # The name that was actually written, which is not always the name that
        # was asked for: a data frame saved as `cohort` becomes `cohort.tsv`.
        # This used to return the asked-for name regardless, so anything built
        # on the answer — a reference to read the file back, a row in the panel
        # — pointed at a path that did not exist.
        if isinstance(obj, pd.DataFrame):
            target = target if target.suffix else target.with_suffix(".tsv")
            obj.to_csv(target, sep="\t", index=False)
        elif hasattr(obj, "savefig"):
            target = target if target.suffix else target.with_suffix(".png")
            obj.savefig(target, dpi=150, bbox_inches="tight")
        else:
            target = target if target.suffix else target.with_suffix(".json")
            target.write_text(json.dumps(obj, indent=2, default=str))
        saved.append(target.name)
        return str(target)

    def present(obj, name: str, description: str = "") -> str:
        """Save something and mark it as an answer, so a person is shown it.

        Saving and showing are different acts and were the same one here, which
        left the results panel holding every intermediate a piece of code
        happened to write out — a wall of `saved.json` above the thing somebody
        asked for.

        Save the working. Present what was asked for: the cohort table, the
        ranking, the figure. Presenting is not about size or type; it is about
        whether a person opening the panel would recognise this as the thing
        they wanted.
        """
        # Record what was written, not what was asked for. `save` supplies the
        # extension when the name has none, so the two differ — and the name is
        # what the panel draws a row from and what a later capability names in a
        # reference. Recording the request would leave both pointing at a file
        # that is not there.
        path = save(obj, name)
        shown.append({"name": os.path.basename(path), "description": description})
        return path

    ns = {"pd": pd, "np": np, "save": save, "present": present,
          "out": str(out), "_saved": saved, "_shown": shown}
    ns.update(tables)
    return ns


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--code", required=True, help="File holding the code to run.")
    ap.add_argument("--table", default="", help="A table, available as `df`.")
    ap.add_argument("--study", default="",
                    help="A staged study. Every table in it is bound by name.")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    _limits()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    tables = {}
    if a.table and Path(a.table).exists():
        tables["df"] = _read(a.table)
        _announce("df", tables["df"])

    loaders = study_tables(a.study)
    if loaders:
        # Named up front and read later. Knowing what is here is what stops the
        # code being written against a table that was guessed at; reading it is
        # what costs, and that waits until the code asks.
        print(f"study tables in scope: {', '.join(sorted(loaders))}")
        print("    read when first used; shape and columns are printed then")

    ns = namespace(out, tables)
    if loaders:
        # `tables` is the same mapping, so iterating it reads only what is
        # iterated, exactly as naming one does.
        ns = Bound(ns, loaders)
        ns["tables"] = ns
    code = Path(a.code).read_text()

    print("-" * 60)
    # What the code prints is kept, not only shown. Printing is the ordinary way
    # to look at something, and here it went to a log that whoever asked never
    # reads — so a run that printed its answer and saved nothing had produced
    # nothing, and the way to find that out was to run it all again. It is still
    # printed as it happens; it is also written down.
    printed = Printed(sys.stdout)
    try:
        with contextlib.redirect_stdout(printed):
            exec(compile(code, "<submitted>", "exec"), ns)
    except Exception:
        # The traceback is the result when the code was wrong. Failing without
        # it would leave the caller guessing at something it wrote itself.
        print("".join(traceback.format_exception(*sys.exc_info())), file=sys.stderr)
        (out / "error.txt").write_text("".join(traceback.format_exception(*sys.exc_info())))
        (out / "printed.txt").write_text(printed.text())
        return 1
    if printed.text().strip():
        (out / "printed.txt").write_text(printed.text())
    print("-" * 60)

    saved, shown = ns["_saved"], ns["_shown"]
    (out / "saved.json").write_text(json.dumps(saved, indent=2) + "\n")
    # What a person is meant to see, written where the panel can find it without
    # opening anything. A run that presented nothing writes nothing, so an older
    # result and a run of pure working both read the same way: no answers here.
    if shown:
        (out / "presented.json").write_text(json.dumps(shown, indent=2) + "\n")
    print(f"saved: {', '.join(saved) if saved else 'nothing. Use save(obj, name).'}")
    if shown:
        print(f"presented: {', '.join(s['name'] for s in shown)}")
    print("RUN_CODE_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
