"""Survival primitives, built on lifelines.

  kaplan_meier   : Kaplan-Meier estimation, optionally stratified by group. Subject
                   aware (collapses repeated rows to one row per subject before
                   fitting) and returns both summaries (median, survival-at-times,
                   log-rank) and the full step curve with confidence band per group,
                   so the same call serves reporting and plotting.
  cox_ph_analysis: a full Cox proportional-hazards fit with every hyperparameter
                   exposed (penalizer, l1_ratio, strata, robust, clustering, ...).
  cox_univariate : a single-covariate Cox fit ("feature ~ T,E"), the unit of a sweep.
  cox_sweep      : cox_univariate run over a matrix of features in one bulk call.

Survival outcomes are subject level: when the input has repeated rows per subject,
the data is collapsed to one row per subject before fitting, otherwise each subject
is counted once per visit and the curve is wrong.
"""

from __future__ import annotations

import warnings
from typing import Any, Dict, List, Optional, Tuple, Union

import numpy as np
import pandas as pd
from lifelines import CoxPHFitter, KaplanMeierFitter
from lifelines.exceptions import ConvergenceWarning
from lifelines.statistics import multivariate_logrank_test


# ── Kaplan-Meier ────────────────────────────────────────────────────────────

def _collapse_to_subject(df: pd.DataFrame, subject_col: str | None, cols: list[str]) -> pd.DataFrame:
    if subject_col and subject_col in df.columns:
        # one row per subject; survival fields are assumed constant within subject
        return df.groupby(subject_col)[cols].first().reset_index()
    return df[cols].copy()


def _resolve_km_ci_columns(ci: pd.DataFrame) -> Tuple[str, str]:
    """Find the lower/upper confidence-band columns of a KM survival-function CI."""
    lo = hi = None
    for c in ci.columns:
        cs = str(c).lower()
        if "lower" in cs:
            lo = str(c)
        if "upper" in cs:
            hi = str(c)
    if lo is None or hi is None:
        raise ValueError("Could not infer KM confidence interval column names")
    return lo, hi


def _km_curve_with_origin(
    timeline: List[float], survival: List[float], lower: List[float], upper: List[float]
) -> Dict[str, List[float]]:
    """Prepend a (t=0, S=1) origin to a KM step curve so plots start at full survival."""
    if not timeline:
        return {"timeline": [0.0], "survival": [1.0], "confidence_lower": [1.0], "confidence_upper": [1.0]}
    if timeline[0] > 0.0:
        return {
            "timeline": [0.0] + timeline,
            "survival": [1.0] + survival,
            "confidence_lower": [1.0] + lower,
            "confidence_upper": [1.0] + upper,
        }
    surv, lo, hi = list(survival), list(lower), list(upper)
    surv[0] = lo[0] = hi[0] = 1.0
    return {"timeline": timeline, "survival": surv, "confidence_lower": lo, "confidence_upper": hi}


def kaplan_meier(
    df: pd.DataFrame,
    duration_col: str,
    event_col: str,
    group_col: str | None = None,
    subject_col: str | None = None,
    at_times: list[float] | None = None,
    alpha: float = 0.05,
) -> dict:
    """Fit Kaplan-Meier survival, optionally stratified by group_col.

    Returns, per group, the median survival, survival probability at requested
    times, and the full step curve with its (1 - alpha) confidence band; plus a
    multivariate log-rank test when a grouping is given.
    """
    needed = [duration_col, event_col] + ([group_col] if group_col else [])
    for col in needed:
        if col not in df.columns:
            raise ValueError(f"column not found: {col}")

    data = _collapse_to_subject(df, subject_col, needed).dropna(subset=[duration_col, event_col])
    at_times = at_times or [6, 12, 24]

    def fit_one(d: pd.DataFrame) -> dict:
        kmf = KaplanMeierFitter(alpha=alpha)
        kmf.fit(d[duration_col], event_observed=d[event_col])
        med = kmf.median_survival_time_
        surv = kmf.survival_function_at_times(at_times)
        sf = kmf.survival_function_
        value_col = sf.columns[0]
        t_raw = [float(x) for x in sf.index]
        s_raw = [float(x) for x in sf[value_col].values]
        ci = kmf.confidence_interval_survival_function_
        lo_col, hi_col = _resolve_km_ci_columns(ci)
        curve = _km_curve_with_origin(
            t_raw, s_raw, [float(x) for x in ci[lo_col].values], [float(x) for x in ci[hi_col].values]
        )
        return {
            "n_subjects": int(len(d)),
            "n_events": int(d[event_col].sum()),
            "median_survival": (None if pd.isna(med) else round(float(med), 3)),
            "survival_at_times": {str(t): round(float(surv.loc[t]), 4) for t in at_times},
            "curve": curve,
        }

    result: dict = {"duration_col": duration_col, "event_col": event_col, "at_times": at_times}

    if group_col:
        result["groups"] = {str(g): fit_one(d) for g, d in data.groupby(group_col)}
        lr = multivariate_logrank_test(data[duration_col], data[group_col], data[event_col])
        result["logrank"] = {
            "test_statistic": round(float(lr.test_statistic), 4),
            "p_value": float(lr.p_value),
            "interpretation_hint": (
                "Log-rank tests whether survival curves differ. Pair the p-value "
                "with the median-survival gap; significance without effect size is hollow."
            ),
        }
    else:
        result["overall"] = fit_one(data)

    return result


