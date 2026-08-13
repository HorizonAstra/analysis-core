# TumorSPACE — Guided Tour

A curated reading path through the repository. Start at Stop 1 and go in order.

---

## Stop 1 — What is this?
**[README.md](../README.md)**

What the platform does, the full feature roadmap (v1 → v3), and a one-command install.

---

## Stop 2 — What does the output look like?
**[pipeline_summary.md](../benchmarks/GSE213688_GSM6592057/expected_outputs/pipeline_summary.md)**

The pipeline summary is the text output of a completed run — tree structure, spatial group
metrics, DA gene counts, SLAB scores, and BayesSpace cluster stats. The full
[Pipeline_Report.pdf](../benchmarks/GSE213688_GSM6592057/expected_outputs/Pipeline_Report.pdf)
is also in that directory.

---

## Stop 3 — Running your first analysis
**[docs/GETTING_STARTED.md](GETTING_STARTED.md)**

From raw GEO data to pipeline output in one command. Covers setup, dataset acquisition,
and a complete first run on the included benchmark dataset (370 spots, ~25 min).

---

## Stop 4 — Benchmark datasets and timing
**[docs/benchmarks.md](benchmarks.md)**

Three validated dataset sizes (small / medium / large), production timing numbers,
and fixed-seed reproducibility results. The reference for expected performance.

---

## Stop 5 — Input and output specification
**[docs/advanced/INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md)**

Exact formats for every input file (expression matrix, spot coordinates, gene names)
and every output file (trees, SG pairs, DA genes, SLAB scores, Pipeline Report).

---

## Stop 6 — Usage and workflow options
**[docs/usage_guide.md](usage_guide.md)**

Native vs container execution, test vs production mode, dataset acquisition workflow,
validation tools, and end-to-end command examples.

---

## Stop 7 — Modifying the code
**[docs/DEVELOPMENT.md](DEVELOPMENT.md)**

Edit → test native → rebuild container → test container → commit. Covers the
development loop, step-by-step test harness, and container rebuild scenarios.

---

## Stop 8 — Current production state
**[CURRENT_PRODUCTION_STATE.md](../CURRENT_PRODUCTION_STATE.md)**

What is validated and production-ready today: container versions, script inventory,
validated test runs, and the reproducibility checklist.
