'''
Longitudinal covariate aggregation.
Collapses per-subject multi-timepoint observations into one value per subject per feature.
Methods: nearest_origin, mean, median, first, last.
The caller (a workflow or tool) is responsible for input validation; this primitive assumes clean input.
'''

import numpy as np
from typing import Dict, List, Any, Optional

SUPPORTED_METHODS = ("nearest_origin", "mean", "median", "first", "last", "slope", "auc")


def _aggregate_subject(times: List[float], values: List[float], method: str) -> Optional[float]:
    clean_times: List[float] = []
    clean_values: List[float] = []
    for t, v in zip(times, values):
        if v is None or (isinstance(v, float) and np.isnan(v)):
            continue
        try:
            fv = float(v)
        except (TypeError, ValueError):
            continue
        if not np.isfinite(fv):
            continue
        clean_times.append(float(t))
        clean_values.append(fv)

    if not clean_values:
        return None

    if method == "mean":
        return float(np.mean(clean_values))
    if method == "median":
        return float(np.median(clean_values))
    if method == "nearest_origin":
        idx = min(range(len(clean_times)), key=lambda i: abs(clean_times[i]))
        return clean_values[idx]
    if method == "first":
        idx = min(range(len(clean_times)), key=lambda i: clean_times[i])
        return clean_values[idx]
    if method == "last":
        idx = max(range(len(clean_times)), key=lambda i: clean_times[i])
        return clean_values[idx]
    if method == "slope":
        if len(clean_values) < 2:
            return None
        try:
            return float(np.polyfit(clean_times, clean_values, 1)[0])
        except (np.linalg.LinAlgError, ValueError):
            return None
    if method == "auc":
        if len(clean_values) < 2:
            return None
        try:
            return float(np.trapz(clean_values, clean_times))
        except (ValueError, Exception):
            return None
    raise ValueError(f"Unsupported aggregation method: {method}")


def aggregate_covariate_matrix(feature_matrix: Dict[str, Any], method: str) -> Dict[str, Any]:
    result: Dict[str, Dict[str, Optional[float]]] = {}
    subject_ids = set()

    for feature_name, subjects in feature_matrix.items():
        feature_result: Dict[str, Optional[float]] = {}
        for subject_id, obs in subjects.items():
            subject_ids.add(subject_id)
            feature_result[subject_id] = _aggregate_subject(obs["times"], obs["values"], method)
        result[feature_name] = feature_result

    return {
        "aggregation_type": "covariate_aggregation",
        "method": method,
        "result": result,
        "n_features": len(feature_matrix),
        "n_subjects": len(subject_ids),
    }
