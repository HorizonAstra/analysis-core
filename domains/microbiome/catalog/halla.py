"""HAllA — WHAT runs for tertiary cross-omic association (taxa <-> metabolites).

Phase: tertiary. Domain: microbiome (any two feature blocks, really). Execution: the local
synchronous Python-CLI backend (compute/backends/pycli.py), in HAllA's own env under
envs/halla/.

HAllA answers a question neither MaAsLin nor LEfSe does: given TWO feature sets measured on
the same samples, which BLOCKS of features associate with each other. It hierarchically
clusters each side, tests cluster against cluster, and reports significant blocks — which is
how you get "this group of taxa tracks this group of metabolites" rather than 954 x 50
independent p-values.

Note it is not pure Python: it calls R through rpy2 (XICOR, eva) at import time, which is why
its env carries a private R library and the runner is handed R_LIBS_USER.
"""

from __future__ import annotations

from pathlib import Path

import pandas as pd

from compute.backends.pycli import PyCliError, available, run_cli

ENV_NAME = "halla"
CLI = "halla"

#: HAllA's own R library, built beside its venv (see envs/halla/build.sh).
_RLIB = Path(__file__).resolve().parents[3] / "envs" / ENV_NAME / "rlib"

#: Association metrics HAllA supports for the pairwise distance.
METRICS = ("spearman", "pearson", "dcor", "mi", "nmi", "xicor")


def enabled() -> bool:
    """True when HAllA can actually run here (its env is built)."""
    return available(ENV_NAME, CLI)


def run_halla(
    x: pd.DataFrame,
    y: pd.DataFrame,
    work_dir: str,
    *,
    metric: str = "spearman",
    fdr_alpha: float = 0.05,
    fdr_method: str = "fdr_bh",
    permute_iters: int | None = None,
    seed: int = 0,
    x_label: str = "X",
    y_label: str = "Y",
    hallagram: bool = True,
    num_threads: int | None = None,
    timeout: int | None = None,
) -> dict:
    """Run HAllA on two aligned feature tables and return its outputs.

    x, y   samples x features, SAME sample_id index (the caller aligns and filters them).
           Written out transposed, since HAllA wants one row per feature.
    metric one of METRICS; 'spearman' is HAllA's default and the safe choice for
           monotonic-but-not-linear omic relationships.

    Returns output paths plus the parsed association and significant-block tables.
    Raises PyCliError on failure.
    """
    if metric not in METRICS:
        raise PyCliError(f"unknown metric '{metric}'; choose one of {METRICS}")

    work = Path(work_dir)
    work.mkdir(parents=True, exist_ok=True)
    x_tsv, y_tsv, out_dir = work / "x.tsv", work / "y.tsv", work / "halla"

    # features as rows, samples as columns
    x.T.rename_axis("feature").to_csv(x_tsv, sep="\t")
    y.T.rename_axis("feature").to_csv(y_tsv, sep="\t")

    args = ["-x", str(x_tsv), "-y", str(y_tsv), "-o", str(out_dir),
            "-m", metric, "--fdr_alpha", str(fdr_alpha), "--fdr_method", fdr_method,
            "--seed", str(seed), "--x_dataset_label", x_label, "--y_dataset_label", y_label,
            "--no_progress",   # progress bars would just fill the captured log
            # PNG, not HAllA's default PDF: the workspace renders an image inline, while a
            # PDF is opaque bytes the user has to download to see.
            "--plot_file_type", "png"]
    if permute_iters is not None:
        args += ["--permute_iters", str(permute_iters)]
    if num_threads:
        args += ["--num_threads", str(num_threads)]
    args += ["--hallagram"] if hallagram else ["--no_hallagram"]

    proc = run_cli(ENV_NAME, CLI, args,
                   extra_env={"R_LIBS_USER": str(_RLIB)}, timeout=timeout)
    (work / "run.log").write_text(
        (proc.stdout or "") + "\n----- STDERR -----\n" + (proc.stderr or ""))

    def _path(name: str) -> str | None:
        p = out_dir / name
        return str(p) if p.exists() else None

    def _read(name: str) -> pd.DataFrame:
        p = out_dir / name
        return pd.read_csv(p, sep="\t") if p.exists() else pd.DataFrame()

    # HAllA signals success by writing its tables, not by an exit sentinel; treat a missing
    # associations table as the failure (its exit code is not reliable on partial runs).
    associations = _read("all_associations.txt")
    if proc.returncode != 0 and associations.empty:
        tail = "\n".join((proc.stderr or proc.stdout or "").splitlines()[-25:])
        raise PyCliError(f"halla failed (rc={proc.returncode}). Last lines:\n{tail}")

    plot = next((_path(f"hallagram.{ext}") for ext in ("png", "pdf")
                 if _path(f"hallagram.{ext}")), None)
    return {
        "output_dir": str(out_dir),
        "associations_path": _path("all_associations.txt"),
        "sig_clusters_path": _path("sig_clusters.txt"),
        "hallagram_path": plot,
        "associations": associations,
        "sig_clusters": _read("sig_clusters.txt"),
        "returncode": proc.returncode,
    }
