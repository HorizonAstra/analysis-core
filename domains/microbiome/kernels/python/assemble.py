"""Turn a microbiome study's tables into the two a statistical tool takes.

Every tertiary tool here — MaAsLin 3, LEfSe, the differential workflow — takes
the same two tables: samples by features, and samples by variables. A study on
disk is neither. It is five long tables, one row per sample per taxon, keyed on
identifiers that have to be lined up.

Turning one into the other is a shape change. There is no judgement in it: no
choice of cohort, no threshold, no test, nothing that could be argued with. It
was nonetheless being done by hand, in submitted code, every time anybody wanted
a differential result — forty lines of pivot and merge written fresh per
question, which is forty lines per question of places to be subtly wrong. The
observed failures were exactly the ones you would predict: a duplicated sample
identifier, and an index that did not line up, both discovered by a tool
refusing the file several minutes later.

So this is that shape change, once, as a capability. What it deliberately does
NOT do is decide anything:

  * No filtering by prevalence or abundance. Every tool downstream has its own
    rule and its own default, and applying one here would silently change what
    those tools were asked to do.
  * No cohort. Which samples are being compared, and on what, is the question
    being asked — it is the one thing that must stay open. So the metadata
    carries every column the study knows, sample-level and subject-level, and
    naming one of them is how a cohort gets chosen.

That second point is what keeps this from becoming a wall. A grouping that is
already a column costs nothing at all. A grouping that is not one — an exposure
window, a threshold, a tertile of something computed — is still built in
submitted code, but only the grouping: one column keyed by sample, joined to
what this already produced, instead of the whole matrix rebuilt around it.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pandas as pd

# How each omic's long table names the things this needs. An omic is added by
# adding a line here, which is the point of writing it as data: the pivot is the
# same pivot, and only the column names differ.
#
# `rank_column` is the column holding the level a row belongs to, for a table
# that carries several. Metabolites have no such thing — a compound is a
# compound — and the None says so rather than a special case downstream.
OMICS = {
    "metagenomics": {"feature": None, "value": "relative_abundance",
                     "rank_column": "taxonomy"},
    "metabolomics": {"feature": "compound", "value": "concentration",
                     "rank_column": None},
}


def _read(path: str) -> pd.DataFrame:
    """A table, read with the separator it actually uses, not the one it is called."""
    with open(path, newline="") as fh:
        head = fh.readline()
    return pd.read_csv(path, sep="," if head.count(",") > head.count("\t") else "\t")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--abundances", required=True,
                    help="The long per-sample table for the omic being assembled.")
    ap.add_argument("--samples", required=True)
    ap.add_argument("--subjects", default="")
    ap.add_argument("--omic", default="metagenomics")
    ap.add_argument("--rank", default="species")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    if a.omic not in OMICS:
        print(f"unknown omic '{a.omic}'. There is: {', '.join(OMICS)}", file=sys.stderr)
        return 1
    spec = OMICS[a.omic]

    long = _read(a.abundances)
    samples = _read(a.samples)
    if "sample_id" not in long.columns or "sample_id" not in samples.columns:
        print("both the abundance table and the samples table must carry sample_id",
              file=sys.stderr)
        return 1

    # A table carrying several ranks holds one row per sample per rank, so the
    # rank has to be chosen before anything is pivoted. Choosing it afterwards
    # sums a species into its own genus and reports the total twice.
    feature_column = spec["feature"] or a.rank
    if spec["rank_column"]:
        if spec["rank_column"] not in long.columns:
            print(f"{a.omic} has no '{spec['rank_column']}' column to read a rank from",
                  file=sys.stderr)
            return 1
        available = sorted(str(r) for r in long[spec["rank_column"]].dropna().unique())
        if a.rank not in available:
            print(f"no rank '{a.rank}'. This study has: {', '.join(available)}",
                  file=sys.stderr)
            return 1
        long = long[long[spec["rank_column"]] == a.rank]
    if feature_column not in long.columns:
        print(f"{a.omic} has no '{feature_column}' column to take feature names from",
              file=sys.stderr)
        return 1

    long = long.dropna(subset=[feature_column, spec["value"]])
    if long.empty:
        print(f"no rows left after selecting rank '{a.rank}'", file=sys.stderr)
        return 1

    # Summed rather than picked: one sample can carry a feature more than once
    # when the source table splits it, and pivoting without an aggregation
    # either raises or silently keeps one of them.
    features = long.pivot_table(index="sample_id", columns=feature_column,
                                values=spec["value"], aggfunc="sum",
                                fill_value=0).reset_index()
    features.columns.name = None

    # One row per sample, and that is a correctness property rather than tidiness:
    # a repeated sample_id here becomes a duplicated row after the join, which
    # every tool downstream reports as a duplicate index — several minutes into a
    # run, in the vocabulary of whatever library noticed.
    metadata = samples.drop_duplicates(subset="sample_id")
    if a.subjects:
        subjects = _read(a.subjects)
        shared = [c for c in subjects.columns if c in metadata.columns]
        # Whatever the two tables agree on identifies the subject. Named by the
        # data rather than by this file, so a study that calls it something else
        # still joins.
        if shared:
            metadata = metadata.merge(subjects.drop_duplicates(subset=shared[0]),
                                      on=shared[0], how="left",
                                      suffixes=("", "_subject"))

    # Only samples that have both. A sample with no abundances cannot be tested
    # and a row of abundances with no metadata cannot be assigned to a cohort, so
    # carrying either forward just moves the failure somewhere less legible.
    keep = set(features["sample_id"]) & set(metadata["sample_id"])
    features = features[features["sample_id"].isin(keep)].sort_values("sample_id")
    metadata = metadata[metadata["sample_id"].isin(keep)].sort_values("sample_id")
    if features.empty:
        print("no sample_id appears in both the abundance table and the samples "
              "table; they describe different sets of samples", file=sys.stderr)
        return 1

    # sample_id first, because every tool downstream reads the first column as the
    # identifier rather than looking for it by name.
    metadata = metadata[["sample_id"] + [c for c in metadata.columns if c != "sample_id"]]

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    features.to_csv(out / "features.tsv", sep="\t", index=False)
    metadata.to_csv(out / "metadata.tsv", sep="\t", index=False)

    # What a caller now has to choose from. Written out because the next decision
    # is always "group by what", and the answer is a column in this file — a
    # reader that has to open the table to find out is a reader spending a step
    # on something the step before it already knew.
    groupings = {c: sorted(str(v) for v in metadata[c].dropna().unique())[:12]
                 for c in metadata.columns if c != "sample_id"
                 and 1 < metadata[c].nunique() <= 12}
    (out / "assembled.json").write_text(json.dumps({
        "omic": a.omic, "rank": a.rank,
        "samples": int(len(features)), "features": int(features.shape[1] - 1),
        "metadata_columns": [c for c in metadata.columns if c != "sample_id"],
        "candidate_groupings": groupings,
        "note": ("Nothing was filtered. Every tool downstream applies its own "
                 "prevalence and abundance rule, and doing it here would change "
                 "what those tools were asked to do."),
    }, indent=2, default=str) + "\n")

    print(f"{len(features)} samples x {features.shape[1] - 1} {a.rank} features "
          f"-> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
