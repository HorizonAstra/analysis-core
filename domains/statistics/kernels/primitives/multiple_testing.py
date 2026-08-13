from statsmodels.stats.multitest import multipletests
from typing import List

SUPPORTED_METHODS = ("bh", "bonferroni", "holm", "none")

# The library's vocabulary is the short name; statsmodels' own spellings are accepted as
# aliases so a caller reaching for the name it knows ('fdr_bh') gets the correction rather
# than a ValueError.
_ALIASES = {"fdr_bh": "bh", "benjamini-hochberg": "bh", "bh_fdr": "bh",
            "bonf": "bonferroni", "holm-bonferroni": "holm", None: "none"}


def _canonical(method: str) -> str:
    m = method.lower().strip() if isinstance(method, str) else method
    return _ALIASES.get(m, m)


def _statsmodels_method(method: str) -> str:
    if method == "bh":
        return "fdr_bh"
    if method == "bonferroni":
        return "bonferroni"
    if method == "holm":
        return "holm"
    raise ValueError(f"Unsupported method: {method}; supported: {SUPPORTED_METHODS}")


def adjust_pvalues(
    p_values: List[float],
    method: str = "bh",
) -> dict:
    """
    Apply multiple testing correction to a list of p-values.
    Returns adjusted p-values in the same order as input.
    The caller is responsible for input validation; this primitive assumes clean input.

    method: 'bh' (Benjamini-Hochberg), 'bonferroni', 'holm', 'none' (passthrough).
    Statsmodels spellings ('fdr_bh') are accepted as aliases.
    """
    method = _canonical(method)
    if method == "none":
        adjusted = [float(x) for x in p_values]
    else:
        statsmodels_method = _statsmodels_method(method)
        _, p_adj, _, _ = multipletests(p_values, method=statsmodels_method)
        adjusted = [float(x) for x in p_adj]

    return {
        "analysis_type": "adjust_pvalues",
        "method": method,
        "n_tests": len(p_values),
        "adjusted": adjusted,
    }
