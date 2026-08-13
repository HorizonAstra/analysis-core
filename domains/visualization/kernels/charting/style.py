"""Shared style for the charting library: the Agg backend, a research-grade theme,
the palette, and small helpers (filename slug, output path).

Research-grade defaults: a clean full box around each axes (thin spines), a subtle
grid, readable fonts, and 300 dpi. Bars are drawn without edges by default; borders
are otherwise welcome. Importing this module configures matplotlib for headless PNG
output, so the chart modules pull matplotlib/numpy/pandas/seaborn from here.
"""

from __future__ import annotations

import os
import re
from datetime import datetime

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import seaborn as sns  # noqa: E402

# qualitative palette for categorical hues, plus a few semantic accents
PALETTE = "Set2"
ACCENT = "#2a9d8f"
ACCENT_ALT = "#e76f51"
POSITIVE = "#2a9d8f"
NEGATIVE = "#e76f51"
HIGHLIGHT = "#264653"
MUTED = "#b8b8b8"


def use_style() -> None:
    """Apply the research-grade rcParams. Idempotent; call at the start of a render."""
    sns.set_theme(style="white")
    plt.rcParams.update({
        "savefig.dpi": 300,
        "savefig.bbox": "tight",
        "figure.dpi": 120,
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        # full box around each axes, thin and dark grey — research-grade framing
        "axes.spines.top": True,
        "axes.spines.right": True,
        "axes.spines.left": True,
        "axes.spines.bottom": True,
        "axes.edgecolor": "#444444",
        "axes.linewidth": 0.9,
        "axes.titlesize": 13,
        "axes.titleweight": "bold",
        "axes.labelsize": 11,
        "font.size": 11,
        "legend.frameon": False,
        "axes.grid": True,
        "grid.color": "#e8e8e8",
        "grid.linewidth": 0.7,
    })


def slug(s: str) -> str:
    """Filesystem-safe short token from any label."""
    return re.sub(r"[^A-Za-z0-9]+", "_", str(s)).strip("_")[:40]


def output_path(out_dir: str, name: str) -> str:
    """Timestamped PNG path under out_dir so nothing is overwritten."""
    os.makedirs(out_dir, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return os.path.join(out_dir, f"{slug(name)}_{stamp}.png")


def short_label(s: str) -> str:
    """Trailing segment of a prefixed feature name (e.g. 'clade:s__E_coli' -> 's__E_coli')."""
    return str(s).split(":")[-1]
