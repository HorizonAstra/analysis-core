"""Differential-abundance workflow — which features differ between cohorts.

This is orchestration, not a primitive: it couples the study's cohort structure to the
general engines and adds the correctness a bare model does not. The parts that are reusable
statistics are COMPOSED, not re-implemented:

  - the per-feature fit goes through `primitives.mixed_models.fit_mixed_model` (one engine,
    one optimizer/variance configuration — no second copy to drift from);
  - the multiple-testing correction goes through `primitives.multiple_testing.adjust_pvalues`.

What stays here is genuinely workflow-level: choosing the reference cohort, deciding whether
to adjust for time, reading pairwise contrasts off one pooled fit, one FDR family across
every comparison shown, and the direction/labeling. A primitive should know none of that.
"""

from __future__ import annotations

import sys
import warnings
from itertools import combinations
from pathlib import Path

import numpy as np
import pandas as pd
import patsy
import statsmodels.formula.api as smf
from scipy.stats import mannwhitneyu, norm, ttest_ind
from scipy.stats import t as _t

# The engines this composes belong to the statistics domain, which is the
# substrate both science domains compute on rather than a fourth science.
#
# These were relative imports — `..primitives`, `.inputs` — from a layout where
# workflows and primitives were siblings under one package. They are not
# siblings here and have not been since the migration, so this module raised
# ImportError on the first line of any attempt to use it, which is why nothing
# ever ran it. Resolved from this file's own location, the same way
# `run_primitive.py` reaches the primitives, so it holds wherever the tree is
# installed and needs nobody to set PYTHONPATH.
_STATISTICS = Path(__file__).resolve().parents[3] / "statistics" / "kernels"
if str(_STATISTICS) not in sys.path:
    sys.path.insert(0, str(_STATISTICS))

from primitives.mixed_models import fit_mixed_model        # noqa: E402
from primitives.multiple_testing import adjust_pvalues     # noqa: E402
from workflows.inputs import coerce_group_map, coerce_matrix  # noqa: E402

VALID_TESTS = ("lme", "ols", "welch", "wilcoxon")


def _cohens_d(reference: np.ndarray, contrast: np.ndarray) -> float:
    """Pooled-SD Cohen's d, contrast minus reference (so the sign agrees with the models:
    positive means higher in the contrast group). Returned as the effect for welch, which
    otherwise would report only a p-value and a direction nobody can size."""
    na, nb = len(reference), len(contrast)
    if na < 2 or nb < 2:
        return float("nan")
    va, vb = reference.var(ddof=1), contrast.var(ddof=1)
    pooled = np.sqrt(((na - 1) * va + (nb - 1) * vb) / (na + nb - 2))
    return float((contrast.mean() - reference.mean()) / pooled) if pooled > 0 else float("nan")


def _one_feature(df: pd.DataFrame, test: str, levels: list) -> dict | None:
    """Two-sample test of one feature between the two cohorts in `levels` (welch/wilcoxon).
    The modelled tests (lme/ols) never come here — they are fit jointly in _pooled_rows."""
    d = df.dropna(subset=["value"])
    a = d[d["group"] == levels[0]]["value"].to_numpy(dtype=float)
    b = d[d["group"] == levels[1]]["value"].to_numpy(dtype=float)
    if len(a) < 3 or len(b) < 3:
        return None

    if test == "welch":
        stat, p = ttest_ind(a, b, equal_var=False)
        return {"effect": _cohens_d(a, b), "effect_kind": "cohens_d", "p": float(p), "n": [len(a), len(b)]}

    if test == "wilcoxon":
        U, p = mannwhitneyu(a, b, alternative="two-sided")
        # U counts reference-beats-contrast pairs, so 1 - 2U/(na*nb) is positive when the
        # contrast group ranks higher, agreeing with the effect beside it.
        rb = 1.0 - (2.0 * U) / (len(a) * len(b))  # rank-biserial correlation
        return {"effect": float(rb), "effect_kind": "rank_biserial", "p": float(p),
                "median_diff": float(np.median(b) - np.median(a)), "n": [len(a), len(b)]}
    return None


# Model term name -> the matrix column it is read from. "time" is the study's day number;
# nothing else is wired up yet, so any other covariate is taken as a column name.
_COVARIATE_SOURCES = {"time": "day"}


