"""Correlation.

One public function, `correlation`. Three choices sit underneath every correlation and
they are independent of each other, so they are arguments rather than separate functions:

  method       how association is measured: pearson, spearman, or kendall.
  subject_col  the independence assumption. Absent, every row counts as its own
               observation. Given, the correlation is computed inside each subject and
               the estimates pooled on the Fisher z scale, which is the honest answer when
               one subject contributes many rows.
  covar_cols   what it is conditional on. Absent, the plain association. Given, a partial
               correlation: both features are regressed on the covariates first and their
               residuals correlated.

All four combinations of the last two are real and all four are computed. Scale is not one
of the choices: x and y take a name or a list of names, so one pair and a full grid are the
same call.

The marginal estimate is always returned, and the within-subject estimate beside it when a
subject column is given, because the gap between them is itself a finding: a large marginal
r with a small within-subject r means the association is between subjects, not something
tracking within a person.

Fisher z pooling weights each subject by (n_i - 3 - k) / c, where k is the number of
covariates and c is 1.0 for pearson or 1.06 for spearman (Fieller's variance inflation).
Kendall has no such variance and so has no pooled path; rmcorr or a mixed model is the
rigorous upgrade and is not implemented here.

Everything else in this module is machinery for that one function.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
from scipy import stats
from scipy.stats import kendalltau, norm, pearsonr, spearmanr

from .transformations import fisher_z_transform, inverse_fisher_z

_MIN_PER_SUBJECT = 4  # need n - 3 >= 1 for a Fisher z variance
_SPEARMAN_C = 1.06    # Fieller variance inflation for Fisher z of a Spearman r

# variance-inflation constant c in Var(z) = c / (n - 3)
_FISHER_C = {"pearson": 1.0, "spearman": _SPEARMAN_C}

_PAIR_FN = {"pearson": pearsonr, "spearman": spearmanr, "kendall": kendalltau}


def _resolve_method(method: str) -> str:
    """Accept 'kendalltau' as an alias for 'kendall'; pass others through."""
    return "kendall" if method == "kendalltau" else method


# ── single pair, naive ──────────────────────────────────────────────────────

# ── bulk, naive ─────────────────────────────────────────────────────────────

def _cross_corr_complete(Xv: np.ndarray, Yv: np.ndarray, method: str):
    """Vectorized cross-correlation of every column of Xv against every column of
    Yv when both blocks are free of missing values. Returns (R, P) of shape
    (n_y, n_x). p-values match scipy: the beta distribution for pearson, the
    t-distribution for spearman."""
    n = Xv.shape[0]
    if method == "spearman":
        Xv = np.apply_along_axis(stats.rankdata, 0, Xv)
        Yv = np.apply_along_axis(stats.rankdata, 0, Yv)
    Xc = Xv - Xv.mean(axis=0)
    Yc = Yv - Yv.mean(axis=0)
    Xn = np.linalg.norm(Xc, axis=0)
    Yn = np.linalg.norm(Yc, axis=0)
    # guard constant columns (zero norm) -> their correlations are undefined (nan)
    with np.errstate(divide="ignore", invalid="ignore"):
        Xs = Xc / Xn
        Ys = Yc / Yn
        R = np.clip(Ys.T @ Xs, -1.0, 1.0)
        if method == "pearson":
            ab = n / 2.0 - 1.0
            dist = stats.beta(ab, ab, loc=-1, scale=2)
            P = 2.0 * dist.sf(np.abs(R))
        else:
            t = R * np.sqrt((n - 2) / (1.0 - R ** 2))
            P = 2.0 * stats.t.sf(np.abs(t), n - 2)
    bad = ~np.isfinite(R)
    R[bad] = np.nan
    P[bad] = np.nan
    return R, P


def _marginal_grid(
    x_vars: dict[str, list],
    y_vars: dict[str, list],
    method: str = "pearson",
) -> dict:
    """Correlate every x variable against every y variable in one bulk call.

    x_vars / y_vars map a variable name to an equal-length list of numbers (None or
    NaN allowed). For each (y, x) pair the correlation is computed over the rows
    where both are present (pairwise-complete); pairs with fewer than 2 such rows,
    or a constant column, are omitted from the output.

    When the data has no missing values the whole grid is computed with vectorized
    linear algebra (one matrix product) for pearson and spearman; kendall, and any
    block containing gaps, fall back to exact per-pair computation.

    Returns {"method", "x_vars", "y_vars", "results"} where results is a nested
    {y_name: {x_name: {"r", "p_value", "n"}}}. Assumes inputs are already validated.
    """
    method = _resolve_method(method)
    x_names = list(x_vars)
    y_names = list(y_vars)
    Xdf = pd.DataFrame({k: pd.to_numeric(pd.Series(v), errors="coerce") for k, v in x_vars.items()})
    Ydf = pd.DataFrame({k: pd.to_numeric(pd.Series(v), errors="coerce") for k, v in y_vars.items()})

    results: dict[str, dict] = {name: {} for name in y_names}

    no_gaps = method != "kendall" and not Xdf.isna().any().any() and not Ydf.isna().any().any()
    if no_gaps and len(Xdf) >= 2:
        R, P = _cross_corr_complete(Xdf.to_numpy(float), Ydf.to_numpy(float), method)
        for iy, yname in enumerate(y_names):
            for ix, xname in enumerate(x_names):
                r = R[iy, ix]
                if not np.isfinite(r):
                    continue
                results[yname][xname] = {
                    "r": round(float(r), 4),
                    "p_value": float(P[iy, ix]),
                    "n": int(len(Xdf)),
                }
        return {"method": method, "x_vars": x_names, "y_vars": y_names, "results": results}

    # Pairwise-complete with gaps present. Columns are grouped by missingness pattern, so
    # every pair inside a block shares the same complete rows and the block is one matrix
    # product on exactly those rows. Same numbers as pair-by-pair, without a dropna per
    # pair; on a full omic grid that is the difference between seconds and minutes.
    if method != "kendall":
        Xa, Ya = Xdf.to_numpy(float), Ydf.to_numpy(float)
        for xpat, xcols in _pattern_groups(~np.isnan(Xa)):
            for ypat, ycols in _pattern_groups(~np.isnan(Ya)):
                rows = np.flatnonzero(xpat & ypat)
                if len(rows) < 2:
                    continue
                R, P = _cross_corr_complete(Xa[np.ix_(rows, xcols)], Ya[np.ix_(rows, ycols)], method)
                for k, iy in enumerate(ycols):
                    for j, ix in enumerate(xcols):
                        r = R[k, j]
                        if not np.isfinite(r):
                            continue
                        results[y_names[iy]][x_names[ix]] = {
                            "r": round(float(r), 4), "p_value": float(P[k, j]), "n": int(len(rows)),
                        }
        return {"method": method, "x_vars": x_names, "y_vars": y_names, "results": results}

    # kendall has no closed form here, so it stays pair by pair
    fn = _PAIR_FN[method]
    for yname in y_names:
        yv = Ydf[yname]
        for xname in x_names:
            pair = pd.concat([Xdf[xname], yv], axis=1).dropna()
            if len(pair) < 2:
                continue
            xc, yc = pair.iloc[:, 0], pair.iloc[:, 1]
            if xc.nunique() < 2 or yc.nunique() < 2:
                continue
            r, p = fn(xc, yc)
            if np.isnan(r):
                continue
            results[yname][xname] = {"r": round(float(r), 4), "p_value": float(p), "n": int(len(pair))}
    return {"method": method, "x_vars": x_names, "y_vars": y_names, "results": results}


# ── Fisher z pooling, shared by the corrected paths ─────────────────────────

def _pool_fisher_z(r_list: list[float], n_list: list[int], method: str) -> dict:
    """Inverse-variance pool a set of per-subject correlations on the Fisher z
    scale. Returns pooled r, 95% CI, and a two-sided p-value. Assumes at least one
    entry; the caller decides the minimum-subject policy."""
    c = _FISHER_C[method]
    z = fisher_z_transform(np.asarray(r_list, dtype=float))
    w = (np.asarray(n_list, dtype=float) - 3.0) / c
    Z = float((z * w).sum() / w.sum())
    se = float(np.sqrt(1.0 / w.sum()))
    lo, hi = Z - 1.96 * se, Z + 1.96 * se
    z_stat = Z / se
    p = float(2 * (1 - norm.cdf(abs(z_stat))))
    return {
        "r_pooled": round(float(inverse_fisher_z(Z)), 4),
        "ci95": [round(float(inverse_fisher_z(lo)), 4), round(float(inverse_fisher_z(hi)), 4)],
        "p_value": p,
    }


def _cross_corr_r_grid(Xv: np.ndarray, Yv: np.ndarray, method: str) -> np.ndarray:
    """r for every (y, x), shape (n_y, n_x). No p-values.

    The p-value half of `_cross_corr_complete` is the expensive half, a scipy distribution
    evaluated over the whole grid, and the within-subject path never uses it: pooling
    derives its own p from the Fisher z variance. Constant columns come back as nan, which
    is how the caller learns to drop them.
    """
    if method == "spearman":
        Xv = np.apply_along_axis(stats.rankdata, 0, Xv)
        Yv = np.apply_along_axis(stats.rankdata, 0, Yv)
    Xc = Xv - Xv.mean(axis=0)
    Yc = Yv - Yv.mean(axis=0)
    with np.errstate(divide="ignore", invalid="ignore"):
        R = np.clip((Yc / np.linalg.norm(Yc, axis=0)).T @ (Xc / np.linalg.norm(Xc, axis=0)), -1.0, 1.0)
    return np.where(np.isfinite(R), R, np.nan)


def _pattern_groups(mask: np.ndarray) -> list[tuple[np.ndarray, list[int]]]:
    """Column indices grouped by identical present/absent pattern, as (pattern, columns).

    Missingness in this data is structural rather than scattered: a sample either carries
    a metagenomics profile or it does not, so every species column in one subject shares
    one pattern. That is what makes the grid collapse into a handful of dense blocks.
    """
    by_key: dict[bytes, list[int]] = {}
    for j in range(mask.shape[1]):
        by_key.setdefault(mask[:, j].tobytes(), []).append(j)
    return [(mask[:, cols[0]], cols) for cols in by_key.values()]


def _within_subject_rn(Xdf: pd.DataFrame, Ydf: pd.DataFrame, subj: pd.Series, method: str):
    """Per-subject r and n for the whole (y, x) grid, as two (n_subjects, n_y, n_x) arrays.

    Pairwise-complete, exactly as the pair-by-pair path is: within one subject, columns are
    grouped by missingness pattern on each side, and every (y, x) pair inside a group shares
    precisely the same complete rows. So each group is one ranking and one matrix product,
    with the same rows the per-pair code would have kept.

    The pair-by-pair equivalent costs a scipy call and a pandas dropna per pair per subject,
    which on a full omic grid is hundreds of thousands of each, and minutes of wall time.
    """
    y_names = list(Ydf.columns)
    ny, nx = len(y_names), Xdf.shape[1]
    subjects = list(subj.groupby(subj, sort=False).groups.items())
    R = np.full((len(subjects), ny, nx), np.nan)
    N = np.zeros((len(subjects), ny, nx))

    for si, (_sid, idx) in enumerate(subjects):
        Xa = Xdf.loc[idx].to_numpy(float)
        Ya = Ydf.loc[idx].to_numpy(float)
        for xpat, xcols in _pattern_groups(~np.isnan(Xa)):
            for ypat, ycols in _pattern_groups(~np.isnan(Ya)):
                rows = np.flatnonzero(xpat & ypat)
                if len(rows) < _MIN_PER_SUBJECT:
                    continue
                block = _cross_corr_r_grid(Xa[np.ix_(rows, xcols)], Ya[np.ix_(rows, ycols)], method)
                # a constant column comes back nan and is dropped by the caller's validity mask
                R[np.ix_([si], ycols, xcols)] = block[None, :, :]
                N[np.ix_([si], ycols, xcols)] = len(rows)
    return R, N


def _per_subject_corr(x: pd.Series, y: pd.Series, subject: pd.Series, method: str):
    """Per-subject correlations for one (x, y) pair. Returns (r_list, n_list,
    used_subjects, excluded) over subjects with enough non-constant points."""
    fn = _PAIR_FN[method]
    frame = pd.DataFrame({"x": x, "y": y, "subject": subject}).dropna()
    r_list, n_list, used, excluded = [], [], [], []
    for sid, g in frame.groupby("subject"):
        n_i = len(g)
        if n_i < _MIN_PER_SUBJECT:
            excluded.append({"subject": str(sid), "reason": f"only {n_i} points (need >= {_MIN_PER_SUBJECT})"})
            continue
        if g["x"].nunique() < 2 or g["y"].nunique() < 2:
            excluded.append({"subject": str(sid), "reason": "constant x or y"})
            continue
        r_list.append(float(fn(g["x"], g["y"])[0]))
        n_list.append(n_i)
        used.append(str(sid))
    return r_list, n_list, used, excluded


# ── partial correlation (controlling for covariates) ───────────────────────

def _residualize(Y: np.ndarray, design: np.ndarray) -> np.ndarray:
    """Residuals of each column of Y after least-squares regression on `design`."""
    beta, *_ = np.linalg.lstsq(design, Y, rcond=None)
    return Y - design @ beta


def _design(covar_block: np.ndarray, n: int) -> np.ndarray:
    return np.column_stack([np.ones(n), covar_block]) if covar_block.size else np.ones((n, 1))


def _within_subject_grid(
    x_vars: dict[str, list],
    y_vars: dict[str, list],
    subject_ids: list,
    method: str = "pearson",
) -> dict:
    """Bulk repeated-measures correct correlation: every x against every y, each
    pooled within subject via Fisher z. The corrected counterpart of
    multi_correlation. subject_ids is aligned row-wise to the variable lists.

    Returns {"method", "x_vars", "y_vars", "results"} where results is a nested
    {y_name: {x_name: {"r_pooled", "ci95", "p_value", "n_subjects_used", ...}}}.
    Pairs that cannot be pooled (fewer than 2 usable subjects) are omitted.
    """
    if method not in ("pearson", "spearman"):
        raise ValueError("within-subject path supports 'pearson' or 'spearman' only.")
    subj = pd.Series(subject_ids, name="subject")
    x_names, y_names = list(x_vars), list(y_vars)
    Xdf = pd.DataFrame({k: pd.to_numeric(pd.Series(v), errors="coerce") for k, v in x_vars.items()})
    Ydf = pd.DataFrame({k: pd.to_numeric(pd.Series(v), errors="coerce") for k, v in y_vars.items()})

    R, N = _within_subject_rn(Xdf, Ydf, subj, method)
    n_subjects = R.shape[0]

    # Pool on the Fisher z scale for the whole grid at once. The per-pair helper is the
    # same arithmetic; doing it pair by pair here would be tens of thousands of calls.
    valid = np.isfinite(R) & (N >= _MIN_PER_SUBJECT)
    z = np.where(valid, fisher_z_transform(np.where(valid, R, 0.0)), 0.0)
    w = np.where(valid, (N - 3.0) / _FISHER_C[method], 0.0)
    W = w.sum(axis=0)
    used = valid.sum(axis=0)
    with np.errstate(divide="ignore", invalid="ignore"):
        Z = (z * w).sum(axis=0) / W
        se = np.sqrt(1.0 / W)
        p = 2.0 * (1.0 - norm.cdf(np.abs(Z / se)))
    r_pooled = inverse_fisher_z(Z)
    lo, hi = inverse_fisher_z(Z - 1.96 * se), inverse_fisher_z(Z + 1.96 * se)

    results: dict[str, dict] = {name: {} for name in y_names}
    for iy, yname in enumerate(y_names):
        for ix, xname in enumerate(x_names):
            if used[iy, ix] < 2 or not np.isfinite(r_pooled[iy, ix]):
                continue
            results[yname][xname] = {
                "r_pooled": round(float(r_pooled[iy, ix]), 4),
                "ci95": [round(float(lo[iy, ix]), 4), round(float(hi[iy, ix]), 4)],
                "p_value": float(p[iy, ix]),
                "n_subjects_used": int(used[iy, ix]),
                "n_subjects_excluded": int(n_subjects - used[iy, ix]),
            }
    return {"method": method, "x_vars": x_names, "y_vars": y_names, "results": results}


# ── the one entry point ─────────────────────────────────────────────────────
# Everything above is the machinery. `correlation` is what callers should use: one pair
# or a whole grid through the same call, returning a flat table rather than nested dicts.
#
# The three ideas it exposes are genuinely distinct and all three are kept:
#   marginal        every row treated as independent
#   within-subject  computed inside each subject, then pooled; the honest estimate when
#                   the same subject appears many times
#   partial         after regressing out covariates
# Only the *combinations* were collapsed. One pair versus many is scale, not statistics,
# so it is an argument here rather than a separate function.

def _within_subject_partial(df, pairs, subject_col, covar_cols, method):
    """Within-subject partial correlation, pooled on the Fisher z scale.

    The two corrections compose rather than conflict: inside each subject the pair is
    residualized on the covariates and the residuals correlated, then those per-subject
    estimates are pooled. Residualizing within the subject is the consistent choice once
    the subject is being treated as the unit; doing it globally would leave between-subject
    covariate structure in the residuals that the pooling then assumes is gone.

    Each subject needs n_i >= k + 4, since the Fisher z variance is 1 / (n - 3 - k).
    """
    k = len(covar_cols)
    fn_rank = method == "spearman"
    rows = []
    for xn, yn in pairs:
        r_list, n_list = [], []
        for _sid, d in df[[xn, yn, subject_col, *covar_cols]].dropna().groupby(subject_col, sort=False):
            n_i = len(d)
            if n_i < k + 4:
                continue
            block = d[[xn, yn, *covar_cols]].to_numpy(dtype=float)
            if fn_rank:
                block = np.apply_along_axis(stats.rankdata, 0, block)
            res = _residualize(block[:, :2], _design(block[:, 2:], n_i))
            if res[:, 0].std() == 0 or res[:, 1].std() == 0:
                continue
            r_list.append(float(np.clip(np.corrcoef(res[:, 0], res[:, 1])[0, 1], -1.0, 1.0)))
            n_list.append(n_i)
        if len(r_list) < 2:
            continue
        # the covariates cost k degrees of freedom in every subject's variance
        pooled = _pool_fisher_z(r_list, [n - k for n in n_list], method)
        rows.append({"x": xn, "y": yn,
                     "r_within": pooled["r_pooled"],
                     "ci_low": pooled["ci95"][0], "ci_high": pooled["ci95"][1],
                     "p_within": pooled["p_value"],
                     "n_subjects_used": len(r_list)})
    return pd.DataFrame(rows, columns=["x", "y", "r_within", "ci_low", "ci_high",
                                       "p_within", "n_subjects_used"])


def _pair_list(x, y):
    """(x_names, y_names, pairs) for str-or-list inputs. y=None means all unordered pairs
    within x, which is the shape a symmetric matrix was for."""
    xs = [x] if isinstance(x, str) else list(x)
    if y is None:
        return xs, xs, [(a, b) for i, a in enumerate(xs) for b in xs[i + 1:]]
    ys = [y] if isinstance(y, str) else list(y)
    return xs, ys, [(a, b) for b in ys for a in xs]


def _partial_table(df, pairs, covar_cols, method):
    """Partial r for each pair, complete cases per pair.

    Per pair rather than complete-case across every variable at once. The single-pair
    helper already did it this way; the matrix helper did not, and dropping a row because
    some unrelated third variable is missing there discards data the pair itself has.
    """
    rows, k = [], len(covar_cols)
    for xn, yn in pairs:
        d = df[[xn, yn, *covar_cols]].dropna()
        n = len(d)
        if n < k + 3:
            continue
        block = d.to_numpy(dtype=float)
        if method == "spearman":
            block = np.apply_along_axis(stats.rankdata, 0, block)
        res = _residualize(block[:, :2], _design(block[:, 2:], n))
        if res[:, 0].std() == 0 or res[:, 1].std() == 0:
            continue
        r = float(np.clip(np.corrcoef(res[:, 0], res[:, 1])[0, 1], -1.0, 1.0))
        dof = n - k - 2
        with np.errstate(divide="ignore", invalid="ignore"):
            t = r * np.sqrt(dof / (1.0 - r ** 2))
        p = float(2 * stats.t.sf(abs(t), dof)) if dof > 0 and abs(r) < 1 else None
        rows.append({"x": xn, "y": yn, "n": n, "r": round(r, 4), "p_value": p})
    return pd.DataFrame(rows, columns=["x", "y", "n", "r", "p_value"])


def correlation(
    df: pd.DataFrame,
    x,
    y=None,
    method: str = "pearson",
    subject_col: str | None = None,
    covar_cols: list[str] | None = None,
    detail: bool = False,
) -> dict:
    """Correlate features, one pair or every pair, as a flat table.

    x and y are column names or lists of them; a plain string is just a grid of one. With
    y omitted, every unordered pair within x is returned. The whole grid is computed in
    one call, so all-against-all never needs looping or chunking.

    subject_col adds the repeated-measures correct estimate beside the marginal one. Both
    are returned on purpose: the *gap* between them is the finding. A large marginal r with
    a small within-subject r means the association is between subjects, not something
    tracking within a person over time.

    covar_cols gives partial correlation, r after regressing both features on the
    covariates. Complete cases are taken per pair.

    Returns {"table": DataFrame, ...}. Table columns are x, y, n, r, p_value, and with a
    subject_col also r_within, ci_low, ci_high, p_within, n_subjects_used,
    n_subjects_excluded. Nothing is FDR adjusted here; a grid is many tests, so pass
    table["p_value"] through adjust_pvalues before reading anything as significant.
    """
    method = _resolve_method(method)
    x_names, y_names, pairs = _pair_list(x, y)
    for col in {*x_names, *y_names, *(covar_cols or []), *([subject_col] if subject_col else [])}:
        if col not in df.columns:
            raise ValueError(f"column not found: {col}")

    notes: list[str] = []
    if covar_cols:
        table = _partial_table(df, pairs, list(covar_cols), method)
        mode = "partial"
        notes.append(f"r is partial, controlling for {', '.join(covar_cols)}.")
        if subject_col is None:
            notes.append("Every row is treated as independent.")
    else:
        marg = _marginal_grid({c: df[c].tolist() for c in x_names},
                                 {c: df[c].tolist() for c in y_names}, method)["results"]
        rows = []
        for xn, yn in pairs:
            cell = marg.get(yn, {}).get(xn)
            if cell is not None:
                rows.append({"x": xn, "y": yn, "n": cell["n"], "r": cell["r"], "p_value": cell["p_value"]})
        table = pd.DataFrame(rows, columns=["x", "y", "n", "r", "p_value"])
        mode = "marginal"

    if subject_col:
        if method not in ("pearson", "spearman"):
            raise ValueError(
                "the within-subject path supports 'pearson' or 'spearman'; for 'kendall' "
                "drop subject_col, or upgrade to rmcorr / a mixed model."
            )
        if covar_cols:
            extra_df = _within_subject_partial(df, pairs, subject_col, list(covar_cols), method)
        else:
            ws = _within_subject_grid(
                {c: df[c].tolist() for c in x_names}, {c: df[c].tolist() for c in y_names},
                df[subject_col].tolist(), method)["results"]
            rows = []
            for xn, yn in pairs:
                c = ws.get(yn, {}).get(xn)
                if c is None:
                    continue
                rows.append({"x": xn, "y": yn, "r_within": c["r_pooled"],
                             "ci_low": c["ci95"][0], "ci_high": c["ci95"][1],
                             "p_within": c["p_value"],
                             "n_subjects_used": c["n_subjects_used"]})
            extra_df = pd.DataFrame(rows, columns=["x", "y", "r_within", "ci_low",
                                                   "ci_high", "p_within", "n_subjects_used"])
        table = table.merge(extra_df, on=["x", "y"], how="left")
        mode = f"{mode} + within_subject"
        notes.append("Report r_within, not r. A large gap between them means the "
                     "association lives between subjects rather than within them.")
    else:
        notes.append("Every row is treated as independent. If the same subject appears "
                     "more than once, pass subject_col: this estimate is pseudoreplicated "
                     "and its p-value is anti-conservative.")

    # A pair with too few overlapping observations is dropped rather than estimated. That
    # is the right call, but a silently shorter table reads as "these are all the pairs",
    # so the count of what fell out is reported rather than left to be noticed.
    dropped = len(pairs) - len(table)
    if dropped:
        notes.append(f"{dropped} of {len(pairs)} pairs were dropped for too few "
                     "overlapping observations, or a constant feature.")

    out = {"method": method, "mode": mode,
           "n_pairs": int(len(table)), "n_pairs_requested": len(pairs), "n_pairs_dropped": dropped,
           "table": table, "notes": notes}

    # Which subjects dropped out, and why. Only for a single pair, where it is short
    # enough to act on; on a grid it would be thousands of lines of the same reasons.
    if detail and subject_col and len(pairs) == 1:
        xn, yn = pairs[0]
        _, _, used, excluded = _per_subject_corr(df[xn], df[yn], df[subject_col], method)
        out["subjects_used"] = used
        out["subjects_excluded"] = excluded
    return out
