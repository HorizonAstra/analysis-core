"""The spatial-transcriptomics study assembler.

The sibling of study.py for the `spatial-transcriptomics` domain. Where a microbiome
study assembles into one wide sample x feature matrix, a spatial study is a cohort of
independent samples, each carrying its own region structure and its own per-gene tables.
There is no single matrix to build, so this returns the cohort index plus lazy access to
each sample's tables rather than pre-loading nineteen samples' worth of gene rows.

Layout, one folder per sample under `samples/`:

    samples/<id>/optimal_svd.txt                         chosen settings + fit quality
                 DA_significant.txt                      genes passing the pipeline cutoff
                 SLAB_scores.txt                         per-gene spatial spread
                 DA_counts_by_node.txt                    genes separating each region pair
                 OptimalTree_pruned_node_compare_list.txt region pairs and their sizes
                 OptimalTree_pruned_node_compare_leaves.txt  spot -> region
                 OptimalTree_pruned_node_info.txt         region parentage and depth
                 OptimalTree_pruned.nw                    the pruned tree
                 barcodes_positions.txt                   spot coordinates (optional)

Every file is optional. A sample missing one is reported in the cohort index rather than
making the study unloadable, because a partial pipeline run is a normal state here and
the fact that it is partial is itself something the user needs to see.
"""

from __future__ import annotations

import os
import re

import pandas as pd

# Per-sample tables, by the role name the rest of the system uses. Filenames come from the
# pipeline and are matched exactly rather than auto-detected: unlike the microbiome domain
# these are tool output with fixed names, so a near-miss is a real problem to surface, not
# a naming convention to absorb.
SAMPLE_FILES = {
    "settings":       "optimal_svd.txt",
    "da":             "DA_significant.txt",
    "slab":           "SLAB_scores.txt",
    "region_counts":  "DA_counts_by_node.txt",
    "region_pairs":   "OptimalTree_pruned_node_compare_list.txt",
    "region_spots":   "OptimalTree_pruned_node_compare_leaves.txt",
    "region_info":    "OptimalTree_pruned_node_info.txt",
    "tree":           "OptimalTree_pruned.nw",
    "positions":      "barcodes_positions.txt",
}

# What a run recorded about itself. `optimal_svd.txt` is "Key: value" lines with comments,
# not a table, so it is parsed rather than read.
_SETTINGS_KEYS = {
    "SVD_Number":        "svd",
    "NodeCor":           "node_cor",
    "Support_Threshold": "support_threshold",
    "Spatial_Threshold": "spatial_threshold",
    "KNN":               "knn",
}
_SETTING_LINE = re.compile(r"^\s*([A-Za-z_]+)\s*:\s*(\S+)")


def _num(v: str):
    try:
        f = float(v)
        return int(f) if f.is_integer() else f
    except (TypeError, ValueError):
        return None


def parse_settings(path: str) -> dict:
    """Chosen hyperparameters and fit quality from one sample's optimal_svd.txt.

    NodeCor is the correlation between predicted and actual spot locations, so it is the
    run's own measure of how well its regions reproduce the tissue. There is no external
    benchmark for what counts as good, which is why the cohort view compares samples
    against each other rather than against a threshold.
    """
    out: dict = {}
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if line.lstrip().startswith("#"):
                    continue
                m = _SETTING_LINE.match(line)
                if m and m.group(1) in _SETTINGS_KEYS:
                    out[_SETTINGS_KEYS[m.group(1)]] = _num(m.group(2))
    except OSError:
        pass
    return out


def sample_dir(study_dir: str, sample: str) -> str:
    return os.path.join(study_dir, "samples", sample)


def sample_file(study_dir: str, sample: str, role: str) -> str | None:
    """Path to one of a sample's tables, or None when that file was not produced."""
    name = SAMPLE_FILES.get(role)
    if not name:
        raise KeyError(f"unknown spatial role '{role}' (have: {sorted(SAMPLE_FILES)})")
    p = os.path.join(sample_dir(study_dir, sample), name)
    return p if os.path.isfile(p) else None


def read_sample_table(study_dir: str, sample: str, role: str) -> pd.DataFrame | None:
    """One of a sample's tab-separated tables, or None when absent. Read on demand: the
    cohort's gene tables together are large enough that eager loading would cost more
    than any single question needs."""
    p = sample_file(study_dir, sample, role)
    if p is None or role in ("settings", "tree"):
        return None
    return pd.read_csv(p, sep="\t")


