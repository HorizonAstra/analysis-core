# Characterization baselines

`verify` proves the **inputs** to a computation are unchanged: the kernel files
and every pinned dependency. It says nothing about the **outputs**. Those are two
different claims, and only the second settles whether a refactor was safe.

A baseline closes that gap. It records the output digests of a seeded run against
fixed input, so a later run can be compared byte for byte.

## Why it has to be seeded

Three stages of this pipeline draw random numbers, and production runs do not
pass a seed. Measured on randi, 2026-08-07, with `differential_abundance` on one
sample, using identical input files:

| Run | Significant calls |
|---|---|
| seed 42, first run | 25,734 |
| seed 42, second run | 25,734 — **byte identical output** |
| no seed, first run | 26,304 |
| no seed, second run | 25,526 |

The two unseeded runs agree on 25,033 calls. 1,271 appear only in the first and
493 only in the second, so they agree on **93.4%** of the union and disagree on
1,764 significance calls.

That is not drift at the last decimal place. Roughly one call in fifteen flips
between two runs of unmodified code on identical input.

The consequence for any refactor: **comparing against a previous production run
proves nothing**, because two production runs of the untouched code do not match
each other either. Seeded comparison is the only sound test.

## Files

One JSON per baseline, named `<capability>-<site>-<inputs>-<date>.json`,
recording the contract version, kernel digests, image digests, parameters
including the seed, every input by content hash, and every output by content
hash.

The `<inputs>` field is a short hash over the inputs and parameters the run was
given. It is in the name because a baseline is a claim about one computation on
one set of inputs, so the same capability on a second sample is a second
legitimate baseline rather than a duplicate. `--check` compares against the
baseline whose inputs match the run in hand, and refuses rather than comparing
across samples: doing that would report every output as changed and mean
nothing.

### Outputs that stamp themselves

`region_finder` writes the wall clock time into the header of `optimal_svd.txt`.
That one line makes the file different on every run, which would fail every
comparison for a cosmetic reason, and a check that always fails is one people
learn to ignore. A contract can therefore declare `volatile` patterns on an
output, and the digest is taken over the file with those lines removed. The
manifest records exactly which patterns were applied, so a filtered digest is
never unexplainable, and the patterns have to be written one at a time: a
blanket rule that skipped anything resembling a date would eventually skip a
result.

## Using one

```sh
python3 bin/baseline.py --record <outdir>   # keep this run as the reference
python3 bin/baseline.py --check  <outdir>   # hold a later run against it
```

Both read the `run_manifest.json` that `run.py` leaves in the output directory,
so nothing is kept in step by hand. `--check` compares inputs and parameters
first, because a difference in the outputs says nothing about the code if the two
runs were not given the same thing. `--record` refuses a run that drew from the
RNG without a seed: a baseline nothing can match is worse than none, since the
failure it guarantees later will look like a regression.

## Status

Every capability at levels 1 to 3 has a recorded baseline on randi, and all seven
have been run against the benchmark sample through the contract layer.

| Capability | Level | Baselines | Seed |
|---|---|---|---|
| `region_finder` | 1 | benchmark | required, and see below |
| `bayesspace` | 1 | benchmark | required, through the R profile |
| `spacet` | 1 | benchmark | none needed |
| `differential_abundance` | 2 | benchmark, one other sample | required |
| `growchain` | 2 | benchmark, one other sample | none needed |
| `de_analysis` | 2 | benchmark | none needed |
| `slab` | 3 | benchmark, one other sample | none needed |

The whole dependency chain has been run end to end on the benchmark in the order
the contracts imply: `region_finder`, then `growchain` and
`differential_abundance` from its outputs, then `slab` from both. Separately,
`bayesspace` then `de_analysis` from its clusters.

`growchain`, `slab`, `spacet` and `de_analysis` need no seed. Independent runs of
each produced identical output with nothing set, which is measured rather than
assumed: `spacet` and `de_analysis` were each run twice and checked.

## What recording these baselines actually caught

The point of a baseline is to fail when something is wrong, and the first one
recorded for `region_finder` did exactly that, against the code that produced it.

Two runs at seed 42 did not match. Four of six outputs differed. Diffing the two
stage trees artifact by artifact put the first divergence at `Tree_support.nw`,
which is upstream of everything that differed and downstream of everything that
matched. The cause was that `--seed` reached only one of the two stages that draw
random numbers: `spatial_optimize.jl` reads `TUMORSPACE_FIXED_SEED`,
`phylo_tree_build.jl` does not read it at all and seeds itself only under
`--test-seed`.

Both stages printed that they were using seed 42. The logs looked correct and the
run was not reproducible, which is the argument for comparing outputs rather than
trusting that a seed was plumbed.

The adapter now passes `--test-seed`, only when a seed was given. The remaining
limitation is recorded in the contract: the seed that flag derives comes from the
task indices rather than from the value, so `--seed 42` and `--seed 43` build the
same trees. Reproducibility, not seed control.

## BayesSpace was not the blocker it looked like

This file previously said `bayesspace` could not have a baseline until the script
was changed, because it exposes fixed seeds only through its test mode. That was
wrong, and the reason is worth keeping.

An ordinary run picks its own two seeds with `sample(10000000, 1)`. Those draws
come from R's global generator, and the script is launched with `Rscript` without
`--vanilla`, so R sources a user profile before the script runs. A profile
containing `set.seed()` therefore fixes the state that the script's own seed
draws come from, and everything downstream follows. The adapter writes that
profile and points `R_PROFILE_USER` at it. The kernel is untouched.

Measured on randi, 2026-08-07, on the benchmark sample:

| Run | `clusters` digest |
|---|---|
| seed 42 | `8cf99583721a71c1` |
| seed 42, again | `8cf99583721a71c1` — byte identical |
| seed 43 | `9b908dd3ed4f602b` |
| no seed | `515edc2808de595d` |

The third row is the one that matters. Without it, two matching runs would only
show that setting the variable stabilised something; the different seed giving a
different result is what shows the seed is what the output depends on.

So every capability at levels 1 to 3 can now be run reproducibly, and the only
ones still without a baseline are `region_finder`, `spacet` and `de_analysis`.
