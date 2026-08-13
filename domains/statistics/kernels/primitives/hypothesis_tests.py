'''
- One-sample t-test
- Two-sample t-test
- Paired t-test
- Welch's t-test
- One-way ANOVA
- Two-way ANOVA
- Volcano univariate (per-feature two-group test for volcano plots)

(PERMANOVA / PERMDISP live in the ordination block — they take a distance matrix,
not raw groups of values, so they belong with PCoA and the beta-diversity bundle.)
'''

import statistics
import numpy as np
import pandas as pd
import statsmodels.formula.api as smf
from statsmodels.stats.anova import anova_lm
from typing import List, Dict, Any, Union, Optional

from .jsonsafe import json_safe_number as _json_safe_number
from .multiple_testing import adjust_pvalues
from scipy.stats import ttest_1samp, ttest_ind, ttest_rel, f_oneway, mannwhitneyu


def one_sample_ttest(values: List[float], hypothesized_mean: float) -> Dict[str, Any]:
    """
    Perform one-sample t-test.
    Tests whether the mean of a sample differs significantly from a hypothesized value.
    """
    t_statistic, p_value = ttest_1samp(values, hypothesized_mean)
    
    return {
        "test_type": "one_sample_ttest",
        "t_statistic": t_statistic,
        "p_value": p_value,
        "hypothesized_mean": hypothesized_mean,
        "sample_mean": statistics.mean(values),
        "sample_size": len(values),
        "values": values
    }

def two_sample_ttest(group1_values: List[float], group2_values: List[float]) -> Dict[str, Any]:
    """
    Perform two-sample (unpaired) t-test.
    Tests whether the means of two independent samples differ significantly.
    """
    t_statistic, p_value = ttest_ind(group1_values, group2_values)
    
    return {
        "test_type": "two_sample_ttest",
        "t_statistic": t_statistic,
        "p_value": p_value,
        "group1_mean": statistics.mean(group1_values),
        "group2_mean": statistics.mean(group2_values),
        "group1_size": len(group1_values),
        "group2_size": len(group2_values),
        "group1_values": group1_values,
        "group2_values": group2_values
    }

def paired_ttest(before_values: List[float], after_values: List[float]) -> Dict[str, Any]:
    """
    Perform paired t-test.
    Tests whether the means of two paired samples differ significantly.
    """
    t_statistic, p_value = ttest_rel(before_values, after_values)
    
    return {
        "test_type": "paired_ttest",
        "t_statistic": t_statistic,
        "p_value": p_value,
        "before_mean": statistics.mean(before_values),
        "after_mean": statistics.mean(after_values),
        "mean_difference": statistics.mean(after_values) - statistics.mean(before_values),
        "sample_size": len(before_values),
        "before_values": before_values,
        "after_values": after_values
    }

def welch_ttest(group1_values: List[float], group2_values: List[float]) -> Dict[str, Any]:
    """
    Perform Welch's t-test (unequal variances t-test).
    Tests whether the means of two independent samples differ significantly,
    without assuming equal variances.
    """
    # Use equal_var=False for Welch's t-test
    t_statistic, p_value = ttest_ind(group1_values, group2_values, equal_var=False)
    
    return {
        "test_type": "welch_ttest",
        "t_statistic": t_statistic,
        "p_value": p_value,
        "group1_mean": statistics.mean(group1_values),
        "group2_mean": statistics.mean(group2_values),
        "group1_size": len(group1_values),
        "group2_size": len(group2_values),
        "group1_values": group1_values,
        "group2_values": group2_values
    }

def one_way_anova(groups: List[List[float]], group_names: List[str]) -> Dict[str, Any]:
    """
    Perform one-way ANOVA.
    Tests whether the means of three or more groups differ significantly.
    """
    f_statistic, p_value = f_oneway(*groups)
    
    # Calculate group statistics
    group_stats = []
    for i, (group_name, group_values) in enumerate(zip(group_names, groups)):
        group_stats.append({
            "name": group_name,
            "mean": statistics.mean(group_values),
            "size": len(group_values),
            "values": group_values
        })
    
    return {
        "test_type": "one_way_anova",
        "f_statistic": f_statistic,
        "p_value": p_value,
        "num_groups": len(groups),
        "total_observations": sum(len(group) for group in groups),
        "groups": group_stats
    }

def two_way_anova(valid_data: List[tuple]) -> Dict[str, Any]:
    """
    Perform two-way ANOVA with interaction using Type II sums of squares (statsmodels).
    Tests the main effect of each factor and their interaction on a continuous outcome.
    Handles unbalanced designs correctly via Type II SS.
    """
    factor1_vals = [str(d[0]) for d in valid_data]
    factor2_vals = [str(d[1]) for d in valid_data]
    values = [d[2] for d in valid_data]

    unique_factor1 = sorted(set(factor1_vals))
    unique_factor2 = sorted(set(factor2_vals))

    df = pd.DataFrame({
        'factor1': factor1_vals,
        'factor2': factor2_vals,
        'value': values
    })

    model = smf.ols('value ~ C(factor1) + C(factor2) + C(factor1):C(factor2)', data=df).fit()
    anova_table = anova_lm(model, typ=2)

    def _safe(val):
        if pd.isna(val):
            return None
        return float(val)

    factor1_row = anova_table.loc['C(factor1)']
    factor2_row = anova_table.loc['C(factor2)']
    interaction_row = anova_table.loc['C(factor1):C(factor2)']
    residual_row = anova_table.loc['Residual']

    combination_stats = []
    for f1 in unique_factor1:
        for f2 in unique_factor2:
            cell_vals = df[(df['factor1'] == f1) & (df['factor2'] == f2)]['value'].tolist()
            if cell_vals:
                combination_stats.append({
                    "combination": f"{f1} x {f2}",
                    "mean": statistics.mean(cell_vals),
                    "size": len(cell_vals),
                    "values": cell_vals
                })

    return {
        "test_type": "two_way_anova",
        "factor1_effect": {
            "F": _safe(factor1_row['F']),
            "p_value": _safe(factor1_row['PR(>F)']),
            "df": int(factor1_row['df']),
            "sum_sq": _safe(factor1_row['sum_sq'])
        },
        "factor2_effect": {
            "F": _safe(factor2_row['F']),
            "p_value": _safe(factor2_row['PR(>F)']),
            "df": int(factor2_row['df']),
            "sum_sq": _safe(factor2_row['sum_sq'])
        },
        "interaction_effect": {
            "F": _safe(interaction_row['F']),
            "p_value": _safe(interaction_row['PR(>F)']),
            "df": int(interaction_row['df']),
            "sum_sq": _safe(interaction_row['sum_sq'])
        },
        "residuals": {
            "df": int(residual_row['df']),
            "sum_sq": _safe(residual_row['sum_sq'])
        },
        "factor1_levels": unique_factor1,
        "factor2_levels": unique_factor2,
        "total_observations": len(values),
        "combinations": combination_stats
    }


