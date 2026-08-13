"""Visualization facade: a general, reusable charting library.

The pieces:
    style.py    research-grade theme, palette, slug/path helpers
    charts.py   chart primitives by type (bar, scatter, line, histogram, box,
                heatmap, forest) — each draws on an Axes you pass in
    compose.py  combine panels into one PNG (compose / render / panel)

Nothing here is tied to a specific analysis: build a volcano from `scatter` with
reference lines, a KM plot from `line(step=True)`, a coefficient plot from `bar`, a
Cox forest from `forest`, and lay several of them out in one figure with `compose`.

Import this facade (`from analysis.visualization import plotting`) for everything, or
the individual modules directly.
"""

from __future__ import annotations

from .charts import bar, box, forest, heatmap, histogram, line, scatter
from .compose import compose, panel, render
from .style import (
    ACCENT,
    ACCENT_ALT,
    HIGHLIGHT,
    MUTED,
    NEGATIVE,
    PALETTE,
    POSITIVE,
    output_path,
    short_label,
    slug,
    use_style,
)

__all__ = [
    # chart primitives
    "bar", "scatter", "line", "histogram", "box", "heatmap", "forest",
    # composition
    "compose", "render", "panel",
    # style helpers
    "use_style", "slug", "output_path", "short_label",
    "PALETTE", "ACCENT", "ACCENT_ALT", "POSITIVE", "NEGATIVE", "HIGHLIGHT", "MUTED",
]
