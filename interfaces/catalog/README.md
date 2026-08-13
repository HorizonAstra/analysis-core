# Capability contracts

A contract declares one analysis capability as data: what it needs, what it returns,
what knobs it has, what machine it wants, and whether it is reproducible.

Every interface asks those same questions in different syntax. Answering once, as
data, means a new interface is a mechanical translation that never touches the
computation.

```
capability   the computation, unchanged
   |
contract     this folder: a JSON declaration of it
   |
bindings     CLI, MCP tool, Nextflow process, HTTP, library import
```

## Why not just adopt a workflow engine

Adopting one makes it the abstraction, which trades one lock-in for another. A
contract can *emit* a Nextflow process, and equally a plain shell invocation or a
tool definition for a platform that has never heard of Nextflow.

## Layout

```
schema.json              JSON Schema for a contract
capabilities/*.json      one file per capability
profiles/*.json          how to launch on a given host
bin/_contract.py         shared resolution and digest checking
bin/render.py            contract -> interface
bin/run.py               contract -> an actual run
bin/graph.py             contracts -> the order they run in
bin/status.py            where every capability stands
bin/baseline.py          record a seeded run, or hold a later one against it
extracted/               code copied out of somewhere it could not be called
baselines/               output digests of seeded runs, to compare against
checks/                  do two implementations of one thing agree
```

Four layers, each answering one question and none knowing the others' business:

| Layer | Answers |
|---|---|
| Kernel, in `workflows/` | Does the mathematics. Never edited |
| Contract, in `capabilities/` | *What* a capability needs and returns |
| Profile, in `profiles/` | *How* to launch it on this machine |
| Tools, in `bin/` | Combine those into an interface or a run |

A new capability is a new contract, a new machine is a new profile, and a new
interface is a new function. Those multiply rather than add, and none of them can
reach the mathematics.

## Rendering an interface

```sh
python3 bin/render.py capabilities/growchain.json --as cli
python3 bin/render.py capabilities/growchain.json --as mcp
python3 bin/render.py capabilities/growchain.json --as openapi
python3 bin/render.py capabilities/growchain.json --as nextflow
python3 bin/render.py capabilities/growchain.json --as slurm --profile randi
python3 bin/render.py randi                       --as nextflow-config
python3 bin/render.py capabilities/growchain.json --as verify
```

The last three of the interface targets are the executor axis: Nextflow, a
scheduler, or a person at a shell. All of them read the same contract and the
same profile, so a machine is described once no matter what ends up driving it.
The resource numbers live in the profile, keyed by what a contract says bounds
it, which is why `--as slurm` and `--as nextflow-config` cannot disagree about
how much memory a capability gets.

`--as verify` is the freeze check, and it asks three independent questions.

The zeroth is whether the contract is still shaped like a contract, by validating
it against `schema.json`. That schema existed from the beginning and nothing ever
ran it, so it had quietly drifted out of agreement with the files it describes:
fields in daily use were not permitted by it, and a nullable one was declared as
a string. A description nothing checks is a comment. Running it here is what
keeps it a specification, and it caught a meaningless field the first time it
ran. Where `jsonschema` is not installed the check reports itself skipped rather
than failing.

The first is whether the mathematics moved: it hashes every file the contract
lists as kernel, compares against the recorded digest, and fails on any third
party package left unpinned.

The second is whether every `{placeholder}` in a template will actually be
substituted. An input's name is not a placeholder, so a template writing
`{ref_dir}` for an input called `ref_dir` passes that text to the kernel
verbatim, which then opens a path that does not exist.

The third is whether the contract still calls those kernels the way they ask to
be called. Most kernels here open by counting their arguments and aborting if the
count is wrong, which is a machine readable statement of the calling convention
written by whoever wrote the kernel. Holding the templates against it catches an
adapter mistake at the terminal instead of forty minutes into a cluster job.
`run.py` runs the same check before it submits anything.

Exit status is non-zero if any of them fails, which makes it usable in CI.

## Running a capability

`run.py` is the adapter. The Julia kernels read fixed filenames out of one
directory instead of taking arguments, so something has to assemble that
directory; the contract records the mapping and this performs it. The kernel is
invoked unchanged.