def _pick_covariates(sub: pd.DataFrame, base: pd.DataFrame, covariates) -> tuple[list, str | None]:
    """Which covariates to adjust for, and a note when the choice is not the obvious one.

    "auto" adjusts for time on longitudinal data, because composition drifts and a
    cohort that correlates with when its samples were taken otherwise reports that drift
    as a cohort effect. It declines when time is nearly determined by cohort (pre/post,
    timepoint cohorts): there the covariate would absorb the very contrast being asked
    for. An explicit list is honoured as given, and [] adjusts for nothing.
    """
    if covariates is None or (isinstance(covariates, (list, tuple)) and not covariates):
        return [], None
    if isinstance(covariates, (list, tuple)):
        bad = [c for c in covariates if _COVARIATE_SOURCES.get(c, c) not in sub.columns]
        if bad:
            return [], f"covariates {bad} are not columns on the matrix; fitted without them"
        return list(covariates), None
    if covariates != "auto":
        return [], f"covariates={covariates!r} not understood; fitted without covariates"

    if _COVARIATE_SOURCES["time"] not in sub.columns:
        return [], None
    t = pd.to_numeric(sub[_COVARIATE_SOURCES["time"]], errors="coerce")
    if t.notna().sum() < 5 or t.nunique(dropna=True) < 3:
        return [], None                              # not longitudinal in any useful sense
    probe = pd.DataFrame({"t": t.values, "g": base["group"].astype(str).values}).dropna()
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            r2 = float(smf.ols("t ~ C(g)", data=probe).fit().rsquared)
    except Exception:  # noqa: BLE001
        return [], None
    if r2 > 0.9:
        return [], (f"not adjusting for time: cohort explains {r2:.0%} of it, so the "
                    f"covariate would absorb the cohort contrast itself")
    return ["time"], None


def _pooled_rows(base: pd.DataFrame, values: pd.Series, levels: list, pairs: list,
                 test: str, covariates: list) -> list[dict]:
    """Fit ONE model over every cohort at once (via the shared engine) and read all pairwise
    contrasts off it.

    Two reasons this is not a loop over pairs. The variance is estimated from every cohort
    rather than two at a time, the more efficient estimate when cohorts share a variance; and
    it is one fit per feature instead of one per pair. Contrasts between two non-reference
    cohorts are a linear combination of the fitted coefficients, so `fit_mixed_model` returns
    the fixed-effect covariance and this reads any contrast off it: effect = c·beta,
    var = c·cov·c, with the normal (mixed) or t (OLS) tail — reproducing MixedLM/OLS t_test.

    Covariates enter the model but never the results: adjusting for time and reporting a
    p-value for time are different things, and a nuisance term in the multiplicity family
    costs power for a hypothesis nobody is testing.
    """
    d = base.copy()
    d["value"] = values.to_numpy()
    d = d.dropna(subset=["value"])
    if d["group"].nunique() < 2:
        return []
    d["group"] = pd.Categorical(d["group"], categories=levels)
    rhs = " + ".join(["C(group)"] + list(covariates))

    # patsy drops any covariate-NA rows from endog and exog together, so realign groups to
    # the survivors. The design (Intercept + C(group)[T.*] + covariates) is identical across
    # features; only `value` changes, but this workflow calls per feature via its caller.
    try:
        y, X = patsy.dmatrices(f"value ~ {rhs}", d, return_type="dataframe")
    except Exception as e:  # noqa: BLE001
        return [{"error": str(e)[:120]}]
    terms = list(X.columns)
    groups = d.loc[y.index, "subject"].to_numpy() if test == "lme" else None
    try:
        fit = fit_mixed_model(y.to_numpy().ravel(), X.to_numpy(), groups)
    except Exception as e:  # noqa: BLE001
        return [{"error": f"fit failed: {str(e)[:80]}"}]

    # A feature whose mixed model will not converge is refit with OLS by the engine rather
    # than dropped (which would quietly shrink the feature set and the FDR denominator); the
    # row says so and the caller is warned.
    if test == "ols":
        fitted_with, note = "ols", None
    elif fit["model_used"] == "mixed":
        fitted_with, note = "lme", None
    else:
        fitted_with, note = "ols_fallback", "LME did not converge; refitted with OLS"

    params, cov, df_resid = fit["params"], fit["cov"], fit["df_resid"]
    counts = d["group"].value_counts()

    def _term(level):
        """The coefficient name for a level, or None for the reference level."""
        for n in terms:
            if n.startswith("C(group)[T.") and n[len("C(group)[T."):-1] == str(level):
                return n
        return None

    rows = []
    for reference, contrast in pairs:
        vec = np.zeros(len(terms))
        ok = True
        for level, sign in ((contrast, 1.0), (reference, -1.0)):
            tname = _term(level)
            if tname is not None:
                vec[terms.index(tname)] = sign
            elif str(level) != str(levels[0]):
                ok = False        # a level that is neither reference nor a fitted term
        if not ok or not vec.any():
            continue
        eff = float(vec @ params)
        var = float(vec @ cov @ vec)
        se = float(np.sqrt(var)) if var > 0 else float("nan")
        stat = eff / se if se == se and se != 0 else float("nan")
        # normal tail for the mixed model, t for OLS — matches MixedLM.t_test / OLS.t_test
        p = float(2 * norm.sf(abs(stat))) if df_resid is None else float(2 * _t.sf(abs(stat), df_resid))
        row = {"reference": str(reference), "contrast": str(contrast),
               "higher_in": (str(contrast) if eff > 0 else str(reference) if eff < 0 else "neither"),
               "effect": eff, "effect_kind": "coef_contrast_minus_reference",
               "se": se, "p": p, "fitted_with": fitted_with,
               "n": [int(counts.get(reference, 0)), int(counts.get(contrast, 0))]}
        if note:
            row["fit_note"] = note
        rows.append(row)
    return rows


