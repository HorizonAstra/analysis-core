"""Distance-matrix ordination and multivariate group tests (scikit-bio).

All blocks take a precomputed square distance matrix (samples x samples) and are
independent of how that distance was built — compute it with the distances block,
or with a transform + distances, and pass it here.

  pcoa               : Principal Coordinates Analysis (ordination).
  permanova          : permutational MANOVA — do group centroids differ? (+ R^2).
  permdisp           : permutational test of homogeneity of dispersions.
  run_beta_diversity : the beta-diversity bundle — PCoA + PERMANOVA + PERMDISP in
                       one call, composed from the three blocks above (no duplicated
                       logic). This is the single call the beta-diversity stage makes.
"""

import numpy as np
import pandas as pd
from typing import Any, Dict, List, Optional, Union

from skbio import DistanceMatrix
from skbio.stats.ordination import pcoa as skbio_pcoa
from skbio.stats.distance import permanova as skbio_permanova
from skbio.stats.distance import permdisp as skbio_permdisp

from .jsonsafe import json_safe_number as _json_safe


def _as_square(distance_matrix: Union[List[List[float]], np.ndarray]) -> np.ndarray:
    X = np.asarray(distance_matrix, dtype=np.float64)
    if X.ndim != 2 or X.shape[0] != X.shape[1]:
        raise ValueError("distance_matrix must be a square 2D array")
    return X


def _resolve_ids(sample_ids: Optional[List[str]], n: int) -> List[str]:
    if sample_ids is None:
        return [str(i) for i in range(n)]
    if len(sample_ids) != n:
        raise ValueError("sample_ids length must match distance matrix size")
    return sample_ids


def pcoa(
    distance_matrix: Union[List[List[float]], np.ndarray],
    sample_ids: Optional[List[str]] = None,
    method: str = "eigh",
    dimensions: Union[int, float] = 0,
    seed: Optional[int] = None,
    warn_neg_eigval: Union[bool, float] = 0.01,
) -> Dict[str, Any]:
    """Principal Coordinates Analysis on a distance matrix. Returns per-sample
    coordinates, eigenvalues, and proportion of variance explained per axis.
    Assumes inputs are validated by the caller."""
    X = _as_square(distance_matrix)
    n = X.shape[0]
    sample_ids = _resolve_ids(sample_ids, n)

    dm = DistanceMatrix(X, ids=sample_ids)
    ord_result = skbio_pcoa(dm, method=method, dimensions=dimensions, seed=seed, warn_neg_eigval=warn_neg_eigval)

    samples_df = ord_result.samples
    coords = samples_df.values
    axis_labels = list(samples_df.columns)
    n_dims = coords.shape[1]

    eigenvalues = np.asarray(ord_result.eigvals).flatten()[:n_dims]
    prop_explained = np.asarray(ord_result.proportion_explained).flatten()[:n_dims]
    cumulative_prop = np.cumsum(prop_explained).tolist()

    coordinates_by_axis = {label: coords[:, i].tolist() for i, label in enumerate(axis_labels[:n_dims])}

    return {
        "analysis_type": "pcoa",
        "n_samples": n,
        "n_dimensions_retained": n_dims,
        "method": method,
        "dimensions_param": dimensions,
        "sample_ids": sample_ids,
        "coordinates": coordinates_by_axis,
        "coordinates_matrix": coords.tolist(),
        "eigenvalues": [float(x) for x in eigenvalues],
        "proportion_explained": [float(x) for x in prop_explained],
        "cumulative_proportion_explained": [float(x) for x in cumulative_prop],
        "axis_labels": axis_labels[:n_dims],
    }


