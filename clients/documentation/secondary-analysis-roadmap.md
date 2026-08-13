# Secondary Analysis on Randi — Roadmap / TODO

A **living checklist** so no capability, decision, or detail gets lost across long
development turns. Deliberately *not* granular — each item is a topic bucket, not a
task breakdown. Update the checkboxes as we go.

Related: the local-biobakery repo (the runner and the tools), `infrastructure/datasource/`
(how data is found and named) and `infrastructure/artifact-store/store.py` (how a result
is recorded).

---

## Goal (this effort)

From the user's chat with the model, the user should be able to:
1. **Discover** which shotgun-pipeline combos they can request.
2. **Launch** a run on Randi against data that already lives there.
3. Be **told when it completes.**

That's the whole scope for now. Turning pipeline outputs into study CSVs (so the
tertiary tools can consume them) is **explicitly deferred** — we'll reuse a former
teammate's reshape script rather than build our own.

---

## Non-negotiable invariants (never regress these)

- [ ] **Writes confined** to `/gpfs/data/dfi-cores/rijul/**` and `/scratch/rijulsareen/**`
      only. Enforced by canonicalizing (`realpath`) every write target in a **preflight**
      and refusing to submit if it resolves outside those roots (blocks `..`/symlink escape).
- [ ] **External input is READ-ONLY** — the pipeline only ever *reads* `--input`; it is
      never written or modified.
- [ ] **Never** run the orchestrator / heavy compute on a login node (existing runner guard).
- [ ] **Latest tools**; DB rule → **no HUMAnN ⇒ LATEST (vJan25); HUMAnN ⇒ COMPAT (vJun23)**.
- [ ] Every run leaves provenance travelling with its output (existing).

---

## Settled decisions

- **Topology:** the backend reaches Randi by **SSH to a login node and `sbatch`** there.
  (Randi allows SSH + sbatch on login nodes, forbids persistent services, and firewalls
  compute nodes from the internet.) An "on-Randi service" is a possible future optimization.
- **Async is mandatory:** a SLURM run is hours; the model cannot block. Every run is
  **submit → return a job handle → poll status on later turns.** No synchronous waiting.
- **DB selection is automatic** from the chosen combo (see below) — the user never picks a DB.

---

## Pipeline combos (the source of truth the model advertises)

Dependency DAG: `KneadData (QC) → MetaPhlAn (taxonomy, always) → { HUMAnN? StrainPhlAn? }`

| Combo id   | Tools                         | Runner flags                       | DB               |
|------------|-------------------------------|------------------------------------|------------------|
| `taxonomy` | Knead → MetaPhlAn             | `--mode taxonomy`                  | **LATEST** vJan25 |
| `function` | + HUMAnN                      | `--bypass-strain-profiling`        | **COMPAT** vJun23 |
| `strains`  | + StrainPhlAn                 | `--bypass-functional-profiling`    | COMPAT vJun23 †   |
| `full`     | all four                      | (none)                             | **COMPAT** vJun23 |

† `strains` (no HUMAnN) *should* get LATEST per the rule, but StrainPhlAn reads the pinned
metaphlan default (COMPAT today); LATEST for strain-including runs needs the per-run
strain-DB piece (workstream 7). Conservative default = COMPAT until then (never mismatches).

`run_wmgx.sh --mode` currently supports only `wmgx`(full) | `taxonomy` — `function` and
`strains` still need adding (or the tool composes the bypass flags directly).

---

## Data discovery & access (how the model knows what it can run on)

Secondary-analysis input is tied to the **existing study/access model**, not free-floating paths:

- A study declares its raw reads in a **`secondary.json`** manifest in its folder
  (`data/<domain>/<study>/secondary.json`): `{input_path, pair_identifier, description}`.
- **`list_pipeline_inputs`** shows the model only studies the user can access (the
  `ALLOWED_STUDIES`/`ALLOWED_DOMAINS` gates) that have such a manifest — so data is
  discoverable *and* invisible to those without access.
- **`run_secondary(study, combo)`** takes a *study*, resolves the reads path from that
  trusted manifest, and refuses studies outside the user's access. The model can no longer
  point the pipeline at an arbitrary path.
- Test fixture: study **`WmgxTest`** (microbiome) → the `small_ssg_fastq` reads; user
  **`mgx@bsd.uchicago.edu`** (pw `mgx`) scoped to *only* that study. Studies are
  gitignored (real cohort data), so this fixture is local — whitelist it in `.gitignore`
  if we want it to travel. → `src/compute/studies.py`, `webapp/{auth,access}.py`.

