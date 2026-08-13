"""Draw one chart from a table, on the machine the table is on.

This exists for the same reason computation goes to the data. A figure drawn
where the data lives can be allowed to travel even when the table cannot, so a
chart is often the only thing anyone is permitted to see of a governed dataset.
A plotting library sitting inside a client can never produce that figure, and a
chart it does draw carries no record of what produced it.

It decides nothing about the science. It reads a table, hands the named columns
to a chart function, and writes a file.

    render_chart.py --chart bar --table t.tsv --out DIR --x name --y value

Which columns mean what is the caller's to say, because this cannot know. What a
column means is the business of whoever declared the table.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from charting import charts, compose  # noqa: E402

# Each chart says which columns it needs, so a missing one is reported by name
# instead of arriving as an obscure error from inside matplotlib.
CHARTS = {
    "bar":       (charts.bar, ("x", "y")),
    "scatter":   (charts.scatter, ("x", "y")),
    "line":      (charts.line, ("x", "y")),
    "histogram": (charts.histogram, ("x",)),
    "box":       (charts.box, ("x", "y")),
    "forest":    (charts.forest, ("label", "estimate", "lower", "upper")),
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--chart", required=True, choices=sorted(CHARTS))
    ap.add_argument("--table", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--name", default="chart")
    ap.add_argument("--title", default="")
    ap.add_argument("--x"), ap.add_argument("--y")
    ap.add_argument("--hue", default=""), ap.add_argument("--label")
    ap.add_argument("--estimate"), ap.add_argument("--lower"), ap.add_argument("--upper")
    ap.add_argument("--xlabel", default=""), ap.add_argument("--ylabel", default="")
    a = ap.parse_args()

    sep = "," if a.table.endswith(".csv") else "\t"
    df = pd.read_csv(a.table, sep=sep)

    fn, needed = CHARTS[a.chart]
    cols = {k: getattr(a, k) for k in needed}
    missing = [k for k, v in cols.items() if not v]
    if missing:
        raise SystemExit(f"chart '{a.chart}' needs {', '.join(missing)}: "
                         f"name the column with --{missing[0]}")
    unknown = [v for v in cols.values() if v not in df.columns]
    if unknown:
        raise SystemExit(f"column not in the table: {', '.join(unknown)}. "
                         f"it has: {', '.join(df.columns)}")

    if a.chart == "bar":
        args = (df[cols["x"]].astype(str).tolist(), df[cols["y"]].tolist())
        kwargs = {}
    elif a.chart == "scatter":
        args = (df[cols["x"]].tolist(), df[cols["y"]].tolist())
        kwargs = {"hue": df[a.hue].tolist()} if a.hue and a.hue in df.columns else {}
    elif a.chart == "line":
        args = ([(str(k), g[cols["x"]].tolist(), g[cols["y"]].tolist())
                 for k, g in (df.groupby(a.hue) if a.hue and a.hue in df.columns
                              else [("series", df)])],)
        kwargs = {}
    elif a.chart == "histogram":
        args = (df[cols["x"]].tolist(),)
        kwargs = {"groups": df[a.hue].tolist()} if a.hue and a.hue in df.columns else {}
    elif a.chart == "box":
        args = ({str(k): g[cols["y"]].tolist() for k, g in df.groupby(cols["x"])},)
        kwargs = {}
    else:
        args = (df[cols["label"]].astype(str).tolist(), df[cols["estimate"]].tolist(),
                df[cols["lower"]].tolist(), df[cols["upper"]].tolist())
        kwargs = {}

    kwargs.update({k: v for k, v in
                   (("title", a.title), ("xlabel", a.xlabel), ("ylabel", a.ylabel)) if v})
    path = Path(compose.render(compose.panel(fn, *args, **kwargs),
                               out_dir=a.out, name=a.name))
    # The library stamps a time into the filename, which made sense when charts
    # were dumped into one shared directory. Every run has its own directory
    # now, so the stamp only makes the output unnameable by a catalog entry and
    # two runs impossible to compare.
    final = path.with_name(f"{a.name}.png")
    if path != final:
        path.replace(final)
    print(f"wrote: {final}")
    print("CHART_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
