"""The read/cache engine under the data layer.

Studies arrive as delimited text (the ingest format), which is fine to load once but
poor to query repeatedly: no column pruning, no predicate pushdown, untyped, slow to
parse. So the first read of a table converts it to Parquet (columnar, compressed, typed)
in a separate cache, and serves from Parquet thereafter; with DuckDB, a projected read
(subset of columns, optional row filter) is pushed down to the file, so a wide table is
never materialized whole. That pushdown is the lever that keeps reads cheap as tables
grow — and it is why compute stays next to the data rather than the data being shipped
to compute.

Properties:
  * Delimiter-robust ingest. The source delimiter is sniffed (comma, tab, ';', '|'), so
    .csv, .tsv, and tab-separated files saved as .csv all load correctly.
  * Fidelity. CSV -> Parquet goes through pandas, so dtypes round-trip exactly to the
    legacy `pd.read_csv` path; whole-table reads come back via `pd.read_parquet`.
  * Graceful degradation. Without pyarrow/duckdb the layer falls back to pandas, so
    nothing breaks — Parquet is acceleration, never a requirement.
  * Writable-cache-safe. The Parquet cache lives under a separate cache root (not next
    to the source), so a read-only data mount (e.g. a mounted Box/object-store volume)
    works. Override with DATASOURCE_CACHE.

Conversion is the slow path (once per file, or pre-warmed by datasource.ingest); reading
is the fast path. The cache is keyed by source mtime, so editing a source rebuilds its
Parquet automatically — no manual step.
"""

from __future__ import annotations

import csv
import os
from pathlib import Path

import pandas as pd

try:
    import pyarrow  # noqa: F401  (pandas needs it to write Parquet)
    _HAVE_PARQUET = True
except Exception:  # pragma: no cover - optional acceleration
    _HAVE_PARQUET = False

try:
    import duckdb
    _HAVE_DUCKDB = True
except Exception:  # pragma: no cover - optional acceleration
    _HAVE_DUCKDB = False

# The cache lives under one writable root (NOT next to the source), so read-only data
# mounts work. Default to <repo>/.cache/parquet; override with DATASOURCE_CACHE.
_CACHE_ROOT = Path(os.environ.get("DATASOURCE_CACHE")
                   or (Path(__file__).resolve().parents[2] / ".cache" / "parquet"))


def parquet_cache_path(src_path: str) -> str:
    """Where the Parquet mirror of a source file lives: the source's absolute path
    mirrored under the cache root, so distinct data roots never collide."""
    ap = os.path.abspath(src_path)
    rel = ap.replace(":", "").lstrip("/\\")          # sanitize drive/leading separators
    return str(_CACHE_ROOT / (os.path.splitext(rel)[0] + ".parquet"))


def sniff_delimiter(src_path: str) -> str:
    """Detect the delimiter from a sample (comma, tab, ';', '|'); default to comma.
    Handles .csv, .tsv, and tab-separated data that happens to be named .csv."""
    try:
        with open(src_path, "r", errors="replace") as f:
            sample = f.read(65536)
        if not sample.strip():
            return ","
        return csv.Sniffer().sniff(sample, delimiters=",\t;|").delimiter
    except Exception:
        return ","


def _fresh(pq: str, src: str) -> bool:
    return os.path.isfile(pq) and os.path.getmtime(pq) >= os.path.getmtime(src)


def ensure_parquet(src_path: str) -> str | None:
    """Return a fresh Parquet mirror of `src_path`, building it if needed. Returns None
    if Parquet support is unavailable (caller falls back to reading the source directly).

    The mirror is written through pandas (so dtypes match the legacy read_csv path) and
    atomically renamed into place so a crash mid-convert never leaves a partial file."""
    if not _HAVE_PARQUET:
        return None
    pq = parquet_cache_path(src_path)
    if _fresh(pq, src_path):
        return pq
    os.makedirs(os.path.dirname(pq), exist_ok=True)
    df = pd.read_csv(src_path, sep=sniff_delimiter(src_path))
    tmp = pq + f".tmp.{os.getpid()}"
    df.to_parquet(tmp, index=False)
    os.replace(tmp, pq)
    return pq


def _quote(col: str) -> str:
    return '"' + str(col).replace('"', '""') + '"'


