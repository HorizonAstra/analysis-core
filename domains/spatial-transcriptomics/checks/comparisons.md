# Checks

A contract's `verify` answers whether the frozen computation has moved, by
comparing digests. A baseline answers whether a run reproduces, by comparing
outputs. Neither answers a third kind of question: whether two pieces of code
that are both in the repository, and are meant to compute the same thing,
actually agree.

That question comes up wherever something was rewritten. A rewrite is usually
justified on speed, and speed is easy to measure, so it gets measured. Whether
the numbers survived the move usually does not, because checking it means
running the retired version, which nobody wants to reinstate.

These checks run the retired version without reinstating it. Each one copies the
old code out of wherever it is parked, runs both, and compares. Production files
are never edited; every extraction records the file and line range it came from,
so the copy can be re-derived and confirmed.

The same folder holds one other kind of check, for the question a digest cannot
answer either: whether an artifact that was stored as a reference still
reproduces today. That is not about two implementations, it is about one
implementation and the passage of time, but it belongs here for the same reason —
it is a claim the repository makes implicitly and had never been tested.

## ripley

Ripley's K decides which nodes survive spatial filtering. It was computed in
Julia inside the optimiser, then moved to R and `spatstat` for speed. The Julia
version is still in `tumorspace_core.jl`, commented out, under a header that
says why it was retired.

The two are not the same calculation. Both sum `|K_border(r) - πr²|` over a range
of `r`, and both use the whole tissue as the observation window, but:

- The Julia version fixes `rmax = min(x_length/4, y_length/4, sqrt(1000/(πλ)))`
  and evaluates 513 evenly spaced radii. The R version takes whatever radii
  `spatstat::Kest` chooses by default. The sums are therefore over different
  grids, and the grids differ per node in different ways.
- The Julia version approximates distance-to-boundary by the distance to 40
  points sampled along the window edge, 10 per side. `spatstat` computes the
  exact distance to the edge. The approximation can only overestimate, which
  keeps points eligible at radii where the exact version would drop them.

So the two produce different numbers, and nothing in the repository claims
otherwise. What matters is narrower than that. The threshold applied downstream
is a quantile of the observed distribution:

```julia
rip_nodes_pass = filter(row -> row.RipleySum >= quantile(rip_nodes_pass.RipleySum, spatial), ...)
```

Any strictly increasing rescaling of `RipleySum` leaves that selection
untouched. The rewrite only changes results if it changes the **ordering** of
nodes. `compare.py` measures that directly, and then measures the thing that
actually propagates: the selected node sets at each quantile the optimiser cuts
on.

### Running it

Needs `allnodes_leaves.tsv` and `allnodes_ripley.tsv` from one `region_finder`
run, which are the input and the output of the R step.

```
julia --project=workflows/tumorspace_core/julia \
    contracts/checks/ripley/run_julia.jl <allnodes_leaves.tsv> julia_ripley.tsv
python3 contracts/checks/ripley/compare.py julia_ripley.tsv <allnodes_ripley.tsv>
```

### Result

They do not agree. Measured 2026-08-07 on the benchmark sample, 369 nodes:
rank correlation 0.9935, and at the thresholds the optimiser searches over,
between 1.3% and 5.3% of the selected nodes differ. Full numbers and the reason
for the divergence are in `ripley/result-2026-08-07.md`.

So results produced before the rewrite and results produced after it are two
different populations. Any refactor validated by comparison against an older
stored run is validating against the wrong thing, and so is any figure that pools
runs from both sides of the change. Validate against a seeded baseline recorded
with the current code instead.

That is what an hour of compute bought, against a question that had otherwise
been carried as an assumption.

## environment

Whether the container images have drifted since the reference outputs in
`benchmarks/` were stored. They have not: a BayesSpace run in `--test` mode, which
fixes its seeds, still md5s identically to the file committed on 2 July.

That result does double duty. It confirms the CRAN `latest` defect has not yet
cost anything, since the images themselves are intact and only a rebuild would
have exposed it. And it isolates why a seeded `region_finder` run does not match
its stored reference from the same day: the environment is unchanged and the
kernels hash identically, so what remains is that the stored file came from an
unseeded run and matches nothing. `environment/result-2026-08-07.md`.
