# Does a stored reference output still reproduce

Measured on randi, 2026-08-07.

## The question

`build_r_container.sh` resolved CRAN against `latest` rather than a dated
snapshot, so the recipe could not rebuild the image it produced. That is a real
defect and it is fixed going forward. But it raises a separate question about the
past: have the images that already exist stayed put, or has the drift already
happened and quietly invalidated everything computed before it.

Reasoning cannot answer that. A stored reference output can.

## The measurement

`benchmarks/GSE213688_GSM6592057/expected_outputs/test_coldata_single.csv` was
committed on 2 July. It is the output of BayesSpace in its `--test` mode, which
sets seed1 to 42 and seed2 to 123 rather than drawing them, and it exists to be
md5-checked. So it is one of the few artifacts in this repository that is
supposed to be reproducible.

I ran the same script, in the same mode, on the same sample, in the current
image.

```
reference (2 July):  98debcd677faafed306c8a57ae9b0ec8
now:                 98debcd677faafed306c8a57ae9b0ec8
```

Identical.

## What this establishes

The environment has not drifted. Combined with the two facts already checked, the
picture is now closed rather than assumed:

| Claim | How it was established |
|---|---|
| The kernels have not changed | All 13 files hash identically to the reference checkout |
| The environment has not changed | This measurement |
| The container is what executes | Image digests recorded in every contract and manifest |

So the recipe defect is real but has not yet cost anything. Nothing computed
against these images is stranded, because the images are intact. The dated
snapshot protects the next rebuild, which is when the exposure would have become
a loss.

## Why this mattered for something else

A seeded `region_finder` run through the contract layer does not match
`expected_outputs/OptimalTree_pruned_node_compare_list.txt`, which was stored the
same day. Same file size, same number of spatial groups, same first rows,
different node identities further down.

There were three possible explanations: the contract layer changed something, the
environment moved, or the stored reference was produced by an unseeded run and
therefore matches nothing. This measurement eliminates the second, and the kernel
hashes eliminate the first, which leaves the third.

That is consistent with everything else measured here. The stored region finder
reference cannot be reproduced by anything, including a re-run of the untouched
code by its own author, because the hyperparameter search draws without a seed.
It is a record of one draw, not a reference.

The contrast with the BayesSpace file is the whole argument in one repository:
the artifact produced in a mode that fixes its seeds still reproduces four weeks
later, and the artifact produced by an ordinary run never could.

## Reproducing

```sh
sbatch bs_testmode.sbatch
```

Runs `run_bayesspace.R --test` in the current image and md5s the result against
the committed reference.
