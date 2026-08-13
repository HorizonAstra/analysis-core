"""Reusable request validators and numeric coercion.

These are the small, composable checks that the per-analysis validators in
requests.py build on, factored out of the old router where the same handful of
patterns (require a field, coerce to a clean float list, check a length, restrict
to a set of choices) were copy-pasted dozens of times. Every failure raises
ValidationError; nothing here computes statistics.
"""

from __future__ import annotations

import math
from typing import Any, Iterable, Sequence

import numpy as np
import pandas as pd

from .exceptions import ValidationError


# ── presence / type ─────────────────────────────────────────────────────────

def require_field(data: dict, key: str, analysis: str) -> Any:
    if not isinstance(data, dict) or key not in data:
        raise ValidationError(f"'{key}' is required for {analysis}!", analysis=analysis)
    return data[key]


def require_fields(data: dict, keys: Sequence[str], analysis: str) -> None:
    missing = [k for k in keys if not isinstance(data, dict) or k not in data]
    if missing:
        joined = ", ".join(f"'{k}'" for k in missing)
        raise ValidationError(f"{joined} {'is' if len(missing) == 1 else 'are'} required for {analysis}!", analysis=analysis)


def require_list(value: Any, name: str, analysis: str, min_len: int = 1) -> list:
    if not isinstance(value, list):
        raise ValidationError(f"'{name}' must be a list!", analysis=analysis)
    if len(value) < min_len:
        raise ValidationError(f"'{name}' must have at least {min_len} item(s)!", analysis=analysis)
    return value


def in_choices(value: Any, choices: Iterable, name: str, analysis: str) -> Any:
    choices = list(choices)
    if value not in choices:
        raise ValidationError(
            f"'{name}' must be one of: {', '.join(map(str, choices))}!", analysis=analysis
        )
    return value


def as_int(value: Any, name: str, analysis: str, minimum: int | None = None, maximum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"'{name}' must be an integer!", analysis=analysis)
    if minimum is not None and value < minimum:
        raise ValidationError(f"'{name}' must be >= {minimum}!", analysis=analysis)
    if maximum is not None and value > maximum:
        raise ValidationError(f"'{name}' must be <= {maximum}!", analysis=analysis)
    return value


def as_float_in_range(value: Any, name: str, analysis: str, lo: float, hi: float,
                      inclusive: bool = False) -> float:
    try:
        v = float(value)
    except (TypeError, ValueError):
        raise ValidationError(f"'{name}' must be a number!", analysis=analysis)
    ok = (lo <= v <= hi) if inclusive else (lo < v < hi)
    if not ok:
        bracket = f"[{lo}, {hi}]" if inclusive else f"({lo}, {hi})"
        raise ValidationError(f"'{name}' must be in {bracket}!", analysis=analysis)
    return v


# ── numeric coercion (the "convert to float, drop None/NaN" pattern) ─────────

def _is_nan(x: Any) -> bool:
    return isinstance(x, float) and math.isnan(x)


def clean_float_list(values: Any, name: str, analysis: str, min_len: int = 1) -> list[float]:
    """Coerce a list to floats, dropping None / NaN / non-numeric entries. Raises if
    fewer than min_len usable values remain."""
    require_list(values, name, analysis, min_len=1)
    out: list[float] = []
    for v in values:
        if v is None or _is_nan(v):
            continue
        try:
            f = float(v)
        except (TypeError, ValueError):
            continue
        if math.isfinite(f):
            out.append(f)
    if len(out) < min_len:
        raise ValidationError(
            f"'{name}' has fewer than {min_len} valid numeric value(s) after cleaning!",
            analysis=analysis,
        )
    return out


