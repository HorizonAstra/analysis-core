"""Tree-based prediction: a single decision tree, a random forest, and gradient
boosting, for either classification or regression.

Each fits one model on a feature matrix in a single call, reports an honest
cross-validated performance estimate (ROC-AUC for binary classification, accuracy
for multiclass, R^2 for regression), and returns feature importances. The task is
inferred from the target unless given. No multiprocessing: estimators run
single-threaded (n_jobs is left at its default of 1).

The single tree is the interpretable baseline; the forest and boosting trade
interpretability for accuracy and robustness. All three are kept because which one
is appropriate depends on the study — none subsumes the others.
"""

from __future__ import annotations

from typing import Any, Dict, List

import numpy as np
import pandas as pd
from sklearn.ensemble import (
    GradientBoostingClassifier,
    GradientBoostingRegressor,
    RandomForestClassifier,
    RandomForestRegressor,
)
from sklearn.model_selection import cross_val_score
from sklearn.tree import DecisionTreeClassifier, DecisionTreeRegressor

_ESTIMATORS = {
    "decision_tree": (DecisionTreeClassifier, DecisionTreeRegressor),
    "random_forest": (RandomForestClassifier, RandomForestRegressor),
    "gradient_boosting": (GradientBoostingClassifier, GradientBoostingRegressor),
}


def _infer_task(y: np.ndarray) -> str:
    if y.dtype.kind in "OUSb":
        return "classification"
    u = np.unique(y[~pd.isna(y)])
    if u.size <= 10 and np.all(u == u.astype(int)):
        return "classification"
    return "regression"


def _json_num(v):
    if v is None:
        return None
    f = float(v)
    return f if np.isfinite(f) else None


def _run(kind: str, X, y, task: str, cv: int, feature_names: List[str] | None, params: dict) -> Dict[str, Any]:
    X = np.asarray(X, dtype=float)
    y = np.asarray(y)
    if task == "auto":
        task = _infer_task(y)
    clf_cls, reg_cls = _ESTIMATORS[kind]
    est = (clf_cls if task == "classification" else reg_cls)(random_state=42, **params)

    # honest cross-validated score (folds bounded so stratification is always valid)
    cv_mean = cv_std = None
    scoring = "r2"
    if task == "classification":
        _, counts = np.unique(y, return_counts=True)
        n_classes = len(counts)
        scoring = "roc_auc" if n_classes == 2 else "accuracy"
        k = min(cv, int(counts.min()))
        feasible = counts.min() >= 2
    else:
        k = min(cv, len(y))
        feasible = len(y) >= 2
    if feasible and k >= 2:
        scores = cross_val_score(est, X, y, cv=k, scoring=scoring)
        cv_mean, cv_std = _json_num(np.mean(scores)), _json_num(np.std(scores))
    else:
        k = 0

    est.fit(X, y)
    names = list(feature_names) if feature_names is not None else [f"x{i}" for i in range(X.shape[1])]
    importances = sorted(
        ({"feature": n, "importance": _json_num(imp)} for n, imp in zip(names, est.feature_importances_)),
        key=lambda d: (d["importance"] is not None, d["importance"]), reverse=True,
    )

    out = {
        "analysis_type": kind,
        "task": task,
        "n_observations": int(X.shape[0]),
        "n_features": int(X.shape[1]),
        "cv_metric": scoring,
        "cv_score_mean": cv_mean,
        "cv_score_std": cv_std,
        "cv_folds": int(k),
        "feature_importances": importances,
        "parameters": params,
    }
    if task == "classification":
        out["classes"] = [str(c) for c in np.unique(y)]
    return out


def decision_tree(X, y, task: str = "auto", max_depth: int = 5, cv: int = 5,
                  feature_names: List[str] = None) -> Dict[str, Any]:
    """A single (interpretable) decision tree. max_depth bounds complexity."""
    return _run("decision_tree", X, y, task, cv, feature_names, {"max_depth": max_depth})


def random_forest(X, y, task: str = "auto", n_estimators: int = 300, max_depth: int = None,
                  cv: int = 5, feature_names: List[str] = None) -> Dict[str, Any]:
    """A random forest of trees — strong, robust default for tabular prediction."""
    return _run("random_forest", X, y, task, cv, feature_names,
                {"n_estimators": n_estimators, "max_depth": max_depth})


def gradient_boosting(X, y, task: str = "auto", n_estimators: int = 200, max_depth: int = 3,
                      learning_rate: float = 0.1, cv: int = 5,
                      feature_names: List[str] = None) -> Dict[str, Any]:
    """Gradient-boosted trees — often the most accurate, more sensitive to tuning."""
    return _run("gradient_boosting", X, y, task, cv, feature_names,
                {"n_estimators": n_estimators, "max_depth": max_depth, "learning_rate": learning_rate})
