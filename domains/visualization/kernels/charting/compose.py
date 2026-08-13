"""Compose one or many charts into a single static PNG.

A *panel* is any callable that takes a matplotlib Axes and draws on it — typically a
chart primitive bound to its data via `panel(...)`. `compose` lays panels out (in a
grid or a named mosaic, so the caller controls placement and relative size) and saves
one figure; `render` is the single-panel convenience. The caller decides figure size,
layout, titles, and per-chart formatting, so a model can assemble an arbitrary
multi-chart figure without any analysis-specific plotting code.
"""

from __future__ import annotations

from typing import Callable, Mapping, Sequence

from .style import np, output_path, plt, use_style

Panel = Callable[[object], object]


def panel(chart_fn: Callable, *args, **kwargs) -> Panel:
    """Bind a chart function to its data/style, returning a panel (a callable of one
    Axes). e.g. panel(charts.bar, categories, values, title='...')."""
    def _draw(ax):
        return chart_fn(ax, *args, **kwargs)
    return _draw


def compose(
    panels: Mapping[str, Panel] | Sequence[Panel],
    layout=None,
    *,
    out_dir: str,
    name: str = "figure",
    figsize: tuple[float, float] = (11, 8),
    suptitle: str | None = None,
    dpi: int | None = None,
) -> str:
    """Render several panels into one PNG and return its path.

    panels + layout forms:
      - dict {key: panel} with a mosaic `layout` (a list of rows of keys, or the
        subplot_mosaic string form). A key spanning multiple cells gets a bigger
        panel — this is how the caller controls relative size and placement.
      - list [panel, ...] with `layout=(nrows, ncols)` (defaults to one row).
    """
    use_style()
    if isinstance(panels, Mapping):
        if layout is None:
            raise ValueError("a mosaic layout is required when panels is a dict")
        fig, axd = plt.subplot_mosaic(layout, figsize=figsize)
        for key, draw in panels.items():
            draw(axd[key])
    else:
        panels = list(panels)
        nrows, ncols = layout or (1, len(panels))
        fig, axes = plt.subplots(nrows, ncols, figsize=figsize, squeeze=False)
        flat = axes.ravel()
        for i, draw in enumerate(panels):
            draw(flat[i])
        for j in range(len(panels), len(flat)):
            flat[j].axis("off")

    if suptitle:
        fig.suptitle(suptitle, fontsize=15, weight="bold")
    fig.tight_layout()
    path = output_path(out_dir, name)
    fig.savefig(path, dpi=dpi) if dpi else fig.savefig(path)
    plt.close(fig)
    return path


def render(chart: Panel, *, out_dir: str, name: str = "chart",
           figsize: tuple[float, float] = (7, 5), dpi: int | None = None) -> str:
    """Render a single panel to a PNG. Convenience wrapper over compose."""
    return compose([chart], (1, 1), out_dir=out_dir, name=name, figsize=figsize, dpi=dpi)