def read_tabular(src_path: str, columns: list[str] | None = None,
                 where: str | None = None) -> pd.DataFrame:
    """Read a delimited source file as a DataFrame, fast.

    columns  : project to these columns only (pushed down to Parquet via DuckDB).
    where    : an optional SQL row filter (trusted, internal) pushed down to Parquet.
    Falls back to pandas (with usecols) when Parquet/DuckDB are unavailable; `where` is
    only honored on the pushdown path.
    """
    pq = ensure_parquet(src_path)
    if pq is not None and _HAVE_DUCKDB and (columns or where):
        sel = ", ".join(_quote(c) for c in columns) if columns else "*"
        sql = f"SELECT {sel} FROM read_parquet(?)"
        if where:
            sql += f" WHERE {where}"
        con = duckdb.connect()
        try:
            return con.execute(sql, [pq]).df()
        finally:
            con.close()
    if pq is not None:
        df = pd.read_parquet(pq)
        return df[columns] if columns else df
    # no Parquet support: read the source directly (delimiter sniffed)
    return pd.read_csv(src_path, sep=sniff_delimiter(src_path), usecols=columns)


# How many values to show from a column that has too many to list. Enough to see
# what kind of thing it holds, few enough that a wide table stays readable.
EXAMPLES = 5


def describe(src_path: str, small: int = 20) -> dict:
    """What one table holds: how many rows, and what each column is.

    The question every caller asks before it can ask anything else, and the one
    that used to have no answer. A client that could only be told a table exists
    left whoever read that to either guess what was in it or run a computation to
    find out — and running a computation to learn a column name is how a simple
    question turns into four cluster jobs.

    A column with few enough distinct values to group by carries those values,
    because "which cohorts could I split this into" is answered by the values
    themselves and by nothing else. `small` is where that stops: past it the
    column is a measurement rather than a grouping, and listing thousands of
    identifiers helps nobody.

    Costs one pass over the Parquet mirror, which the first read builds anyway.
    Seven tables totalling 86 MB describe in about a third of a second.
    """
    pq = ensure_parquet(src_path)
    if pq is None or not _HAVE_DUCKDB:
        return _describe_with_pandas(src_path, small)
    con = duckdb.connect()
    try:
        rel = con.execute("SELECT * FROM read_parquet(?) LIMIT 0", [pq])
        names = [d[0] for d in rel.description]
        types = [str(t) for t in rel.description and [d[1] for d in rel.description]]
        rows = con.execute("SELECT count(*) FROM read_parquet(?)", [pq]).fetchone()[0]
        columns = []
        for name, kind in zip(names, types):
            n = con.execute(f"SELECT count(DISTINCT {_quote(name)}) "
                            f"FROM read_parquet(?)", [pq]).fetchone()[0]
            col = {"name": name, "type": kind, "distinct": int(n)}
            if n:
                # Every value when there are few enough to group by. A handful
                # otherwise, because knowing a column holds compound names, and
                # what one looks like, is the difference between searching it
                # and not knowing it is there. The count is always given, so a
                # short list is never mistaken for the whole column.
                want = small if n <= small else EXAMPLES
                got = con.execute(f"SELECT DISTINCT {_quote(name)} FROM read_parquet(?) "
                                  f"ORDER BY 1 LIMIT {want}", [pq]).fetchall()
                col["values" if n <= small else "examples"] = [v[0] for v in got]
            columns.append(col)
        return {"rows": int(rows), "columns": columns}
    finally:
        con.close()


def _describe_with_pandas(src_path: str, small: int) -> dict:
    """The same answer without DuckDB. Reads the table, so it is the slow path."""
    try:
        df = read_tabular(src_path)
    except Exception as e:                        # noqa: BLE001
        return {"error": f"{type(e).__name__}: {e}"}
    columns = []
    for name in df.columns:
        n = int(df[name].nunique(dropna=True))
        col = {"name": str(name), "type": str(df[name].dtype), "distinct": n}
        if n:
            vals = sorted(df[name].dropna().unique().tolist(), key=str)
            col["values" if n <= small else "examples"] = vals[:small if n <= small
                                                               else EXAMPLES]
        columns.append(col)
    return {"rows": int(len(df)), "columns": columns}


def capabilities() -> dict:
    """What acceleration is active — surfaced by setup/diagnostics, not the model."""
    return {"parquet": _HAVE_PARQUET, "duckdb": _HAVE_DUCKDB}
