"""Model-facing tools for the TERTIARY bioBakery stats suite — running bioBakery's own
programs on a study's assembled tables (as opposed to tools/secondary/, which produces those
tables from raw reads on Randi). All of these are LOCAL and SYNCHRONOUS: the run happens on
the toolkit host and finishes in seconds to minutes, so unlike secondary runs they return the
result directly rather than a job handle to poll.

  maaslin3_association  which taxa associate with covariates (multivariable, two-part,
                        repeated-measures aware, FDR-controlled)     — R backend
  lefse_biomarkers      which taxa discriminate two cohorts, by LDA effect size
                        (two classes, no covariates, unadjusted by default) — R backend
  halla_association     which BLOCKS of taxa associate with blocks of metabolites
                        (cross-omic, no cohorts)                     — HAllA's own env

These are used AS-IS: their statistics are never reimplemented or altered. What this layer
adds is shape bridging (each wants a different input layout), validation, the caveats their
defaults invite, and provenance. Where a default is debatable it is exposed as a parameter
and explained, rather than silently "fixed".

The module spans two backends, so each tool verifies its own before running, and
list_stats_options advertises only the ones whose backend is built.
"""

from __future__ import annotations

import os
import re
import shutil
import tempfile

import pandas as pd

import context
import derived
from compute.tertiary import halla, lefser, maaslin

# MaAsLin 3 result columns worth putting in front of the model; the full table is saved.
_SIG_COLS = ("feature", "metadata", "value", "coef", "stderr",
             "pval_individual", "qval_individual", "model", "N", "N_not_zero")


def _slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "_", str(s)).strip("_") or "x"


def _assemble(st: dict, study: str, covariates: list[str]):
    """Build the aligned (abundance, metadata) pair MaAsLin 3 and LEfSe need: taxa
    abundance (samples x species, zero-filled) and a metadata frame on the same sample_id
    index holding subject_id plus the requested covariates.

    Resolving and assembling are one step because a covariate may be a study column OR a
    saved artifact (see derived.py), and both end up as a column of the TSV these programs
    read — which is the only way a derived cohort can reach a separate process at all.

    Returns (abundance, metadata, n_dropped_na, info). On an unresolvable covariate
    abundance is None and info is a ready-to-return error payload.
    """
    values, info = derived.resolve_columns(st, study, covariates)
    if values is None:
        return None, None, 0, info

    ab = st["clade_abundance"].fillna(0.0)
    samp = st["samples"].set_index("sample_id")

    idx = pd.Index([s for s in ab.index if s in samp.index], name="sample_id")
    md = pd.DataFrame(index=idx)
    md["subject_id"] = samp.loc[idx, "subject_id"].values
    for c in covariates:
        md[c] = values[c].reindex(idx).values

    before = len(md)
    md = md.dropna(subset=covariates) if covariates else md
    return ab.loc[md.index], md, before - len(md), info


