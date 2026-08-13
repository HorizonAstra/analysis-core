# Feature Rollout Guide

Developer reference for planning and executing feature rollouts in TumorSPACE_AWS.

---

## Pipeline Roadmap

| Version | Feature | Status |
|---------|---------|--------|
| v1 | Data Acquisition | ✅ Production (Feb 2026) |
| v1 | TumorSPACE Core (Steps 1–9) | ✅ Production |
| v1 | BayesSpace | ✅ Production (Feb 2026) |
| v1 | Pipeline Report | ✅ Production |
| v2 | Spatial Domain Analysis | 🔲 Pre-production (rename + generalize `workflows/sg_analysis/` → `spatial_domain_analysis/`) |
| v2 | SpaCET Cell Type Deconvolution | 🔲 Planned — Vivek |
| v2 | DE Analysis (Seurat + DESpace) | ✅ Production (Mar 2026) |
| v3 | Probabilistic Region Alignment | 🔲 Planned |

For the frontend outputs each version enables, see the [README Roadmap](../README.md#roadmap).

---

## Feature Areas

TumorSPACE_AWS is organized into five feature areas, each with its own directory
under `workflows/`:

| Feature | Directory | Status |
|---------|-----------|--------|
| `tumorspace_core` | `workflows/tumorspace_core/` | ✅ Production |
| `acquisition` | `workflows/acquisition/` | ✅ Production (Feb 2026) |
| `bayesspace` | `workflows/bayesspace/` | ✅ Production (Feb 2026) |
| `pipeline_report` | `workflows/pipeline_report/` | ✅ Production |
| `spatial_domain_analysis` | `workflows/sg_analysis/` → `workflows/spatial_domain_analysis/` | 🔲 v2: Pre-production (scripts in `workflows/sg_analysis/R/`; rename + generalize before developing) |
| `spacet` | (new) | 🔲 v2: Planned — Vivek |
| `despace` | `workflows/DE_analysis/` | ✅ Production (Mar 2026) — Seurat FindAllMarkers + DESpace 2.0; `tumorspace_r45.sif` (R 4.5.0) |
| `probabilistic_region_alignment` | `exploratory/probabilistic_region_alignment/` | 🔲 v3: Planned |

---

## Rollout Order

Features are rolled out one at a time, in this order:

1. **bayesspace** — ✅ shipped Feb 2026
2. **pipeline_report** — ✅ integrated, production
3. **despace / de_analysis** — ✅ shipped Mar 2026 (Seurat + DESpace 2.0, `tumorspace_r45.sif`)
4. **spatial_domain_analysis** (rename + generalize `sg_analysis` first) — v2, next
5. **spacet** — v2, Vivek
6. **probabilistic_region_alignment** — v3
7. **housekeeping** — last (not a feature; see below)

---

## Feature Rollout Playbook

Follow these phases for each feature rollout. The acquisition feature (Feb 2026)
is the reference implementation.

### Phase 1: Discovery & scoping
- Read all existing code in the feature directory before touching anything
- Run the feature end-to-end in a live terminal to observe actual behavior
- Identify the gap between what exists and what is needed
- Write a short scope statement before writing any code
- **Container assessment (mandatory):** Answer these questions before writing
  any code or container definition:
  1. Does this feature require software not in any existing container?
  2. If yes: default is to **merge into the existing container** — prefer
     container sparsity (fewer containers = simpler setup, simpler user
     mental model). A new container requires explicit justification.
  3. Criteria that **do** justify a new container:
     - Incompatible base language or runtime version (e.g. Python vs R, or
       R 4.4 vs R 4.3 with a hard floor)
     - Genuinely conflicting package versions between the feature and existing
       container
  4. Criteria that **do NOT** justify a new container on their own:
     - Large number of new packages (Phase 1 base rebuild is already slow; adding
       more packages doesn't change Phase 2 script-layer rebuild speed)
     - Packages are "unrelated" to the existing workflow — unrelated is fine,
       conflicting is not; sparsity wins over conceptual tidiness
  5. Before concluding a new container is needed, verify actual incompatibility
     (check `Depends: R (>= x.x.x)` on CRAN/Bioconductor, check whether
     packages vendor their own C libs before adding system dep requirements)
  - The answer determines whether Phase 3 adds packages to `tumorspace_r_base.def`
    and the `build_r_container.sh` install block, or introduces a new `.def` and
    a new `build_*_singularity()` function in `setup.sh`

### Phase 2: Bug triage first
- Fix any bugs that block basic usage before adding new capability
- Each bug fix committed atomically with a clear diagnostic commit message
- Confirm the fix works in a live terminal before moving on

### Phase 3: Core implementation
- New code lives under the appropriate `workflows/<feature>/` subdirectory
- Shell wrappers in `orchestration/` expose Python/Julia/R tools cleanly —
  users should never need to call scripts in `python/`, `julia/`, or `R/` directly
- A pytest or equivalent test suite is added alongside the feature code
- **If merging into existing container** (the default): add packages to the
  relevant base `.def` (reference spec) and to the `install.packages()` /
  `BiocManager::install()` block in the active build driver; add any new R
  scripts to the `R_SCRIPTS` array and the verification lists in both
  `build_r_container.sh` and `tests/clean_container_rebuild.sh`
- **If a new container is genuinely required** (per Phase 1 assessment):
  `.def` file goes in `containers/`, a `build_<feature>_singularity()` function
  is added to `setup.sh` and called in the `SINGULARITY)` case block, and
  `tests/clean_container_rebuild.sh` gets the corresponding `.sif` existence
  check — **all features build by default; opt-out is a future concern**

### Phase 4: Documentation in lockstep
- `docs/GETTING_STARTED.md` updated to reflect actual current behavior — never left stale
- Feature-specific reference doc under `docs/` maintained separately from the
  getting-started guide
- Outdated or misleading content is replaced, not just appended to
- All shell snippets in docs use paths relative to the repo root and are tested
  in a live terminal before being committed

### Phase 5: Hardening
- State management (caches, intermediate files) made robust with versioning and
  explicit invalidation mechanisms (e.g. `--refresh` flag)
- Edge cases found through live testing, not just code review
- Output paths and working-directory assumptions made explicit

### Phase 6: Clean commit & declare complete
- All changes pushed to master before declaring feature complete
- `git status` is clean (or any untracked files are explicitly acknowledged)
- `CURRENT_PRODUCTION_STATE.md` updated to reflect new feature status

---

## Notes on `spatial_domain_analysis`

The current `workflows/sg_analysis/` directory is scoped too narrowly around
"spatial groups" (SGs) from the TumorSPACE core pipeline. The generalized
feature should support any spatial domain object type:

- **SGs** — spatial groups output by the TumorSPACE core pipeline (Steps 7–8)
- **BayesSpace clusters** — from the `bayesspace` feature
- **Manual annotations** — user-supplied domain labels

Before developing new analysis capabilities, rename `workflows/sg_analysis/`
to `workflows/spatial_domain_analysis/` and update all references.
Object-type-specific code should be organized as subdirectories or modules
within the feature (e.g. `spatial_domain_analysis/sg/`, `spatial_domain_analysis/bayesspace/`).

---

## Housekeeping (last)

These tasks are not features and should be done as a single cleanup pass after
all feature rollouts are complete:

- Fill in pending commit hashes in `CHANGELOG.md` (ISSUE-6, ISSUE-8)
- Triage untracked files at repo root (ad-hoc run scripts, R analysis scripts)
- Decide whether `benchmarks/GSE213688_GSM6592057/VALIDATION_REPORT.txt` is tracked
- Move or gitignore `workflows/sg_analysis/R/test_isg_gse193460.R`
- Confirm `reference_data/feature_references/` non-cache files are committed
