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


def namespace(out: Path, tables: dict[str, pd.DataFrame]) -> dict:
    """What the code can reach.

    The primitives are importable by name rather than pre-imported one by one.
    A list of names here would be a second place to update every time the domain
    gains a function, and it would be wrong the first time someone forgot.
    """
    import numpy as np

    saved: list[str] = []

    def save(obj, name: str) -> str:
        """Write a result out. Anything not saved does not survive the run."""
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(obj, pd.DataFrame):
            obj.to_csv(target if target.suffix else target.with_suffix(".tsv"),
                       sep="\t", index=False)
        elif hasattr(obj, "savefig"):
            obj.savefig(target if target.suffix else target.with_suffix(".png"),
                        dpi=150, bbox_inches="tight")
        else:
            target.write_text(json.dumps(obj, indent=2, default=str))
        saved.append(name)
        return str(target)

    ns = {"pd": pd, "np": np, "save": save, "out": str(out), "_saved": saved}
    ns.update(tables)
    return ns


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--code", required=True, help="File holding the code to run.")
    ap.add_argument("--table", default="", help="A table, available as `df`.")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    _limits()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    tables = {}
    if a.table and Path(a.table).exists():
        tables["df"] = _read(a.table)
        cols = [str(c) for c in tables["df"].columns]
        print(f"df: {tables['df'].shape[0]} rows, {len(cols)} columns")
        # Quoted, because this listing is read and copied straight into code.
        # Printed bare, a name like Barcode looks like an identifier rather than
        # a string, and the code that comes back says df[Barcode] and dies with
        # NameError on its first line. Quoting them is the difference between a
        # listing that describes the table and one that can be pasted.
        shown = ", ".join(repr(c) for c in cols[:25])
        rest = len(cols) - 25
        # Said out loud when the list is cut. Silently showing 25 of 36 invites
        # code that reaches for a column it was never told about.
        print(f"    {shown}" + (f", and {rest} more" if rest > 0 else ""))

    ns = namespace(out, tables)
    code = Path(a.code).read_text()

    print("-" * 60)
    try:
        exec(compile(code, "<submitted>", "exec"), ns)
    except Exception:
        # The traceback is the result when the code was wrong. Failing without
        # it would leave the caller guessing at something it wrote itself.
        print("".join(traceback.format_exception(*sys.exc_info())), file=sys.stderr)
        (out / "error.txt").write_text("".join(traceback.format_exception(*sys.exc_info())))
        return 1
    print("-" * 60)

    saved = ns["_saved"]
    (out / "saved.json").write_text(json.dumps(saved, indent=2) + "\n")
    print(f"saved: {', '.join(saved) if saved else 'nothing. Use save(obj, name).'}")
    print("RUN_CODE_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
