"""Alpha diversity: per-sample within-sample diversity.

A pure primitive over a samples x taxa relative-abundance matrix. The multivariate
between-sample analyses (distance, PCoA, PERMANOVA) are not here — those operate on
a distance matrix and live in the ordination block; the omic-specific beta-diversity
recipe that couples them lives in the workflows layer.

Every index is named for exactly what it computes. "Simpson" alone is ambiguous in
the literature — it is used for the concentration, for its complement, and for its
reciprocal, which are three different numbers on three different scales — so no
column is called that. Ask for the one you mean.
"""

from __future__ import annotations

import numpy as np
import pandas as pd


def alpha_diversity(abundance: pd.DataFrame) -> pd.DataFrame:
    """Per-sample alpha diversity from a samples x taxa relative-abundance matrix.

    Abundances are renormalised per sample to sum to 1 first, so percent or
    proportion input both work. Returned DataFrame is indexed by sample_id.

    Computed per sample over taxa with positive abundance (p = proportions,
    S = number of taxa observed):

      richness              S. Taxa observed. Hill number of order 0.
      shannon               H = -sum(p ln p), in nats.
      hill_q1               exp(H). Effective number of taxa of order 1.
      simpson_concentration D = sum(p^2). Simpson's (1949) concentration: the
                            probability two random draws are the same taxon.
                            Higher means LESS diverse.
      gini_simpson          1 - D. The probability two random draws differ. Also
                            called Simpson's index of diversity. Bounded 0 to 1.
      inverse_simpson       1/D. Simpson's reciprocal index, the effective number
                            of taxa of order 2 (Hill number of order 2). Ranges
                            from 1 (one taxon) upward, unbounded above by S.
      evenness              Pielou's J = H / ln(S).

    gini_simpson and inverse_simpson are different transforms of the same D and are
    not interchangeable: 1/D is not 1 - D, and a threshold set on one scale means
    nothing on the other. inverse_simpson is an effective count with a floor of 1;
    gini_simpson is a probability with a floor of 0.

    Undefined values are NaN, never 0. An empty sample has no diversity to report
    (richness is a true 0; every other index is undefined), and Pielou's J is 0/0
    when a single taxon is observed. Returning 0 there would be indistinguishable
    from a real minimum, which for gini_simpson is exactly what single-taxon
    dominance looks like.

    Note: alpha diversity must be computed on relative abundances, not on the CLR
    values in the assembled matrix. Pass study["clade_abundance"], not the matrix.
    """
    m = abundance.fillna(0.0).astype(float)
    M = m.to_numpy(dtype=float)
    totals = M.sum(axis=1)
    nonempty = totals > 0

    # relative abundances per sample (rows that sum to 0 stay all-zero)
    with np.errstate(divide="ignore", invalid="ignore"):
        P = np.where(nonempty[:, None], M / np.where(totals[:, None] == 0, 1.0, totals[:, None]), 0.0)

    richness = (M > 0).sum(axis=1).astype(int)
    # p*ln(p) is 0 at p=0 by convention; mask to avoid log(0)
    plnp = np.where(P > 0, P * np.log(P, where=P > 0, out=np.zeros_like(P)), 0.0)
    shannon = -plnp.sum(axis=1) + 0.0      # + 0.0 turns -0.0 into 0.0
    concentration = (P ** 2).sum(axis=1)

    with np.errstate(divide="ignore", invalid="ignore"):
        inverse_simpson = np.where(concentration > 0, 1.0 / np.where(concentration == 0, 1.0, concentration), np.nan)
        evenness = np.where(richness > 1, shannon / np.log(np.where(richness > 1, richness, 2)), np.nan)

    # an empty sample has undefined diversity, not zero diversity
    shannon = np.where(nonempty, shannon, np.nan)
    concentration = np.where(nonempty, concentration, np.nan)
    inverse_simpson = np.where(nonempty, inverse_simpson, np.nan)
    evenness = np.where(nonempty, evenness, np.nan)
    hill_q1 = np.exp(shannon)

    return pd.DataFrame(
        {
            "richness": richness,
            "shannon": np.round(shannon, 5),
            "hill_q1": np.round(hill_q1, 5),
            "simpson_concentration": np.round(concentration, 5),
            "gini_simpson": np.round(1.0 - concentration, 5),
            "inverse_simpson": np.round(inverse_simpson, 5),
            "evenness": np.round(evenness, 5),
        },
        index=abundance.index,
    ).rename_axis("sample_id")
