"""Site: the CRI "Randi" cluster (UChicago) — WHERE work runs, not how.

Everything machine-specific about Randi lives here and nowhere else: the SSH target, the
directory layout, which roots a run may write to, and where outputs land. The backend
(SLURM over SSH) and the pipeline (biobakery) are both site-agnostic, so pointing the same
pipeline at a different cluster means adding a sibling module here — not editing either.

The capability is enabled ONLY when RANDI_SSH_HOST is set, mirroring the toolkit's rule
that a tool the user cannot actually use is not offered. Every path defaults to rijul's
locations, and the two allowed write roots are baked in as defaults so a misconfiguration
cannot silently widen where runs may write.
"""

from __future__ import annotations

import os

from compute.backends.registry import JobRegistry
from compute.backends.slurm_ssh import SlurmSshBackend
from compute.base import WriteScope
from compute.secondary.biobakery import BiobakeryLauncher

NAME = "randi-slurm"


def _lab() -> str:
    return os.environ.get("RANDI_LAB_DIR") or "/gpfs/data/dfi-cores/rijul"


def _scratch() -> str:
    return os.environ.get("RANDI_SCRATCH_DIR") or "/scratch/rijulsareen"


def _repo() -> str:
    return os.environ.get("RANDI_REPO_DIR") or f"{_lab()}/local-biobakery"


def _output_base() -> str:
    # Outputs default to SCRATCH (the large-quota space; purges on ~30d inactivity), NOT the
    # dfi-cores lab quota. Deep/many-sample HUMAnN output is GB-scale, so it doesn't belong on
    # the lab share; keepers get moved off scratch before purge (a later, separate step).
    return os.environ.get("RANDI_OUTPUT_DIR") or f"{_scratch()}/studies"


def enabled() -> bool:
    """True when this site is configured (so the secondary tools should be offered)."""
    return bool(os.environ.get("RANDI_SSH_HOST"))


def write_scope() -> WriteScope:
    """The only two roots any run here may write under."""
    return WriteScope((_lab(), _scratch()))


def default_paths(study: str, combo: str, label: str | None = None) -> tuple[str, str]:
    """A run's output + scratch, keyed by study AND combo so concurrent runs never collide:
    different studies (or different combos of one study) get separate dirs, hence separate
    AnADAMA tracking DBs. An optional `label` adds a third level, so you can run multiple
    INDEPENDENT instances of the same study+combo at once (e.g. reproducibility batches) --
    without a label, re-running a study+combo reuses one dir (resume). Both paths live under
    the scratch root (an allowed write dir)."""
    sub = f"{study}/{combo}" + (f"/{label}" if label else "")
    return (f"{_output_base()}/{sub}/output", f"{_scratch()}/local-biobakery/{sub}")


def backend(registry_path: str) -> SlurmSshBackend | None:
    """The biobakery-on-Randi backend, or None when unconfigured.

    Composes the three axes: the SLURM/ssh execution model, this site's host + dirs +
    write scope, and the biobakery pipeline's launcher.
    """
    host = os.environ.get("RANDI_SSH_HOST")
    if not host:
        return None
    return SlurmSshBackend(
        ssh_host=host,
        work_dir=_repo(),
        registry=JobRegistry(registry_path),
        write_scope=write_scope(),
        launcher=BiobakeryLauncher(),
        name=NAME,
    )
