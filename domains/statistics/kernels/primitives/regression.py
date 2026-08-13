'''
- Linear Regression (single predictor)
- Polynomial Regression
- Multiple Regression (OLS, several predictors; optional robust SE)
- Logistic Regression (binary outcome; odds ratios)
- Regularized Regression (ridge / lasso / elastic net, cross-validated)

The simple single-predictor forms are kept on purpose: not every study needs a
multivariable model, and a clean bivariate fit is often the right tool. The richer
forms are added alongside, not in place of them.
'''

import numpy as np
import pandas as pd
import statsmodels.api as sm
from typing import List, Dict, Any
from scipy.stats import linregress
from scipy import stats
from sklearn.linear_model import ElasticNet, Lasso, LinearRegression, Ridge
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import cross_val_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import PolynomialFeatures, StandardScaler


def _json_num(v):
    if v is None:
        return None
    f = float(v)
    return f if np.isfinite(f) else None


def linear_regression(x: List[float], y: List[float]) -> Dict[str, Any]:
    """
    Perform linear regression analysis.
    Fits a linear model to the data and returns regression statistics.
    """
    x_clean = np.array(x)
    y_clean = np.array(y)
    
    # Perform linear regression using scipy
    slope, intercept, r_value, p_value, std_err = linregress(x_clean, y_clean)
    
    # Calculate additional statistics
    y_pred = slope * x_clean + intercept
    residuals = y_clean - y_pred
    r_squared = r_value ** 2
    
    # Calculate confidence intervals (simplified)
    n = len(x_clean)
    t_val = stats.t.ppf(0.975, n - 2)  # 95% confidence
    slope_ci = t_val * std_err
    intercept_ci = t_val * std_err * np.sqrt(np.mean(x_clean**2))
    
    return {
        "analysis_type": "linear_regression",
        "slope": slope,
        "intercept": intercept,
        "r_squared": r_squared,
        "correlation": r_value,
        "p_value": p_value,
        "std_error": std_err,
        "slope_ci_lower": slope - slope_ci,
        "slope_ci_upper": slope + slope_ci,
        "intercept_ci_lower": intercept - intercept_ci,
        "intercept_ci_upper": intercept + intercept_ci,
        "n_observations": n,
        "x": x_clean.tolist(),
        "y": y_clean.tolist(),
        "y_predicted": y_pred.tolist(),
        "residuals": residuals.tolist()
    }

def polynomial_regression(x: List[float], y: List[float], degree: int) -> Dict[str, Any]:
    """
    Perform polynomial regression analysis.
    Fits polynomial models of different degrees and returns the best fit.
    """
    x_clean = np.array(x)
    y_clean = np.array(y)
    
    # Create polynomial features
    poly_features = PolynomialFeatures(degree=degree)
    x_poly = poly_features.fit_transform(x_clean.reshape(-1, 1))
    
    # Fit polynomial regression
    model = LinearRegression()
    model.fit(x_poly, y_clean)
    
    # Predictions
    y_pred = model.predict(x_poly)
    
    # Calculate R-squared
    ss_res = np.sum((y_clean - y_pred) ** 2)
    ss_tot = np.sum((y_clean - np.mean(y_clean)) ** 2)
    r_squared = float(1 - (ss_res / ss_tot)) if ss_tot != 0 else None
    
    # Get coefficients
    coefficients = model.coef_.tolist()
    intercept = model.intercept_
    
    return {
        "analysis_type": "polynomial_regression",
        "degree": degree,
        "coefficients": coefficients,
        "intercept": float(intercept),
        "r_squared": r_squared,
        "n_observations": len(x_clean),
        "x": x_clean.tolist(),
        "y": y_clean.tolist(),
        "y_predicted": y_pred.tolist(),
        "residuals": (y_clean - y_pred).tolist()
    }


def multiple_regression(df: pd.DataFrame, outcome: str, predictors: List[str],
                        robust: bool = False) -> Dict[str, Any]:
    """
    Multivariable ordinary least squares: outcome ~ predictors. Returns each
    coefficient with its standard error, t, p, and 95% CI, plus R^2, adjusted R^2,
    the overall F-test, AIC, and BIC. robust=True uses heteroscedasticity-consistent
    (HC3) standard errors. Complete cases over the named columns are used.
    """
    d = df[[outcome] + list(predictors)].dropna()
    if len(d) < len(predictors) + 2:
        raise ValueError("not enough complete cases for the number of predictors")
    y = d[outcome].astype(float)
    X = sm.add_constant(d[list(predictors)].astype(float))
    fit = sm.OLS(y, X).fit(cov_type="HC3") if robust else sm.OLS(y, X).fit()
    ci = fit.conf_int()
    coefs = []
    for name in fit.params.index:
        coefs.append({
            "term": str(name),
            "coefficient": _json_num(fit.params[name]),
            "std_error": _json_num(fit.bse[name]),
            "t": _json_num(fit.tvalues[name]),
            "p_value": _json_num(fit.pvalues[name]),
            "ci_lower": _json_num(ci.loc[name, 0]),
            "ci_upper": _json_num(ci.loc[name, 1]),
        })
    return {
        "analysis_type": "multiple_regression",
        "outcome": outcome,
        "predictors": list(predictors),
        "n_observations": int(len(d)),
        "r_squared": _json_num(fit.rsquared),
        "adj_r_squared": _json_num(fit.rsquared_adj),
        "f_statistic": _json_num(fit.fvalue),
        "f_pvalue": _json_num(fit.f_pvalue),
        "aic": _json_num(fit.aic),
        "bic": _json_num(fit.bic),
        "coefficients": coefs,
        "robust_se": robust,
    }


