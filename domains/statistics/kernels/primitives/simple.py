'''
- Mean
- Median
- Variance
- Standard Deviation
- Range
- Sum
- Min
- Max
'''

import statistics
from typing import List, Dict, Any


def descriptive_analysis(statistic: str, values: List[float]) -> Dict[str, Any]:
    """
    Perform descriptive statistics on the provided data.
    
    Args:
        statistic: The type of statistic to calculate (mean, median, variance, etc.)
        values: List of numeric values to analyze (already validated and cleaned)
    
    Returns:
        Dictionary containing the calculated statistics
    """
    result = {
        "statistic": statistic,
        "count": len(values),
        "values": values
    }
    
    if statistic == "mean":
        result["value"] = statistics.mean(values)
    elif statistic == "median":
        result["value"] = statistics.median(values)
    elif statistic == "variance":
        if len(values) < 2:
            result["value"] = 0.0
        else:
            result["value"] = statistics.variance(values)
    elif statistic == "std_dev":
        if len(values) < 2:
            result["value"] = 0.0
        else:
            result["value"] = statistics.stdev(values)
    elif statistic == "range":
        result["value"] = max(values) - min(values)
    elif statistic == "sum":
        result["value"] = sum(values)
    elif statistic == "min":
        result["value"] = min(values)
    elif statistic == "max":
        result["value"] = max(values)
    else:
        raise Exception(f"Unknown descriptive statistic: {statistic}")
    
    return result