def _run_pair(matrix: pd.DataFrame, features: list[str], group_map: dict, test: str, levels: tuple) -> list[dict]:
    """Run every feature for one cohort pair (welch/wilcoxon), restricting to samples in the
    two levels first so a third cohort never bleeds in. `levels` is (reference, contrast)."""
    reference, contrast = levels[0], levels[1]
    groups = [group_map.get(s) for s in matrix["sample_id"]]
    keep = [i for i, g in enumerate(groups) if g in levels]
    sub = matrix.iloc[keep].reset_index(drop=True)
    base = pd.DataFrame({
        "sample_id": sub["sample_id"].values,
        "subject": sub["subject_id"].values,
        "group": [group_map.get(s) for s in sub["sample_id"]],
    })
    rows = []
    for f in features:
        df = base.copy()
        df["value"] = sub[f].values
        res = _one_feature(df, test, [reference, contrast])
        if res and "p" in res:
            eff = res.get("effect")
            higher = None
            if isinstance(eff, (int, float)) and eff == eff:
                higher = str(contrast) if eff > 0 else (str(reference) if eff < 0 else "neither")
            rows.append({"feature": f, "reference": str(reference), "contrast": str(contrast),
                         "higher_in": higher, **res})
    return rows


def _format(rows: list[dict], top_n: int | None) -> list[dict]:
    """Rows sorted by adjusted p, cut to top_n. top_n None or 0 returns all of them."""
    rows = sorted(rows, key=lambda r: r["p_adj_bh"])
    if top_n:
        rows = rows[:top_n]
    return [{k: (round(v, 5) if isinstance(v, float) else v) for k, v in r.items()} for r in rows]


def _withheld(rows: list[dict], shown: list[dict]) -> dict:
    """How much of a comparison's table was cut, said out loud."""
    n_sig = sum(1 for r in rows if r["p_adj_bh"] < 0.05)
    out = {"n_shown": len(shown), "n_tested": len(rows)}
    if len(shown) < len(rows):
        out["truncated"] = True
        out["n_withheld"] = len(rows) - len(shown)
        out["how_to_see_all"] = "pass top_n=None (or a larger top_n) for the full table"
        if n_sig > len(shown):
            out["significant_not_shown"] = n_sig - len(shown)
    return out


# Cohort vocabularies whose order is not in dispute. Used only to pick a sensible default
# reference; the chosen order is always reported back as cohort_order, and an explicit
# `levels` argument overrides it.
_ORDINAL_VOCABULARIES = (
    ("low", "medium", "high"),
    ("low", "mid", "high"),
    ("low", "high"),
    ("none", "low", "medium", "high"),
    ("negative", "positive"),
    ("absent", "present"),
    ("control", "treated"),
    ("pre", "post"),
    ("baseline", "followup"),
)


