"""Spatial statistics over pipeline output: joining effect to spread, summarizing region
structure, and counting recurrence across a cohort.

Pure primitives over DataFrames. Loading lives in spatial_study.py; nothing here touches
disk. Two conventions the pipeline sets and these functions preserve:

  * genes are Ensembl accessions in a column named `DA_Object`;
  * significance is the pipeline's own permutation-based flag, not an FDR. Nothing here
    recomputes it, because a Benjamini-Hochberg q on the same data answers a different
    question and the two are not comparable.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

# Where a gene sits on the two axes. Effect is how much it changed between a region and
# its neighbour; spread is what fraction of the tissue carries that bias. They are
# independent, and the pair is more informative than either alone: the same effect size
# means something different in one corner of the tissue than across all of it.
_QUADRANTS = {
    (True, True):   "strong, widespread",
    (True, False):  "strong, focal",
    (False, True):  "mild, widespread",
    (False, False): "mild, focal",
}


def map_symbols(df: pd.DataFrame, symbols: pd.DataFrame,
                on: str = "DA_Object") -> pd.DataFrame:
    """Add a `gene` column of readable symbols beside the Ensembl accessions.

    Accessions that have no symbol keep the accession as their label rather than becoming
    blank, so a row is never silently unidentifiable. A no-op when no map was supplied.
    """
    out = df.copy()
    if symbols is None or symbols.empty or on not in out.columns:
        out["gene"] = out[on] if on in out.columns else None
        return out
    m = dict(zip(symbols["ensembl_gene_id"], symbols["external_gene_name"]))
    out["gene"] = [m.get(a) or a for a in out[on]]
    return out


def slab_by_gene(slab: pd.DataFrame) -> pd.DataFrame:
    """Collapse the pipeline's SLAB table to one row per gene.

    Read `sg_slab_score.jl` before changing this. SLAB's `Dir` is a property of *spots*,
    not of a region comparison: spots inside a node get the gene's node-versus-sibling
    direction, and spots in the sibling get the inverse of it, then everything is pooled
    across the whole sample. `Both` is a third value, for spots carrying an up and a down
    bias from different comparisons.

    So a SLAB score describes a gene across the entire sample and cannot be attributed to
    one region pair. It is reshaped here into `spread_up`, `spread_down`, `spread_both`,
    and `spread`, the largest of them, which is the gene's overall spatial reach.
    """
    if slab is None or slab.empty or "DA_Object" not in slab.columns:
        return pd.DataFrame(columns=["DA_Object", "spread", "spread_dir"])
    s = slab.copy()
    if "Dir" not in s.columns:
        s["Dir"] = "Up"
    wide = (s.pivot_table(index="DA_Object", columns="Dir", values="SLAB", aggfunc="max")
             .rename(columns={"Up": "spread_up", "Down": "spread_down", "Both": "spread_both"})
             .reset_index())
    for c in ("spread_up", "spread_down", "spread_both"):
        if c not in wide.columns:
            wide[c] = np.nan
    parts = wide[["spread_up", "spread_down", "spread_both"]]
    wide["spread"] = parts.max(axis=1)
    # which direction that largest score came from, so the number is never read bare
    wide["spread_dir"] = parts.idxmax(axis=1).str.replace("spread_", "", regex=False)
    wide.loc[wide["spread"].isna(), "spread_dir"] = None
    if "Spots" in s.columns:
        wide = wide.merge(s.groupby("DA_Object")["Spots"].max().rename("spots_total").reset_index(),
                          on="DA_Object", how="left")
    return wide


def da_slab_join(da: pd.DataFrame, slab: pd.DataFrame,
                 symbols: pd.DataFrame | None = None,
                 spread_cut: float | None = None) -> pd.DataFrame:
    """One gene table carrying both effect and spatial spread, with a quadrant label.

    `da` is the pipeline's significant-gene table, one row per gene per region comparison
    (DA_Object, Mean_Node, Mean_Sibling, P, Node, Sibling). `slab` is its spread table,
    which is per gene for the whole sample rather than per comparison (see `slab_by_gene`).
    They are therefore joined on the gene alone. Spread is repeated across a gene's region
    rows because it genuinely is one whole-sample number, not a per-region one, and
    `spread_scope` records that so the column is never read as region-specific.

    Effect is `Mean_Node - Mean_Sibling`, the difference the pipeline itself measured,
    positive when the gene sits higher in the region than in its neighbour. Genes are split
    at the median of each axis, making the quadrants a statement about this sample rather
    than an absolute cutoff; pass `spread_cut` to fix the spread split instead. Rows keep
    the pipeline's own significance and nothing is retested.
    """
    if da is None or da.empty:
        return pd.DataFrame()

    out = da.copy()
    if {"Mean_Node", "Mean_Sibling"} <= set(out.columns):
        out["effect"] = out["Mean_Node"].astype(float) - out["Mean_Sibling"].astype(float)
        out["direction"] = np.where(out["effect"] >= 0, "Up", "Down")
    else:
        out["effect"] = np.nan
        out["direction"] = None

    by_gene = slab_by_gene(slab)
    if not by_gene.empty:
        out = out.merge(by_gene, on="DA_Object", how="left")
        out["spread_scope"] = "whole sample"
    else:
        out["spread"] = np.nan
        out["spread_scope"] = None

    out["abs_effect"] = out["effect"].abs()
    strong = (out["abs_effect"] > out["abs_effect"].median()
              if out["abs_effect"].notna().any() else pd.Series(False, index=out.index))
    if spread_cut is not None:
        wide = out["spread"] > spread_cut
    else:
        wide = (out["spread"] > out["spread"].median()
                if out["spread"].notna().any() else pd.Series(False, index=out.index))
    strong, wide = strong.fillna(False), wide.fillna(False)
    out["quadrant"] = [_QUADRANTS[(bool(s), bool(w))] for s, w in zip(strong, wide)]

    out = map_symbols(out, symbols)
    front = [c for c in ("gene", "DA_Object", "Node", "Sibling", "direction", "effect",
                         "spread", "spread_dir", "quadrant", "P") if c in out.columns]
    return out[front + [c for c in out.columns if c not in front]]


def region_summary(pairs: pd.DataFrame, counts: pd.DataFrame,
                   info: pd.DataFrame | None = None) -> pd.DataFrame:
    """Region pairs ranked by how many genes actually separate them.

    `pairs` is the region-versus-neighbour list (Parent, Node, Node_Leaves, Sibling,
    Sibling_Leaves_Total); `counts` is genes passing the cutoff per region
    (Node, DA_Gene_Count); `info` adds parentage (Node, N_Leafs, Parent, Sibling).

    The ranking matters because region count on its own says nothing: a sample often
    partitions into many boundaries that separate one gene or none, alongside a few that
    separate hundreds. A region with no entry in `counts` separated nothing, which is
    recorded as zero rather than dropped, since "this split is empty" is a finding.
    """
    if pairs is None or pairs.empty:
        return pd.DataFrame()
    out = pairs.copy()
    if counts is not None and not counts.empty and {"Node", "DA_Gene_Count"} <= set(counts.columns):
        out = out.merge(counts[["Node", "DA_Gene_Count"]].drop_duplicates("Node"),
                        on="Node", how="left")
    else:
        out["DA_Gene_Count"] = np.nan
    out["DA_Gene_Count"] = out["DA_Gene_Count"].fillna(0).astype(int)

    if info is not None and not info.empty and "Node" in info.columns:
        extra = [c for c in ("N_Leafs", "Num_Siblings") if c in info.columns]
        if extra:
            out = out.merge(info[["Node"] + extra].drop_duplicates("Node"), on="Node", how="left")

    out = out.rename(columns={"Node_Leaves": "region_spots",
                              "Sibling_Leaves_Total": "neighbour_spots",
                              "DA_Gene_Count": "genes_separating"})
    if {"region_spots", "neighbour_spots"} <= set(out.columns):
        total = out["region_spots"].astype(float) + out["neighbour_spots"].astype(float)
        # how lopsided the split is; 0.5 is an even division
        out["balance"] = (out[["region_spots", "neighbour_spots"]].min(axis=1) / total).round(4)

    front = [c for c in ("Node", "Sibling", "Parent", "region_spots", "neighbour_spots",
                         "balance", "genes_separating") if c in out.columns]
    return (out[front + [c for c in out.columns if c not in front]]
            .sort_values("genes_separating", ascending=False, ignore_index=True))


def strongest_per_sample(da: pd.DataFrame, n: int, on: str = "DA_Object") -> pd.DataFrame:
    """A sample's `n` strongest genes by absolute effect, one row each.

    Exists because plain recurrence over the pipeline's full significant list does not
    discriminate: a sample can carry tens of thousands of significant gene-by-region rows,
    so appearing in most samples is the default state rather than a signal. Ranking each
    sample first and then counting asks the sharper question, which genes are *prominent*
    in sample after sample. A gene's effect here is its largest across that sample's
    regions, since it may be significant in several.
    """
    if da is None or da.empty or on not in da.columns:
        return pd.DataFrame(columns=[on, "effect"])
    if not {"Mean_Node", "Mean_Sibling"} <= set(da.columns):
        return da[[on]].drop_duplicates().head(n)
    e = (da["Mean_Node"].astype(float) - da["Mean_Sibling"].astype(float)).abs()
    return (da.assign(effect=e).groupby(on)["effect"].max()
              .nlargest(n).reset_index())


def feature_recurrence(per_sample: dict[str, pd.DataFrame], on: str = "DA_Object",
                       min_samples: int = 1, symbols: pd.DataFrame | None = None) -> pd.DataFrame:
    """How many samples each feature turns up in, given one table per sample.

    Domain agnostic: it counts set membership across samples and nothing else, so it is
    valid wherever "how often does this recur" is the question. Counting is all it does
    deliberately — the pipeline already decided what counts as significant in each sample,
    and re-deriving that here would replace its criterion with a different one.

    A feature present twice in one sample (two regions) counts once for that sample, so
    the result is samples-recurred-in, not total occurrences.
    """
    seen: dict[str, set[str]] = {}
    for sample, df in (per_sample or {}).items():
        if df is None or df.empty or on not in df.columns:
            continue
        for f in set(df[on].dropna().astype(str)):
            seen.setdefault(f, set()).add(sample)

    n_samples = len({s for s, d in (per_sample or {}).items() if d is not None and not d.empty})
    rows = [{on: f, "n_samples": len(s), "samples": ",".join(sorted(s))}
            for f, s in seen.items() if len(s) >= min_samples]
    out = pd.DataFrame(rows, columns=[on, "n_samples", "samples"])
    if out.empty:
        return out
    out["fraction_of_samples"] = (out["n_samples"] / n_samples).round(4) if n_samples else np.nan
    out = map_symbols(out, symbols, on=on)
    return out.sort_values(["n_samples", on], ascending=[False, True], ignore_index=True)
