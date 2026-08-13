"""Confounding and collinearity diagnostics.

  vif                    : variance inflation factors — how collinear each predictor
                           is with the others (VIF > 5-10 flags a problem).
  confounding_assessment : the change-in-estimate approach — compare the crude
                           exposure->outcome effect to the effect adjusted for each
                           candidate confounder, and flag those that move it
                           materially (the classic 10% rule).
"""

from __future__ import annotations

from typing import Any, Dict, List

import numpy as np
import pandas as pd
import statsmodels.api as sm


def _json_num(v):
    if v is None:
        return None
    f = float(v)
    return f if np.isfinite(f) else None


def vif(df: pd.DataFrame, predictors: List[str]) -> Dict[str, Any]:
    """Variance inflation factor for each predictor: 1 / (1 - R^2_j), where R^2_j is
    from regressing predictor j on all the others. Complete cases are used."""
    d = df[list(predictors)].dropna().astype(float)
    if d.shape[1] < 2:
        raise ValueError("VIF needs at least 2 predictors")
    results = []
    cols = list(d.columns)
    for j, col in enumerate(cols):
        others = [c for c in cols if c != col]
        X = sm.add_constant(d[others])
        r2 = sm.OLS(d[col], X).fit().rsquared
        v = 1.0 / (1.0 - r2) if r2 < 1 else float("inf")
        results.append({"predictor": col, "vif": _json_num(v), "r_squared": _json_num(r2)})
    return {
        "analysis_type": "vif",
        "n_observations": int(len(d)),
        "results": sorted(results, key=lambda r: (r["vif"] is not None, r["vif"]), reverse=True),
        "interpretation_hint": "VIF > 5 suggests notable collinearity; > 10 is severe.",
    }


def confounding_assessment(df: pd.DataFrame, exposure: str, outcome: str,
                           candidate_confounders: List[str], family: str = "gaussian",
                           threshold: float = 0.10) -> Dict[str, Any]:
    """For each candidate confounder, compare the crude exposure effect on the outcome
    to the effect adjusted for that confounder, and report the relative change in the
    exposure coefficient. A change above `threshold` (default 10%) flags confounding.
    Also fits the fully-adjusted model. family: 'gaussian' (continuous outcome, OLS)
    or 'binomial' (binary outcome, logistic; effects are on the log-odds scale)."""
    cols = [exposure, outcome, *candidate_confounders]
    for c in cols:
        if c not in df.columns:
            raise ValueError(f"column not found: {c}")
    d = df[cols].dropna()

    if family == "binomial":
        levels = sorted(pd.unique(d[outcome]), key=lambda v: str(v))
        if len(levels) != 2:
            raise ValueError("binomial family needs a binary outcome")
        y = (d[outcome] == levels[1]).astype(float)
        fit = lambda X: sm.Logit(y, sm.add_constant(X)).fit(disp=False)
    elif family == "gaussian":
        y = d[outcome].astype(float)
        fit = lambda X: sm.OLS(y, sm.add_constant(X)).fit()
    else:
        raise ValueError("family must be 'gaussian' or 'binomial'")

    crude = fit(d[[exposure]].astype(float)).params[exposure]

    per_confounder = []
    for c in candidate_confounders:
        adj = fit(d[[exposure, c]].astype(float)).params[exposure]
        pct = abs((adj - crude) / crude) if crude != 0 else None
        per_confounder.append({
            "confounder": c,
            "adjusted_exposure_effect": _json_num(adj),
            "percent_change": _json_num(pct),
            "is_confounder": bool(pct is not None and pct >= threshold),
        })

    full = fit(d[[exposure, *candidate_confounders]].astype(float)).params[exposure]
    return {
        "analysis_type": "confounding_assessment",
        "exposure": exposure,
        "outcome": outcome,
        "family": family,
        "effect_scale": "log_odds" if family == "binomial" else "linear",
        "n_observations": int(len(d)),
        "crude_exposure_effect": _json_num(crude),
        "fully_adjusted_exposure_effect": _json_num(full),
        "threshold": threshold,
        "candidates": sorted(per_confounder, key=lambda r: (r["percent_change"] is not None, r["percent_change"]), reverse=True),
        "interpretation_hint": (
            "A confounder is identified by how much it moves the exposure effect "
            "(change-in-estimate), not by its own p-value."
        ),
    }
