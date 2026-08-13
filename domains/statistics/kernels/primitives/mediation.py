"""Mediation analysis (Baron-Kenny with a bootstrapped indirect effect).

Decomposes the effect of a treatment on an outcome into a direct path and an
indirect path through a mediator: does X act on Y partly *because* it changes M?
The indirect effect a*b is the quantity of interest; its confidence interval comes
from a nonparametric bootstrap (the modern standard, replacing the Sobel test),
computed in one call. Continuous outcome (OLS paths); covariates optional.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np
import pandas as pd


def _coef(design: np.ndarray, y: np.ndarray) -> np.ndarray:
    beta, *_ = np.linalg.lstsq(design, y, rcond=None)
    return beta


def _paths(t: np.ndarray, m: np.ndarray, yv: np.ndarray, cov: np.ndarray):
    """Return (a, b, direct c', total c) for one (resampled) dataset."""
    n = len(t)
    ones = np.ones((n, 1))
    base = np.column_stack([ones, t, cov]) if cov.size else np.column_stack([ones, t])
    a = _coef(base, m)[1]                                   # M ~ T (+cov)
    bdes = np.column_stack([ones, m, t, cov]) if cov.size else np.column_stack([ones, m, t])
    bcoef = _coef(bdes, yv)
    b, direct = bcoef[1], bcoef[2]                          # Y ~ M + T (+cov)
    total = _coef(base, yv)[1]                              # Y ~ T (+cov)
    return a, b, direct, total


def mediation_analysis(df: pd.DataFrame, treatment: str, mediator: str, outcome: str,
                       covariates: Optional[List[str]] = None, n_boot: int = 1000,
                       seed: int = 42) -> Dict[str, Any]:
    """Estimate the indirect (mediated), direct, and total effects of `treatment` on
    `outcome` through `mediator`, controlling for optional `covariates`. The indirect
    effect a*b gets a percentile bootstrap 95% CI and a two-sided bootstrap p-value.
    Complete cases over the named columns are used."""
    covariates = list(covariates or [])
    cols = [treatment, mediator, outcome, *covariates]
    for c in cols:
        if c not in df.columns:
            raise ValueError(f"column not found: {c}")
    d = df[cols].dropna()
    n = len(d)
    if n < len(covariates) + 4:
        raise ValueError("not enough complete cases for mediation analysis")

    t = d[treatment].to_numpy(float)
    m = d[mediator].to_numpy(float)
    yv = d[outcome].to_numpy(float)
    cov = d[covariates].to_numpy(float) if covariates else np.empty((n, 0))

    a, b, direct, total = _paths(t, m, yv, cov)
    indirect = a * b

    rng = np.random.default_rng(seed)
    boot = np.empty(n_boot)
    for i in range(n_boot):
        idx = rng.integers(0, n, n)
        ba, bb, _, _ = _paths(t[idx], m[idx], yv[idx], cov[idx] if cov.size else cov)
        boot[i] = ba * bb
    lo, hi = np.percentile(boot, [2.5, 97.5])
    frac_pos = float(np.mean(boot > 0))
    p_boot = 2 * min(frac_pos, 1 - frac_pos)

    return {
        "analysis_type": "mediation",
        "treatment": treatment,
        "mediator": mediator,
        "outcome": outcome,
        "covariates": covariates,
        "n_observations": int(n),
        "a_path": round(float(a), 5),
        "b_path": round(float(b), 5),
        "indirect_effect": round(float(indirect), 5),
        "indirect_ci95": [round(float(lo), 5), round(float(hi), 5)],
        "indirect_p_bootstrap": float(p_boot),
        "direct_effect": round(float(direct), 5),
        "total_effect": round(float(total), 5),
        "proportion_mediated": round(float(indirect / total), 5) if total != 0 else None,
        "n_bootstrap": int(n_boot),
        "interpretation_hint": (
            "The indirect effect (a*b) is mediation; judge it by its bootstrap CI, not "
            "the Baron-Kenny step significances. Proportion mediated is unstable when the "
            "total effect is near zero."
        ),
    }
