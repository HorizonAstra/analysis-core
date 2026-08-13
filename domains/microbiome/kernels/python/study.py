"""Study loader for real platform CSV exports, organized as per-study folders.

Layout:
    data/
      <study_name>/
        Project_subjects.csv       (clinical)
        Project_samples.csv
        Project_metabolomics.csv
        Project_metagenomics.csv
        Project_events.csv

None of these files are mandatory. A folder is a study if it contains at least one
recognized table, and the loader builds from whatever is present — a study may be
clinical-only, a single omic, omics without a separate samples table, and so on.
Missing tables are simply absent from the assembled study (and noted in meta), never
a hard error.

Filenames matched by keyword (case-insensitive substring). Column names are
auto-detected from the actual file headers rather than assumed, so minor naming
differences across studies are handled without code changes.

Detected column roles:
  subject ID   : subject_id | study_id | patient_id | participant_id
  sample ID    : sample_id
  day/timeline : sample_collection | timeline_collected | day | timepoint | time
  rank column  : taxonomic_rank | taxonomy | rank | tax_rank | taxrank

Day convention: integer days relative to a per-study anchor of 0; negatives valid.

This module is the domain *assembler*: it shapes the raw tables into the in-memory
study (CLR matrix, spine, feature lists, meta). Where those tables physically live and
how they are read fast (Parquet/DuckDB) is the data layer's job — see the `datasource`
package. Reads here go through `datasource`, so the assembler never touches a path or a
CSV parser directly and the same code works when data moves to object storage later.
"""

from __future__ import annotations

import json
from pathlib import Path
import os
from functools import lru_cache

import numpy as np
import pandas as pd

from datasource import default_source, fingerprint as _fingerprint, read_tabular, resolve_files
from datasource.local import find_studies, resolve_study_dir, study_allowed  # noqa: F401 (re-export)

# This domain's own column roles, read from its own declaration. They used to be
# imported from the data layer, which had this domain's shape written into it.
_STUDY_SPEC = json.loads((Path(__file__).resolve().parents[2] / "study.json").read_text())
ROLE_KEYWORDS = {k: tuple(v) for k, v in (_STUDY_SPEC.get("roles") or {}).items()}

# ordered by preference; first match wins
_SUBJECT_ID_CANDIDATES = ("subject_id", "study_id", "patient_id", "participant_id")
_DAY_CANDIDATES        = ("sample_collection", "timeline_collected", "day", "timepoint", "time")
_RANK_CANDIDATES       = ("taxonomic_rank", "taxonomy", "rank", "tax_rank", "taxrank")
_EVENT_SUBJECT_CANDIDATES = ("subject_id", "study_id", "patient_id", "participant_id")
_EVENT_START_CANDIDATES   = ("event_start", "timeline_start", "start_day", "start")
_EVENT_END_CANDIDATES     = ("event_end",   "timeline_end",   "end_day",   "end")


def _pick(cols: list[str], candidates: tuple[str, ...]) -> str | None:
    low = {c.lower(): c for c in cols}
    for cand in candidates:
        if cand in low:
            return low[cand]
    return None


def _clr_matrix(wide: pd.DataFrame) -> pd.DataFrame:
    m = wide.fillna(0.0).astype(float)
    out = pd.DataFrame(index=m.index, columns=m.columns, dtype=float)
    for sid, row in m.iterrows():
        vals = row.values.copy()
        pos = vals[vals > 0]
        if pos.size == 0:
            out.loc[sid] = np.nan
            continue
        vals[vals == 0] = 0.5 * pos.min()
        vals = vals / vals.sum()
        logv = np.log(vals)
        out.loc[sid] = logv - logv.mean()
    return out


