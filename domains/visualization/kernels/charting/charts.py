"""General chart primitives, named by chart type, not by analysis.

Every function draws onto a matplotlib Axes you pass in and returns that Axes, so
the same chart works standalone (via render) or as one panel of a composed figure
(via compose). None of them know anything about a specific analysis — feed them
x/y/values/matrices and they draw. Build a volcano from `scatter` with reference
lines, a Kaplan-Meier from `line(step=True)`, a coefficient plot from `bar`, a Cox
forest from `forest`, and so on.
"""

from __future__ import annotations

from typing import Any, Mapping, Sequence

from .style import ACCENT, HIGHLIGHT, MUTED, NEGATIVE, PALETTE, POSITIVE, np, pd, plt, sns


def _finish(ax, title, xlabel, ylabel):
    if title:
        ax.set_title(title)
    if xlabel is not None:
        ax.set_xlabel(xlabel)
    if ylabel is not None:
        ax.set_ylabel(ylabel)
    return ax


def _hue_colors(hue: Sequence, palette: str) -> tuple[list, dict]:
    levels = list(dict.fromkeys(str(h) for h in hue))
    colors = sns.color_palette(palette, n_colors=max(len(levels), 1))
    mapping = {lv: colors[i % len(colors)] for i, lv in enumerate(levels)}
    return levels, mapping


def bar(ax, categories: Sequence[str], values: Sequence[float], *, orientation: str = "vertical",
        color: Any = ACCENT, colors: Sequence | None = None, errors: Sequence | None = None,
        annotate: Sequence[str] | None = None, baseline: float | None = None,
        title: str | None = None, xlabel: str | None = None, ylabel: str | None = None):
    """Bar chart (vertical or horizontal). Per-bar `colors` override the single
    `color`. `baseline` draws a reference line at a value (e.g. 0 for effect sizes);
    `annotate` writes a label next to each bar (e.g. significance stars). Bars are
    drawn without edges."""
    cats = list(categories)
    vals = list(values)
    bar_colors = list(colors) if colors is not None else color
    if orientation == "horizontal":
        ax.barh(cats, vals, color=bar_colors, edgecolor="none",
                xerr=errors, error_kw={"elinewidth": 0.8, "ecolor": "#666"})
        if baseline is not None:
            ax.axvline(baseline, color="#888", linewidth=1)
        if annotate:
            for i, txt in enumerate(annotate):
                if txt:
                    ax.text(vals[i], i, f" {txt}", va="center",
                            ha="left" if vals[i] >= 0 else "right")
    else:
        ax.bar(cats, vals, color=bar_colors, edgecolor="none",
               yerr=errors, error_kw={"elinewidth": 0.8, "ecolor": "#666"})
        if baseline is not None:
            ax.axhline(baseline, color="#888", linewidth=1)
        if annotate:
            for i, txt in enumerate(annotate):
                if txt:
                    ax.text(i, vals[i], f"{txt}", ha="center",
                            va="bottom" if vals[i] >= 0 else "top")
        ax.tick_params(axis="x", rotation=45)
    return _finish(ax, title, xlabel, ylabel)


def scatter(ax, x: Sequence[float], y: Sequence[float], *, hue: Sequence | None = None,
            palette: str = PALETTE, color: Any = ACCENT, size: float = 42,
            point_labels: Mapping[int, str] | None = None, hlines: Sequence[float] | None = None,
            vlines: Sequence[float] | None = None, legend_title: str | None = None,
            title: str | None = None, xlabel: str | None = None, ylabel: str | None = None):
    """Scatter plot. `hue` colours points by a categorical label (with a legend).
    `hlines`/`vlines` draw reference lines — pass a threshold to turn this into a
    volcano. `point_labels` maps point indices to text annotations (e.g. top hits)."""
    x = np.asarray(x, dtype=float)
    y = np.asarray(y, dtype=float)
    if hue is not None:
        levels, mapping = _hue_colors(hue, palette)
        for lv in levels:
            m = np.array([str(h) == lv for h in hue])
            ax.scatter(x[m], y[m], s=size, color=mapping[lv], edgecolor="white", linewidth=0.5, alpha=0.9, label=lv)
        ax.legend(title=legend_title, fontsize=8)
    else:
        ax.scatter(x, y, s=size, color=color, edgecolor="white", linewidth=0.5, alpha=0.9)
    for h in (hlines or []):
        ax.axhline(h, color="#888", linestyle="--", linewidth=1)
    for vline in (vlines or []):
        ax.axvline(vline, color="#bbb", linewidth=1)
    for i, txt in (point_labels or {}).items():
        ax.annotate(txt, (x[i], y[i]), fontsize=8, xytext=(4, 3), textcoords="offset points", color="#333")
    return _finish(ax, title, xlabel, ylabel)