def permanova(
    distance_matrix: Union[List[List[float]], np.ndarray],
    grouping: List[str],
    sample_ids: Optional[List[str]] = None,
    permutations: int = 9999,
    seed: Optional[int] = None,
) -> Dict[str, Any]:
    """PERMANOVA: permutational multivariate analysis of variance. Tests whether
    groups differ in multivariate space. Reports the scikit-bio pseudo-F and a
    research-grade one-way R^2 effect size (SS_between / SS_total over unique pairs,
    matching vegan::adonis for a single factor). Assumes validated inputs."""
    X = _as_square(distance_matrix)
    n = X.shape[0]
    if len(grouping) != n:
        raise ValueError("grouping length must match distance matrix size")
    sample_ids = _resolve_ids(sample_ids, n)

    dm = DistanceMatrix(X, ids=sample_ids)
    series_result = skbio_permanova(dm, grouping, permutations=permutations, seed=seed)

    sq = X ** 2
    ss_total = float(sq[np.triu_indices(n, k=1)].sum() / n)
    ss_within = 0.0
    for g in pd.unique(pd.Series(grouping)):   # Series: pd.unique on a bare list is deprecated
        idx = [i for i, label in enumerate(grouping) if label == g]
        if len(idx) < 2:
            continue
        sub_sq = sq[np.ix_(idx, idx)]
        ss_within += float(sub_sq[np.triu_indices(len(idx), k=1)].sum() / len(idx))
    ss_between = ss_total - ss_within
    r_squared = ss_between / ss_total if ss_total > 0 else None

    return {
        "test_type": "permanova",
        "f_statistic": _json_safe(series_result.get("test statistic")),
        "p_value": _json_safe(series_result.get("p-value")),
        "r_squared": _json_safe(r_squared),
        "ss_total": _json_safe(ss_total),
        "ss_within": _json_safe(ss_within),
        "ss_between": _json_safe(ss_between),
        "n_permutations": int(series_result.get("number of permutations", permutations)),
        "sample_size": int(series_result.get("sample size", n)),
        "number_of_groups": int(series_result.get("number of groups", len(set(grouping)))),
        "grouping": grouping,
        "sample_ids": sample_ids,
        "parameters": {"permutations": permutations, "seed": seed},
        "raw_result": {str(k): _json_safe(v) for k, v in series_result.items()},
    }


def permdisp(
    distance_matrix: Union[List[List[float]], np.ndarray],
    grouping: List[str],
    sample_ids: Optional[List[str]] = None,
    test: str = "median",
    permutations: int = 9999,
    method: str = "eigh",
    dimensions: int = 10,
    seed: Optional[int] = None,
    warn_neg_eigval: Union[bool, float] = 0.01,
) -> Dict[str, Any]:
    """PERMDISP: permutational test of homogeneity of multivariate dispersions.
    Tests whether group spreads differ. Assumes validated inputs."""
    X = _as_square(distance_matrix)
    n = X.shape[0]
    if len(grouping) != n:
        raise ValueError("grouping length must match distance matrix size")
    sample_ids = _resolve_ids(sample_ids, n)

    dm = DistanceMatrix(X, ids=sample_ids)
    series_result = skbio_permdisp(
        dm, grouping, test=test, permutations=permutations,
        method=method, dimensions=dimensions, seed=seed, warn_neg_eigval=warn_neg_eigval,
    )

    return {
        "test_type": "permdisp",
        "f_statistic": _json_safe(series_result.get("test statistic")),
        "p_value": _json_safe(series_result.get("p-value")),
        "n_permutations": int(series_result.get("number of permutations", permutations)),
        "sample_size": int(series_result.get("sample size", n)),
        "number_of_groups": int(series_result.get("number of groups", len(set(grouping)))),
        "test": test,
        "method": method,
        "dimensions": dimensions,
        "grouping": grouping,
        "sample_ids": sample_ids,
        "parameters": {
            "test": test, "permutations": permutations, "method": method,
            "dimensions": dimensions, "seed": seed, "warn_neg_eigval": warn_neg_eigval,
        },
        "raw_result": {str(k): _json_safe(v) for k, v in series_result.items()},
    }


def run_beta_diversity(
    distance_matrix: Union[List[List[float]], np.ndarray],
    grouping: List[str],
    sample_ids: Optional[List[str]] = None,
    pcoa_method: str = "eigh",
    pcoa_dimensions: Union[int, float] = 0,
    permanova_permutations: int = 999,
    permdisp_test: str = "median",
    permdisp_permutations: int = 999,
    permdisp_method: str = "eigh",
    permdisp_dimensions: int = 10,
    seed: Optional[int] = None,
    warn_neg_eigval: Union[bool, float] = 0.01,
) -> Dict[str, Any]:
    """Beta-diversity bundle on a precomputed distance matrix: PCoA, PERMANOVA, and
    PERMDISP in one call. Composes the pcoa / permanova / permdisp blocks above, so
    there is exactly one implementation of each test. Assumes validated inputs."""
    return {
        "pcoa": pcoa(
            distance_matrix, sample_ids=sample_ids, method=pcoa_method,
            dimensions=pcoa_dimensions, seed=seed, warn_neg_eigval=warn_neg_eigval,
        ),
        "permanova": permanova(
            distance_matrix, grouping, sample_ids=sample_ids,
            permutations=permanova_permutations, seed=seed,
        ),
        "permdisp": permdisp(
            distance_matrix, grouping, sample_ids=sample_ids, test=permdisp_test,
            permutations=permdisp_permutations, method=permdisp_method,
            dimensions=permdisp_dimensions, seed=seed, warn_neg_eigval=warn_neg_eigval,
        ),
    }