```sh
python3 bin/run.py capabilities/differential_abundance.json \
    --sg_pairs        path/to/OptimalTree_pruned_node_compare_list.txt \
    --sg_pair_members path/to/OptimalTree_pruned_node_compare_leaves.txt \
    --matrix          path/to/M.txt \
    --observations    path/to/barcodes.txt \
    --features        path/to/features.txt \
    --outdir results/ --seed 42
```

Named arguments, any filenames, any location. Add `--dry-run` to print the plan
and execute nothing.

Four things it does beyond copying files:

- **Refuses to start on a moved kernel.** The freeze check runs first, so a run
  can never silently produce results that are not comparable to earlier ones.
- **Warns when a run will not reproduce.** Capabilities that draw from the RNG
  say so in their contract; omitting the seed produces a warning rather than
  silence.
- **Pins the environment**, thread counts included, since those can move
  low-order bits.
- **Writes `run_manifest.json`** next to the results: contract version, kernel
  digests, dependency versions, parameters, whether the run was reproducible,
  and every input by content hash.

That manifest is what lets a result be traced back to exactly what produced it,
which nothing in the current pipeline records.

### Resuming

The region finder is eight stages and, on the benchmark, over half an hour. Every
failure it has produced so far was in the adapter rather than the kernel: a
container named wrongly, a project flag missing, one argument too many. Losing
correct computation to fix a one line mistake is avoidable.

```sh
python3 bin/run.py capabilities/region_finder.json ... --stage-dir /scratch/$USER/rf
# it fails at stage six; fix the cause, then
python3 bin/run.py capabilities/region_finder.json ... --stage-dir /scratch/$USER/rf --resume
```

A failed run records what finished, and prints the command to continue. Resuming
refuses in two cases, both of which would otherwise blend two versions of a
computation into one result:

- Anything that decides a number has changed since: a kernel digest, an image
  digest, a parameter, the pinned environment, or an input file's contents.
- A step that already ran now has a different command. Fixing a stage that has
  not run yet is the point; changing one that has is a different computation
  wearing the same name, and everything after it was derived from the old one.

## Three ideas the schema encodes

**A capability is not a script.** The region finder is one capability containing
eight stages across two languages. Differential abundance is one capability run against two different
feature spaces. Contracts are written at the capability boundary.

**`staged_as` carries the coupling.** The Julia kernels read fixed filenames out
of one directory rather than taking arguments. Recording that mapping is what lets
a named-argument interface sit in front of an unchanged kernel: the adapter reads
`staged_as` and assembles the directory. `workflows/spacet/R/prepare_ct_matrix.R`
already does this by hand for the cell-type feature space.

**Shape and cost are independent.** `fans_out` decides whether a scheduler is
needed. `bound_by` and `scales_with` decide which machine. A single job can be
expensive, and a fan-out can be individually cheap and still need a scheduler for
throughput. `basis` records where the estimate came from; most of this repository
provides no measurement, so `derived_from_algorithm` is the honest value until a
run is instrumented.

## Adding a capability

1. Identify the capability boundary, which may span several scripts.
2. Record every file whose content determines the numbers, with its digest.
3. Map each logical input to the exact path the kernel opens.
4. State whether it draws from the RNG, and which variable seeds it.
5. Fill `resources` from the algorithm, and label `basis` accordingly.
6. Run `--as verify` and confirm it passes before relying on the contract.

## Status

Run `python3 bin/status.py` for the current picture. At the time of writing:

| Capability | Level | Stages | Reproducible | `verify` | Calls checked |
|---|---|---|---|---|---|
| `harmonize` | 0 | 1 | Yes | Passes | 0 of 1 |
| `region_finder` | 1 | 8 | Only when seeded, see below | Passes | 4 of 8 |
| `spacet` | 1 | 1 | Expected, unverified | Passes | 0 of 1 |
| `bayesspace` | 1 | 1 | **No seed available** | Passes | 0 of 1 |
| `differential_abundance` | 2 | 1 | Only when seeded | Passes | 1 of 1 |
| `growchain` | 2 | 1 | Yes | Passes | 1 of 1 |
| `de_analysis` | 2 | 1 | Expected, unverified | Passes | 1 of 1 |
| `slab` | 3 | 1 | Yes | Passes | 1 of 1 |
| `cohort_sgp` | 4 | 1 | Yes | Passes | 0 of 1 |

