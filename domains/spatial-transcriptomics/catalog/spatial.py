"""Curated tools for the spatial-transcriptomics domain.

Thin, like the other curated tools: load the study, call a primitive, persist the result.
Almost nothing here is new statistics — the pipeline already tested and called its own
significance, and three of these four tools read and join what it produced. That is the
point. Re-deriving significance with a general test would silently replace the pipeline's
criterion with a different one, so nothing here does.
"""

from __future__ import annotations

import context
from analysis.domains.spatial_transcriptomics import stats as _sp
from analysis.domains.spatial_transcriptomics import study as _ss


def _rows(df, top_n: int | None = None) -> list[dict]:
    if df is None or df.empty:
        return []
    return (df.head(top_n) if top_n else df).to_dict("records")


def _samples_arg(requested, available: list[str]):
    """Resolve the `sample` argument to a list of sample ids.

    None or "all" means every sample. A tool that only ever answers for one sample forces
    the caller to loop, and a cohort question then costs one round trip per sample; the
    work itself is the same either way, so the batch is the default and a single name is
    just the shortest case of it.
    """
    if requested in (None, "", "all", "*"):
        return list(available), None
    names = [requested] if isinstance(requested, str) else list(requested)
    unknown = [n for n in names if n not in available]
    if unknown:
        return None, {"error": f"unknown sample(s): {', '.join(unknown)}",
                      "available_samples": available}
    return names, None


