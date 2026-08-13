"""The data layer: a swappable seam between the analysis engine and where study data
lives. Local CSV/Parquet today (LocalSource), object storage or a data service later —
the engine only ever sees the DataSource port returning DataFrames.

See base.py for the contract, local.py for the local realization, tables.py for the
Parquet/DuckDB read engine, and ingest.py to pre-warm the Parquet cache.
"""

from __future__ import annotations

from functools import lru_cache

from . import domains
from .base import DataSource
from .domains import DOMAINS, known_domains
from .paths import resolve_data_root
from .local import (
    LocalSource,
    allowed_domains,
    allowed_studies,
    domain_allowed,
    find_domains,
    find_studies,
    fingerprint,
    resolve_files,
    resolve_study_dir,
    scan_studies,
    study_allowed,
    study_collisions,
    study_domain,
)
from .tables import capabilities, ensure_parquet, read_tabular

__all__ = [
    "DataSource",
    "LocalSource",
    "default_source",
    "find_studies",
    "fingerprint",
    "resolve_files",
    "resolve_study_dir",
    "allowed_studies",
    "study_allowed",
    "read_tabular",
    "ensure_parquet",
    "capabilities",
    # domains
    "domains",
    "DOMAINS",
    "known_domains",
    "allowed_domains",
    "domain_allowed",
    "find_domains",
    "scan_studies",
    "study_domain",
    "study_collisions",
]


@lru_cache(maxsize=8)
def default_source(data_root: str = "data") -> LocalSource:
    """The process-wide LocalSource for a data root (cached so callers share one)."""
    return LocalSource(data_root)
