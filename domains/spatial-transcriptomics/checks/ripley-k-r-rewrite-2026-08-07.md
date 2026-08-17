# Ripley's K: does the R rewrite select the same nodes

Measured on randi, 2026-08-07.

## What was compared

| | |
|---|---|
| Sample | `benchmarks/GSE213688_GSM6592057`, 370 spots |
| Run | `region_finder`, seed 42, candidate SVD 5 (`svd_run_1`) |
| Nodes | 369, present in both outputs |
| Leaf rows | 5,537 |
| R side | `allnodes_ripley.tsv`, produced by `compute_ripley_k.R` during that run |
| Julia side | `tumorspace_core.jl` lines 371-462, extracted and run unmodified |

Both implementations read the same `allnodes_leaves.tsv`. The Julia code takes
its coordinates from columns 9 and 10 by position and R takes `pxl_row_in_mm`
and `pxl_col_in_mm` by name; in this file those are the same two columns, so the
comparison is of the two calculations and not of two different inputs.

## Result

```
magnitude
  julia  min 1.26183     max 4704.28
  R      min 0.0522121   max 4704.28

rank agreement (Spearman): 0.993515
  discordant pairs: 1332 of 67896  (1.962%)

selected node sets, at the quantile the optimiser cuts on
   spatial   julia      R   both  differ  agreement
      0.50     185    185    183       4    97.86%
      0.60     148    148    147       2    98.66%
      0.70     111    111    108       6    94.74%
      0.80      76     74     74       2    97.37%
      0.90      46     46     45       2    95.74%
```

## Reading it

**The two do not agree.** Rank correlation of 0.9935 sounds like agreement, and
that is the trap: the pipeline does not consume the ranking, it consumes a cut
through the ranking. At the thresholds the optimiser actually searches over,
between 1.3% and 5.3% of the selected nodes differ. Every spatial group that
survives filtering is carried into the pair construction and from there into
everything downstream, so a node that appears on one side and not the other is
not a rounding difference.

The row at `spatial = 0.80` is worth noticing separately: the two select
different *counts*, 76 against 74. A quantile cut returns a fixed fraction unless
values are tied at the boundary, so the tie structure differs too.

The largest value matches to six figures in both. That is the expected signature
of two implementations of the same statistic diverging on discretisation rather
than on definition: the node whose extent fills the window is insensitive to
where the radii are placed, and the small, tightly clumped nodes are not.

## Why they differ

Both sum `|K_border(r) - πr²|`. The disagreement is in what is summed over.

- The Julia version fixes `rmax = min(x_length/4, y_length/4, sqrt(1000/(πλ)))`
  and evaluates 513 evenly spaced radii. The R version uses whatever radii
  `spatstat::Kest` picks by default. Different grids, differing per node in
  different ways, so the sums are not on a common scale, which the minima show:
  1.26 against 0.052.
- The Julia version approximates the distance from a point to the window edge by
  its distance to 40 points sampled along the perimeter, 10 per side. `spatstat`
  computes the exact distance. The approximation can only overestimate, so points
  stay eligible at radii where the exact calculation would have dropped them.

Neither is wrong. They are two different discretisations, and the repository
never claimed they matched: the note in `spatial_optimize.jl` justifies the move
on speed alone.

## Consequence

Results produced before this rewrite and results produced after it are two
populations, not one. Any refactor validated by comparing its output against an
older stored run is validating against the wrong thing, and so is any figure that
pools runs from both sides of the change.

This compounds with what the baselines already measured. Two unseeded runs of
unmodified `differential_abundance` code agree on 93.4% of significance calls.
Node selection agreement sits at 94.7% in the worst case here. Neither number is
alarming on its own; together they mean a comparison against historical output
cannot distinguish a refactor that broke something from one that did not.

The practical rule this leaves: validate against a seeded baseline recorded with
the current code, never against a stored production result.

## Reproducing

```sh
sbatch ripley_check.sbatch <a svd_run_N directory from a region_finder run>
```

or directly:

```sh
julia --project=workflows/tumorspace_core/julia \
    contracts/checks/ripley/run_julia.jl <run>/allnodes_leaves.tsv julia_ripley.tsv
python3 contracts/checks/ripley/compare.py julia_ripley.tsv <run>/allnodes_ripley.tsv
```

## Not yet answered

Whether the disagreement grows with sample size. This was one sample at 370
spots, which is small; the rewrite was made because the Julia version did not
scale, so the cases that motivated it are exactly the ones not measured here.
