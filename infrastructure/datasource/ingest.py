"""Pre-warm the Parquet cache for studies — the slow ingest path, run once.

Reading already builds the Parquet mirror on first touch, so this is optional: it just
moves that one-time cost up front (e.g. right after dropping new study folders) instead
of paying it on the first query. Safe to re-run; only stale/missing mirrors are rebuilt.

Usage:
    python -m datasource.ingest --all                 # every study under ./data
    python -m datasource.ingest MICU Leukemia         # named studies
    python -m datasource.ingest --all --data-root /path/to/data
"""

from __future__ import annotations

import argparse
import os
import sys

from . import capabilities, find_studies, resolve_files
from .tables import ensure_parquet, parquet_cache_path


def ingest_study(study_dir: str) -> list[tuple[str, str, int, int]]:
    """Build Parquet for every recognized table in a study folder. Returns rows of
    (role, table_name, source_bytes, parquet_bytes)."""
    rows = []
    for role, src in sorted(resolve_files(study_dir).items()):
        pq = ensure_parquet(src)
        if pq is None:
            continue
        rows.append((role, os.path.basename(src),
                     os.path.getsize(src), os.path.getsize(pq)))
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Pre-build the Parquet cache for studies.")
    ap.add_argument("studies", nargs="*", help="study names (default: use --all)")
    ap.add_argument("--all", action="store_true", help="ingest every study under the data root")
    ap.add_argument("--data-root", default="data", help="data root (default: ./data)")
    args = ap.parse_args(argv)

    caps = capabilities()
    if not caps["parquet"]:
        print("Parquet support not installed (pip install pyarrow duckdb); nothing to do.")
        return 1

    root = os.path.abspath(args.data_root)
    studies = find_studies(root) if args.all or not args.studies else args.studies
    if not studies:
        print(f"No studies found under {root}.")
        return 1

    total_src = total_pq = 0
    for study in studies:
        sdir = study if os.path.isdir(study) else os.path.join(root, study)
        if not os.path.isdir(sdir):
            print(f"  {study}: not found, skipping")
            continue
        rows = ingest_study(sdir)
        for role, name, sbytes, pbytes in rows:
            total_src += sbytes
            total_pq += pbytes
            print(f"  {study:14s} {role:12s} {name:42s} "
                  f"{sbytes/1e6:7.1f} MB -> {pbytes/1e6:6.1f} MB")
    if total_src:
        print(f"\nDone. {total_src/1e6:.1f} MB CSV -> {total_pq/1e6:.1f} MB Parquet "
              f"({100*total_pq/total_src:.0f}% of source).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
