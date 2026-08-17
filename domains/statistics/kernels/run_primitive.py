"""Call one statistics primitive from the command line.

The primitives are functions over data frames, not programs, so something has to
stand between a catalog entry and a function call. This is that, and it is the
only thing of its kind in the domain: one adapter shared by every entry, rather
than a wrapper per capability.

It computes nothing. It loads a table, calls the named function with the
arguments it was given, and writes what comes back. Anything that decides a
number is in the module being called, which is why a capability pins both this
file and that module.

    run_primitive.py --module correlation --function correlation \
        --table features.tsv --out results/ [--any-keyword value ...]

Unrecognised flags become keyword arguments. A value that parses as JSON is
passed as JSON, so a number stays a number; anything else is passed as the
string it is.

An array parameter arrives comma separated, which is what every other kernel
here already receives, so `--list-args` names the ones to split. Guessing from
the presence of a comma would quietly turn a one-element list into a string the
day a column name contains one.
"""

from __future__ import annotations

import argparse
import importlib
import json
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))


def _value(raw: str):
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return raw


def _read(path: str) -> pd.DataFrame:
    """A table, read with the separator it actually uses.

    Not the one its name suggests. An input is staged under a name the contract
    chose, so a comma-separated file can arrive called table.tsv, and reading
    that by extension silently collapses every column into one.
    """
    with open(path, newline="") as fh:
        head = fh.readline()
    sep = "," if head.count(",") > head.count("\t") else "\t"
    return pd.read_csv(path, sep=sep, index_col=0)


def _index_matters(frame: pd.DataFrame) -> bool:
    """Whether this table's index is data rather than row numbers.

    Every table was written with `index=False`, which is right for a primitive
    returning a flat table of results: `correlation` gives one row per pair and
    its index is 0, 1, 2. It is wrong for one that answers per sample.
    `alpha_diversity` returns a frame indexed by sample_id, and dropping that
    wrote seven diversity indices for 312 samples with no way to tell which
    sample any row belonged to — a table that cannot be joined to anything, and
    which reads as valid because the numbers are all correct.

    A name is the test. A primitive that indexes by something meaningful names
    it, and pandas' default positional index has no name, so nothing has to be
    declared per capability and nothing has to be remembered.
    """
    named = [n for n in (frame.index.names or []) if n]
    return bool(named)


def _write(result, out: Path) -> list[str]:
    """Whatever a primitive returned, as files.

    A primitive returns a dict carrying one or more tables and some notes. The
    notes are not decoration: they say when an estimate is partial, or which
    cases were dropped, and a result read without them is misread.
    """
    out.mkdir(parents=True, exist_ok=True)
    written = []
    if isinstance(result, pd.DataFrame):
        result = {"table": result}
    for key, value in (result or {}).items():
        if isinstance(value, pd.DataFrame):
            value.to_csv(out / f"{key}.tsv", sep="\t", index=_index_matters(value))
            written.append(f"{key}.tsv")
    rest = {k: v for k, v in (result or {}).items() if not isinstance(v, pd.DataFrame)}
    if rest:
        (out / "notes.json").write_text(json.dumps(rest, indent=2, default=str) + "\n")
        written.append("notes.json")
    return written


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    # primitives.correlation, workflows.survival: the package layout is the
    # domain's own, and relative imports inside it only resolve that way.
    ap.add_argument("--module", required=True)
    ap.add_argument("--function", required=True)
    ap.add_argument("--table", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--list-args", default="",
                    help="Comma separated names of the arguments that are lists.")
    known, rest = ap.parse_known_args()
    as_list = {a for a in known.list_args.split(",") if a}

    kwargs = {}
    it = iter(rest)
    for token in it:
        if not token.startswith("--"):
            raise SystemExit(f"unexpected argument: {token}")
        value = next(it, "")
        name = token[2:].replace("-", "_")
        if value == "":
            continue
        kwargs[name] = ([v for v in value.split(",") if v] if name in as_list
                        else _value(value))

    fn = getattr(importlib.import_module(known.module), known.function)
    result = fn(_read(known.table), **kwargs)

    written = _write(result, Path(known.out))
    print(f"wrote: {', '.join(written) or 'nothing'}")
    print("PRIMITIVE_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