def list_samples(study_dir: str) -> list[str]:
    root = os.path.join(study_dir, "samples")
    if not os.path.isdir(root):
        return []
    return sorted(n for n in os.listdir(root)
                  if not n.startswith(".") and os.path.isdir(os.path.join(root, n)))


def gene_symbols(study_dir: str) -> pd.DataFrame:
    """Ensembl accession to gene symbol, empty when the study carries no map.

    Kept separate from the sample tables because every one of them keys genes by accession
    and an unmapped accession is unreadable to a user. Callers join on `ensembl_gene_id`.
    """
    for name in sorted(os.listdir(study_dir)) if os.path.isdir(study_dir) else []:
        if "gene" not in name.lower() or not name.lower().endswith((".csv", ".tsv", ".txt")):
            continue
        p = os.path.join(study_dir, name)
        if not os.path.isfile(p):
            continue
        sep = "," if name.lower().endswith(".csv") else "\t"
        try:
            df = pd.read_csv(p, sep=sep, usecols=lambda c: c in ("ensembl_gene_id", "external_gene_name"))
        except Exception:  # noqa: BLE001 - a malformed map must not make the study unloadable
            continue
        if {"ensembl_gene_id", "external_gene_name"} <= set(df.columns):
            return df.dropna(subset=["ensembl_gene_id"]).drop_duplicates("ensembl_gene_id")
    return pd.DataFrame(columns=["ensembl_gene_id", "external_gene_name"])


def _line_count(path: str | None) -> int | None:
    """Rows in a headed table, without parsing it."""
    if path is None:
        return None
    try:
        with open(path, "rb") as f:
            n = sum(1 for _ in f)
        return max(n - 1, 0)
    except OSError:
        return None


def cohort_index(study_dir: str) -> pd.DataFrame:
    """One row per sample: its settings, its fit, its size, and what it is missing.

    This is the study's spine and the first thing worth looking at, because it says which
    runs are usable before anything is read into them. `missing` names files the pipeline
    did not leave behind, which is a property of the run rather than an error here.
    """
    rows = []
    for s in list_samples(study_dir):
        settings_path = sample_file(study_dir, s, "settings")
        row: dict = {"sample_id": s}
        row.update(parse_settings(settings_path) if settings_path else {})
        row["n_regions"] = _line_count(sample_file(study_dir, s, "region_counts"))
        row["n_spots"] = _line_count(sample_file(study_dir, s, "region_spots"))
        row["n_da_genes"] = _line_count(sample_file(study_dir, s, "da"))
        row["has_positions"] = sample_file(study_dir, s, "positions") is not None
        row["missing"] = ",".join(r for r in SAMPLE_FILES
                                  if sample_file(study_dir, s, r) is None)
        rows.append(row)
    df = pd.DataFrame(rows)
    # n_spots counts spot-to-region assignments, and a spot can sit in several nested
    # regions, so it is an assignment count rather than a spot count. Named plainly.
    return df.rename(columns={"n_spots": "n_spot_assignments"})


def load(study_dir: str) -> dict:
    """Assemble a spatial study: its cohort index, its samples, and its gene map.

    Deliberately not a matrix. The per-sample gene tables stay on disk and are read
    through `read_sample_table` when a question actually needs them.
    """
    samples = list_samples(study_dir)
    index = cohort_index(study_dir)
    symbols = gene_symbols(study_dir)
    cohort = None
    for name in sorted(os.listdir(study_dir)) if os.path.isdir(study_dir) else []:
        if "cohort" in name.lower() and name.lower().endswith(".csv"):
            try:
                cohort = pd.read_csv(os.path.join(study_dir, name))
            except Exception:  # noqa: BLE001
                cohort = None
            break
    if cohort is not None and "sample_id" in cohort.columns:
        index = index.merge(cohort, on="sample_id", how="left")

    incomplete = index.loc[index["missing"].astype(bool), "sample_id"].tolist() if len(index) else []
    return {
        "domain":     "spatial-transcriptomics",
        "study_dir":  study_dir,
        "samples":    samples,
        "index":      index,
        "symbols":    symbols,
        "meta": {
            "n_samples":        len(samples),
            "has_symbol_map":   not symbols.empty,
            "has_cohort_table": cohort is not None,
            # group labels are the researcher's to supply; the pipeline never produces them
            "label_columns":    [c for c in (cohort.columns if cohort is not None else [])
                                 if c != "sample_id"],
            "incomplete_samples": incomplete,
        },
    }
