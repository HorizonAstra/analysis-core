"""Coercions for the shapes a caller actually holds.

Every workflow that compares cohorts needs the same two things: the assembled matrix,
and a mapping of sample to cohort. Callers in the scratch space hold those in whatever
form the work produced them — a study dict rather than a bare matrix, a Series rather
than a dict — and a function that accepts exactly one shape turns a correct analysis
into a round trip spent discovering which shape that was. Accepted here once, so every
workflow accepts the same set.
"""

from __future__ import annotations

import pandas as pd


def coerce_matrix(matrix):
    """Accept the assembled matrix, or a loaded study to take it from."""
    if isinstance(matrix, dict) and isinstance(matrix.get("matrix"), pd.DataFrame):
        return matrix["matrix"]
    return matrix


def coerce_group_map(groups, matrix: pd.DataFrame) -> dict:
    """Normalise a grouping into {sample_id: label}.

    Accepts a dict, a Series indexed by sample_id, a one-column DataFrame, or the name
    of a column already on the matrix. All four say the same thing.
    """
    if isinstance(groups, str):
        if not isinstance(matrix, pd.DataFrame) or groups not in matrix.columns:
            raise KeyError(f"'{groups}' is not a column on the matrix; "
                           f"pass a dict or Series of sample_id -> cohort instead")
        return dict(zip(matrix["sample_id"], matrix[groups]))
    if isinstance(groups, pd.Series):
        return {k: v for k, v in groups.dropna().items()}
    if isinstance(groups, pd.DataFrame):
        if groups.shape[1] == 1:
            return {k: v for k, v in groups.iloc[:, 0].dropna().items()}
        raise ValueError("a DataFrame grouping must have exactly one column of labels")
    if isinstance(groups, dict):
        return groups
    raise TypeError(f"grouping must be a dict, Series, one-column DataFrame, or column "
                    f"name; got {type(groups).__name__}")
