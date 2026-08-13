# Claude AI Coding Principles

## 1. Errors & Failures
1.1. Never create silent fallbacks that hide bugs; fail loudly with actionable fix instructions  
1.2. Never auto-install missing dependencies at runtime; fail with container rebuild instructions  
1.3. Required binaries/tools must hard-fail with actionable error message when missing  
1.4. When a fallback is acceptable (optional feature), it must warn loudly and state what is being skipped  

## 2. Container & Build
2.1. Every new dependency or embedded script must be reflected in post-build verification, explicitly or implicitly  
2.2. Post-build verification runs automatically as part of every container build  
2.3. Never merge to master without `tests/clean_container_rebuild.sh` passing — it clones the repo to `/tmp` and builds from scratch without touching local containers  
2.4. setup.sh must build ALL containers required to run the full pipeline  
2.5. Execution mode availability (container vs native) is determined once at setup/build time and written to `config/capabilities.sh` (gitignored). Orchestration scripts source this file; they never run environment discovery during job execution. Each feature registers entries: `<FEATURE>_CONTAINER_AVAILABLE` and/or `<FEATURE>_NATIVE_AVAILABLE`. The interactive install prompt lives only in `setup.sh`, never in orchestration scripts.  

## 3. Git & Branching
3.1. Dev branch commits are acceptable during iterative testing  
3.2. Master only receives merges that have passed clean environment testing  
3.3. All non-trivial work — including container/infrastructure builds — must be done on a feature branch (e.g. `feat/bayesspace-container`), not directly on master. This applies even to iterative debugging sessions: create the branch at the start, regardless of how exploratory the work is. Merging 20+ `fix(container):` commits directly to master is a code review anti-pattern and makes bisecting regressions harder.  
3.4. When a build or debugging session produces a corrupt git object (e.g. from an interrupted write), do not attempt to repair it in-place. Create a clean branch from the last good commit, cherry-pick or squash the working result onto it, and push that. Never force-push a branch containing corrupt objects to a remote.  

## 4. Code Quality
4.1. Do not create one-off scripts for trivial tasks  
4.2. Do not place analysis or submission scripts in the repository root  
4.3. When implementing a new feature, ensure its installation is checked in post-build verification
4.4. Script-only changes must use the script-layer rebuild path (build_r_container.sh, ~30 sec); only trigger a full base rebuild (--force) when R packages change

## 5. Testing
5.1. Every feature must have a test. Choose the tier based on what is being tested — not on convention.
5.2. **Tier 1 — Unit tests with synthetic data (pytest, `tests/<feature>/`):** Use when the feature contains substantial custom logic (parsing, caching, validation, transformation). Synthetic fixtures (minimal tmp_path data) keep tests offline, fast, and deterministic. Example: `tests/acquisition/`.
5.3. **Tier 2 — Integration tests on real benchmark data (shell, `tests/<feature>/`):** Use when the feature is primarily a wrapper around an established external tool (R package, Julia binary, Singularity container). Run the actual tool against `benchmarks/GSE213688_GSM6592057/input_data/` (371 spots, full real dataset, tracked in repo) and assert on outputs. Example: `tests/clean_container_rebuild.sh`, `tests/bayesspace/`.
5.4. All Tier 2 integration tests use `benchmarks/GSE213688_GSM6592057/input_data/` as the standard input. This dataset is small enough to run quickly, real enough to produce meaningful plots, and consistent across features.
5.5. Rationale for rules lives in docs/advanced/DEVELOPMENT_NOTES.md if needed