That covers every capability at levels 0 to 4, which is the whole pipeline from
a Space Ranger directory to a cohort result.

Level 0 is the ingest step, and contracting it closed a gap that had been patched
in the data. The differential abundance kernel opens a file called `genes.txt`;
ingest writes one called `features.txt`. The benchmark dataset works because
`genes.txt` there is a symlink to `features.txt`, made by hand and committed
beside the data. A fix living in the data cannot be reviewed, cannot be tested,
and does not survive a copy that does not preserve links. The contract records
the filename each kernel opens, so the adapter places whatever file it is given
under the name that kernel wants, and no link is needed.

Only one of the two ingest implementations is contracted. The other, for datasets
pulled from a public repository rather than from Space Ranger, writes four of the
six files and, where the scale factors are missing, writes zero into both
coordinate columns and continues rather than stopping. A dataset taking that path
reaches the spatial optimisation with every spot at the origin. Contracting it
would mean promising output that the rest of the pipeline cannot use.

Every version is now pinned, but it is worth being precise about where those pins
came from, because it is not where you would want them to come from. The three
package wrappers depend on published R packages whose versions appear nowhere in
this repository. The versions recorded in the contracts were read out of the
built container images, one by one. That makes the images the primary record and
the recipes secondary, which is backwards: `build_r_container.sh` resolved CRAN
against `latest`, so whoever built on whatever morning got whatever CRAN held
that day, and the recipe cannot reproduce the image it built. The build scripts
now take a dated snapshot, so images built from here on are reproducible; the
existing images are pinned by digest because that is the only thing about them
that is stable.

The "calls checked" column counts stages whose kernel states its own argument
count. Where it says 0, the kernel parses named flags in a loop or is a shell
script, and the calling convention has to be read rather than checked.

`bayesspace` looked like the one case that would need a kernel edit. It runs a
Markov chain sampler and takes fixed seeds only through its test mode, so two
ordinary runs over the same input give different cluster labels. It turned out
not to need one. The seeds it picks for itself come from R's global generator,
and it is launched with `Rscript` without `--vanilla`, so R sources a user
profile first; a profile holding `set.seed()` fixes the state those draws come
from. The adapter writes that profile and points `R_PROFILE_USER` at it, which
makes seeding a wrapper mechanism like every other one here. Measured: two runs
at seed 42 are byte identical, seed 43 differs, unseeded differs again.

`region_finder` needed a second, different fix, and it is the one that shows why
plumbing a seed is not the same as seeding a run. It draws from the RNG in two
stages. `spatial_optimize.jl` reads `TUMORSPACE_FIXED_SEED` and honours it.
`phylo_tree_build.jl`, which builds the replicate trees, never reads that
variable: it seeds itself only when `--test-seed` is present and otherwise draws
unseeded. So a run with `--seed 42` seeded the hyperparameter search and left the
bootstrap free, and both stages logged that they were using seed 42, which is why
reading the logs would not have caught it. Two seeded runs diverged, first at
`Tree_support.nw`, with everything downstream inheriting it.

The adapter now passes `--test-seed`, and only when a seed was supplied, so an
unseeded run is unchanged. The flag occurs at one line of that script and does
nothing else. One limitation cannot be fixed from outside the kernel: the seed it
derives comes from the task indices and ignores the value, so `--seed 42` and
`--seed 43` build identical trees. That buys reproducibility, not seed control,
and the contract says so rather than implying otherwise.

Every capability at levels 1 to 3 can now be run reproducibly.

Julia side versions come from `workflows/tumorspace_core/julia/Manifest.toml`,
which resolves Julia 1.9.0, HypothesisTests 0.11.4 and SpectralInference 0.4.1.
The Julia version itself is recorded as part of the scientific surface, because
the RNG stream is a language level guarantee: a different Julia can draw a
different hyperparameter search even under a fixed seed. Note that the manifest
says 1.9.0 and the image runs 1.9.4, so the lockfile and the runtime disagree;
the contracts record the image, because the image is what executes.

