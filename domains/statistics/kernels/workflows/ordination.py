"""Ordination workflow — phase 1 of differential analysis: do the cohorts separate overall?

Distance (Aitchison for clade = Euclidean on the CLR matrix; log1p + z-scored Euclidean for
metabolites), PCoA, and a PERMANOVA cohort test.

Composed, not re-implemented: the transforms, the distance, the ordination and the group
test are all primitives. What stays here is the domain orchestration — which transform and
distance each omic gets, complete-case handling, dropping samples with no cohort label, and
the shape of the reported result.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

# Absolute rather than relative. There is no __init__.py anywhere under
# kernels/, so `primitives` and `workflows` are sibling top-level packages
# once the kernels directory is on the path, and `from ..primitives` asks
# for a parent package that does not exist. This file and survival.py both
# raised ImportError on every import until 2026-08-16, which is to say
# nothing had ever run them. differential.py carried the same defect.
from primitives.distances import compute_distance_matrix
from primitives.ordination import pcoa as _pcoa
from primitives.ordination import permanova as _permanova
from primitives.transformations import log_transform, zscore_transform

#: PERMANOVA permutations are seeded so the same data gives the same p-value twice.
_SEED = 0


def _omic_distance_matrix(matrix: pd.DataFrame, features: list[str], omic: str):
    """Return (sample_ids, square distance matrix, shape) for the chosen omic.

    Keeps only samples that have every feature for the omic (complete cases), since a
    distance is undefined when a feature is missing. Reports what was kept.

    The per-omic choice is the domain knowledge this workflow owns: clade features arrive
    CLR-transformed from the loader, so plain Euclidean on them IS Aitchison distance;
    metabolite concentrations are log1p'd and z-scored first so that features measured on
    wildly different scales contribute comparably.
    """
    block = matrix[["sample_id"] + features].copy()
    block = block.dropna(axis=0, how="any")  # complete-case samples
    sample_ids = block["sample_id"].tolist()
    X = block[features]

    if omic == "metab":
        X = log_transform(X, base="log1p")
        # Drop zero-variance features before standardizing: they carry no information, and
        # dropping (rather than keeping them as all-zero columns) is what n_features_used
        # has always reported.
        X = X.loc[:, X.std(axis=0, ddof=0) > 0]
        X = zscore_transform(X, ddof=0)
    # clade is already CLR; Euclidean on it is Aitchison distance

    d = np.asarray(compute_distance_matrix(X, metric="euclidean")["distance_matrix"], dtype=float)
    return sample_ids, d, X.shape


def _drop_unlabelled(sample_ids: list, dist: np.ndarray, group_map: dict):
    """Restrict to samples that have a cohort label — a sample with no cohort cannot take
    part in a group test. Returns (sample_ids, dist, groups, n_dropped)."""
    groups = [group_map.get(s) for s in sample_ids]
    keep = [i for i, g in enumerate(groups)
            if g is not None and not (isinstance(g, float) and np.isnan(g))]
    dropped = len(groups) - len(keep)
    if dropped:
        sample_ids = [sample_ids[i] for i in keep]
        dist = dist[np.ix_(keep, keep)]
        groups = [groups[i] for i in keep]
    return sample_ids, dist, groups, dropped


def _permanova_block(dist: np.ndarray, groups: list, sample_ids: list, permutations: int) -> dict:
    """The PERMANOVA primitive's result, in this workflow's reporting shape."""
    if len(set(map(str, groups))) < 2:
        return {"error": "need at least 2 groups for PERMANOVA"}
    res = _permanova(dist, [str(g) for g in groups], sample_ids=[str(s) for s in sample_ids],
                     permutations=permutations, seed=_SEED)
    counts = pd.Series([str(g) for g in groups]).value_counts()
    return {
        "pseudo_F": res["f_statistic"],
        "p_value": res["p_value"],
        # Effect size, from the primitive: the share of variation the cohorts explain.
        # A tiny p with a small R^2 is a real but slight separation, and saying so needs both.
        "r_squared": res["r_squared"],
        "permutations": res["n_permutations"],
        "groups": {lv: int(c) for lv, c in counts.items()},
        "interpretation_hint": (
            "PERMANOVA tests whether cohort centroids differ in multivariate space. "
            "A small p means the cohorts separate; read it with r_squared (how much "
            "variation cohort explains) and the PCoA proportion explained (how much "
            "structure the axes capture)."
        ),
    }


def _pcoa_block(dist: np.ndarray, sample_ids: list, n_axes: int) -> dict:
    """The PCoA primitive's result, truncated to n_axes, in this workflow's shape."""
    res = _pcoa(dist, sample_ids=[str(s) for s in sample_ids], dimensions=n_axes)
    eig = res["eigenvalues"]
    return {
        "coordinates": res["coordinates_matrix"],
        "proportion_explained": [round(float(p), 4) for p in res["proportion_explained"][:n_axes]],
        # Non-Euclidean distances can yield negative eigenvalues; when they are large the
        # ordination distorts the real distances and the axes should be read cautiously.
        "negative_eigenvalue_warning": bool(any(float(v) < -1e-6 for v in eig)),
    }


def _distance_label(omic: str) -> str:
    return ("aitchison (euclidean on CLR)" if omic == "clade"
            else "euclidean on log1p z-scored concentrations")


def beta_diversity(matrix: pd.DataFrame, features: list[str], omic: str, group_map: dict,
                   permutations: int = 999) -> dict:
    """Full phase-1 analysis: distance, PCoA, and PERMANOVA group test."""
    sample_ids, dist, shape = _omic_distance_matrix(matrix, features, omic)
    if len(sample_ids) < 3:
        return {"error": f"only {len(sample_ids)} complete-case samples; too few for ordination"}

    sample_ids, dist, groups, dropped = _drop_unlabelled(sample_ids, dist, group_map)
    ord_res = _pcoa_block(dist, sample_ids, n_axes=3)
    return {
        "omic": omic,
        "distance": _distance_label(omic),
        "n_samples_used": len(sample_ids),
        "n_features_used": int(shape[1]),
        "samples_dropped_missing_group": dropped,
        "pcoa": {
            "proportion_explained": ord_res["proportion_explained"],
            "negative_eigenvalue_warning": ord_res["negative_eigenvalue_warning"],
        },
        "permanova": _permanova_block(dist, groups, sample_ids, permutations),
    }


def ordinate(matrix: pd.DataFrame, features: list[str], omic: str, group_map: dict,
             permutations: int = 999) -> dict:
    """Return PCoA coordinates plus the PERMANOVA test, for plotting phase 1.

    Same distance and ordination as beta_diversity, but exposes the per-sample
    coordinates (which beta_diversity summarizes away) so a PCoA scatter can be drawn.
    """
    sample_ids, dist, shape = _omic_distance_matrix(matrix, features, omic)
    if len(sample_ids) < 3:
        return {"error": f"only {len(sample_ids)} complete-case samples; too few to ordinate"}
    sample_ids, dist, groups, _ = _drop_unlabelled(sample_ids, dist, group_map)
    ord_res = _pcoa_block(dist, sample_ids, n_axes=2)
    return {
        "sample_ids": sample_ids,
        "coordinates": ord_res["coordinates"],
        "proportion_explained": ord_res["proportion_explained"],
        "groups": [str(g) for g in groups],
        "permanova": _permanova_block(dist, groups, sample_ids, permutations),
        "omic": omic,
        "distance": _distance_label(omic),
    }
