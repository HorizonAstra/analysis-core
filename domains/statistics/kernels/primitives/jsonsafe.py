"""One JSON-safety coercion for numeric results.

Every primitive returns dicts that eventually become JSON for the model, and JSON has no
NaN, no infinity, and no numpy scalars. This was re-implemented in three primitives with
subtly different rules (whether ints stayed ints, whether pandas NA was caught), so the
same value could serialize differently depending on which block produced it. One helper
instead, with the union of those behaviours.
"""

from __future__ import annotations

from typing import Any

import numpy as np
import pandas as pd


def json_safe_number(val: Any) -> Any:
    """NaN/NA/inf -> None; numpy scalars -> native int/float; anything else unchanged.

    Integers stay integers and floats stay floats — a count and a probability should not
    become the same type on the way out.
    """
    if val is None:
        return None
    if isinstance(val, (np.integer, int)) and not isinstance(val, bool):
        return int(val)
    if isinstance(val, (np.floating, float)):
        v = float(val)
        return None if not np.isfinite(v) else v
    # pandas NA/NaT and other scalar missing markers; non-scalars are returned as-is.
    try:
        if pd.isna(val):
            return None
    except (TypeError, ValueError):
        pass
    return val