`cohort_sgp` is the only one whose result does not belong to a sample. Every
other capability can be recomputed for one sample in isolation; this one cannot,
because the decomposition is over the whole cohort at once. Adding or removing a
sample changes every program rather than adding one, which makes cohort
membership a parameter of the analysis rather than a detail of how it was run.

That shape needed two things the earlier contracts did not. An input can declare
`aggregates` instead of `produced_by`, meaning it is assembled from the outputs
of several capabilities across every sample rather than being one named output of
one run: a gather rather than a join, and the graph now distinguishes the two. And
an input can declare `stage_mode: link`, because a cohort directory is the first
input large enough that copying it would cost more than reading it; the adapter
then binds its real location into the container, since a link out of the staging
tree resolves to nothing inside one.

Wiring it up also found a gap in `region_finder`. The cohort reads
`OptimalTree_pruned_node_info.txt`, which that capability has always produced and
always copied into `optimal/`, but never declared. It is an output now. Nothing
about the computation changed; what changed is that it is promised rather than
merely present, which is the difference between a dependency and a coincidence.

## Multi stage capabilities

`region_finder` is one capability containing eight kernel invocations across two
languages. Its `stages` array describes internal execution; the artifacts passed
between stages are deliberately absent from `inputs` and `outputs`, which stay
the external surface.

Six of the eight stages repeat once per candidate SVD size. Inside a fan out
stage the template may use `{run}` for the index, `{item}` for the value, and
`{run_dir}` for a directory private to that iteration. The private directory is
not a detail: every stage writes fixed filenames, so a shared directory would
have each iteration overwrite the last.

The runner expands a fan out serially. Where a kernel derives its seed from the
task index, serial and parallel execution give identical results, which makes
parallelism a throughput decision for whichever runner is driving rather than a
property of the capability.

`tree_build` is that case, but only under a seed. Given one it derives from its
candidate and replicate indices, so the order the iterations run in cannot
matter. Without one it draws unseeded, and then neither serial nor parallel
execution reproduces anything, so the question does not arise.

The fan out is two dimensional. `tree_build` repeats over candidate SVD sizes and
then, inside each, over bootstrap replicates, which `bootstrap_support`
concatenates into the file `gotree` reads. Modelling only the outer dimension
produced a single tree per candidate and a stage that failed on a file that was
never assembled.

## What the baselines say

`baselines/` records the output digests of seeded runs, so a later run can be
compared byte for byte rather than by eye. The measurement that motivated them,
taken on randi with `differential_abundance` on one sample and identical inputs:
two seeded runs produced byte identical output, and two unseeded runs of the same
unmodified code agreed on 93.4% of significance calls and disagreed on 1,764 of
them.

The consequence is worth stating plainly, because it constrains how any refactor
here can be validated. Comparing a new run against a previous production run
proves nothing, since two production runs of the untouched code do not match each
other either. Seeded comparison against a recorded baseline is the only sound
test.

## Still missing

A seed that the tree builder actually honours by value. It now seeds itself
reproducibly when a seed is supplied, which is what validating a refactor needs,
but it derives that seed from its task indices rather than from the value, so
`--seed 42` and `--seed 43` build the same trees. Changing that means editing the
kernel rather than the wrapper.

A decision on Ripley's K. `checks/ripley/` has now been run: the R rewrite that
replaced the Julia implementation does **not** select the same nodes. Rank
correlation is 0.9935, but at the thresholds the optimiser searches over, between
1.3% and 5.3% of the selected nodes differ, and at one threshold the two select
different counts. Both are defensible discretisations of the same statistic and
neither is wrong, so this is not a bug to fix; it is a fact that has to be
recorded, because it means results from before and after that rewrite are two
populations rather than one. `checks/ripley/result-2026-08-07.md` has the
numbers. What is still missing is whether the gap widens with sample size, which
matters because the rewrite was made for samples larger than the one measured.