def _build_clade(clade: pd.DataFrame, rank: str) -> tuple[pd.DataFrame, dict]:
    notes: dict = {"clade_rank": rank}
    cols = list(clade.columns)

    rank_col = _pick(cols, _RANK_CANDIDATES)
    if rank_col is None:
        if "species" in [c.lower() for c in cols]:
            notes["clade_rank_col_missing"] = (
                f"No rank column found; treating all rows as species-level. "
                f"Columns: {cols}"
            )
            sub = clade.copy()
        else:
            notes["clade_skipped"] = f"No rank or species column found. Columns: {cols}"
            return pd.DataFrame(), pd.DataFrame(), notes
    else:
        # Which ranks this study actually carries, recorded before filtering to the
        # requested one. Without it there is no way to know that 'family' is a valid
        # rank here short of loading the study and seeing whether anything came back.
        levels = clade[rank_col].astype(str).str.lower().str.strip()
        notes["clade_ranks_available"] = sorted(x for x in levels.unique() if x and x != "nan")
        sub = clade[levels == rank].copy()

    # find the name column for the requested rank. In this schema each rank
    # has its own column (species/genus/family/order/...), so a family-level
    # row carries its name in the "family" column, not "species". Fall back to
    # "species" only when the rank column was missing (species-level default).
    name_candidates = (rank,) if rank_col is not None else ("species",)
    feat_col = _pick(list(sub.columns), name_candidates)
    if feat_col is None or feat_col not in sub.columns:
        notes["clade_skipped"] = (
            f"No name column for rank '{rank}' (looked for {name_candidates}). "
            f"Columns: {list(sub.columns)}"
        )
        return pd.DataFrame(), pd.DataFrame(), notes

    blank = sub[feat_col].isna() | (sub[feat_col].astype(str).str.strip() == "")
    notes["clade_rows_dropped_blank_name"] = int(blank.sum())
    sub = sub[~blank]

    if sub.empty:
        notes["clade_skipped"] = f"No rows remain after filtering to rank='{rank}'"
        return pd.DataFrame(), pd.DataFrame(), notes

    wide = sub.pivot_table(
        index="sample_id", columns=feat_col,
        values="relative_abundance", aggfunc="sum"
    )
    clr = _clr_matrix(wide)
    clr.columns = [f"clade:{c}" for c in clr.columns]
    notes["clade_n_features"] = int(clr.shape[1])
    notes["clade_n_samples"] = int(clr.shape[0])
    # wide is the raw relative-abundance matrix (sample x species), kept for alpha diversity
    return clr, wide, notes


