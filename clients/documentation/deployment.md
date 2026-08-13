# Deployment

## One complete image

Everything the toolkit can **do** is baked in. Everything about **where it runs** is
injected. That split follows from two kinds of capability:

| | Examples | Decided |
|---|---|---|
| **Software** | R + Bioconductor (MaAsLin 3, LEfSe), HAllA | **Build time.** Deterministic, so it is always present. |
| **Environment** | a reachable cluster, which data a user may read, secrets | **Runtime.** Cannot live in an image. |

No slim/full variants. Variants mean deployments that differ in what they can do, and
"tool absent" becoming ambiguous between *not installed* and *not permitted* — the worst
failure mode the startup gating creates. A few GB is the cheaper problem. If size ever
matters it is an optimization with evidence, not an upfront split.

## Deployment-agnostic by construction

Nothing in the image names a platform:

- **Plain OCI image.** Runs under Docker, Podman, or Kubernetes, and converts to
  Apptainer/Singularity for an HPC that forbids a root daemon:
  `apptainer build toolkit.sif docker://<registry>/multiomics:<tag>`
- **Secrets at runtime**, env var or mounted file; never baked in.
- **All state relocatable**: `DATA_ROOT`, `OUTPUTS_ROOT`, `CHATS_ROOT`, `DATASOURCE_CACHE`,
  `RETIRED_ROOT`. The app does not care whether these are a bind mount, a PVC, or NFS.
  `DATASOURCE_CACHE` is rebuildable — losing it costs time, not data.
- **Input is read-only.** Mount `data/` read-only; it matches the toolkit's own rule that
  input is never modified.
- **Non-root and arbitrary-UID tolerant.** Many platforms assign a UID and ignore `USER`,
  so state paths are group-writable with group root rather than owned by a fixed uid.
- `0.0.0.0:$PORT`, no assumptions about TLS or ingress — a proxy's job.
- Logs to stdout/stderr only.
- `GET /healthz` — unauthenticated liveness, touches no dependency. (`/` redirects to the
  login page, so probing it would exercise auth to answer a question about the process.)
- **tini as PID 1.** uvicorn already handles SIGTERM and the lifespan shuts the per-user MCP
  subprocesses down cleanly, so this is defence for hard kills and double-forking children,
  not a fix for a known leak.

```
docker build -t multiomics .
docker run --init -p 8000:8000 --env-file .env \
  -v "$PWD/data:/data:ro" -v multiomics-state:/state multiomics
```

`docker-compose.yml` is a local convenience, not the contract. The contract is: a port,
secrets, a read-only data mount, a writable `/state`.

## Environments: author vs restore

**A build may never resolve versions.** Each environment has two paths, and a build only
ever runs the second:

| Env | Author (by hand, then commit the lock) | Restore (exact; what builds run) |
|---|---|---|
| toolkit Python | edit + `pip freeze > requirements.txt` | `pip install -r requirements.txt` |
| `envs/r-stats` | `Rscript envs/r-stats/install.R` | `bash envs/r-stats/restore.sh` |
| `envs/halla` | `bash envs/halla/build.sh` | `bash envs/halla/restore.sh` |

Both restore paths end in the env's own `verify.sh`, so a broken environment fails the
build rather than surfacing as a broken tool at a user's first request.

Why two paths at all: it makes "works on my laptop" and "works in the image" the *same*
claim instead of two.

### How each is pinned

- **r-stats** — `renv.lock` (R 4.5.0, Bioconductor 3.22, ~295 packages). `renv::restore()`
  installs exactly that. The image base is `rocker/r-ver:4.5.0` because the lock records
  4.5.0 and restore wants a matching R; Debian's own `r-base` drifts. Change the base only
  together with re-authoring the lock.
- **halla Python** — `requirements.lock.txt`, a full freeze including transitives;
  `uv pip sync` makes the env match it exactly.
- **halla R** (`XICOR`, `eva`) — pinned by a **dated CRAN snapshot** in `envs/halla/env.conf`.
  A frozen date resolves the same versions transitively on any platform *and* can use
  binaries. `r-requirements.lock.txt` is the drift **check**, not the install instruction.
  `remotes::install_version` was tried and rejected: it forces source builds, and `mnormt`
  is Fortran, so it fails wherever gfortran is absent.

### Why HAllA has its own environment

It is a program we invoke, not a library we import — same reasoning as MaAsLin's renv
project. It also wants rpy2, seaborn and jenkspy, none of which the toolkit needs, so
isolating it means a HAllA upgrade can never move the toolkit's numpy. And it is not pure
Python: it calls R through rpy2 and imports `XICOR` and `eva` at module load, so its env
carries a **private** R library (`domains/microbiome/environments/rlib`) that cannot collide with r-stats.

## Capabilities

```
./mo capabilities                       # what is available, and why not
./mo capabilities --require-all         # non-zero unless every capability can run somewhere
```

The image build runs the second form. Without it, a layer that half-failed ships as an
image that silently offers fewer tools. Environment capabilities are reported but never
required — demanding them would make the image undeployable anywhere else.

## Cluster access (optional)

Secondary analysis submits jobs over SSH. It is off unless configured, and configuring it
is runtime-only: set `RANDI_SSH_HOST` and mount a key. Absent either, those tools are not
offered. The image ships an ssh *client*, never a key. Paths and the two writable roots are
env-overridable — see `compute/sites/randi.py`; a different cluster is a sibling module
there, not an edit to a backend.

## Known limits

- **One long-lived MCP subprocess per signed-in user.** Fine for a handful of users, not for
  many. The fix (a warm pool with idle eviction) is in [future-work.md](future-work.md).
- **The image is unbuilt.** It was written on a machine with no container runtime. The
  Python and app layers are low risk; the R layer is the one to watch, since packages that
  install as macOS binaries during development may build from source on Linux — which is why
  the build deps and gfortran are explicit. Build it once and fix what the log says.