def volcano_univariate(
    feature_matrix: Union[List[List[float]], np.ndarray],
    feature_ids: List[str],
    grouping: List[Union[str, int]],
    group1_label: Optional[Union[str, int]] = None,
    group2_label: Optional[Union[str, int]] = None,
    test: str = "ttest",
    fdr_method: str = "bh",
    transform: str = "none",
) -> Dict[str, Any]:
    """
    Per-feature two-group univariate test for volcano plots (differential abundance/expression).
    For each feature, computes group means, log2 fold change, p-value, and FDR-adjusted p-value.
    test: 'ttest' (independent t-test) or 'wilcoxon' (Mann-Whitney U).
    fdr_method: 'bh' (Benjamini-Hochberg, default), 'bonferroni', 'holm', 'none'. Correction is
        delegated to the adjust_pvalues primitive rather than re-implemented here, so every
        block in the library corrects the same way and speaks the same method vocabulary.
        The family is the features tested in THIS call — if you pool several calls (several
        cohort pairs, several omics), correct across the pooled raw p_value yourself with
        adjust_pvalues and ignore adjusted_p_value here, which would be the wrong family.
    The caller (a workflow or tool) is responsible for input validation; this primitive assumes clean input.
    """
    X = np.asarray(feature_matrix, dtype=np.float64)
    if X.ndim != 2:
        raise ValueError("feature_matrix must be 2D (samples x features)")
    n_samples, n_features = X.shape
    if len(grouping) != n_samples:
        raise ValueError("grouping length must match number of samples (rows)")
    if len(feature_ids) != n_features:
        raise ValueError("feature_ids length must match number of features (columns)")

    groups = np.asarray(grouping)
    uniq = np.unique(groups)
    if len(uniq) != 2:
        raise ValueError("grouping must contain exactly two groups")
    if group1_label is None:
        group1_label = uniq[0]
    if group2_label is None:
        group2_label = uniq[1]
    mask1 = groups == group1_label
    mask2 = groups == group2_label
    n1 = int(np.sum(mask1))
    n2 = int(np.sum(mask2))
    if n1 < 2 or n2 < 2:
        raise ValueError("Each group must have at least 2 samples")

    results = []
    for j in range(n_features):
        col = X[:, j]
        v1 = col[mask1]
        v2 = col[mask2]
        mean1 = _json_safe_number(np.nanmean(v1))
        mean2 = _json_safe_number(np.nanmean(v2))
        if transform in ('clr', 'log', 'log2', 'log10', 'log1p'):
            log2fc = _json_safe_number(float(mean2) - float(mean1))
        else:
            if mean1 <= 0 or mean2 <= 0:
                log2fc = None
            else:
                log2fc = _json_safe_number(np.log2(float(mean2) / float(mean1)))

        if test == "ttest":
            stat, p = ttest_ind(v1, v2, equal_var=False, nan_policy="omit")
            test_statistic = _json_safe_number(stat)
        elif test == "wilcoxon":
            stat, p = mannwhitneyu(v1, v2, alternative="two-sided", nan_policy="omit")
            test_statistic = float(stat)
        else:
            raise ValueError("test must be 'ttest' or 'wilcoxon'")
        pval = _json_safe_number(p) if not np.isnan(p) else None
        results.append({
            "feature_id": feature_ids[j],
            "mean_group1": mean1,
            "mean_group2": mean2,
            "log2_fold_change": log2fc,
            "p_value": pval,
            "test_statistic": test_statistic,
            "n_group1": n1,
            "n_group2": n2,
        })

    p_vals = [r["p_value"] for r in results if r["p_value"] is not None]
    if p_vals:
        p_adj = adjust_pvalues(p_vals, method=fdr_method)["adjusted"]
        adj_map = {i: _json_safe_number(p) for i, p in enumerate(p_adj)}
    else:
        adj_map = {}
    idx = 0
    for r in results:
        if r["p_value"] is not None:
            r["adjusted_p_value"] = adj_map[idx]
            idx += 1
        else:
            r["adjusted_p_value"] = None

    return {
        "analysis_type": "volcano_univariate",
        "test": test,
        "fdr_method": fdr_method,
        "group1_label": group1_label,
        "group2_label": group2_label,
        "n_samples": n_samples,
        "n_features": n_features,
        "n_group1": n1,
        "n_group2": n2,
        "features": results,
        "parameters": {
            "test": test,
            "fdr_method": fdr_method,
            "transform": transform,
        },
    }