def register(mcp) -> None:
    @mcp.tool()
    def list_stats_options() -> str:
        """List the tertiary bioBakery STATS tools available on a study's assembled tables
        (distinct from the secondary pipelines that create those tables). Call this to tell
        the user what statistical analyses they can run and on what inputs."""
        # Each tool runs on its own backend (R env vs HAllA's own env), so each is listed only
        # when that backend is actually built — the same rule as tool registration, applied one
        # level down, because this module now spans two backends.
        _backend_ready = {"maaslin3": maaslin.enabled(), "lefse": lefser.enabled(),
                          "halla": halla.enabled()}
        return context.dump({
            "tools": [t for t in [{
                "id": "maaslin3",
                "name": "MaAsLin 3",
                "does": "multivariable association / differential abundance of taxa against "
                        "clinical covariates, with abundance AND prevalence models; handles "
                        "repeated measures via a per-subject random effect",
                "runs_on": "the study's metagenomics abundance table (omic='clade')",
                "call": "maaslin3_association(study, fixed_effects=[...])",
            }, {
                "id": "lefse",
                "name": "LEfSe (lefser)",
                "does": "biomarker discovery — which taxa best DISCRIMINATE two cohorts, "
                        "ranked by LDA effect size (Kruskal-Wallis -> Wilcoxon -> LDA). Exactly "
                        "two classes, no covariates, and unadjusted by default",
                "runs_on": "the study's metagenomics abundance table",
                "call": "lefse_biomarkers(study, group_by='<two-level column>')",
            }, {
                "id": "halla",
                "name": "HAllA",
                "does": "hierarchical all-against-all association between TWO omics: clusters "
                        "each side and tests block against block, so the finding is 'these taxa "
                        "track these metabolites' rather than thousands of pairwise p-values",
                "runs_on": "metagenomics AND metabolomics, on the samples that have both",
                "call": "halla_association(study)",
            }] if _backend_ready.get(t["id"])],
            "choosing": "MaAsLin 3 and LEfSe both answer 'which taxa differ between cohorts', "
                        "differently; HAllA answers a different question entirely (omic vs omic, "
                        "no cohorts). MaAsLin 3 "
                        "is the inferential one: several covariates at once, a per-subject random "
                        "effect for repeated measures, FDR-controlled. LEfSe is the descriptive "
                        "one: two classes only, no adjustment, and it reports the LDA effect size "
                        "the LEfSe literature uses. On longitudinal data prefer MaAsLin 3 for any "
                        "claim, and read LEfSe as an exploratory ranking.",
            "note": "Synchronous — runs on the toolkit host and returns results directly "
                    "(no job to poll). Use study_overview to see a study's covariate columns.",
        })

    @mcp.tool()
    @context.guarded("MaAsLin 3 association")
    def maaslin3_association(study: str, fixed_effects: list[str], omic: str = "clade",
                             reference: dict | None = None, use_random_effect: bool = True,
                             min_prevalence: float = 0.1, max_significance: float = 0.1,
                             plots: bool = True, rank: str = "species", max_rows: int = 60) -> str:
        """Run MaAsLin 3: which taxa are associated with the given covariates, controlling
        for the others. Fits both an ABUNDANCE model (linear, on log relative abundance
        among samples where present) and a PREVALENCE model (logistic, presence/absence);
        the `model` column of the result says which. FDR is Benjamini-Hochberg; a hit is
        qval_individual < max_significance. The full result tables and a summary plot are
        saved to the workspace.

        study            a microbiome study (must have a metagenomics table).
        fixed_effects    covariate names to test. Each may be a study subjects/samples
                         column (see study_overview) OR the name of a cohort/column you
                         saved earlier — build one in run_code, save(cohort, "name"), and
                         pass "name" here exactly like a real column. Keys may be
                         sample_ids or subject_ids; a saved table with several labellings
                         is addressed as "artifact:column". The first-listed convention
                         does not apply; every covariate is adjusted for the others.
        omic             'clade' (taxa) — the MaAsLin use case. metab is not yet supported.
        reference        for a categorical covariate with MORE THAN TWO levels, the baseline
                         level to compare against, as {covariate: level} (e.g.
                         {"race": "Caucasian"}); binary covariates pick one automatically.
        use_random_effect  add a per-subject random intercept on longitudinal studies (the
                         repeated-measures correct choice). Ignored when each subject has one
                         sample. Uses subject_id.
        min_prevalence   drop taxa present in fewer than this fraction of samples (default 0.1).
        max_significance the q-value cutoff for the saved 'significant' table (default 0.1).
        plots            also render MaAsLin's summary plot (a PDF artifact).

        coef is the effect for the covariate level shown in `value` versus its reference:
        in the abundance model, the change in log relative abundance; in the prevalence
        model, the log-odds of being present. Report qval_individual, never the raw p.
        """
        if not maaslin.enabled():
            return context.dump({"error": "MaAsLin 3 is unavailable: the R stats env is not built",
                                 "fix": "run: Rscript envs/r-stats/install.R"})
        if omic != "clade":
            return context.dump({"error": f"omic '{omic}' is not supported yet; MaAsLin 3 here "
                                          "runs on taxa (omic='clade')"})
        if not fixed_effects:
            return context.dump({"error": "fixed_effects is required — name at least one covariate",
                                 "hint": "see a study's covariates with study_overview"})

        st, err = context.load_study_or_error(study, rank)
        if err:
            return err
        if st["clade_abundance"] is None or st["clade_abundance"].empty:
            return context.dump({"error": f"study '{study}' has no metagenomics abundance to analyze"})

        ab, md, dropped, info = _assemble(st, study, fixed_effects)
        if ab is None:
            return context.dump(info)
        if len(md) < 3:
            return context.dump({"error": "too few samples with complete covariates to model",
                                 "samples_usable": int(len(md)), "samples_dropped_missing": int(dropped)})

        random_effects = ("subject_id",) if (use_random_effect and st["meta"]["is_longitudinal"]) else ()
        ref_str = ";".join(f"{k},{v}" for k, v in (reference or {}).items())

        base = os.path.join(context.OUT, "_rstats")
        os.makedirs(base, exist_ok=True)
        work = tempfile.mkdtemp(dir=base, prefix=f"maaslin3_{_slug(study)}_")
        try:
            res = maaslin.run_maaslin3(
                ab, md, work, fixed_effects=list(fixed_effects), random_effects=random_effects,
                reference=ref_str, normalization="TSS", transform="LOG",
                min_prevalence=min_prevalence, max_significance=max_significance, plots=plots,
            )
        except maaslin.RStatsError as e:
            return context.dump({"error": f"MaAsLin 3 failed: {e}"})
        finally:
            pass  # work dir cleaned after we've persisted what we keep (below)

        allr, sig = res["all_results"], res["significant_results"]
        tag = _slug("_".join(fixed_effects))
        saved: dict[str, str | None] = {
            "all_results": context.persist(study, f"maaslin3_{tag}_all", allr, "table",
                                           "tertiary: maaslin3_association"),
            "significant": context.persist(study, f"maaslin3_{tag}_significant", sig, "table",
                                           "tertiary: maaslin3_association"),
        }
        if res.get("summary_plot_path"):
            saved["summary_plot"] = context.persist(study, f"maaslin3_{tag}_summary_plot",
                                                    res["summary_plot_path"], "plot",
                                                    "tertiary: maaslin3_association")
        shutil.rmtree(work, ignore_errors=True)

        cols_present = [c for c in _SIG_COLS if c in sig.columns]
        rows = sig[cols_present].head(max_rows).to_dict(orient="records")
        payload = {
            "tool": "MaAsLin 3", "study": study, "omic": omic,
            "model": {"fixed_effects": list(fixed_effects),
                      "random_effects": list(random_effects),
                      "reference": reference or {},
                      "normalization": "TSS", "transform": "LOG",
                      "min_prevalence": min_prevalence, "max_significance": max_significance},
            # Where each covariate came from — a study column or a saved artifact. Reported
            # because "adjusted for responder_status" is only reproducible if the reader can
            # see which responder_status that was.
            "covariate_sources": info.get("sources", {}),
            "samples_used": int(len(md)), "samples_dropped_missing": int(dropped),
            "features_tested": int(allr["feature"].nunique()) if "feature" in allr.columns else None,
            "n_significant": int(len(sig)),
            "significant": rows,
            "how_to_read": "coef = effect for the level in `value` vs its reference; model="
                           "abundance is the linear log-abundance effect, model=prevalence the "
                           "logistic presence/absence effect. Significant means qval_individual < "
                           f"{max_significance}.",
            "artifacts": saved,
        }
        # Turning the random effect off on longitudinal data IS pseudoreplication, and it was
        # the only way to do so silently: differential_abundance warns for test='ols' and LEfSe
        # warns when unblocked, so MaAsLin saying nothing was the odd one out.
        caveats = []
        if st["meta"]["is_longitudinal"] and not random_effects:
            caveats.append(
                f"use_random_effect is off, but this study has repeated samples per subject "
                f"({st['meta']['n_samples']} samples from {st['meta']['n_subjects']} subjects). "
                "Every sample is treated as independent, so the p-values are anti-conservative "
                "and the hit count is inflated. Leave the random effect on for any claim.")
        for name, src in info.get("sources", {}).items():
            if src.get("keyed_by") == "subject_id" and random_effects:
                caveats.append(
                    f"'{name}' is constant within a subject, and the model has a per-subject "
                    "random intercept — the random effect absorbs part of its effect, so its "
                    "coefficient is shrunk toward zero. The random-effect variable is fixed to "
                    "subject_id; the only alternative is use_random_effect=False, which "
                    "pseudoreplicates. Read a null result here as inconclusive, not negative.")
        if caveats:
            payload["caveats"] = caveats
        if len(sig) > max_rows:
            payload["note"] = (f"showing {max_rows} of {len(sig)} significant rows; the full table "
                               "is the saved 'significant' artifact")
        return context.dump(payload)

    @mcp.tool()
    @context.guarded("LEfSe biomarker discovery")
    def lefse_biomarkers(study: str, group_by: str, compare: list | None = None,
                         lda_threshold: float = 2.0, kruskal_threshold: float = 0.05,
                         wilcox_threshold: float = 0.05, correction: str = "none",
                         block_by_subject: bool = False, plot: bool = True,
                         rank: str = "species", max_rows: int = 60) -> str:
        """Run LEfSe: which taxa best DISCRIMINATE two cohorts, ranked by LDA effect size.

        Kruskal-Wallis, then Wilcoxon, then Linear Discriminant Analysis; survivors get one
        signed LDA score. Strictly TWO classes and no covariates — it cannot adjust for
        confounders, and by default (correction='none', the published LEfSe behaviour) it does
        NOT correct for multiple testing. Use it for the LEfSe-style effect-size ranking the
        literature is written in; use maaslin3_association when you need covariate adjustment,
        repeated-measures handling, or FDR-controlled inference.

        study            a microbiome study (must have a metagenomics table).
        group_by         a two-level subjects or samples column (see study_overview), or the
                         name of a cohort you saved earlier — build it in run_code,
                         save(cohort, "name"), and pass "name" here. With more than two
                         levels, pass `compare` to pick the two.
        compare          [class_a, class_b] when group_by has more than two levels.
        lda_threshold    minimum |LDA score| to report (default 2.0, the LEfSe convention).
        correction       multiple-testing correction applied inside lefser: 'none' (default,
                         LEfSe as published) or 'BH' / 'bonferroni' / 'holm' to control it.
        block_by_subject pass subject_id as lefser's subclass, the paired/blocked variant. Some
                         protection against repeated measures, but NOT a random effect.

        The score's sign is relative to the reference class, which is reported back as
        `reference_class`: a negative score means higher in the reference. Results and the
        plot are saved to the workspace.
        """
        if not lefser.enabled():
            return context.dump({"error": "LEfSe is unavailable: the R stats env is not built",
                                 "fix": "run: Rscript envs/r-stats/install.R"})
        st, err = context.load_study_or_error(study, rank)
        if err:
            return err
        if st["clade_abundance"] is None or st["clade_abundance"].empty:
            return context.dump({"error": f"study '{study}' has no metagenomics abundance to analyze"})

        ab, md, dropped, info = _assemble(st, study, [group_by])
        if ab is None:
            return context.dump(info)
        levels = [str(x) for x in pd.Series(md[group_by].astype(str)).dropna().unique()]
        if compare:
            missing = [c for c in map(str, compare) if c not in levels]
            if missing or len(compare) != 2:
                return context.dump({"error": "`compare` must name exactly 2 classes present in "
                                              f"'{group_by}'", "available_classes": sorted(levels),
                                     "got": compare})
            keep = md[group_by].astype(str).isin([str(c) for c in compare])
            md = md[keep]
            ab = ab.loc[md.index]
            levels = [str(c) for c in compare]
        if len(levels) != 2:
            return context.dump({
                "error": f"LEfSe compares exactly two classes; '{group_by}' has {len(levels)}",
                "available_classes": sorted(levels),
                "hint": "pass compare=[class_a, class_b], or use maaslin3_association which "
                        "handles more than two levels and covariates"})
        md = md.copy()
        md[group_by] = md[group_by].astype(str)

        base = os.path.join(context.OUT, "_rstats")
        os.makedirs(base, exist_ok=True)
        work = tempfile.mkdtemp(dir=base, prefix=f"lefser_{_slug(study)}_")
        try:
            res = lefser.run_lefser(
                ab, md, work, class_col=group_by,
                subclass_col=("subject_id" if block_by_subject else None),
                kruskal_threshold=kruskal_threshold, wilcox_threshold=wilcox_threshold,
                lda_threshold=lda_threshold, method=correction, plot=plot,
            )
        except lefser.RStatsError as e:
            return context.dump({"error": f"LEfSe failed: {e}"})

        table = res["results"]
        tag = _slug(f"{group_by}_{'_vs_'.join(levels)}")
        saved: dict[str, str | None] = {
            "results": context.persist(study, f"lefse_{tag}", table, "table",
                                       "tertiary: lefse_biomarkers"),
        }
        if res.get("plot_path"):
            saved["plot"] = context.persist(study, f"lefse_{tag}_plot", res["plot_path"],
                                            "plot", "tertiary: lefse_biomarkers")
        shutil.rmtree(work, ignore_errors=True)

        # lefser announces its reference category in a message; that is what fixes the sign.
        ref = next((m.split("reference category is")[-1].strip(" .'\"")
                    for m in res["messages"] if "reference category is" in m), None)
        ordered = table.reindex(table["scores"].abs().sort_values(ascending=False).index) \
            if "scores" in table.columns and len(table) else table
        payload = {
            "tool": "LEfSe (lefser)", "study": study, "group_by": group_by,
            "cohort_source": info.get("sources", {}).get(group_by, {}),
            "classes": levels, "reference_class": ref,
            "thresholds": {"lda": lda_threshold, "kruskal": kruskal_threshold,
                           "wilcox": wilcox_threshold, "correction": correction},
            "blocked_by_subject": bool(block_by_subject),
            "samples_used": int(len(md)), "samples_dropped_missing": int(dropped),
            "features_tested": res.get("n_features_tested"),
            "n_significant": int(len(table)),
            "biomarkers": ordered.head(max_rows).to_dict(orient="records"),
            "how_to_read": (
                f"scores are LDA effect sizes, signed relative to the reference class"
                + (f" ('{ref}')" if ref else "")
                + ": a negative score means higher in the reference, positive means higher in "
                  "the other class. Ranked here by |score|."),
            "artifacts": saved,
        }
        caveats = []
        if correction == "none":
            caveats.append("No multiple-testing correction was applied (LEfSe as published). "
                           "With thousands of features some hits are expected by chance; "
                           "pass correction='BH', or corroborate with maaslin3_association.")
        if st["meta"]["is_longitudinal"] and not block_by_subject:
            caveats.append(
                f"This study has repeated samples per subject "
                f"({st['meta']['n_samples']} samples from {st['meta']['n_subjects']} subjects), "
                "but LEfSe treats every sample as independent, so its p-values are "
                "anti-conservative and the hit count is inflated. Treat this as exploratory "
                "ranking; use maaslin3_association (per-subject random effect) for inference, "
                "or block_by_subject=True for partial protection.")
        if caveats:
            payload["caveats"] = caveats
        if len(table) > max_rows:
            payload["note"] = (f"showing the {max_rows} strongest of {len(table)} features by "
                               "|score|; the full table is the saved 'results' artifact")
        return context.dump(payload)

    @mcp.tool()
    @context.guarded("HAllA cross-omic association")
    def halla_association(study: str, metric: str = "spearman", fdr_alpha: float = 0.05,
                          min_taxon_prevalence: float = 0.2, min_metabolite_coverage: float = 0.8,
                          max_features_per_side: int = 200, plot: bool = True,
                          rank: str = "species", max_rows: int = 40) -> str:
        """Run HAllA: which BLOCKS of taxa associate with which blocks of metabolites.

        HAllA hierarchically clusters each omic, then tests cluster against cluster, so the
        answer is "this group of taxa tracks this group of metabolites" rather than tens of
        thousands of independent pairwise p-values. Use it for cross-omic structure; use
        correlation_analysis for one named pair, and maaslin3_association / differential
        abundance for feature-vs-cohort questions.

        study                   a microbiome study with BOTH metagenomics and metabolomics.
        metric                  spearman (default) | pearson | dcor | mi | nmi | xicor.
                                spearman is the safe default for monotonic-but-not-linear
                                omic relationships; dcor/mi also catch non-monotonic ones.
        fdr_alpha               FDR level for calling a block significant (default 0.05).
        min_taxon_prevalence    keep taxa present in at least this fraction of samples.
        min_metabolite_coverage keep metabolites measured in at least this fraction.
        max_features_per_side   cap each side (most prevalent taxa / most complete
                                metabolites) so a run stays minutes rather than hours.

        Both omics must be measured on the SAME samples; only that overlap is used, and the
        counts are reported. Results and the hallagram figure are saved to the workspace.
        """
        if not halla.enabled():
            return context.dump({"error": "HAllA is unavailable: its environment is not built",
                                 "fix": "run: bash envs/halla/build.sh"})
        if metric not in halla.METRICS:
            return context.dump({"error": f"unknown metric '{metric}'",
                                 "choices": list(halla.METRICS)})
        st, err = context.load_study_or_error(study, rank)
        if err:
            return err
        ab = st["clade_abundance"]
        if ab is None or ab.empty:
            return context.dump({"error": f"study '{study}' has no metagenomics abundance"})
        if not st["metab_features"]:
            return context.dump({"error": f"study '{study}' has no metabolomics to associate with",
                                 "hint": "HAllA needs two omics measured on the same samples"})

        mat = st["matrix"].set_index("sample_id")
        met = mat[st["metab_features"]]
        shared = [s for s in ab.index if s in met.index]
        if len(shared) < 10:
            return context.dump({
                "error": "too few samples have both omics measured",
                "samples_with_both": len(shared),
                "hint": "HAllA needs the two omics on the same samples"})

        X_all, Y_all = ab.loc[shared].fillna(0.0), met.loc[shared]
        # Metabolites first (they carry the missingness), then drop any sample still incomplete,
        # since HAllA wants a complete matrix. Taxa filtering follows on the surviving samples.
        Y = Y_all.loc[:, Y_all.notna().mean() >= min_metabolite_coverage].dropna(axis=0, how="any")
        if Y.empty or Y.shape[1] < 2:
            return context.dump({
                "error": "no metabolites are measured consistently enough to associate",
                "metabolites_available": int(Y_all.shape[1]),
                "hint": f"lower min_metabolite_coverage (currently {min_metabolite_coverage})"})
        X = X_all.loc[Y.index]
        X = X.loc[:, (X > 0).mean() >= min_taxon_prevalence]
        if X.shape[1] < 2:
            return context.dump({
                "error": "no taxa are prevalent enough to associate",
                "hint": f"lower min_taxon_prevalence (currently {min_taxon_prevalence})"})
        # Cap each side by the most informative features: HAllA's cost grows with the product
        # of the two sides, so an uncapped whole-omic run is hours.
        capped = {}
        if X.shape[1] > max_features_per_side:
            X = X[(X > 0).mean().sort_values(ascending=False).index[:max_features_per_side]]
            capped["taxa"] = f"kept the {max_features_per_side} most prevalent"
        if Y.shape[1] > max_features_per_side:
            Y = Y[Y.notna().mean().sort_values(ascending=False).index[:max_features_per_side]]
            capped["metabolites"] = f"kept the {max_features_per_side} most complete"

        base = os.path.join(context.OUT, "_rstats")
        os.makedirs(base, exist_ok=True)
        work = tempfile.mkdtemp(dir=base, prefix=f"halla_{_slug(study)}_")
        try:
            res = halla.run_halla(X, Y, work, metric=metric, fdr_alpha=fdr_alpha,
                                  x_label="taxa", y_label="metabolites", hallagram=plot,
                                  timeout=3600)
        except halla.PyCliError as e:
            return context.dump({"error": f"HAllA failed: {e}"})

        assoc, clusters = res["associations"], res["sig_clusters"]
        tag = _slug(f"{metric}_{X.shape[1]}x{Y.shape[1]}")
        saved: dict[str, str | None] = {
            "associations": context.persist(study, f"halla_{tag}_associations", assoc, "table",
                                            "tertiary: halla_association"),
            "significant_blocks": context.persist(study, f"halla_{tag}_blocks", clusters, "table",
                                                  "tertiary: halla_association"),
        }
        if res.get("hallagram_path"):
            saved["hallagram"] = context.persist(study, f"halla_{tag}_hallagram",
                                                 res["hallagram_path"], "plot",
                                                 "tertiary: halla_association")
        shutil.rmtree(work, ignore_errors=True)

        qcol = next((c for c in ("q-values", "q_values", "qvalue") if c in assoc.columns), None)
        top = (assoc.sort_values(qcol).head(max_rows) if qcol else assoc.head(max_rows))
        payload = {
            "tool": "HAllA", "study": study,
            "metric": metric, "fdr_alpha": fdr_alpha,
            "samples_used": int(len(Y)),
            "samples_with_both_omics": len(shared),
            "taxa_tested": int(X.shape[1]), "metabolites_tested": int(Y.shape[1]),
            "filters": {"min_taxon_prevalence": min_taxon_prevalence,
                        "min_metabolite_coverage": min_metabolite_coverage,
                        **({"capped": capped} if capped else {})},
            "n_pairs_tested": int(len(assoc)),
            "n_significant_blocks": int(len(clusters)),
            "significant_blocks": clusters.to_dict(orient="records"),
            "strongest_pairs": top.to_dict(orient="records"),
            "how_to_read": (
                "HAllA's unit of inference is the BLOCK (significant_blocks): a cluster of "
                "taxa associated with a cluster of metabolites, FDR-controlled at "
                f"{fdr_alpha}. strongest_pairs lists individual feature pairs by q-value for "
                "context — they are not separately FDR-controlled findings, so report blocks "
                "and use the pairs to describe what is inside them."),
            "artifacts": saved,
        }
        if len(assoc) > max_rows:
            payload["note"] = (f"showing {max_rows} of {len(assoc)} pairs; the full table is the "
                               "saved 'associations' artifact")
        return context.dump(payload)
