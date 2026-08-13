"""Survival workflow: two stages, eligible to run independently.

  kaplan_meier_stage : kaplan_meier over all cohorts, then a cox_univariate per
                       ordered cohort pair (a comparison-vs-reference indicator)
                       whose hazard ratios annotate the KM curves.
  cox_sweep_stage    : optional transform (skipped for a trajectory strategy) ->
                       aggregate_covariate_matrix (method chosen by strategy) ->
                       cox_sweep -> adjust_pvalues (BH-FDR). Display is pooled (one
                       sweep) or per-cohort (one sweep each).
"""

from __future__ import annotations

from itertools import permutations

import numpy as np
import pandas as pd

from ..primitives.aggregation import aggregate_covariate_matrix
from ..primitives.multiple_testing import adjust_pvalues
from ..primitives.survival import cox_sweep, cox_univariate, kaplan_meier

# covariate strategy -> aggregation method
_STRATEGY_METHOD = {
    "nearest_origin": "nearest_origin",
    "median": "median", "mean": "mean", "first": "first", "last": "last",
    "slope": "slope", "auc": "auc",
}
_TRAJECTORY_STRATEGIES = ("slope", "auc")


def kaplan_meier_stage(
    df: pd.DataFrame,
    duration_col: str,
    event_col: str,
    cohort_col: str,
    subject_col: str | None = None,
    at_times: list[float] | None = None,
) -> dict:
    """KM over all cohorts plus a cox_univariate hazard ratio for every ordered
    (reference, comparison) cohort pair, for annotating the curves."""
    km = kaplan_meier(df, duration_col, event_col, group_col=cohort_col, subject_col=subject_col, at_times=at_times)

    # collapse to one row per subject so each subject is counted once in the HRs
    cols = [duration_col, event_col, cohort_col]
    if subject_col and subject_col in df.columns:
        sub = df.groupby(subject_col)[cols].first().reset_index()
    else:
        sub = df[cols].copy()
    sub = sub.dropna(subset=cols)

    cohorts = list(pd.unique(sub[cohort_col]))
    hazard_ratios = {}
    for ref, comp in permutations(cohorts, 2):
        pair = sub[sub[cohort_col].isin([ref, comp])]
        times = pair[duration_col].astype(float).tolist()
        events = pair[event_col].astype(int).tolist()
        indicator = (pair[cohort_col] == comp).astype(int).tolist()
        try:
            hazard_ratios[f"{comp} vs {ref}"] = cox_univariate(times, events, indicator, f"{comp} vs {ref}")
        except Exception as e:  # noqa: BLE001 - a degenerate pair must not sink the stage
            hazard_ratios[f"{comp} vs {ref}"] = {"error": str(e)}

    return {"stage": "kaplan_meier", "kaplan_meier": km, "cohort_hazard_ratios": hazard_ratios}


def _aligned_sweep(feature_long: dict, subjects: list, times: list[float], events: list[int], method: str,
                   penalizer: float, adjust: bool) -> dict:
    """Aggregate each feature to one value per subject, align to the subject order,
    run cox_sweep, then BH-adjust the p-values."""
    agg = aggregate_covariate_matrix(feature_long, method)["result"]
    feature_matrix = {f: [per_subject.get(s) for s in subjects] for f, per_subject in agg.items()}
    sweep = cox_sweep(feature_matrix, times, events, penalizer=penalizer)
    if adjust:
        pvals, idx = [], []
        for i, r in enumerate(sweep["results"]):
            if r.get("p_value") is not None:
                pvals.append(r["p_value"])
                idx.append(i)
        if pvals:
            adjusted = adjust_pvalues(pvals, "bh")["adjusted"]
            for i, q in zip(idx, adjusted):
                sweep["results"][i]["adjusted_p_value"] = q
        sweep["multiple_testing"] = "BH-FDR applied across swept features"
    return sweep


def cox_sweep_stage(
    feature_long: dict,
    survival: dict,
    strategy: str = "median",
    display: str = "pooled",
    penalizer: float = 0.0,
    adjust: bool = True,
) -> dict:
    """Cox sweep over many features.

    feature_long : {feature: {subject: {"times": [...], "values": [...]}}}.
    survival     : {subject: {"time": float, "event": 0/1, "cohort": label}}.
    strategy     : aggregation strategy (nearest_origin | mean | median | first |
                   last | slope | auc). slope/auc are trajectory strategies.
    display      : "pooled" (one sweep over all subjects) or "cohorts" (one sweep
                   per cohort).
    """
    if strategy not in _STRATEGY_METHOD:
        raise ValueError(f"unknown strategy {strategy!r}; valid: {tuple(_STRATEGY_METHOD)}")
    method = _STRATEGY_METHOD[strategy]
    is_trajectory = strategy in _TRAJECTORY_STRATEGIES

    def sweep_for(subject_subset: list) -> dict:
        subjects = [s for s in subject_subset if s in survival]
        times = [float(survival[s]["time"]) for s in subjects]
        events = [int(survival[s]["event"]) for s in subjects]
        return _aligned_sweep(feature_long, subjects, times, events, method, penalizer, adjust)

    all_subjects = list(survival.keys())
    result: dict = {"stage": "cox_sweep", "strategy": strategy, "aggregation_method": method,
                    "transform_skipped": is_trajectory, "display": display}

    if display == "cohorts":
        by_cohort: dict[str, list] = {}
        for s, rec in survival.items():
            by_cohort.setdefault(str(rec.get("cohort")), []).append(s)
        result["sweeps"] = {cohort: sweep_for(subs) for cohort, subs in by_cohort.items()}
    else:
        result["sweep"] = sweep_for(all_subjects)
    return result
