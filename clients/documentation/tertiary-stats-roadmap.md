# Tertiary Stats (bioBakery) Engine — Roadmap / TODO

A **living checklist** for adding bioBakery's statistical tools as a **second tertiary engine**
alongside the toolkit's own Python primitives. Companion to `secondary-analysis-roadmap.md`.

## Goal
Let the model run bioBakery's association / biomarker / correlation analyses on a study's
**assembled tables** (taxa + metabolites + clinical). This is **tertiary** (tables → insight),
**local to the toolkit host, and synchronous** (minutes) — NOT the SLURM async path used for
secondary. It's a *different compute backend*, same "guarded tool" pattern as `curated.py`.

## The landscape (bioBakery wiki, verified 2026-08)
| Tool | What it does | Lang | Notes |
|---|---|---|---|
| **MaAsLin 3** | multivariable association / differential abundance (abundance **and** prevalence, compositional) | **R** | supersedes MaAsLin 2; longitudinal via random effects; Bioconductor + `biobakery/maaslin3`. The workhorse. |
| **HAllA** | hierarchical all-vs-all association between two feature sets (e.g. taxa ↔ metabolites) | **Python** | key given our metabolomics |
| **LEfSe** | biomarker discovery (Kruskal–Wallis + LDA effect size) | **Python** orig; **R** as `lefser` (Bioconductor) | prefer `lefser` to stay in one env |
| **MMUPHin** | meta-analysis + batch/covariate correction across studies | **R** | |
| **CCREPE** | compositionality-corrected correlation / co-occurrence | **R** | |
| **BAnOCC** | Bayesian compositional correlation networks | **R** | Stan-backed, heavier/slower |
| **anpan** | phylogenetic GLMMs (strain / function association) | **R** | pairs with StrainPhlAn output |
| MTXmodel | metatranscriptomics MaAsLin variant | R | when we add mtx |
| SparseDOSSA2 | synthetic data simulation | R | not analysis — skip |
| microPITA / PARATHAA | sample selection / 16S phylo assoc | Py / — | niche; on demand |

**Language split:** R = MaAsLin3, MMUPHin, CCREPE, BAnOCC, anpan, `lefser`. Python = HAllA, LEfSe(orig).
So the user's "R-based" instinct is *mostly* right — the majority (and the newest) are R; HAllA is the main Python one.

## Design
- **New tertiary backend: local + synchronous.** Runs where the toolkit runs (Mac dev / webapp host), blocking (minutes). Fits the org model: `tertiary-R = local sync` (vs `secondary = randi-slurm async`, `tertiary-python = in-process`). Implemented in `src/compute/backends/rscript.py` (the runner) plus one module per tool under `src/compute/tertiary/`.
- **Env: system R + `renv`** (DECIDED — not conda). The Mac already has system R (4.5) and no conda; installing conda just for this cut against the uv-only/nimble setup. `renv` is R's lockfile-based, project-local env (the `uv`/`venv` of R): packages live under `envs/r-stats/renv/library/` (gitignored), pinned in `envs/r-stats/renv.lock`. That one lockfile is the whole reproducibility contract and **also drives the future Docker image** (`rocker` base + `renv::restore()`), so there is ONE env recipe, not a Mac one and a container one. On CRAN R, Bioconductor ships macOS binaries, so `install.R` DOWNLOADS packages rather than compiling. (The old conda `environment.yml` was removed as dead weight — it was never usable on the Mac.)
- **Invocation:** guarded MCP tools (`tools/tertiary/biobakery.py`, same shape as `tools/tertiary/microbiome.py`) that: load the study's tables → assemble + align the tool's input tables → `compute/tertiary/<tool>.py` writes TSVs and runs a small R wrapper (`src/compute/tertiary/r/*.R`) via **`Rscript` subprocess** with the renv project as cwd (its `.Rprofile` activates the pinned library) → read outputs → `context.persist` them as workspace artifacts. Subprocess over `rpy2` for isolation/robustness.
- **Data contract:** study abundance matrix + metadata (subjects/samples/events) → each tool's expected input. Reuse the existing study loader. MaAsLin 3 takes the **raw** relative-abundance table (`clade_abundance`), NOT the CLR `matrix` — it does its own TSS+LOG.

## Priority
1. [x] **MaAsLin 3** (R) — the workhorse; differential abundance + longitudinal. **DONE:** `maaslin3_association` in `tools/tertiary/biobakery.py`, via `compute/tertiary/maaslin.py` + `r/run_maaslin3.R`. Fits abundance (linear) AND prevalence (logistic) models, per-subject random effect on longitudinal studies (subject_id), BH FDR. Saves `all_results`, `significant_results`, and the summary plot (PNG) as workspace artifacts. Verified on Leukemia (312 stool samples × 954 species, `sex` + subject RE, ~31 s): 2 taxa higher in males. Proves the R-subprocess pattern for the rest.
2. [ ] **HAllA** (Python) — taxa ↔ metabolite association (we have metabolomics).
3. [x] **LEfSe** via `lefser` (R) — biomarker discovery. **DONE:** `lefse_biomarkers` in
   `tools/tertiary/biobakery.py` via `compute/tertiary/lefser.py` + `r/run_lefser.R`. Two-class only,
   signed LDA scores, reference class reported. Guarded: refuses >2 levels (suggests `compare`), and
   warns on pseudoreplication + no-correction — on Leukemia it finds 209 hits where MaAsLin 3 finds 2.
4. [ ] **MMUPHin / CCREPE / BAnOCC / anpan** — as needed.
   - Adding an R tool: add `bioc::<pkg>` to `envs/r-stats/install.R`, `Rscript envs/r-stats/install.R` to refresh the lock, write `compute/tertiary/r/run_<tool>.R` + `compute/tertiary/<tool>.py`, then a guarded tool in `tools/tertiary/biobakery.py`. Installed so far: maaslin3, lefser, MMUPHin, ccrepe, banocc (anpan pending).

## Resolved decisions
- **Env mechanism:** system R + `renv` (see Design). Not conda, not Docker-only.
- **LEfSe:** use `lefser` (R) — stays in the one R env. (Installed and built; see priority 3.)
- **Direct tools vs `biobakery_workflows stats`:** call the tools **directly** (latest versions + full control), not the bundled workflow (which pins older versions).
- **metab omic in MaAsLin 3:** deferred. Metabolite concentrations are not compositional counts, so TSS is wrong and zeros-vs-missing needs care (NONE/LOG + prevalence filtering). v1 is taxa-only (`omic='clade'`); the tool refuses metab with a clear message.

## Next
HAllA (Python, taxa ↔ metabolite) is the next highest-value tool given the metabolomics data — it is the only remaining priority-2/3 item, and the one non-R tool. MMUPHin/CCREPE/BAnOCC are installed and ready to wrap on demand. Also open: surface a `list_stats_options`-style menu entry per tool as they land, and (see future-work) slash-command selection so the user can pin a specific tool.
