# One complete image: everything the toolkit can DO is inside it.
#
# NOT VALIDATED BY A BUILD YET — written on a machine with no container runtime. The Python
# and app layers are low risk; the R layer is the part to watch, because packages that install
# as macOS binaries during development may build from source here. Build it once and fix what
# the log says before trusting it.
#
# Why one image rather than slim/full variants: capabilities split into two kinds, and only one
# of them may vary.
#   SOFTWARE capability (R + Bioconductor, HAllA) is deterministic, so it is BAKED IN. Making it
#   optional would mean deployments that differ in what they can do, and "tool absent" becoming
#   ambiguous between not-installed and not-permitted. That ambiguity is the worst failure mode
#   this design has; a few GB is the cheaper problem.
#   ENVIRONMENT capability (a reachable cluster, which data a user may read, secrets) cannot be
#   in an image at all. It is injected at runtime and gated dynamically at startup.
#
# Nothing here names a deployment target. It is a plain OCI image: it runs under Docker,
# Podman or Kubernetes, and converts to Apptainer/Singularity for an HPC that has no Docker.
#
#   docker build -t multiomics .
#   docker run --init -p 8000:8000 --env-file .env \
#     -v "$PWD/data:/data:ro" -v multiomics-state:/state multiomics

# renv.lock records R 4.5.0 / Bioconductor 3.22, and renv::restore() wants a matching R.
# Debian/Ubuntu's own r-base drifts, so pin the base to the version the lock was authored
# against. Change this only together with re-authoring the lock.
FROM rocker/r-ver:4.5.0

# System libraries. Two groups, both needed:
#   * Bioconductor build deps — several packages compile from source on Linux even when they
#     ship binaries on macOS, and gfortran in particular is non-negotiable (mnormt, and much
#     of the R stats stack, is Fortran).
#   * openssh-client — so the cluster backend can submit jobs when a site is configured. The
#     client, never a key: keys are mounted at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gfortran \
        libcurl4-openssl-dev libssl-dev libxml2-dev zlib1g-dev \
        libpng-dev libjpeg-dev libtiff5-dev libfreetype6-dev libfontconfig1-dev \
        libharfbuzz-dev libfribidi-dev libgit2-dev libglpk-dev libgsl-dev \
        libgomp1 openssh-client ca-certificates curl git tini \
    && rm -rf /var/lib/apt/lists/*

# uv manages the Python interpreter as well as the packages, so the Python version is pinned
# by us rather than inherited from whatever the base image happens to carry.
COPY --from=ghcr.io/astral-sh/uv:0.11.30 /uv /uvx /usr/local/bin/
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
RUN uv python install 3.12

WORKDIR /app

# ── environments, slowest-changing first so app edits never rebuild them ──────────────
# Each env is restored from its LOCK, never resolved: restore.sh installs exactly what was
# authored, so this image and a laptop get the same contents. Each restore ends in its own
# verify.sh, which fails the build here rather than surfacing as a broken tool later.

# R stats env (MaAsLin 3, LEfSe, MMUPHin, CCREPE, BAnOCC) — the slowest layer.
# The whole dir, not just the lock: renv activates through .Rprofile -> renv/activate.R, which
# is how every later Rscript call finds the pinned library. .dockerignore keeps the built
# library itself out, so this copies the recipe and the image builds the library.
COPY envs/r-stats/ ./envs/r-stats/
RUN bash envs/r-stats/restore.sh

# HAllA: its own Python env plus a private R library, because it calls R through rpy2 and
# imports XICOR and eva at module load. Private so it cannot collide with the r-stats library.
COPY envs/halla/ ./envs/halla/
RUN bash envs/halla/restore.sh

# Toolkit Python deps (pinned in requirements.txt).
COPY requirements.txt ./
RUN uv venv /opt/venv --python 3.12 \
    && VIRTUAL_ENV=/opt/venv uv pip install -r requirements.txt
ENV PATH="/opt/venv/bin:${PATH}"

# ── application ───────────────────────────────────────────────────────────────────────
COPY src/ ./src/
COPY context/ ./context/
COPY webapp/ ./webapp/
COPY mo ./

# State lives outside the image, so a container can be replaced without losing anything. All
# four are env-configurable in the app already; these defaults put them under one mount point.
# .cache is deliberately in here too: it is rebuildable, so losing it costs time, not data.
ENV DATA_ROOT=/data \
    OUTPUTS_ROOT=/state/outputs \
    CHATS_ROOT=/state/userdata/chats \
    DATASOURCE_CACHE=/state/cache \
    RETIRED_ROOT=/state/retired \
    HOST=0.0.0.0 PORT=8000 \
    PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

# Assert the build produced a complete image. Without this, a layer that half-failed ships as
# an image that silently offers fewer tools — the one failure mode the startup gating creates.
RUN python src/capabilities.py --require-all --tools

# Non-root, and tolerant of an arbitrary UID: many platforms assign one at random and ignore
# USER, so state paths are group-writable with group root rather than owned by a fixed uid.
RUN useradd --uid 10001 --create-home --shell /bin/bash app \
    && mkdir -p /data /state/outputs /state/userdata/chats /state/cache /state/retired \
    && chgrp -R 0 /app /state /data && chmod -R g=u /app /state /data
USER 10001

EXPOSE 8000
VOLUME ["/state"]

# Liveness only: unauthenticated, touches no dependency, answers "is this process serving?".
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/healthz" || exit 1

# tini as PID 1 so signals reach the app and orphaned grandchildren are reaped. uvicorn does
# handle SIGTERM and the lifespan does shut the per-user MCP subprocesses down cleanly, so
# this is defence against the untidy cases (a hard kill, a double-forking child), not a fix
# for a known leak.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "webapp/server.py"]