## Workstreams (topic buckets)

1. [x] **Compute-backend port** — `ComputeBackend` ABC mirroring `DataSource`, with the async
       + confined-write contract baked into the interface. → `src/compute/base.py` (+ `WriteScope`,
       `JobSpec`, `JobRecord`, `JobState`).
2. [x] **Async job layer** — `JobRegistry` persists handles as atomic JSON so they survive turns
       and restarts; status via `sacct` (+ `squeue` fallback); terminal states short-circuit.
       → `src/compute/registry.py`, `src/compute/randi.py`.
3. [x] **Model-facing MCP tools** — `list_pipeline_options`, `run_secondary` (async, + `dry_run`),
       `job_status`, `list_pipeline_jobs`, `cancel_pipeline_job`. → `src/McpServer/tools/secondary/pipelines.py`,
       wired (gated on config) in `mcp_server.py`.
4. [x] **Combos spec** — one declarative source of truth (combo → tools → DB → runner flags).
       → `src/compute/pipelines.py`.
5. [x] **Safety preflight** — `WriteScope.check()` (canonicalized; blocks `..`/symlink escape)
       enforced in `submit`/`plan` before any SSH; input is read-only by construction. Verified.
6. [x] **Randi transport / config** — `RandiSlurmBackend` SSHes to a login node and sbatches via
       `submit_wmgx.sh`; env-driven (`RANDI_SSH_HOST` / `_REPO_DIR` / `_LAB_DIR` / `_SCRATCH_DIR` /
       `_STUDIES_DIR`). **Single-user (rijul);** multi-user auth deferred. → `src/compute/config.py`.
7. [ ] **DB-mode rule** — generalize "no HUMAnN ⇒ LATEST"; includes the per-run strain-DB
       handling so `strains` can use LATEST. Add `function`/`strains` to `run_wmgx.sh --mode`.
8. [ ] **Reshape / ingestion seam** — **DEFERRED.** Find + reuse the ex-teammate's script
       (biobakery output → 5-CSV study). This marks the current scope boundary.
9. [ ] **Provenance chaining** — **DEFERRED.** Link tertiary study → secondary run (tool + DB
       versions, job id) → source FASTQs.
10. [ ] **Testing** — exercise combos on `small_ssg_fastq` (640k-read ERR101900) end-to-end.

---

## This phase vs deferred

- **This phase:** workstreams 1–6 (discover combos → launch → report completion).
- **Deferred (later):** 7 (strain-LATEST refinement), 8 (results ingestion), 9 (provenance
  chaining). Also out of scope: multi-user auth, assembly, non-wmgx workflows (16S, etc.),
  returning/using outputs to the user.

---

## Immediate next steps

Phase-1 code (workstreams 1–6) is implemented and unit-tested against a mocked Randi
(submit → parse SLURM id, poll/transition, cancel, scope refusal, capability gating).

- [x] **SSH reachability** — key-based auth to `randi.cri.uchicago.edu` is passwordless
      (`ssh-copy-id` installed the Mac's `id_ed25519`; existing `randi` alias). `RANDI_SSH_HOST=randi`
      in `.env`; `mo web` sources it and `_user_env` forwards it, so the per-user MCP subprocess
      registers the 5 secondary tools. Verified via the real `mcp_server` import path.
- [x] **First real run — GREEN (2026-08-01).** `small_ssg_fastq` (ERR101900) → taxonomy, end-to-end
      on Randi via the non-interactive submit path: COMPLETED (5/5 tasks), profile = 87.8% *S. aureus*
      (matches the fixture), on vJan25. Surfaced + fixed two Randi-side bugs the non-interactive path
      exposed (see local-biobakery): `activate.sh` LD_LIBRARY_PATH `grep` tripping `set -e` (`c1edaca`),
      and `run_wmgx.sh` appending to a missing `provenance/` dir (`0ecf6e9`). Job submit/parse/poll all
      verified against real SLURM state.
- [ ] Then **phase-2**: the reshape/ingestion seam (workstream 8, ex-teammate's script) so outputs
      become studies the tertiary tools consume.

### Resolved: how the MCP process authenticates to Randi
The web app runs locally via `mo` (on the Mac), so the per-user MCP subprocess uses the Mac's SSH
key/agent — passwordless, no stored secret. No Duo needed for key login. (If the web app is ever
dockerized/deployed off the Mac, that host needs its own key to Randi — deferred.)
