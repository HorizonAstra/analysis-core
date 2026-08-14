"""The data layer: a swappable seam between the analysis engine and where study data
lives. Local CSV/Parquet today (LocalSource), object storage or a data service later —
the engine only ever sees the DataSource port returning DataFrames.

See base.py for the contract, local.py for the local realization, tables.py for the
Parquet/DuckDB read engine, and ingest.py to pre-warm the Parquet cache.
"""

from __future__ import annotations

from functools import lru_cache

from . import describe
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
from .refs import study_parts
# Not `describe` — that name belongs to the submodule below, and importing the
# function of the same name here would shadow it.
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
    "describe",
    "describe_study",
    "study_files",
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
    # references
    "study_parts",
]


@lru_cache(maxsize=8)
def default_source(data_root: str = "data") -> LocalSource:
    """The process-wide LocalSource for a data root (cached so callers share one)."""
    return LocalSource(data_root)


def study_files(study: str, domain: str = "", data_root: str = "") -> list[dict]:
    """Every file one study holds, with the role it fills or None when unrecognised."""
    root = resolve_data_root(data_root or "data")
    where = resolve_study_dir(study, root)
    return describe.files(where, domain or (study_domain(study, root) or ""))


def describe_study(study: str, domain: str = "", data_root: str = "") -> dict:
    """One study's tables, their columns, and how they join. See describe.py.

    Takes a study by name, because that is what a caller holds; where it lives is
    the data layer's business and nobody else's.
    """
    root = resolve_data_root(data_root or "data")
    where = resolve_study_dir(study, root)
    return describe.study(where, domain or (study_domain(study, root) or ""), study)
