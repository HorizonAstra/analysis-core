# Future work

Directions that are deliberately out of scope today but that the architecture is
meant to grow into. Nothing here is wired yet.

## Performance
- **Parallel processing for analysis.** Per-feature model fits (`cox_sweep`,
  `linear_mixed_effects_association`), permutation tests (PERMANOVA/PERMDISP), and
  bootstraps are embarrassingly parallel. They are intentionally sequential for now;
  a process/thread pool (opt-in, bounded) is the natural speedup once the
  single-process behavior is locked in.
- **Caching of intermediate results** beyond the study loader (e.g. distance
  matrices, transformed feature blocks) keyed by inputs.

## Testing
- **Automated testing against the Claude API** — integration tests that drive the
  standalone client end to end (tool selection, multi-step reasoning, image
  results) on fixture studies, with cost controls.
- A primitives/workflows test suite with golden values, so refactors are guarded. The cheap,
  high-value half is not the golden values but the **architecture assertions** — "no primitive
  imports a domain", "no backend contains a site path", "every tool declares a phase" — which
  never need maintenance because they encode the rules rather than any behaviour. The
  duplicate-LME drift that produced two diverging mixed-model implementations is exactly what
  a golden-output test catches and a type checker never would.
- A **capability smoke test** in CI: start the built image and assert the tool inventory is
  exactly what is expected. The startup gating makes "silently fewer tools" a real failure
  mode, and `./mo capabilities --require-all` is the check for it.

## Provenance and user-facing outputs
- Richer cross-study provenance views (an artifact graph across workspaces). *(Seeded:
  `list_results` gives a flat cross-topic view, and every results manifest backlinks to
  its source workspace/artifact and records its `studies`. A real graph — edges across
  `depends_on` and `provenance` spanning workspaces — is still to build.)*

## Context and behavior
- **Improve the standing context across sections** — fill in `context/defaults.md`,
  tune the per-section guidance, and keep it in sync as capabilities change.
- Per-study context overlays (study-specific notes injected alongside the global brief).
- **Clinical anchor per study.** Add the per-study reference event or date that day 0
  means (e.g. transplant, ICU admission, enrollment) to the context, so day numbers are
  interpreted against the right zero point for each study rather than assumed.

## Analysis depth
- **Advanced model testing** — the parked foundational-model track (autoencoders,
  VAE, VGAE, HMM). The clean dependency: this environment is the substrate, and a
  trained model later becomes another callable inside the scratch space.
- Wiring an events-to-outcome derivation so survival can run from a study's events
  table (today the subject-level (duration, event) table is built by hand in the scratch
  space before `kaplan_meier`/`cox_sweep_stage`).
- **A real R MaAsLin integration** — *(Done, as MaAsLin **3**: the `maaslin3_association`
  tool over the tertiary R stats engine — system R + renv + `compute/backends/rscript.py` calling
  `Rscript`. See `tertiary-stats-roadmap.md`.)* The old `maaslin2_analysis()` placeholder
  stub has been removed, and `microbiome.py` with it. The `linear_mixed_effects_association`
  primitive moved to `primitives/mixed_models.py` — it is the one-part MaAsLin 2-equivalent
  (multivariable fixed effects + subject random intercept, one linear model) and it stays;
  MaAsLin 3 adds the two-part (abundance + prevalence) model on top of it.
- **LEfSe and HAllA** — *(Done: `lefse_biomarkers` and `halla_association`.)* Still open from
  bioBakery's suite: MMUPHin, CCREPE and BAnOCC are installed and ready to wrap on demand;
  **anpan** is deliberately not, because both its input paths need secondary output we have
  never produced (pglmm wants StrainPhlAn trees, batch wants HUMAnN profiles) and it needs a
  CmdStan toolchain — a heavy install for a tool with nothing to run on.

## Agentic frameworks
- A **framework for paper-level agentic workflows** — end-to-end, reproducible runs
  that go from a question to publication-ready figures, tables, and methods text.
  The current workflows are deliberately concrete and detailed (not agentic); these
  abstract, agentic orchestrations are a different layer and want their own package (with
  workflow classes) rather than living under `workflows/`. Note the *paper schemas* are not
  that layer and are not code: they are Markdown delivered into the model's context, and they
  would live with the standing brief.
