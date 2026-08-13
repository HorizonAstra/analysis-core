#!/usr/bin/env python3
"""Does the R rewrite of Ripley's K select the same nodes as the Julia original.

Ripley's K was computed in Julia inside the optimiser, then moved to R and
spatstat for speed. The Julia version still sits in tumorspace_core.jl, commented
out. Two implementations of one statistic is a question nobody had answered: does
the replacement change which nodes the pipeline keeps.

The magnitudes are not the thing to compare. Downstream, the cut is a quantile:

    rip_nodes_pass = filter(row -> row.RipleySum >= quantile(RipleySum, spatial), ...)

so any strictly increasing rescaling of RipleySum leaves the selected set
untouched. What matters is the ordering, and then the selected sets themselves.

    compare.py <julia.tsv> <r.tsv>
"""

from __future__ import annotations

import sys
from pathlib import Path

# The hyperparameter is searched over this grid in the optimiser, so these are
# the cuts that actually occur rather than round numbers chosen here.
QUANTILES = (0.5, 0.6, 0.7, 0.8, 0.9)


def read(path: Path) -> dict:
    rows = {}
    with open(path) as fh:
        header = next(fh).rstrip("\n").split("\t")
        node, val = header.index("Node"), header.index("RipleySum")
        for line in fh:
            f = line.rstrip("\n").split("\t")
            rows[int(f[node])] = float(f[val])
    return rows


def rank(values: list) -> list:
    """Ordinary ranks, ties averaged, so Spearman is the Pearson of these."""
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        shared = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = shared
        i = j + 1
    return ranks


def pearson(a: list, b: list) -> float:
    n = len(a)
    ma, mb = sum(a) / n, sum(b) / n
    num = sum((x - ma) * (y - mb) for x, y in zip(a, b))
    da = sum((x - ma) ** 2 for x in a) ** 0.5
    db = sum((y - mb) ** 2 for y in b) ** 0.5
    return num / (da * db) if da and db else float("nan")


def quantile(values: list, q: float) -> float:
    """Julia's Statistics.quantile default: linear interpolation, same as type 7."""
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    pos = q * (len(s) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (pos - lo) * (s[hi] - s[lo])


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    jl, r = read(Path(sys.argv[1])), read(Path(sys.argv[2]))
    shared = sorted(set(jl) & set(r))

    print(f"nodes: julia {len(jl)}, R {len(r)}, in both {len(shared)}")
    only_jl, only_r = sorted(set(jl) - set(r)), sorted(set(r) - set(jl))
    if only_jl or only_r:
        print(f"  only julia: {len(only_jl)}   only R: {len(only_r)}")
    if not shared:
        print("nothing to compare")
        return 1

    a = [jl[n] for n in shared]
    b = [r[n] for n in shared]

    print(f"\nmagnitude")
    print(f"  julia  min {min(a):.6g}  max {max(a):.6g}")
    print(f"  R      min {min(b):.6g}  max {max(b):.6g}")

    rho = pearson(rank(a), rank(b))
    print(f"\nrank agreement (Spearman): {rho:.6f}")
    print("  1.0 means the two orderings are identical, and every quantile cut")
    print("  below would then select exactly the same nodes.")

    # Whether the orderings are identical has to be decided exactly. Spearman
    # on identical input lands a rounding step short of 1.0, so the count of
    # discordant pairs is the test, and it localises a break better anyway.
    ra, rb = rank(a), rank(b)
    total = len(shared) * (len(shared) - 1) // 2
    if len(shared) <= 6000:
        swaps = sum(1 for i in range(len(shared)) for j in range(i + 1, len(shared))
                    if (ra[i] - ra[j]) * (rb[i] - rb[j]) < 0)
        print(f"  discordant pairs: {swaps} of {total}"
              + (f"  ({100 * swaps / total:.3f}%)" if total else ""))
    else:
        swaps = None
        print(f"  discordant pairs: not counted, {len(shared)} nodes is too many "
              f"for the pairwise sweep")

    print(f"\nselected node sets, at the quantile the optimiser actually cuts on")
    print(f"  {'spatial':>8}  {'julia':>6} {'R':>6} {'both':>6} {'differ':>7}  agreement")
    worst = 1.0
    for q in QUANTILES:
        ta, tb = quantile(a, q), quantile(b, q)
        sa = {n for n in shared if jl[n] >= ta}
        sb = {n for n in shared if r[n] >= tb}
        both = len(sa & sb)
        union = len(sa | sb)
        agree = both / union if union else 1.0
        worst = min(worst, agree)
        print(f"  {q:>8.2f}  {len(sa):>6} {len(sb):>6} {both:>6} "
              f"{union - both:>7}  {100 * agree:.2f}%")

    print()
    if swaps == 0:
        print("VERDICT: the orderings are identical. The rewrite changes the "
              "numbers but not\n         which nodes are kept, at any threshold.")
    elif worst == 1.0:
        print("VERDICT: the orderings differ, but not across any cut the "
              "optimiser uses, so\n         the selected nodes are the same at "
              "every quantile tested.")
    else:
        print(f"VERDICT: the two implementations select different nodes. Worst "
              f"agreement\n         {100 * worst:.2f}%. Results computed before "
              f"and after the rewrite are not\n         comparable, and neither "
              f"is a refactor validated against either one.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