def line(ax, series: Sequence[tuple], *, palette: str = PALETTE, step: bool = False,
         bands: Mapping[str, tuple] | None = None, legend_title: str | None = None,
         title: str | None = None, xlabel: str | None = None, ylabel: str | None = None):
    """Line chart. `series` is a list of (label, x, y) triples. `step=True` draws
    step curves (Kaplan-Meier). `bands` maps a series label to (lower, upper) arrays
    drawn as a shaded confidence band."""
    levels = [str(s[0]) for s in series]
    colors = sns.color_palette(palette, n_colors=max(len(levels), 1))
    drawstyle = "steps-post" if step else "default"
    for i, (label, xs, ys) in enumerate(series):
        c = colors[i % len(colors)]
        ax.plot(xs, ys, label=str(label), color=c, linewidth=1.6, drawstyle=drawstyle)
        if bands and str(label) in bands:
            lo, hi = bands[str(label)]
            ax.fill_between(xs, lo, hi, color=c, alpha=0.15, step="post" if step else None, linewidth=0)
    if len(series) > 1 or any(s[0] for s in series):
        ax.legend(title=legend_title, fontsize=8)
    return _finish(ax, title, xlabel, ylabel)


def histogram(ax, values: Sequence[float], *, groups: Sequence | None = None, bins: int = 30,
              palette: str = PALETTE, color: Any = ACCENT, title: str | None = None,
              xlabel: str | None = None, ylabel: str | None = "count"):
    """Histogram. With `groups` (a categorical label per value) it overlays a
    translucent histogram per group."""
    if groups is not None:
        df = pd.DataFrame({"value": np.asarray(values, dtype=float), "group": [str(g) for g in groups]})
        sns.histplot(data=df, x="value", hue="group", bins=bins, palette=palette,
                     edgecolor="white", alpha=0.6, ax=ax)
    else:
        ax.hist(np.asarray(values, dtype=float), bins=bins, color=color, edgecolor="white", alpha=0.85)
    return _finish(ax, title, xlabel, ylabel)


def box(ax, data: Mapping[str, Sequence[float]], *, palette: str = PALETTE, points: bool = True,
        title: str | None = None, xlabel: str | None = None, ylabel: str | None = None):
    """Box plot from a {group: values} mapping. With `points`, overlays the raw
    points as a light jittered strip."""
    order = list(data.keys())
    long = pd.DataFrame(
        [{"group": str(g), "value": float(v)} for g, vals in data.items() for v in vals if pd.notna(v)]
    )
    sns.boxplot(data=long, x="group", y="value", order=[str(o) for o in order], hue="group",
                legend=False, palette=palette, linewidth=1.1, fliersize=0, ax=ax)
    if points:
        sns.stripplot(data=long, x="group", y="value", order=[str(o) for o in order],
                      color="#333", size=3, alpha=0.45, jitter=0.2, ax=ax)
    return _finish(ax, title, xlabel, ylabel)