# ── Cox proportional hazards ────────────────────────────────────────────────

def _safe_float(x):
    if x is None:
        return None
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    return v if np.isfinite(v) else None


def _cox_confidence_bounds(ci: pd.DataFrame) -> Tuple[Optional[pd.Series], Optional[pd.Series]]:
    if ci is None or ci.empty or len(ci.columns) < 2:
        return None, None
    lower_col = upper_col = None
    for col in ci.columns:
        label = str(col).lower()
        if "lower" in label:
            lower_col = col
        if "upper" in label:
            upper_col = col
    if lower_col is None or upper_col is None:
        return None, None
    return ci[lower_col], ci[upper_col]


def cox_ph_analysis(
    df: pd.DataFrame,
    duration_col: str,
    event_col: str,
    penalizer: float = 0.0,
    l1_ratio: float = 0.0,
    alpha: float = 0.05,
    baseline_estimation_method: str = "breslow",
    strata: Optional[Union[List[str], str]] = None,
    weights_col: Optional[str] = None,
    robust: bool = False,
    cluster_col: Optional[str] = None,
    entry_col: Optional[str] = None,
    formula: Optional[str] = None,
    show_progress: bool = False,
) -> Dict[str, Any]:
    """Fit a Cox proportional hazards model. All hyperparameters are configurable.
    Returns coefficients, hazard ratios, CIs, p-values, concordance, AIC/BIC, etc.
    Assumes inputs are validated by the caller."""
    cph = CoxPHFitter(
        penalizer=penalizer,
        l1_ratio=l1_ratio,
        baseline_estimation_method=baseline_estimation_method,
        alpha=alpha,
        strata=strata,
    )
    fit_kwargs = dict(
        duration_col=duration_col,
        event_col=event_col,
        weights_col=weights_col,
        robust=robust,
        cluster_col=cluster_col,
        entry_col=entry_col,
        formula=formula,
        show_progress=show_progress,
    )
    converged = True
    with warnings.catch_warnings():
        warnings.simplefilter("error", ConvergenceWarning)
        try:
            cph.fit(df, **fit_kwargs)
        except ConvergenceWarning:
            converged = False
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", ConvergenceWarning)
                cph.fit(df, **fit_kwargs)

    params = cph.params_
    ci = cph.confidence_intervals_

    coefficients = {str(k): _safe_float(v) for k, v in params.items()}
    hazard_ratios = {str(k): _safe_float(v) for k, v in cph.hazard_ratios_.items()}
    standard_errors = {str(k): _safe_float(v) for k, v in cph.standard_errors_.items()}

    ci_lower, ci_upper = _cox_confidence_bounds(ci)
    if ci_lower is not None and ci_upper is not None:
        confidence_intervals = {
            str(k): {"lower": _safe_float(ci_lower.get(k)), "upper": _safe_float(ci_upper.get(k))}
            for k in params.index
        }
    else:
        confidence_intervals = {}

    summary_df = cph.summary
    summary_table = []
    if summary_df is not None and not summary_df.empty:
        for name in summary_df.index:
            row = summary_df.loc[name]
            row_dict = {"covariate": str(name)}
            for col in summary_df.columns:
                row_dict[str(col)] = _safe_float(row[col]) if col in row.index else None
            summary_table.append(row_dict)

    n_events = int(df[event_col].sum()) if event_col in df.columns else None
    variance_matrix = None
    if getattr(cph, "variance_matrix_", None) is not None:
        variance_matrix = cph.variance_matrix_.to_dict()

    return {
        "analysis_type": "cox_ph",
        "model": "Cox proportional hazards",
        "n_observations": int(len(df)),
        "n_events": n_events,
        "coefficients": coefficients,
        "hazard_ratios": hazard_ratios,
        "standard_errors": standard_errors,
        "confidence_intervals": confidence_intervals,
        "confidence_level": 1 - alpha,
        "summary_table": summary_table,
        "concordance_index": _safe_float(getattr(cph, "concordance_index_", None)),
        "log_likelihood": _safe_float(getattr(cph, "log_likelihood_", None)),
        "partial_aic": _safe_float(getattr(cph, "AIC_partial_", None)),
        "aic": _safe_float(getattr(cph, "AIC_partial_", None)),
        "bic": _safe_float(getattr(cph, "BIC_", None)),
        "variance_matrix": variance_matrix,
        "duration_col": duration_col,
        "event_col": event_col,
        "converged": converged,
        "parameters": {
            "penalizer": penalizer,
            "l1_ratio": l1_ratio,
            "alpha": alpha,
            "baseline_estimation_method": baseline_estimation_method,
            "strata": strata,
            "weights_col": weights_col,
            "robust": robust,
            "cluster_col": cluster_col,
        },
    }


