"""Partial least squares: PLS regression and PLS discriminant analysis (PLS-DA).

PLS projects many collinear predictors (the typical omics situation: more features
than samples) onto a few latent components that covary with the outcome. Both
functions return the latent scores, the per-feature VIP (variable importance in
projection), explained variance, and a cross-validated performance estimate, in one
call. No multiprocessing.
"""

from __future__ import annotations

from typing import Any, Dict, List

import numpy as np
from sklearn.cross_decomposition import PLSRegression
from sklearn.model_selection import StratifiedKFold, cross_val_score


def _json_num(v):
    if v is None:
        return None
    f = float(v)
    return f if np.isfinite(f) else None


def _vip(pls: PLSRegression, n_features: int) -> np.ndarray:
    """Variable Importance in Projection for each feature."""
    t = pls.x_scores_
    w = pls.x_weights_
    q = pls.y_loadings_
    ss = (t ** 2).sum(axis=0) * (q ** 2).sum(axis=0)  # explained SS per component
    total = ss.sum()
    if total <= 0:
        return np.zeros(n_features)
    w_norm = w / np.linalg.norm(w, axis=0)
    return np.sqrt(n_features * (w_norm ** 2 @ ss) / total)


def _explained_variance(pls: PLSRegression, X: np.ndarray) -> List[float]:
    total_var = X.var(axis=0, ddof=1).sum()
    if total_var <= 0:
        return [0.0] * pls.x_scores_.shape[1]
    return [float(pls.x_scores_[:, a].var(ddof=1) / total_var) for a in range(pls.x_scores_.shape[1])]


def pls_regression(X, Y, n_components: int = 2, feature_names: List[str] = None,
                   cv: int = 5, scale: bool = True) -> Dict[str, Any]:
    """PLS regression of a continuous outcome Y on predictors X. Returns the latent
    sample scores, per-feature VIP, per-component explained variance of X, and
    cross-validated R^2."""
    X = np.asarray(X, dtype=float)
    Y = np.asarray(Y, dtype=float)
    n_components = min(n_components, X.shape[1], X.shape[0] - 1)
    pls = PLSRegression(n_components=n_components, scale=scale)
    pls.fit(X, Y)

    names = list(feature_names) if feature_names is not None else [f"x{i}" for i in range(X.shape[1])]
    vip = _vip(pls, X.shape[1])
    k = max(2, min(cv, X.shape[0]))
    cv_scores = cross_val_score(PLSRegression(n_components=n_components, scale=scale), X, Y, cv=k, scoring="r2")

    return {
        "analysis_type": "pls_regression",
        "n_components": int(n_components),
        "n_observations": int(X.shape[0]),
        "n_features": int(X.shape[1]),
        "scores": pls.x_scores_.tolist(),
        "explained_variance_x": _explained_variance(pls, X),
        "vip": sorted(({"feature": n, "vip": _json_num(v)} for n, v in zip(names, vip)),
                      key=lambda d: d["vip"] or 0.0, reverse=True),
        "cv_r2_mean": _json_num(np.mean(cv_scores)),
        "cv_r2_std": _json_num(np.std(cv_scores)),
        "cv_folds": int(k),
    }


def pls_da(X, y, n_components: int = 2, feature_names: List[str] = None,
           cv: int = 5, scale: bool = True) -> Dict[str, Any]:
    """PLS discriminant analysis: PLS regression onto one-hot class indicators, used
    for classification. Returns latent scores, per-feature VIP, and a stratified
    cross-validated accuracy."""
    X = np.asarray(X, dtype=float)
    y = np.asarray(y)
    classes, y_idx = np.unique(y, return_inverse=True)
    if len(classes) < 2:
        raise ValueError("pls_da needs at least 2 classes")
    onehot = np.eye(len(classes))[y_idx]
    n_components = min(n_components, X.shape[1], X.shape[0] - 1)
    pls = PLSRegression(n_components=n_components, scale=scale)
    pls.fit(X, onehot)

    names = list(feature_names) if feature_names is not None else [f"x{i}" for i in range(X.shape[1])]
    vip = _vip(pls, X.shape[1])

    # stratified CV accuracy (manual, single-threaded)
    _, counts = np.unique(y_idx, return_counts=True)
    k = max(2, min(cv, int(counts.min())))
    accs = []
    if counts.min() >= 2:
        skf = StratifiedKFold(n_splits=k, shuffle=True, random_state=42)
        for tr, te in skf.split(X, y_idx):
            m = PLSRegression(n_components=min(n_components, len(tr) - 1), scale=scale)
            m.fit(X[tr], np.eye(len(classes))[y_idx[tr]])
            pred = m.predict(X[te]).argmax(axis=1)
            accs.append(float((pred == y_idx[te]).mean()))

    return {
        "analysis_type": "pls_da",
        "n_components": int(n_components),
        "n_observations": int(X.shape[0]),
        "n_features": int(X.shape[1]),
        "classes": [str(c) for c in classes],
        "scores": pls.x_scores_.tolist(),
        "vip": sorted(({"feature": n, "vip": _json_num(v)} for n, v in zip(names, vip)),
                      key=lambda d: d["vip"] or 0.0, reverse=True),
        "cv_accuracy_mean": _json_num(np.mean(accs)) if accs else None,
        "cv_accuracy_std": _json_num(np.std(accs)) if accs else None,
        "cv_folds": int(k) if accs else 0,
    }
