'''
Pairwise distance / dissimilarity matrix computation.

Supported metrics
-----------------
Metagenomics (compositional / count-based):
    bray_curtis   — Bray-Curtis dissimilarity (de facto standard for β-diversity)
    jaccard       — Jaccard index on binary (presence/absence) data
    canberra      — Canberra distance (down-weights abundant taxa)

Metabolomics / continuous features:
    euclidean     — L2 norm (standard for metabolomics PCoA / PCA input)
    manhattan     — L1 norm (cityblock)
    cosine        — 1 − cosine similarity (angle between feature vectors)
    correlation   — 1 − Pearson correlation (shape similarity across features)
    chebyshev     — L-∞ norm (max absolute difference per feature)

Compositional (Aitchison geometry):
    aitchison     — Euclidean distance on CLR-transformed data; requires all
                    non-negative values (zeros handled via multiplicative replacement).
                    The CLR step is delegated to transformations.clr_transform so
                    there is a single CLR implementation; this block does not
                    reimplement compositional handling.
'''

import numpy as np
import pandas as pd
from typing import Dict, Any, List, Optional, Union
from scipy.spatial.distance import pdist, squareform

from .transformations import clr_transform

# scipy metric names that map 1-to-1 from our public names
_SCIPY_METRICS = {
    "bray_curtis": "braycurtis",
    "jaccard": "jaccard",
    "canberra": "canberra",
    "euclidean": "euclidean",
    "manhattan": "cityblock",
    "cosine": "cosine",
    "correlation": "correlation",
    "chebyshev": "chebyshev",
}

SUPPORTED_METRICS = list(_SCIPY_METRICS.keys()) + ["aitchison"]


def compute_distance_matrix(
    feature_df: pd.DataFrame,
    metric: str = "bray_curtis",
    sample_ids: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """
    Compute a symmetric pairwise distance matrix from a samples × features table.

    Parameters
    ----------
    feature_df : pd.DataFrame
        Rows = samples, columns = features. Values must be numeric and finite.
    metric : str
        One of SUPPORTED_METRICS.
    sample_ids : list[str] or None
        Labels for rows. If None, uses feature_df.index (cast to str).

    Returns
    -------
    dict with keys:
        metric, n_samples, sample_ids, distance_matrix (2-D list, symmetric, zero diagonal),
        min_distance, max_distance, mean_distance, parameters.

    The caller (a workflow or tool) is responsible for input validation; this primitive assumes clean input.
    """
    X = feature_df.values.astype(np.float64)
    n_samples = X.shape[0]

    ids = (
        [str(s) for s in sample_ids]
        if sample_ids is not None
        else [str(s) for s in feature_df.index]
    )

    if metric == "aitchison":
        # Aitchison distance = Euclidean distance on CLR-transformed data. The CLR
        # (with multiplicative replacement for zeros) is the transformations block's
        # job, not this one's, so we reuse it rather than duplicate it here.
        X_clr = clr_transform(feature_df).values.astype(np.float64)
        condensed = pdist(X_clr, metric="euclidean")
    else:
        scipy_metric = _SCIPY_METRICS[metric]
        condensed = pdist(X, metric=scipy_metric)

    matrix = squareform(condensed)

    # Summary stats on the upper triangle only (excluding diagonal zeros)
    upper = condensed  # pdist already gives upper-triangle values
    return {
        "metric": metric,
        "n_samples": n_samples,
        "sample_ids": ids,
        "distance_matrix": matrix.tolist(),
        "min_distance": float(upper.min()) if len(upper) > 0 else 0.0,
        "max_distance": float(upper.max()) if len(upper) > 0 else 0.0,
        "mean_distance": float(upper.mean()) if len(upper) > 0 else 0.0,
        "parameters": {
            "metric": metric,
            "n_samples": n_samples,
            "n_features": X.shape[1],
        },
    }