- **Multi-agent workflows** — multiple specialized agents collaborating on a study.

## Summaries
- Default **multi-format summary artifacts** — visual, written, and tabular — that
  capture the complete picture after a long working session so it is not lost. The
  model would default toward these styles/instructions but not be restricted by them
  (they are guidance, not hard constraints). *(The destination exists:
  `present(..., summary=True)` marks these as summaries on their manifest; what remains is
  the model defaulting to producing the multi-format set.)*

## Product, access, and deployment
- **Hide the internals** — an organization/packaging where a user can use the system
  without the whole codebase and internal vocabulary being exposed. (Still
  transitioning away from the prototype, so today's openness is acceptable.)
- **Run on any hardware** — *(Done in design, unproven in practice: one complete OCI image
  with every software capability baked in and every environment concern injected at runtime.
  See [deployment.md](deployment.md).)* What remains is to actually **build it** — no container
  runtime was available where it was written, and the R layer is the risk, since packages that
  install as macOS binaries during development may build from source on Linux. After that: push
  it to a registry, and confirm the Apptainer conversion for an HPC that forbids a root daemon.
- A **custom interface** for the application. *(Done: the `webapp/` browser product.)*
- **Authentication and user-account handling.** *(Minimal version in place: fixed accounts,
  signed-cookie sessions, per-user chats and per-user study access. Still to do: a real
  org auth layer (SSO), sign-up restricted to @bsd.uchicago.edu, and hashed credentials.)*
- **A warm pool of per-user MCP servers** with idle eviction — today each user gets one
  long-lived MCP server; that is fine for a handful of users, not for many.
- **Persist the model conversation.** *(Done: `webapp/conversations.py`.)* Each chat's
  native provider blocks are written to `.userdata/conversations/<user>/<chat>.json` at
  the end of every turn and rehydrated on a cache miss, so a restart no longer leaves the
  user looking at a transcript the model has no memory of. The whole block goes to disk,
  not just the text: a thinking block's signature is verified by the API and a compaction
  block is what lets the API drop the summarized history, so neither survives a
  text-only round trip. A stored history is refused if the provider or model has changed
  since it was written. Because the record is now on disk, `Engine.conversations` became
  an LRU cache (`LLM_MAX_LIVE_CHATS`, default 50) and the old unbounded growth is gone.
  What remains: a shared store so more than one server process can serve the same chat.
- A set of **research example chats**, ready to show what the system can do.

## Interaction / UX
- **Slash-command tool selection.** From an experienced user's point of view it is
  sometimes hard to make the model reach for the *specific* tool you have in mind through
  natural language alone — the model interprets intent, and intent is fuzzy. Borrow Claude
  Code's slash-command idea: let the user type `/anova`, `/maaslin3`, `/beta_diversity`,
  etc. to name a tool/analysis explicitly and pass it granular control, while plain
  natural language keeps working for everything else. The command would map to a specific
  tool (or a curated prompt that pins the tool + its key parameters); a `/` menu could list
  what is available in the current scope. This pairs naturally with the growing tool menu
  (secondary pipelines, tertiary Python primitives, tertiary R stats): as the surface area
  grows, "which tool did I get?" gets harder, and an explicit escape hatch is the fix.

## Model providers
- Support models **beyond Claude**: other hosted providers (e.g. Google) and
  in-house / open-source models run locally.

## Visualization
- **Custom chart-styling passes based on how the charts actually look.** The general
  charting library is research-grade by default, but specific chart types will need
  hand-tuned adjustments (spacing, label placement, color choices, annotation
  density, per-chart-type tweaks) once we judge them by eye on real output.

## Robustness
- A hardened multi-tenant sandbox for `run_code`. *(Partly done: an executor seam exists
  with an in-process backend (dev default) and a portable `subprocess` backend —
  timeout, CPU/file limits, scrubbed env, crash isolation — selected by
  `RUN_CODE_EXECUTOR`. The remaining work is a container/microVM backend behind the same
  seam for untrusted multi-tenant isolation, plus a warm worker pool so the subprocess
  backend keeps study caches hot.)*