def clean_pairs(x: Any, y: Any, analysis: str, name_x: str = "x", name_y: str = "y",
                min_len: int = 2) -> tuple[list[float], list[float]]:
    """Align two sequences, dropping any index where either side is missing /
    non-numeric. Raises if they differ in length or too few pairs survive."""
    require_list(x, name_x, analysis, min_len=1)
    require_list(y, name_y, analysis, min_len=1)
    if len(x) != len(y):
        raise ValidationError(f"'{name_x}' and '{name_y}' must have the same length!", analysis=analysis)
    xs, ys = [], []
    for xv, yv in zip(x, y):
        if xv is None or yv is None or _is_nan(xv) or _is_nan(yv):
            continue
        try:
            xf, yf = float(xv), float(yv)
        except (TypeError, ValueError):
            continue
        if math.isfinite(xf) and math.isfinite(yf):
            xs.append(xf)
            ys.append(yf)
    if len(xs) < min_len:
        raise ValidationError(
            f"fewer than {min_len} valid ({name_x}, {name_y}) pairs after cleaning!", analysis=analysis
        )
    return xs, ys


def to_numeric_frame(raw: Any, name: str, analysis: str, min_rows: int = 1,
                     allow_nan: bool = True) -> pd.DataFrame:
    """Parse a 2D list (rows) or a column-keyed dict into a numeric DataFrame.
    Rejects empty input and, unless allow_nan, any NaN/inf values."""
    if raw is None:
        raise ValidationError(f"'{name}' is required!", analysis=analysis)
    if isinstance(raw, pd.DataFrame):
        df = raw.copy()
    else:
        try:
            df = pd.DataFrame(raw)
        except Exception:
            raise ValidationError(f"'{name}' must be a 2D list (rows) or a column-keyed object!", analysis=analysis)
    if df.empty:
        raise ValidationError(f"'{name}' must not be empty!", analysis=analysis)
    if df.shape[0] < min_rows:
        raise ValidationError(f"'{name}' needs at least {min_rows} row(s)!", analysis=analysis)
    try:
        df = df.apply(pd.to_numeric)
    except Exception:
        raise ValidationError(f"all values in '{name}' must be numeric!", analysis=analysis)
    if not allow_nan:
        if df.isnull().any().any():
            raise ValidationError(f"'{name}' must not contain NaN or null values!", analysis=analysis)
        if not np.isfinite(df.values).all():
            raise ValidationError(f"'{name}' must not contain infinite values!", analysis=analysis)
    return df


def to_square_matrix(raw: Any, name: str, analysis: str, min_n: int = 2) -> np.ndarray:
    """Parse a distance/similarity matrix into a square float ndarray."""
    if raw is None:
        raise ValidationError(f"'{name}' is required!", analysis=analysis)
    if not isinstance(raw, list) and not hasattr(raw, "__array__"):
        raise ValidationError(f"'{name}' must be a 2D list or array!", analysis=analysis)
    try:
        X = np.asarray(raw, dtype=np.float64)
    except (ValueError, TypeError):
        raise ValidationError(f"'{name}' must contain numeric data!", analysis=analysis)
    if X.ndim != 2 or X.shape[0] != X.shape[1]:
        raise ValidationError(f"'{name}' must be a square 2D array!", analysis=analysis)
    if X.shape[0] < min_n:
        raise ValidationError(f"'{name}' must have at least {min_n} samples!", analysis=analysis)
    return X


def to_2d_matrix(raw: Any, name: str, analysis: str) -> np.ndarray:
    if raw is None:
        raise ValidationError(f"'{name}' is required!", analysis=analysis)
    if not isinstance(raw, list) and not hasattr(raw, "__array__"):
        raise ValidationError(f"'{name}' must be a 2D list or array!", analysis=analysis)
    try:
        X = np.asarray(raw, dtype=np.float64)
    except (ValueError, TypeError):
        raise ValidationError(f"'{name}' must contain numeric data!", analysis=analysis)
    if X.ndim != 2:
        raise ValidationError(f"'{name}' must be 2D!", analysis=analysis)
    return X


def check_length(seq: Sequence, n: int, name: str, analysis: str) -> None:
    if seq is not None and len(seq) != n:
        raise ValidationError(f"'{name}' length ({len(seq)}) must match {n}!", analysis=analysis)