def _ordinal_order(present: list) -> list | None:
    """The cohorts in their conventional order, or None if that is not knowable."""
    labels = {str(p).strip().lower(): p for p in present}
    if len(labels) != len(present):
        return None                                     # duplicate after casefolding
    for vocab in _ORDINAL_VOCABULARIES:
        if set(labels) <= set(vocab):
            return [labels[v] for v in vocab if v in labels]
    return None


def differential_abundance(
    matrix: pd.DataFrame,
    features: list[str],
    group_map: dict,
    test: str = "lme",
    is_longitudinal: bool = True,
    top_n: int | None = None,
    compare: list | None = None,
    levels: list | None = None,
    covariates="auto",
) -> dict:
    """Test features between cohorts, one Benjamini-Hochberg correction across all.

    For lme/ols: one pooled fit per feature (via the shared engine), every pairwise contrast
    read off it, one FDR family. For welch/wilcoxon: a two-sample test per pair. Covariates
    are adjusted for but never reported or FDR-corrected — nuisance terms, not hypotheses.
    """
    if test not in VALID_TESTS:
        return {"error": f"unknown test '{test}'", "valid_tests": list(VALID_TESTS)}

    matrix = coerce_matrix(matrix)
    if not isinstance(matrix, pd.DataFrame) or "sample_id" not in matrix.columns:
        return {"error": "matrix must be the assembled matrix (a DataFrame with a sample_id "
                         "column) or a loaded study dict"}
    if isinstance(features, str):
        features = [features]
    missing = [f for f in features if f not in matrix.columns]
    if missing:
        return {"error": f"{len(missing)} feature(s) not on the matrix",
                "missing_features": [str(f) for f in missing[:10]]}
    try:
        group_map = coerce_group_map(group_map, matrix)
    except (KeyError, ValueError, TypeError) as e:
        return {"error": str(e)}

    present = pd.Series([group_map.get(s) for s in matrix["sample_id"]]).dropna().unique().tolist()

    if levels is not None:
        unknown = [lv for lv in levels if lv not in present]
        if unknown:
            return {"error": f"`levels` names cohorts not present: {[str(x) for x in unknown]}",
                    "available_cohorts": sorted(str(x) for x in present)}
        levels_all = [lv for lv in levels]
    else:
        # sorted, not first-appearance: the reference must not depend on row order. A few
        # unambiguous ordinal vocabularies are ordered as meant; `levels` overrides both.
        levels_all = _ordinal_order(present) or sorted(present, key=str)

    if compare:
        bad = [c for c in compare if c not in present]
        if bad or len(compare) != 2:
            return {"error": f"`compare` must name exactly 2 existing cohorts, [reference, contrast]; got {compare}",
                    "available_cohorts": sorted(str(x) for x in present)}
        pairs = [tuple(compare)]
    elif len(levels_all) >= 2:
        pairs = list(combinations(levels_all, 2))
    else:
        return {"error": f"need at least 2 cohorts; found {len(levels_all)}: {[str(x) for x in levels_all]}"}

    # run every pair, tagging each row with its comparison, collecting raw p.
    tagged: list[tuple[str, dict]] = []
    cov_used, cov_note = [], None

    if test in ("lme", "ols"):
        # one pooled fit per feature; see _pooled_rows
        keep_levels = set(levels_all)
        keep = [i for i, s in enumerate(matrix["sample_id"]) if group_map.get(s) in keep_levels]
        sub = matrix.iloc[keep].reset_index(drop=True)
        base = pd.DataFrame({
            "sample_id": sub["sample_id"].values,
            "subject": sub["subject_id"].values if "subject_id" in sub.columns else sub["sample_id"].values,
            "group": [group_map.get(s) for s in sub["sample_id"]],
        })
        cov_used, cov_note = _pick_covariates(sub, base, covariates)
        for c in cov_used:
            base[c] = pd.to_numeric(sub[_COVARIATE_SOURCES.get(c, c)], errors="coerce").values
        base = base.dropna(subset=list(cov_used)) if cov_used else base
        for f in features:
            vals = sub.loc[base.index, f] if len(base) != len(sub) else sub[f]
            for r in _pooled_rows(base.reset_index(drop=True), vals.reset_index(drop=True),
                                  levels_all, pairs, test, cov_used):
                if "p" not in r:
                    continue
                tagged.append((f"{r['contrast']} vs {r['reference']}", {"feature": f, **r}))
    else:
        for lv in pairs:
            label = f"{lv[1]} vs {lv[0]}"
            for r in _run_pair(matrix, features, group_map, test, lv):
                tagged.append((label, r))

    if not tagged:
        return {"error": "no feature had enough data in any comparison", "test": test}

    # ONE Benjamini-Hochberg correction across every test shown — composed, not inlined.
    padj = adjust_pvalues([r["p"] for _, r in tagged], method="bh")["adjusted"]
    for (_, r), q in zip(tagged, padj):
        r["p_adj_bh"] = float(q)

    warn = None
    if is_longitudinal and test in ("ols", "welch", "wilcoxon"):
        warn = (f"'{test}' treats every sample as independent, but this data has repeated samples "
                f"per subject. The p-values are anti-conservative. Use 'lme' for a "
                f"repeated-measures-correct result, or treat these as exploratory only.")

    if test in ("lme", "ols"):
        rhs = " + ".join(["cohort"] + list(cov_used)) + (" + (1|subject)" if test == "lme" else "")
        model_desc = {
            "formula": f"feature ~ {rhs}",
            "covariates_adjusted": list(cov_used),
            "fit_scope": "one fit across all cohorts; pairwise contrasts read off it",
        }
        if cov_note:
            model_desc["covariate_note"] = cov_note
    else:
        model_desc = {"formula": f"two-sample {test} per pair", "covariates_adjusted": [],
                      "fit_scope": "each pair tested on its own samples"}

    # Features that fell back to OLS are reported rather than dropped.
    fell_back = sum(1 for _, r in tagged if r.get("fitted_with") == "ols_fallback")
    fallback_warn = None
    if fell_back:
        fallback_warn = (f"{fell_back} of {len(tagged)} tests could not fit a mixed model and were "
                         f"refitted with OLS (rows marked fitted_with='ols_fallback'). Those rows "
                         f"ignore repeated sampling within subject, so their p-values are "
                         f"anti-conservative; read them as exploratory.")

    # single comparison: flat shape (back-compatible)
    if len(pairs) == 1:
        rows = [r for _, r in tagged]
        out = {
            "test": test,
            "model": model_desc,
            "comparison": f"{pairs[0][1]} vs {pairs[0][0]}",
            "reference": str(pairs[0][0]),
            "contrast": str(pairs[0][1]),
            "n_features_tested": len(rows),
            "n_significant_q05": int(sum(r["p_adj_bh"] < 0.05 for r in rows)),
            "table": _withheld(rows, _format(rows, top_n)),
            "results": _format(rows, top_n),
            "interpretation_hint": (
                f"Sorted by FDR-adjusted p. Report effect size with adjusted p, not raw p. "
                f"Every effect is '{pairs[0][1]} minus {pairs[0][0]}' on the analysis scale "
                f"(CLR for clade): positive means higher in {pairs[0][1]}. Each row also "
                f"names its own reference and contrast."
            ),
        }
        if warn:
            out["pseudoreplication_warning"] = warn
        if fallback_warn:
            out["lme_fallback_warning"] = fallback_warn
        return out

    # all-pairs: grouped by comparison, with shared FDR noted
    by_label: dict[str, list[dict]] = {}
    for label, r in tagged:
        by_label.setdefault(label, []).append(r)
    out = {
        "test": test,
        "model": model_desc,
        "mode": "all_pairs",
        "n_cohorts": len(levels_all),
        "cohort_order": [str(x) for x in levels_all],
        "n_comparisons": len(pairs),
        "total_tests": len(tagged),
        "fdr_note": ("Benjamini-Hochberg FDR is applied jointly across all comparisons shown, "
                     "not within each pair, so the all-pairs view does not inflate false positives."),
        "comparisons": [
            {
                "comparison": label,
                "n_significant_q05": int(sum(r["p_adj_bh"] < 0.05 for r in rows)),
                "table": _withheld(rows, _format(rows, top_n)),
                "results": _format(rows, top_n),
            }
            for label, rows in by_label.items()
        ],
        "interpretation_hint": (
            "Report effect size with the jointly-adjusted p, not raw p. In every comparison "
            "'<contrast> vs <reference>', the effect is contrast minus reference: positive "
            "means higher in the cohort named first. Each row also names its own reference "
            "and contrast, so no direction has to be inferred from the order of anything."
        ),
    }
    if warn:
        out["pseudoreplication_warning"] = warn
    if fallback_warn:
        out["lme_fallback_warning"] = fallback_warn
    return out