def _build_metab(metab: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    notes: dict = {}
    m = metab.copy()
    m["feature"] = "metab:" + m["panel"].astype(str) + ":" + m["compound"].astype(str)
    notes["metab_duplicates_averaged"] = int(
        m.duplicated(subset=["sample_id", "feature"]).sum()
    )
    wide = m.pivot_table(
        index="sample_id", columns="feature",
        values="concentration", aggfunc="mean"
    )
    notes["metab_n_features"] = int(wide.shape[1])
    notes["metab_n_samples"] = int(wide.shape[0])
    return wide, notes


@lru_cache(maxsize=8)
def _load_cached(study_dir: str, rank: str, fingerprint: tuple) -> dict:
    files = resolve_files(study_dir)

    def _read(role):
        # read through the data layer (Parquet/DuckDB with a CSV fallback), not a raw
        # CSV parser — same DataFrame, faster, and swappable for a remote source later
        return read_tabular(files[role]) if role in files else None

    subjects_raw = _read("subjects")
    samples_raw  = _read("samples")
    metab_raw    = _read("metabolomics")
    clade_raw    = _read("metagenomics")
    events_raw   = _read("events")

    # omic feature blocks (each optional; a malformed table degrades to empty + note)
    try:
        clade_m, clade_abund, cnotes = (_build_clade(clade_raw, rank) if clade_raw is not None
                                        else (pd.DataFrame(), pd.DataFrame(), {}))
    except Exception as e:  # noqa: BLE001 - a bad omic table must not make the study unloadable
        clade_m, clade_abund, cnotes = pd.DataFrame(), pd.DataFrame(), {"clade_skipped": f"could not parse metagenomics: {e}"}
    try:
        metab_m, mnotes = _build_metab(metab_raw) if metab_raw is not None else (pd.DataFrame(), {})
    except Exception as e:  # noqa: BLE001
        metab_m, mnotes = pd.DataFrame(), {"metab_skipped": f"could not parse metabolomics: {e}"}

    # samples spine (optional): standardize sample_id / subject_id / day, filling what is absent
    subj_col = day_col = None
    if samples_raw is not None:
        samples = samples_raw.copy()
        subj_col = _pick(list(samples.columns), _SUBJECT_ID_CANDIDATES)
        day_col  = _pick(list(samples.columns), _DAY_CANDIDATES)
        samples = samples.rename(columns={c: n for c, n in ((subj_col, "subject_id"), (day_col, "day")) if c})
        if "sample_id" not in samples.columns:
            samples["sample_id"] = [f"s{i}" for i in range(len(samples))]
        if "subject_id" not in samples.columns:
            samples["subject_id"] = samples["sample_id"]
        if "day" not in samples.columns:
            samples["day"] = 0
    else:
        samples = None

    # the spine: from samples if present, else derived from the omic sample ids
    if samples is not None:
        spine = samples[["sample_id", "subject_id", "day"]].copy()
    else:
        ids = sorted(set(map(str, clade_m.index)) | set(map(str, metab_m.index)))
        spine = pd.DataFrame({"sample_id": ids, "subject_id": ids, "day": [0] * len(ids)})

    matrix = spine.set_index("sample_id")
    if not clade_m.empty:
        matrix = matrix.join(clade_m, how="left")
    if not metab_m.empty:
        matrix = matrix.join(metab_m, how="left")
    matrix = matrix.reset_index()

    # subjects (optional): derive a minimal table from the spine if absent
    if subjects_raw is not None:
        subjects = subjects_raw.copy()
        subj_col_s = _pick(list(subjects.columns), _SUBJECT_ID_CANDIDATES)
        if subj_col_s:
            subjects = subjects.rename(columns={subj_col_s: "subject_id"})
        if "subject_id" not in subjects.columns:
            subjects["subject_id"] = subjects.index.astype(str)
    else:
        subjects = pd.DataFrame({"subject_id": sorted(spine["subject_id"].dropna().unique())})

    # events (optional)
    if events_raw is not None:
        events = events_raw.copy()
        ev_subj  = _pick(list(events.columns), _EVENT_SUBJECT_CANDIDATES)
        ev_start = _pick(list(events.columns), _EVENT_START_CANDIDATES)
        ev_end   = _pick(list(events.columns), _EVENT_END_CANDIDATES)
        if ev_subj:  events = events.rename(columns={ev_subj:  "subject_id"})
        if ev_start: events = events.rename(columns={ev_start: "event_start"})
        if ev_end:   events = events.rename(columns={ev_end:   "event_end"})
    else:
        events = pd.DataFrame()

    clade_features = [c for c in matrix.columns if c.startswith("clade:")]
    metab_features = [c for c in matrix.columns if c.startswith("metab:")]
    per_subj = spine.groupby("subject_id").size() if len(spine) else pd.Series(dtype=int)

    subj_grouping_cols = [c for c in subjects.columns
                          if c != "subject_id" and subjects[c].nunique() <= 20]
    samp_grouping_cols = ([c for c in samples.columns
                           if c not in ("sample_id", "subject_id", "day") and samples[c].nunique() <= 20]
                          if samples is not None else [])

    day_vals = pd.to_numeric(spine["day"], errors="coerce").dropna() if len(spine) else pd.Series(dtype=float)
    day_range = [int(day_vals.min()), int(day_vals.max())] if len(day_vals) else None

    meta = {
        "study_dir":                study_dir,
        "available_tables":         sorted(files.keys()),
        "detected_columns": {
            "subject_id_col":   subj_col,
            "day_col":          day_col,
        },
        "n_subjects":               int(subjects["subject_id"].nunique()) if len(subjects) else 0,
        "n_samples":                int(len(spine)),
        "samples_per_subject_min":  int(per_subj.min()) if len(per_subj) else 0,
        "samples_per_subject_max":  int(per_subj.max()) if len(per_subj) else 0,
        "samples_per_subject_mean": round(float(per_subj.mean()), 2) if len(per_subj) else 0,
        "is_longitudinal":          bool(len(per_subj) and per_subj.max() > 1),
        "day_range":                day_range,
        "subject_columns":          list(subjects.columns),
        "sample_columns":           list(samples.columns) if samples is not None else [],
        "subject_grouping_cols":    subj_grouping_cols,
        "sample_grouping_cols":     samp_grouping_cols,
        "event_types":              sorted(
            events["event_type"].dropna().astype(str).unique().tolist()
            if "event_type" in events.columns else []
        ),
        "n_clade_features":         len(clade_features),
        "n_metab_features":         len(metab_features),
        "loader_notes":             {**cnotes, **mnotes},
    }

    return {
        "subjects":        subjects,
        "samples":         samples if samples is not None else spine.copy(),
        "events":          events,
        "matrix":          matrix,
        "clade_abundance": clade_abund,   # raw relative abundance (sample x species)
        "clade_features":  clade_features,
        "metab_features":  metab_features,
        "meta":            meta,
    }


def load_study(study: str, data_root: str = "data", rank: str = "species") -> dict:
    study_dir = resolve_study_dir(study, data_root)
    # access control: a study the caller may not see is reported as simply not found
    if not study_allowed(study_dir) or not os.path.isdir(study_dir):
        raise FileNotFoundError(f"study folder not found: {study_dir}")
    return _load_cached(study_dir, rank, _fingerprint(study_dir))


def list_study_files(study: str, data_root: str = "data") -> list[dict]:
    """Every file in the study folder, including raw files beyond the five assembled
    tables (qPCR, pathway, shortBRED, label exports, ...). Each entry notes which
    assembled role a recognized table fills, or None for an additional raw file that the
    standard load does not fold in but read_study_file can open. Delegates to the data
    layer so it works the same when data moves off local disk."""
    return default_source(data_root).list_files(study)


def read_study_file(study: str, filename: str, data_root: str = "data",
                    as_text: bool = False, columns: list[str] | None = None):
    """Open a raw file from a study folder as-is, beyond the five assembled tables.

    CSV/TSV parse to a DataFrame (optionally projected to `columns`), JSON to its Python
    value, anything else to text. Path-safe: the filename is resolved under the study
    directory and refused if it escapes. Reads the raw bytes, not the standardized/CLR
    matrix — the way in to qPCR, pathway, shortBRED and label-export tables."""
    return default_source(data_root).read_file(study, filename, as_text=as_text, columns=columns)


def search_features(study: dict, query: str, omic: str | None = None) -> list[str]:
    pools = []
    if omic in (None, "clade"):
        pools += study["clade_features"]
    if omic in (None, "metab"):
        pools += study["metab_features"]
    return [f for f in pools if query.lower() in f.lower()]


def features_for(study: dict, omic: str) -> list[str]:
    return study["clade_features"] if omic == "clade" else study["metab_features"]


def resolve_groups(study: dict, group_by: str) -> dict:
    """Map each sample_id to a group label from a subjects or samples column."""
    samples  = study["samples"]
    subjects = study["subjects"]
    if group_by in subjects.columns:
        m = samples.merge(subjects[["subject_id", group_by]], on="subject_id", how="left")
        return dict(zip(m["sample_id"], m[group_by]))
    if group_by in samples.columns:
        return dict(zip(samples["sample_id"], samples[group_by]))
    raise ValueError(
        f"group column '{group_by}' not found in subjects "
        f"{list(subjects.columns)} or samples {list(samples.columns)}"
    )