def _label_budget(ax, axis: str, fontsize: float) -> int:
    """How many tick labels fit along an axis without overlapping.

    Measured from the axes' own size rather than assumed, so the same call behaves
    correctly in a small panel of a composed figure and in a full-page figure. Row labels
    need about 1.6 line-heights each; column labels are rotated upright, so they are also
    bounded by height rather than by the length of the text.
    """
    fig = ax.figure
    w_in, h_in = fig.get_size_inches()
    pos = ax.get_position()
    span_pt = (w_in * pos.width if axis == "x" else h_in * pos.height) * 72.0
    return max(0, int(span_pt // (fontsize * 1.6)))


def heatmap(ax, matrix, *, row_labels: Sequence[str] | None = None, col_labels: Sequence[str] | None = None,
            cmap: str = "Spectral", center: float | None = 0.0, vmin: float | None = None,
            vmax: float | None = None, annot: bool = False, cbar: bool = True,
            cbar_label: str | None = None, square: bool = False, title: str | None = None,
            labels: str | bool = "auto", max_labels: int | None = None,
            grid: str | bool = "auto", fontsize: float = 8.0):
    """Heatmap of a 2-D matrix (array or DataFrame). Spectral, centered at 0 by
    default — pass center=None for sequential data.

    Scales from a handful of cells to a few thousand a side. The whole grid is drawn as
    one image rather than one artist per cell, so a 1500 x 1500 matrix renders as fast as
    a small one and stays a picture of the overall structure, which is often the point of
    looking at it at that size.

    Labels are thinned to what physically fits: every k-th name, or none at all when even
    that would overlap. `labels` forces the decision — True always labels every row and
    column (readable only when the matrix is small), False never labels. `max_labels` caps
    it further. Cell gridlines and annotation follow the same rule, since both stop being
    legible long before the image does; `grid` and `annot` override.
    """
    data = matrix.values if isinstance(matrix, pd.DataFrame) else np.asarray(matrix, dtype=float)
    data = np.asarray(data, dtype=float)
    if row_labels is None and isinstance(matrix, pd.DataFrame):
        row_labels = [str(i) for i in matrix.index]
    if col_labels is None and isinstance(matrix, pd.DataFrame):
        col_labels = [str(c) for c in matrix.columns]
    n_rows, n_cols = data.shape

    # colour limits: symmetric about `center` unless given explicitly, so a diverging map
    # actually diverges around the value it is supposed to
    if vmin is None or vmax is None:
        finite = data[np.isfinite(data)]
        lo = float(finite.min()) if finite.size else 0.0
        hi = float(finite.max()) if finite.size else 1.0
        if center is not None:
            reach = max(abs(hi - center), abs(center - lo)) or 1.0
            lo, hi = center - reach, center + reach
        vmin = lo if vmin is None else vmin
        vmax = hi if vmax is None else vmax

    im = ax.imshow(data, cmap=cmap, vmin=vmin, vmax=vmax, aspect="equal" if square else "auto",
                   interpolation="nearest", origin="upper")
    im.cmap.set_bad(color="#f2f0ec")          # missing cells read as absent, not as zero

    def ticks(names, n, axis):
        if labels is False or not names:
            return [], []
        budget = n if labels is True else _label_budget(ax, axis, fontsize)
        if max_labels is not None:
            budget = min(budget, max_labels)
        if budget < 1:
            return [], []
        step = max(1, int(np.ceil(n / budget)))
        idx = list(range(0, n, step))
        return idx, [str(names[i]) for i in idx]

    xt, xl = ticks(col_labels, n_cols, "x")
    yt, yl = ticks(row_labels, n_rows, "y")
    ax.set_xticks(xt); ax.set_xticklabels(xl, rotation=90, fontsize=fontsize)
    ax.set_yticks(yt); ax.set_yticklabels(yl, fontsize=fontsize)
    if not xt and not yt and (row_labels or col_labels):
        ax.set_xlabel(f"{n_cols} columns"); ax.set_ylabel(f"{n_rows} rows")

    # gridlines only while a cell is still big enough to have an edge
    show_grid = grid is True or (grid == "auto" and n_rows * n_cols <= 2500)
    if show_grid:
        ax.set_xticks(np.arange(-0.5, n_cols, 1), minor=True)
        ax.set_yticks(np.arange(-0.5, n_rows, 1), minor=True)
        ax.grid(which="minor", color="white", linewidth=0.4)
        ax.tick_params(which="minor", length=0)

    if annot and n_rows * n_cols <= 400:
        mid = (vmin + vmax) / 2.0
        for i in range(n_rows):
            for j in range(n_cols):
                v = data[i, j]
                if np.isfinite(v):
                    ax.text(j, i, f"{v:.2f}", ha="center", va="center", fontsize=fontsize - 1,
                            color="#1f1d1b" if abs(v - mid) < (vmax - vmin) * 0.3 else "white")

    if cbar:
        cb = ax.figure.colorbar(im, ax=ax, shrink=0.7)
        if cbar_label:
            cb.set_label(cbar_label)
    if title:
        ax.set_title(title)
    return ax


def forest(ax, labels: Sequence[str], estimate: Sequence[float], lower: Sequence[float],
           upper: Sequence[float], *, ref: float | str | None = "auto", log_x: bool = False,
           color: Any = HIGHLIGHT, title: str | None = None, xlabel: str | None = None):
    """Forest plot of point estimates with confidence intervals.

    labels / estimate / lower / upper are parallel sequences, one entry per row.

    `ref` draws the null reference line, and "auto" places it where the scale implies:
    1 when log_x is set, since a log axis means the estimates are ratios and the null is
    1; 0 otherwise, since a linear axis means they are differences or coefficients and
    the null is 0. It used to default to 1 outright, which drew the null line in the
    wrong place for every coefficient plot — and a reference line in the wrong place does
    not look broken, it looks like a result. Pass a number to place it yourself, or None
    for no line.
    """
    if ref == "auto":
        ref = 1.0 if log_x else 0.0
    est = np.asarray(estimate, dtype=float)
    lo = np.asarray(lower, dtype=float)
    hi = np.asarray(upper, dtype=float)
    ypos = np.arange(len(labels))[::-1]
    ax.errorbar(est, ypos, xerr=[est - lo, hi - est], fmt="o", color=color,
                ecolor="#888", elinewidth=1.2, capsize=3, markersize=6)
    ax.set_yticks(ypos)
    ax.set_yticklabels([str(label_text) for label_text in labels])
    if ref is not None:
        ax.axvline(ref, color="#888", linestyle="--", linewidth=1)
    if log_x:
        ax.set_xscale("log")
    return _finish(ax, title, xlabel, None)
