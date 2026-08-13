"""The DataSource port: the seam between the analysis engine and wherever study data
physically lives.

This is the one contract worth locking. Today it is realized by local CSV/Parquet
(LocalSource); tomorrow it can be Parquet in object storage or a remote data service,
without the engine changing — every analysis depends on *this interface returning
DataFrames given a study id and selectors*, never on "a CSV on local disk".

Reads take optional `columns` and `where` so large tables are pushed down (read the
columns/rows you need) rather than pulled whole. At GB/TB scale that projection is the
difference between tractable and not; at today's scale it simply costs nothing.
"""

from __future__ import annotations

from abc import ABC, abstractmethod

import pandas as pd


class DataSource(ABC):
    @abstractmethod
    def list_studies(self) -> list[str]:
        """The studies this source can serve."""

    @abstractmethod
    def has_study(self, study: str) -> bool:
        ...

    @abstractmethod
    def table_roles(self, study: str) -> dict[str, str]:
        """Map each recognized table role present (subjects, samples, metabolomics,
        metagenomics, events) to a source identifier (a path or uri)."""

    @abstractmethod
    def read_table(self, study: str, role: str, *, columns: list[str] | None = None,
                   where: str | None = None) -> pd.DataFrame:
        """Read one recognized table, optionally projected/filtered (pushed down)."""

    @abstractmethod
    def list_files(self, study: str) -> list[dict]:
        """Every file in the study, each tagged with the role it fills (or None for an
        extra raw file beyond the recognized tables)."""

    @abstractmethod
    def read_file(self, study: str, filename: str, *, as_text: bool = False,
                  columns: list[str] | None = None):
        """Open an arbitrary raw file in the study as-is (DataFrame for delimited data,
        text otherwise). Path-safe implementations must refuse to escape the study."""

    def local_dir(self, study: str) -> str | None:
        """Local directory backing the study, if any (some tools still want a path).
        Remote sources return None."""
        return None
