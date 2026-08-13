"""Curated, guardrailed analysis tools: correlation, beta diversity, differential
abundance, and alpha diversity. Each loads the study, runs a curated workflow, and
saves the result to the provenance workspace."""

from __future__ import annotations

import context
import derived
from analysis.primitives.correlation import correlation as _correlation
from analysis.primitives.diversity import alpha_diversity as _alpha
from analysis.domains.microbiome.study import features_for, search_features
from analysis.visualization import plotting as _plt
from analysis.workflows.differential import differential_abundance as _diff
from analysis.workflows.ordination import beta_diversity as _beta


def _wire_view(res: dict, cap: int | None) -> dict:
    """A conversation-sized copy of a result whose full table is already saved.

    The artifact keeps every row; this trims only what travels back into the model's
    context, where a whole-omic run is thousands of rows resent on every subsequent step
    of the turn. Nothing is lost by trimming here, which is the whole point: it used to
    be the saved artifact that got cut, so the withheld rows existed nowhere at all.
    """
    if not cap:
        return res

    def trim(block: dict) -> dict:
        rows = block.get("results") or []
        if len(rows) <= cap:
            return block
        out = {**block, "results": rows[:cap]}
        out["table"] = {**(block.get("table") or {}),
                        "n_shown": cap, "truncated": True, "n_withheld": len(rows) - cap,
                        "how_to_see_all": "every row is in the saved artifact; open it with "
                                          "read_artifact, or load() it in run_code"}
        return out

    view = trim(res) if "results" in res else dict(res)
    if "comparisons" in view:
        view["comparisons"] = [trim(c) for c in view["comparisons"]]
    return view


