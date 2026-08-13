"""General feature-ratio computation.

Ratios (and log-ratios) of one feature to another are a recurring need — a
metabolite to its precursor, a taxon to a reference taxon, a clinical marker to
another. This block computes them in one bulk call, vectorized, in any of three
modes, and returns a samples x ratio table. It makes no assumption about which
features are numerator or denominator; the caller specifies.
"""

from __future__ import annotations

from itertools import permutations
from typing import Optional, Sequence

import numpy as np
import pandas as pd


def feature_ratios(
    df: pd.DataFrame,
    pairs: Optional[Sequence[tuple]] = None,
    features: Optional[Sequence[str]] = None,
    reference: Optional[str] = None,
    log: bool = False,
    base: str = "natural",
    eps: float = 0.0,
) -> pd.DataFrame:
    """Compute feature ratios over a samples x features table. Exactly one mode:

      - pairs: an explicit list of (numerator, denominator) column names.
      - features + reference: each feature divided by the reference column.
      - features only: every ordered pair among the features (all-vs-all).

    log=True returns the log-ratio instead (natural/2/10). eps is added to numerator
    and denominator before dividing to tame exact zeros (default 0 = off). Division
    by zero yields inf/NaN (NaN under log of a non-positive ratio). Returns a
    DataFrame indexed like df with one column per ratio, named "num/den".
    """
    if base not in ("natural", "2", "10"):
        raise ValueError("base must be 'natural', '2', or '10'")

    if pairs is not None:
        selected = [(str(n), str(d)) for n, d in pairs]
    elif features is not None and reference is not None:
        selected = [(str(f), str(reference)) for f in features if str(f) != str(reference)]
    elif features is not None:
        selected = list(permutations([str(f) for f in features], 2))
    else:
        raise ValueError("provide one of: pairs, (features + reference), or features")

    needed = {c for pair in selected for c in pair}
    missing = [c for c in needed if c not in df.columns]
    if missing:
        raise ValueError(f"columns not found: {missing}")

    nums = np.array([c for c, _ in selected])
    dens = np.array([c for _, c in selected])
    num_block = df[nums].to_numpy(dtype=float) + eps
    den_block = df[dens].to_numpy(dtype=float) + eps

    with np.errstate(divide="ignore", invalid="ignore"):
        ratio = num_block / den_block
        if log:
            ratio = np.log(ratio)
            if base == "2":
                ratio = ratio / np.log(2)
            elif base == "10":
                ratio = ratio / np.log(10)

    names = [f"{n}/{d}" for n, d in selected]
    return pd.DataFrame(ratio, index=df.index, columns=names)
