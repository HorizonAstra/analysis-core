'''
- Feature filtering (prevalence + minimum abundance)
- CLR transform (compositional data / metagenomics)
- Log transform (non-compositional data / metabolomics)
- TSS normalization (total-sum scaling)
- Fisher z transform (variance-stabilizing transform for correlation coefficients)
'''

import numpy as np
import pandas as pd
from typing import Union
from skbio.stats.composition import clr, multi_replace

ArrayLike = Union[float, list, np.ndarray, pd.Series]


def filter_features(
    df: pd.DataFrame,
    min_prevalence: float = 0.1,
    min_abundance: float = 0.0001,
) -> pd.DataFrame:
    """
    Filter feature columns by prevalence and minimum abundance.
    A feature is retained only if it exceeds min_abundance in at least
    min_prevalence fraction of samples.
    Matches MaAsLin2's default prevalence + abundance filtering step.
    """
    if not isinstance(df, pd.DataFrame):
        raise ValueError("df must be a pandas DataFrame")
    if not (0 < min_prevalence <= 1):
        raise ValueError("min_prevalence must be in (0, 1]")
    if min_abundance < 0:
        raise ValueError("min_abundance must be non-negative")

    # Abundance filter: per data-point — zero out values below min_abundance.
    # This does not drop features or samples; it operates at the data-point level.
    filtered = df.where(df > min_abundance, other=0.0)

    # Prevalence filter: per feature, evaluated independently of abundance.
    # A feature is kept if the fraction of samples with value > 0 meets min_prevalence.
    prevalence = (filtered > 0).mean(axis=0)
    filtered = filtered.loc[:, prevalence >= min_prevalence]

    # Drop samples (rows) that are all zeros after feature filtering so that
    # downstream transforms like CLR do not receive compositions with total
    # mass zero, which skbio rejects.
    if not filtered.empty:
        row_sums = filtered.sum(axis=1)
        filtered = filtered.loc[row_sums != 0]

    return filtered


def clr_transform(
    df: pd.DataFrame,
    pseudocount_method: str = "multiplicative_replacement",
) -> pd.DataFrame:
    """
    Centered log-ratio (CLR) transform for compositional data (e.g. metagenomics).
    Zeros are handled before CLR via multiplicative replacement (skbio default,
    matches MaAsLin2 behavior). Returns a DataFrame with the same index and columns.

    pseudocount_method: currently only 'multiplicative_replacement' is supported (mapped to multi_replace internally).
    """
    if not isinstance(df, pd.DataFrame):
        raise ValueError("df must be a pandas DataFrame")
    if (df < 0).any().any():
        raise ValueError("CLR transform requires non-negative values")
    if pseudocount_method != "multiplicative_replacement":
        raise ValueError("Only 'multiplicative_replacement' is currently supported")

    values = df.values.astype(np.float64)
    replaced = multi_replace(values)
    transformed = clr(replaced)
    transformed = np.asarray(transformed).reshape(df.shape)
    return pd.DataFrame(transformed, index=df.index, columns=df.columns)


def log_transform(
    df: pd.DataFrame,
    base: str = "natural",
    epsilon: float = 1e-10,
) -> pd.DataFrame:
    """
    Log transform for non-compositional data (e.g. metabolomics).
    base: 'natural' (ln), '2' (log2), '10' (log10), or 'log1p' (ln(1+x), handles exact zeros
    without epsilon — the standard choice for count data and sparse features).
    For all bases except 'log1p', epsilon is added before log to handle zeros.
    epsilon: small offset added to values before log (default 1e-10); ignored when base='log1p'.
    Returns a DataFrame with the same index and columns.
    """
    if not isinstance(df, pd.DataFrame):
        raise ValueError("df must be a pandas DataFrame")
    if base not in ("natural", "2", "10", "log1p"):
        raise ValueError("base must be 'natural', '2', '10', or 'log1p'")
    if epsilon < 0:
        raise ValueError("epsilon must be non-negative")

    values = df.values.astype(np.float64)
    if base == "log1p":
        transformed = np.log1p(values)
    else:
        values = values + epsilon
        if base == "natural":
            transformed = np.log(values)
        elif base == "2":
            transformed = np.log2(values)
        else:
            transformed = np.log10(values)
    return pd.DataFrame(transformed, index=df.index, columns=df.columns)


def tss_normalize(
    df: pd.DataFrame,
) -> pd.DataFrame:
    """
    Total-sum scaling (TSS): divides each sample (row) by its row sum, converting
    raw counts to relative abundances in [0, 1].
    Rows that sum to zero are left as-is (all zeros returned for that row).
    Returns a DataFrame with the same index and columns.
    """
    if not isinstance(df, pd.DataFrame):
        raise ValueError("df must be a pandas DataFrame")

    row_sums = df.sum(axis=1)
    row_sums_safe = row_sums.replace(0, np.nan)
    normalized = df.div(row_sums_safe, axis=0).fillna(0.0)
    return normalized


def zscore_transform(df: pd.DataFrame, ddof: int = 0) -> pd.DataFrame:
    """
    Standardize each feature (column) to zero mean and unit variance:
    (x - mean) / std. Variance-stabilizing comparison across features measured on
    different scales (e.g. metabolite concentrations before a Euclidean distance).
    Constant columns (zero variance) are returned as all-zeros rather than NaN.
    Returns a DataFrame with the same index and columns.
    """
    if not isinstance(df, pd.DataFrame):
        raise ValueError("df must be a pandas DataFrame")
    values = df.values.astype(np.float64)
    mean = values.mean(axis=0)
    std = values.std(axis=0, ddof=ddof)
    with np.errstate(divide="ignore", invalid="ignore"):
        standardized = np.where(std > 0, (values - mean) / std, 0.0)
    return pd.DataFrame(standardized, index=df.index, columns=df.columns)


def fisher_z_transform(r: ArrayLike, clip: float = 0.9999) -> np.ndarray:
    """
    Fisher z-transform of a correlation coefficient: z = arctanh(r).

    Variance-stabilizing transform that maps r in (-1, 1) to z in (-inf, inf),
    making the sampling distribution of z approximately normal with variance
    1 / (n - 3). This is the standard basis for pooling / meta-analysing
    correlations and building confidence intervals on them.

    Accepts a scalar, list, ndarray, or Series and returns an ndarray of the
    same shape (vectorized). Values are clipped to (-clip, clip) before the
    transform so that r == +/-1 maps to a large finite number rather than +/-inf.
    """
    if not (0 < clip < 1):
        raise ValueError("clip must be in (0, 1)")
    r_arr = np.clip(np.asarray(r, dtype=np.float64), -clip, clip)
    return np.arctanh(r_arr)


def inverse_fisher_z(z: ArrayLike) -> np.ndarray:
    """
    Inverse Fisher z-transform: r = tanh(z). Maps a z-value (or array of them)
    back to a correlation coefficient in (-1, 1). Vectorized; returns an ndarray.
    """
    return np.tanh(np.asarray(z, dtype=np.float64))