def register(mcp) -> None:
    @mcp.tool()
    @context.guarded("correlation analysis")
    def correlation_analysis(study: str, x_feature: str, y_feature: str, method: str = "pearson", rank: str = "species") -> str:
        """Correlate two omic features across a study, corrected for repeated measures.

        Always runs the within-subject Fisher z aggregation (the pseudoreplication
        correct estimate) and reports the naive value as a labelled contrast. Features
        must be exact names from list_features; clade features are already CLR
        transformed. method: pearson or spearman. Result is saved to the workspace.
        """
        st, err = context.load_study_or_error(study, rank)
        if err:
            return err
        # Gated on what the study actually has, not on its domain: the within-subject
        # correction is the whole point of this tool, and a study with one sample per
        # subject has nothing to correct, so running it would report a naive value under
        # a name that promises otherwise.
        if not st["meta"].get("is_longitudinal"):
            return context.dump({"error": f"study '{study}' has no repeated measures per subject, "
                                          "so the within-subject correction this tool exists for "
                                          "does not apply",
                                 "suggestion": "correlate the two features directly in run_code"})
        matrix, cols = st["matrix"], set(st["matrix"].columns)
        missing = [f for f in (x_feature, y_feature) if f not in cols]
        if missing:
            def _seed(name: str) -> str:
                tail = name.split("__")[-1] if "__" in name else name.split(":")[-1]
                return "".join(c for c in tail if c.isalpha())[:6]
            return context.dump({"error": "feature(s) not found", "missing": missing,
                                 "did_you_mean": {f: search_features(st, _seed(f))[:5] for f in missing}})
        out = _correlation(matrix, x_feature, y_feature, method=method, subject_col="subject_id",
                           detail=True)
        row = out["table"].iloc[0].to_dict() if len(out["table"]) else {}
        res = {"method": out["method"], "mode": out["mode"], **row,
               "notes": out["notes"], "subjects_excluded": out.get("subjects_excluded", [])}
        res["saved_to"] = context.persist(study, f"corr_{_plt.slug(x_feature)}__{_plt.slug(y_feature)}",
                                          res, "result", "primitive: correlation_analysis")
        return context.dump(res)

    @mcp.tool()
    @context.guarded("beta diversity")
    def beta_diversity(study: str, omic: str, group_by: str, permutations: int = 999, rank: str = "species") -> str:
        """Phase 1 of differential analysis: do the cohorts separate overall? Distance
        (Aitchison for clade, log1p + z-score + Euclidean for metab), PCoA, PERMANOVA.
        Pair the PERMANOVA p-value with the PCoA proportion explained. omic: 'clade' or
        'metab'. group_by: a subjects or samples column (see study_overview), or the name
        of a cohort you saved earlier with save(cohort, "name") in run_code. Result is
        saved to the workspace.
        """
        st, err = context.load_study_or_error(study, rank)
        if err:
            return err
        if omic not in ("clade", "metab"):
            return context.dump({"error": "omic must be 'clade' or 'metab'"})
        groups, info = derived.resolve_column(st, study, group_by)
        if groups is None:
            return context.dump(info)
        gm = {k: v for k, v in groups.dropna().items()}
        res = _beta(st["matrix"], features_for(st, omic), omic, gm, permutations=permutations)
        res["cohort_source"] = info
        res["saved_to"] = context.persist(study, f"beta_{omic}_by_{_plt.slug(group_by)}", res, "result", "primitive: beta_diversity")
        return context.dump(res)

    @mcp.tool()
    @context.guarded("differential abundance")
    def differential_abundance(study: str, omic: str, group_by: str, test: str = "lme", top_n: int | None = 50, compare: list | None = None, rank: str = "species") -> str:
        """Phase 2 of differential analysis: which features differ between cohorts.
        Tests every feature, applies Benjamini-Hochberg FDR jointly across all tests
        shown, and returns an effect size with each adjusted p. Never report a hit on
        raw p. With more than two cohorts it compares every pair (or pass compare=
        ["A","B"] for one). test (default 'lme') is repeated-measures correct; 'ols',
        'welch', 'wilcoxon' are pseudoreplicated here and flagged. group_by: a subjects
        or samples column, or the name of a cohort you saved earlier with
        save(cohort, "name") in run_code. Result is saved to the workspace.

        Effects are contrast minus reference: positive means higher in the cohort named
        first in "<contrast> vs <reference>". Every row names its own reference and
        contrast, and higher_in names the cohort it is higher in. With ordinal cohorts
        pass levels=[...] to set the reference, or the default order is used
        (conventional for low/medium/high, alphabetical otherwise) and reported back as
        cohort_order.

        The saved artifact always holds EVERY tested feature. top_n only limits how many
        rows come back in this reply, to keep a whole-omic run out of the conversation; it
        never limits what was tested, corrected, or saved. Read the artifact for the rest
        rather than re-running with a bigger top_n.

        For cohorts that are not an existing column (a threshold, a time window, alpha
        diversity, a prior result), build the cohort in run_code — then either save it and
        name it here, or call the workflow there directly. Saving is preferable when the
        cohort is worth keeping or reusing, because it is then a provenance-tracked
        artifact and every tool can name it (including maaslin3_association and
        lefse_biomarkers, which can only take a name):

            save(cohort, "responder_status")             # in run_code
            differential_abundance(study, "clade", "responder_status")   # then here

        In run_code the workflow takes the data directly instead, which is the right shape
        for a one-off:

            differential_abundance(study, ["clade:f__Lachnospiraceae"], cohort,
                                   test="lme", levels=["low", "medium", "high"])

        where `cohort` is sample_id -> label as a dict or a Series (a column name on the
        matrix also works). Pass `study` or `study["matrix"]`, either is accepted.
        """
        st, err = context.load_study_or_error(study, rank)
        if err:
            return err
        if omic not in ("clade", "metab"):
            return context.dump({"error": "omic must be 'clade' or 'metab'"})
        groups, info = derived.resolve_column(st, study, group_by)
        if groups is None:
            return context.dump(info)
        gm = {k: v for k, v in groups.dropna().items()}
        # Full table computed and SAVED, then trimmed only for the reply. The artifact is
        # what the user opens and downloads, so it must never be the cut version.
        res = _diff(st["matrix"], features_for(st, omic), gm, test=test,
                    is_longitudinal=st["meta"]["is_longitudinal"], top_n=None, compare=compare)
        res["cohort_source"] = info
        res["saved_to"] = context.persist(study, f"diff_{omic}_by_{_plt.slug(group_by)}_{test}", res, "result", "primitive: differential_abundance")
        return context.dump(_wire_view(res, top_n))

    @mcp.tool()
    @context.guarded("alpha diversity")
    def alpha_diversity(study: str, rank: str = "species") -> str:
        """Per-sample alpha diversity from the metagenomics composition, computed on
        relative abundances. Saved as a table artifact.

        Every index is returned under its exact name, because "Simpson" alone means
        three different numbers in the literature: richness, shannon, hill_q1,
        simpson_concentration (sum p^2), gini_simpson (1 - sum p^2), inverse_simpson
        (1 / sum p^2, an effective taxon count starting at 1), evenness. Use the column
        the question asks for; do not convert between gini_simpson and inverse_simpson
        by hand, and do not apply a threshold meant for one to the other.

        Use it to build diversity-based cohorts in run_code: read it back, bin a metric
        into low/medium/high, and run a primitive on the bins.
        """
        import json

        st, err = context.load_study_or_error(study, rank)
        if err:
            return err
        # The one genuinely taxa-specific tool here: alpha diversity is a statement about
        # a community of organisms in a sample, so it is gated on the abundance table
        # existing rather than on any domain label.
        ab = st.get("clade_abundance")
        if ab is None or ab.empty:
            return context.dump({"error": "no metagenomics abundance available for this study"})
        res = _alpha(ab)
        saved = context.persist(study, f"alpha_diversity_{rank}", res, "table", "primitive: alpha_diversity")
        return context.dump({
            "n_samples": int(len(res)),
            "metrics": list(res.columns),
            "summary": json.loads(res.describe().round(3).to_json()),
            "head": res.head(10).reset_index().to_dict(orient="records"),
            "saved_to": saved,
            "note": "Full per-sample table saved as artifact 'alpha_diversity_" + rank + "'. Read it in run_code to build cohorts.",
        })