def logistic_regression(df: pd.DataFrame, outcome: str, predictors: List[str]) -> Dict[str, Any]:
    """
    Binary logistic regression: P(outcome = positive) ~ predictors. The outcome must
    have exactly two levels; the larger (or 1/True) is the positive class. Returns
    each coefficient with its odds ratio and 95% CI, p-value, McFadden pseudo-R^2,
    in-sample AUC, and convergence. Complete cases over the named columns are used.
    """
    d = df[[outcome] + list(predictors)].dropna()
    levels = sorted(pd.unique(d[outcome]), key=lambda v: str(v))
    if len(levels) != 2:
        raise ValueError(f"logistic regression needs a binary outcome; got levels {levels}")
    positive = levels[1]
    y = (d[outcome] == positive).astype(int)
    X = sm.add_constant(d[list(predictors)].astype(float))
    fit = sm.Logit(y, X).fit(disp=False)
    ci = fit.conf_int()
    coefs = []
    for name in fit.params.index:
        coefs.append({
            "term": str(name),
            "coefficient": _json_num(fit.params[name]),
            "odds_ratio": _json_num(np.exp(fit.params[name])),
            "or_ci_lower": _json_num(np.exp(ci.loc[name, 0])),
            "or_ci_upper": _json_num(np.exp(ci.loc[name, 1])),
            "p_value": _json_num(fit.pvalues[name]),
        })
    try:
        auc = _json_num(roc_auc_score(y, fit.predict(X)))
    except ValueError:
        auc = None
    return {
        "analysis_type": "logistic_regression",
        "outcome": outcome,
        "positive_class": positive,
        "predictors": list(predictors),
        "n_observations": int(len(d)),
        "n_positive": int(y.sum()),
        "pseudo_r_squared_mcfadden": _json_num(fit.prsquared),
        "auc": auc,
        "coefficients": coefs,
        "converged": bool(fit.mle_retvals.get("converged", True)),
    }


def regularized_regression(X, y, method: str = "ridge", alpha: float = 1.0,
                           l1_ratio: float = 0.5, cv: int = 5,
                           feature_names: List[str] = None, standardize: bool = True) -> Dict[str, Any]:
    """
    Penalized linear regression for many (possibly collinear) predictors:
    'ridge' (L2), 'lasso' (L1, sparse), or 'elasticnet' (both). Features are
    standardized by default so the penalty is applied fairly. Returns the
    coefficients, intercept, the count of non-zero coefficients (lasso/elastic net
    selection), and cross-validated R^2 (mean and sd over cv folds).
    """
    X = np.asarray(X, dtype=float)
    y = np.asarray(y, dtype=float)
    if method == "ridge":
        est = Ridge(alpha=alpha)
    elif method == "lasso":
        est = Lasso(alpha=alpha)
    elif method == "elasticnet":
        est = ElasticNet(alpha=alpha, l1_ratio=l1_ratio)
    else:
        raise ValueError("method must be 'ridge', 'lasso', or 'elasticnet'")

    pipe = make_pipeline(StandardScaler(), est) if standardize else make_pipeline(est)
    cv_scores = cross_val_score(pipe, X, y, cv=min(cv, len(y)), scoring="r2")
    pipe.fit(X, y)
    final = pipe[-1]
    coef = np.asarray(final.coef_, dtype=float)
    names = list(feature_names) if feature_names is not None else [f"x{i}" for i in range(X.shape[1])]

    return {
        "analysis_type": "regularized_regression",
        "method": method,
        "alpha": alpha,
        **({"l1_ratio": l1_ratio} if method == "elasticnet" else {}),
        "n_observations": int(X.shape[0]),
        "n_features": int(X.shape[1]),
        "coefficients": {n: _json_num(c) for n, c in zip(names, coef)},
        "intercept": _json_num(final.intercept_),
        "n_nonzero": int(np.sum(np.abs(coef) > 1e-12)),
        "cv_r2_mean": _json_num(np.mean(cv_scores)),
        "cv_r2_std": _json_num(np.std(cv_scores)),
        "cv_folds": int(min(cv, len(y))),
    }