def register(mcp) -> None:
    @mcp.tool()
    @context.guarded("spatial run quality")
    def spatial_run_quality(study: str) -> str:
        """Per-sample run settings and fit quality across a spatial study: the first thing
        to check, because it says which samples are worth interpreting at all.

        Reports each sample's chosen hyperparameters, its NodeCor (how well its regions
        reproduce the real tissue geography, 0 to 1), how many region boundaries it found,
        and anything the pipeline did not produce for it. There is no external benchmark
        for a good NodeCor, so read it by comparing samples against each other and treat
        a sample far below the rest as suspect rather than as a finding. Saved to the
        workspace.
        """
        st, _d, err = context.load_spatial_or_error(study)
        if err:
            return err
        idx = st["index"]
        cor = idx["node_cor"].dropna() if "node_cor" in idx.columns else None
        res = {
            "study": study,
            "n_samples": st["meta"]["n_samples"],
            "samples": _rows(idx),
            "node_cor_summary": ({"min": round(float(cor.min()), 4),
                                  "median": round(float(cor.median()), 4),
                                  "max": round(float(cor.max()), 4),
                                  "weakest_samples": idx.nsmallest(3, "node_cor")["sample_id"].tolist()}
                                 if cor is not None and not cor.empty else None),
            "incomplete_samples": st["meta"]["incomplete_samples"],
            "has_symbol_map": st["meta"]["has_symbol_map"],
            "label_columns": st["meta"]["label_columns"],
            "note": ("NodeCor has no absolute threshold; compare samples against each "
                     "other. Group labels are not produced by the pipeline and only "
                     "exist if a label column is listed above."),
        }
        res["saved_to"] = context.persist(study, "spatial_run_quality", res, "result",
                                          "primitive: spatial_run_quality")
        return context.dump(res)

    @mcp.tool()
    @context.guarded("spatial regions")
    def spatial_regions(study: str, sample=None, top_n: int = 20) -> str:
        """Regions ranked by how many genes actually separate each region from its
        neighbour. Covers every sample in one call by default; pass `sample` (a name or a
        list) to narrow it.

        A region count on its own says nothing: a tumour often splits into many boundaries
        that separate one gene or none, alongside a few that separate hundreds. This
        ranking is what identifies the sample's real internal divisions. `balance` is how
        evenly a split divides its spots, where 0.5 is even and a small value means a
        sliver against the rest. Region identifiers are internal to one sample and must
        never be compared across samples. Saved to the workspace.
        """
        st, d, err = context.load_spatial_or_error(study)
        if err:
            return err
        names, bad = _samples_arg(sample, st["samples"])
        if bad:
            return context.dump(bad)

        per_sample, detail = [], {}
        for s in names:
            regions = _sp.region_summary(_ss.read_sample_table(d, s, "region_pairs"),
                                         _ss.read_sample_table(d, s, "region_counts"),
                                         _ss.read_sample_table(d, s, "region_info"))
            if regions.empty:
                per_sample.append({"sample": s, "error": "no region tables"})
                continue
            sep = regions["genes_separating"]
            top = regions.iloc[0]
            per_sample.append({
                "sample": s,
                "n_regions": int(len(regions)),
                "n_regions_separating_nothing": int((sep == 0).sum()),
                "max_genes_separating": int(sep.max()),
                "top_region": top.get("Node"), "top_neighbour": top.get("Sibling"),
                "top_region_spots": top.get("region_spots"),
                "top_neighbour_spots": top.get("neighbour_spots"),
                "top_balance": top.get("balance"),
            })
            detail[s] = _rows(regions, top_n)

        per_sample.sort(key=lambda r: r.get("max_genes_separating", -1), reverse=True)
        res = {
            "study": study, "samples": names, "n_samples": len(names),
            "per_sample": per_sample,
            "note": "Region ids are internal to a sample; the same number in another "
                    "sample is an unrelated region, so they are never compared directly.",
        }
        # the full ranking only when one sample was asked for; across a cohort it is
        # thousands of rows and the per-sample summary is the answer
        if len(names) == 1:
            res["regions"] = detail[names[0]]
        else:
            res["top_regions_by_sample"] = {s: rows[:3] for s, rows in detail.items()}
        tag = names[0] if len(names) == 1 else "all"
        res["saved_to"] = context.persist(study, f"spatial_regions_{tag}", res, "result",
                                          "primitive: spatial_regions")
        return context.dump(res)

    @mcp.tool()
    @context.guarded("spatial genes")
    def spatial_genes(study: str, sample=None, node: str | int | None = None,
                      direction: str | None = None, top_n: int = 25,
                      sort_by: str = "effect") -> str:
        """Genes with effect and spatial spread side by side, symbols mapped. Covers every
        sample in one call by default; pass `sample` (a name or a list) to narrow it.

        Effect is how much a gene differs between a region and its neighbour. Spread is
        what fraction of the tissue's spots carry that bias, which is a different question:
        a widespread bias is often a mild field effect rather than a strong one. `quadrant`
        crosses the two. Filter to one region with `node` (from spatial_regions) and to
        'Up' or 'Down' with `direction`. sort_by: 'effect' or 'spread'.

        Significance is the pipeline's own permutation-based flag, which is a stricter and
        different criterion than an FDR. It is reported as given and never recomputed, so
        do not compare these p-values against a q-value from another tool. Saved to the
        workspace.
        """
        st, d, err = context.load_spatial_or_error(study)
        if err:
            return err
        names, bad = _samples_arg(sample, st["samples"])
        if bad:
            return context.dump(bad)
        frames = []
        for s in names:
            g = _sp.da_slab_join(_ss.read_sample_table(d, s, "da"),
                                 _ss.read_sample_table(d, s, "slab"), st["symbols"])
            if not g.empty:
                frames.append(g.assign(sample=s))
        if not frames:
            return context.dump({"error": "no significant-gene tables for those samples",
                                 "samples": names})
        import pandas as _pd
        genes = _pd.concat(frames, ignore_index=True)
        total = len(genes)
        if node is not None and "Node" in genes.columns:
            genes = genes[genes["Node"].astype(str) == str(node)]
        if direction and "direction" in genes.columns:
            genes = genes[genes["direction"].str.lower() == direction.strip().lower()]
        if genes.empty:
            return context.dump({"error": "no genes match that filter",
                                 "samples": names, "node": node, "direction": direction})
        key = "spread" if sort_by == "spread" else "abs_effect"
        if key in genes.columns:
            genes = genes.sort_values(key, ascending=False, na_position="last")
        res = {
            "study": study, "samples": names,
            "filters": {"node": node, "direction": direction, "sort_by": sort_by},
            "n_genes_total": int(total), "n_genes_shown": int(min(top_n, len(genes))),
            "n_genes_matching": int(len(genes)),
            "genes": _rows(genes, top_n),
            "note": ("Significance is the pipeline's permutation cutoff, not an FDR. "
                     "Spread is how widespread a bias is, not how strong."),
        }
        tag = names[0] if len(names) == 1 else "all"
        res["saved_to"] = context.persist(study, f"spatial_genes_{tag}", res, "result",
                                          "primitive: spatial_genes")
        return context.dump(res)

    @mcp.tool()
    @context.guarded("gene recurrence")
    def gene_recurrence(study: str, min_samples: int = 2, top_n: int = 40,
                        per_sample_top: int | None = 100) -> str:
        """How many samples each gene is prominent in, across the whole study.

        The first genuinely cohort-level view: a gene that recurs in patient after patient
        is a different kind of claim than one standing out in a single tumour. Counting
        only, with no further test, because each sample's significance was already decided
        by the pipeline.

        `per_sample_top` first restricts each sample to its strongest genes by effect, and
        it matters. Over the pipeline's full significant lists, recurrence does not
        discriminate at all: roughly half of all genes seen appear in fifteen or more of
        these samples, so recurring is the default rather than a signal. Set it to None to
        count over the full lists anyway, and read the result knowing that. Saved to the
        workspace.
        """
        st, d, err = context.load_spatial_or_error(study)
        if err:
            return err
        raw = {s: _ss.read_sample_table(d, s, "da") for s in st["samples"]}
        contributing = [s for s, t in raw.items() if t is not None and not t.empty]
        per = ({s: _sp.strongest_per_sample(t, per_sample_top) for s, t in raw.items()}
               if per_sample_top else raw)
        rec = _sp.feature_recurrence(per, min_samples=min_samples, symbols=st["symbols"])
        if rec.empty:
            return context.dump({"error": "no genes recur in that many samples",
                                 "min_samples": min_samples,
                                 "samples_with_results": len(contributing)})
        n = len(contributing)
        res = {
            "study": study,
            "samples_with_results": n,
            "samples_without_results": [s for s in st["samples"] if s not in contributing],
            "min_samples": min_samples,
            "per_sample_top": per_sample_top,
            "n_genes": int(len(rec)),
            "n_genes_in_most_samples": int((rec["n_samples"] >= max(n - 4, 1)).sum()),
            "genes": _rows(rec, top_n),
            "note": ("Recurrence counts samples, not regions or effect size. Ties in the "
                     "count are ordered arbitrarily, so read the count rather than the "
                     "position. A recurring gene is not necessarily a strong one in any "
                     "given sample."),
        }
        res["saved_to"] = context.persist(study, "gene_recurrence", res, "result",
                                          "primitive: gene_recurrence")
        return context.dump(res)