def _drop_nan_aligned(
    times: List[float], events: List[int], covariate: List[float]
) -> Tuple[List[float], List[int], List[float]]:
    out_t, out_e, out_c = [], [], []
    for ti, ei, ci in zip(times, events, covariate):
        if ci is None or pd.isna(ci):
            continue
        fv = float(ci)
        if not np.isfinite(fv):
            continue
        out_t.append(float(ti))
        out_e.append(int(ei))
        out_c.append(fv)
    return out_t, out_e, out_c


def _cox_univariate_p_z(summary_table: List[Dict[str, Any]]) -> Tuple[float, float]:
    for row in summary_table:
        if row.get("covariate") != "feature":
            continue
        pv, zv = row.get("p"), row.get("z")
        if pv is None or zv is None:
            break
        return float(pv), float(zv)
    raise ValueError("Could not read p- and z-statistics for covariate 'feature' from Cox summary")


def cox_univariate(
    times: List[float],
    events: List[int],
    covariate: List[float],
    feature_name: str,
    penalizer: float = 0.0,
    l1_ratio: float = 0.0,
    alpha: float = 0.05,
    robust: bool = False,
) -> Dict[str, Any]:
    """Single-covariate Cox fit ("feature ~ T, E") for one feature. NaN covariate
    rows are dropped first. Returns HR with CI, p, z, concordance, and convergence."""
    t2, e2, c2 = _drop_nan_aligned(times, events, covariate)
    if len(t2) < 2:
        raise ValueError("cox_univariate needs at least 2 subjects after removing missing covariate values")
    df = pd.DataFrame({"T": t2, "E": e2, "feature": c2})
    # breslow is the only ties handling exposed by CoxPHFitter's baseline methods
    result = cox_ph_analysis(
        df,
        duration_col="T",
        event_col="E",
        formula="feature",
        baseline_estimation_method="breslow",
        penalizer=penalizer,
        l1_ratio=l1_ratio,
        alpha=alpha,
        robust=robust,
    )
    hr = result["hazard_ratios"].get("feature")
    ci_feat = result["confidence_intervals"].get("feature") or {}
    hr_lower_95 = np.exp(ci_feat["lower"]) if ci_feat.get("lower") is not None else None
    hr_upper_95 = np.exp(ci_feat["upper"]) if ci_feat.get("upper") is not None else None
    p_value, z_stat = _cox_univariate_p_z(result["summary_table"])
    n_events = result["n_events"]
    warn = "n_events < 10: coefficient estimates unreliable" if (n_events is not None and n_events < 10) else None
    return {
        "analysis_type": "cox_univariate",
        "feature_name": feature_name,
        "hr": _safe_float(hr),
        "hr_lower_95": _safe_float(hr_lower_95),
        "hr_upper_95": _safe_float(hr_upper_95),
        "p_value": _safe_float(p_value),
        "z": _safe_float(z_stat),
        "n_subjects": int(result["n_observations"]),
        "n_events": int(n_events) if n_events is not None else 0,
        "concordance": _safe_float(result["concordance_index"]),
        "converged": result["converged"],
        "warning": warn,
    }


def cox_sweep(
    feature_matrix: Dict[str, List[float]],
    times: List[float],
    events: List[int],
    penalizer: float = 0.0,
    l1_ratio: float = 0.0,
    alpha: float = 0.05,
    robust: bool = False,
) -> Dict[str, Any]:
    """Run cox_univariate over every feature in feature_matrix in one bulk call.

    Each value list is a covariate aligned to times/events. Features that error out
    or fail to converge are reported separately rather than aborting the sweep. Cox
    fits are iterative per-feature model fits, so this is an honest sequential loop
    (no vectorization or process pool is applicable).
    """
    results: List[Dict[str, Any]] = []
    failed_features: List[str] = []
    convergence_failed_features: List[str] = []

    for feature_name, covariate in feature_matrix.items():
        try:
            outcome = cox_univariate(
                times, events, covariate, feature_name,
                penalizer=penalizer, l1_ratio=l1_ratio, alpha=alpha, robust=robust,
            )
        except Exception:  # noqa: BLE001 - a bad feature must not sink the whole sweep
            failed_features.append(feature_name)
            continue
        if outcome.get("converged") is False:
            convergence_failed_features.append(feature_name)
        results.append(outcome)

    return {
        "analysis_type": "cox_sweep",
        "results": results,
        "n_features_tested": len(feature_matrix),
        "n_features_failed": len(failed_features),
        "failed_features": failed_features,
        "n_convergence_failures": len(convergence_failed_features),
        "convergence_failed_features": convergence_failed_features,
    }
