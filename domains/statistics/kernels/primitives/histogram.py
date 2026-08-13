'''
Histogram and bin size calculation methods:
- Freedman-Diaconis (uses IQR, robust to outliers and skew)
- Scott (uses standard deviation)
- Sturges (simple formula based on data size)
- Doane (extension of Sturges for skewed data)
- Square Root (simple square root rule)
- Fixed Count (user-specified number of bins)
- Fixed Width (user-specified bin width)
'''

import numpy as np
from typing import List, Dict, Any


def calculate_bins_freedman_diaconis(values: List[float]) -> int:
    """
    Freedman-Diaconis rule: Uses IQR instead of std, robust to outliers and skew.
    Works well for both raw RA and raw concentrations which are skewed/zero-inflated.

    Formula: bin_width = 2 * IQR / n^(1/3)
    """
    values_array = np.array(values)
    q75, q25 = np.percentile(values_array, [75, 25])
    iqr = q75 - q25

    if iqr == 0:
        return max(1, int(np.ceil(np.sqrt(len(values)))))

    bin_width = 2 * iqr / (len(values) ** (1/3))
    data_range = np.max(values_array) - np.min(values_array)

    if bin_width == 0:
        return max(1, int(np.ceil(np.sqrt(len(values)))))

    n_bins = max(1, int(np.ceil(data_range / bin_width)))
    return n_bins


def calculate_bins_scott(values: List[float]) -> int:
    """
    Scott's rule: Uses standard deviation.

    Formula: bin_width = 3.5 * std / n^(1/3)
    """
    values_array = np.array(values)
    std = np.std(values_array)

    if std == 0:
        return max(1, int(np.ceil(np.sqrt(len(values)))))

    bin_width = 3.5 * std / (len(values) ** (1/3))
    data_range = np.max(values_array) - np.min(values_array)

    if bin_width == 0:
        return max(1, int(np.ceil(np.sqrt(len(values)))))

    n_bins = max(1, int(np.ceil(data_range / bin_width)))
    return n_bins


def calculate_bins_sturges(values: List[float]) -> int:
    """
    Sturges' rule: Simple formula based on data size.

    Formula: n_bins = ceil(log2(n)) + 1
    """
    n = len(values)
    n_bins = int(np.ceil(np.log2(n))) + 1
    return max(1, n_bins)


def calculate_bins_doane(values: List[float]) -> int:
    """
    Doane's rule: Extension of Sturges for skewed distributions.

    Formula: n_bins = ceil(1 + log2(n) + log2(1 + |skewness|/sqrt(6/n)))
    """
    values_array = np.array(values)
    n = len(values)

    # Calculate skewness
    mean = np.mean(values_array)
    std = np.std(values_array)

    if std == 0:
        return max(1, int(np.ceil(np.log2(n))) + 1)

    skewness = np.mean(((values_array - mean) / std) ** 3)

    sigma_g = np.sqrt((6 * (n - 2)) / ((n + 1) * (n + 3)))
    n_bins = 1 + np.log2(n) + np.log2(1 + np.abs(skewness) / sigma_g)

    return max(1, int(np.ceil(n_bins)))


def calculate_bins_sqrt(values: List[float]) -> int:
    """
    Square root rule: Simple and fast.

    Formula: n_bins = ceil(sqrt(n))
    """
    n = len(values)
    n_bins = int(np.ceil(np.sqrt(n)))
    return max(1, n_bins)


def calculate_bins_fixed_count(values: List[float], n_bins: int) -> int:
    """
    Fixed Count: User-specified number of bins.
    """
    if n_bins < 1:
        raise ValueError("n_bins must be at least 1")
    return n_bins


def calculate_bins_fixed_width(values: List[float], bin_width: float) -> int:
    """
    Fixed Width: User-specified bin width.
    Calculates number of bins based on data range and bin width.
    """
    if bin_width <= 0:
        raise ValueError("bin_width must be greater than 0")

    values_array = np.array(values)
    data_range = np.max(values_array) - np.min(values_array)

    # Number of bins needed to cover the range with given width
    n_bins = max(1, int(np.ceil(data_range / bin_width)))
    return n_bins


def histogram_analysis(method: str, values: List[float], n_bins: int = None, bin_width: float = None) -> Dict[str, Any]:
    """
    Generate histogram with specified bin calculation method.

    Args:
        method: Bin calculation method (freedman_diaconis, scott, sturges, doane, sqrt, fixed_count, fixed_width)
        values: List of numeric values to analyze (already validated and cleaned)
        n_bins: Number of bins for 'fixed_count' method (required if method='fixed_count')
        bin_width: Bin width for 'fixed_width' method (required if method='fixed_width')

    Returns:
        Dictionary containing histogram data with counts, bin edges, and metadata
    """
    values_array = np.array(values)

    # Determine number of bins based on method
    if method == "freedman_diaconis":
        bins = calculate_bins_freedman_diaconis(values)
    elif method == "scott":
        bins = calculate_bins_scott(values)
    elif method == "sturges":
        bins = calculate_bins_sturges(values)
    elif method == "doane":
        bins = calculate_bins_doane(values)
    elif method == "sqrt":
        bins = calculate_bins_sqrt(values)
    elif method == "fixed_count":
        if n_bins is None:
            raise ValueError("n_bins is required for 'fixed_count' method")
        bins = calculate_bins_fixed_count(values, n_bins)
    elif method == "fixed_width":
        if bin_width is None:
            raise ValueError("bin_width is required for 'fixed_width' method")
        bins = calculate_bins_fixed_width(values, bin_width)
    else:
        raise ValueError(f"Unknown histogram method: {method}")

    # Generate histogram
    counts, bin_edges = np.histogram(values_array, bins=bins)

    # Calculate bin centers
    bin_centers = (bin_edges[:-1] + bin_edges[1:]) / 2

    return {
        "method": method,
        "n_bins": bins,
        "counts": counts.tolist(),
        "bin_edges": bin_edges.tolist(),
        "bin_centers": bin_centers.tolist(),
        "n_values": len(values),
        "min": float(np.min(values_array)),
        "max": float(np.max(values_array)),
        "mean": float(np.mean(values_array)),
        "std": float(np.std(values_array))
    }
