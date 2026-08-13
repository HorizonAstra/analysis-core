"""Linear mixed-effects / OLS association modeling — the general, domain-agnostic engine.

Two layers, both batch-first (a call that takes many features also takes one):

  fit_mixed_model              fit ONE model to one response: a random-intercept mixed model
                               when a grouping is given and repeats, else OLS, with an OLS
                               fallback if the mixed fit will not converge. Returns the
                               fixed-effect estimates, their covariance, and fit metadata —
                               enough to read off coefficients OR any linear contrast.

  linear_mixed_effects_association
                               fit one model PER feature against a shared fixed-effects
                               formula and return the coefficient table for every
                               (feature, term). One bulk call covers every feature.

Deliberately NOT here: multiple-testing correction (that is `adjust_pvalues`' job — the
caller composes it over whichever p-values form the family it cares about) and any domain
assumption (CLR, subject-as-group, time adjustment — the caller supplies those via the data
and formula it passes). This is the one mixed-model engine; workflows compose it rather than
re-fitting inline, so there is a single optimizer/variance configuration and no drift.
"""

from __future__ import annotations

import warnings

import numpy as np
import pandas as pd
import patsy
import statsmodels.api as sm

from .jsonsafe import json_safe_number as _json_safe_number

# Mixed-model optimizers, in order of attempt. lbfgs is deliberately excluded: it can report
# success while returning a non-converged fit, so a silently wrong estimate. reml=True by
# default gives the less-biased variance-component estimate.
_METHODS = ["bfgs", "cg", "powell"]


def fit_mixed_model(endog, exog, groups=None, *, reml: bool = True,
                    method: list[str] | None = None) -> dict:
    """Fit one linear model to a single response and return its fixed-effect estimates.

    endog    length-n response vector.
    exog     n x k design matrix, INCLUDING its intercept column — the caller builds it
             (e.g. via patsy), so this stays formula- and domain-agnostic.
    groups   length-n grouping for a random intercept (e.g. subject id). A mixed model is
             fit when groups is given and has fewer levels than observations (repeated
             measures); otherwise, or if the mixed fit will not converge, OLS is used.

    Returns {params, bse, tvalues, pvalues, cov, df_resid, model_used, converged}:
      params/bse/tvalues/pvalues  length-k fixed-effect arrays (tvalues are Wald z for the
                                  mixed model, t for OLS; pvalues match).
      cov                         k x k covariance of the fixed effects — the raw material
                                  for ANY linear contrast (effect = c·beta, var = c·cov·c).
      df_resid                    residual df for OLS (contrast p-values use t); None for the
                                  mixed model (contrast p-values use the normal).
      model_used                  'mixed' | 'ols'.
    No multiple-testing correction and no per-feature loop — this is the single-fit unit.
    """
    method = method or _METHODS
    endog = np.asarray(endog, dtype=float)
    exog = np.asarray(exog, dtype=float)
    k = exog.shape[1]

    want_mixed = groups is not None and pd.Series(groups).nunique() < len(endog)
    if want_mixed:
        try:
            # The engine owns convergence: it retries optimizers and falls back to OLS below,
            # so statsmodels' per-retry ConvergenceWarnings are internal noise, not the
            # caller's to see (a whole-omic batch would otherwise flood thousands of them).
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                r = sm.MixedLM(endog, exog, groups=np.asarray(groups)).fit(
                    reml=reml, method=method, disp=False)
            if getattr(r, "converged", True):
                cov = np.asarray(r.cov_params())[:k, :k]
                return {
                    "params": np.asarray(r.fe_params, dtype=float),
                    "bse": np.asarray(r.bse_fe, dtype=float),
                    "tvalues": np.asarray(r.tvalues, dtype=float)[:k],
                    "pvalues": np.asarray(r.pvalues, dtype=float)[:k],
                    "cov": cov, "df_resid": None, "model_used": "mixed", "converged": True,
                }
        except Exception:  # noqa: BLE001 - fall through to OLS, reported via model_used
            pass

    r = sm.OLS(endog, exog).fit()
    return {
        "params": np.asarray(r.params, dtype=float),
        "bse": np.asarray(r.bse, dtype=float),
        "tvalues": np.asarray(r.tvalues, dtype=float),
        "pvalues": np.asarray(r.pvalues, dtype=float),
        "cov": np.asarray(r.cov_params(), dtype=float),
        "df_resid": float(r.df_resid),
        "model_used": "ols", "converged": True,
    }


def linear_mixed_effects_association(
    feature_df: pd.DataFrame,
    metadata_df: pd.DataFrame,
    formula: str,
    group_col: str,
    reml: bool = True,
) -> dict:
    """Per-feature association: fit one model per column of feature_df against a shared
    fixed-effects `formula` (right-hand side, patsy syntax), with a random intercept grouped
    by `group_col` where the data is longitudinal, and return the coefficient for every
    (feature, term). ONE bulk call fits every feature.

    Returns raw (unadjusted) p-values — apply `adjust_pvalues` over the family you care about;
    multiple-testing correction is intentionally NOT done here. The fixed-effects design is
    built once (it is identical across features), and each feature drops only its own missing
    responses. Features that fail to fit are listed in failed_features rather than raising.
    """
    exog_full = patsy.dmatrix(formula, metadata_df, return_type="dataframe")
    terms = list(exog_full.columns)
    groups_full = metadata_df[group_col]
    is_longitudinal = groups_full.nunique() < len(feature_df)

    rows: list[dict] = []
    failed: list[str] = []
    failed_errors: dict[str, str] = {}
    n_mixed = n_ols = 0

    for feature in feature_df.columns:
        try:
            y = pd.Series(feature_df[feature].values, index=exog_full.index)
            mask = y.notna().values
            groups = groups_full.values[mask] if is_longitudinal else None
            fit = fit_mixed_model(y.values[mask], exog_full.values[mask], groups, reml=reml)
            n_mixed += fit["model_used"] == "mixed"
            n_ols += fit["model_used"] == "ols"
            for j, term in enumerate(terms):
                if term == "Intercept":
                    continue
                rows.append({
                    "feature": feature, "covariate": term,
                    "coefficient": _json_safe_number(fit["params"][j]),
                    "std_error": _json_safe_number(fit["bse"][j]),
                    "z_score": _json_safe_number(fit["tvalues"][j]),
                    "p_value": _json_safe_number(fit["pvalues"][j]),
                    "model_used": fit["model_used"],
                })
        except Exception as e:  # noqa: BLE001
            failed.append(feature)
            failed_errors[feature] = str(e)

    return {
        "analysis_type": "lme_association",
        "n_features": len(feature_df.columns),
        "n_samples": len(feature_df),
        "is_longitudinal": bool(is_longitudinal),
        "formula": formula,
        "group_col": group_col,
        "results": rows,
        "n_mixed": n_mixed,
        "n_ols": n_ols,
        "n_failed": len(failed),
        "failed_features": failed,
        "failed_feature_errors": failed_errors,
        "multiple_testing": "p_value is raw; apply adjust_pvalues over your chosen family",
    }
