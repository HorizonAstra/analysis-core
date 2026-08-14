"""Run the differential-abundance workflow from the command line.

`differential.py` is a function over data frames, so something has to stand
between a catalog entry and a function call. This is that, and it does nothing
else: it reads two tables, builds the three arguments the workflow takes, calls
it, and writes what comes back. Every decision that changes a number is in the
module being called, which is why the entry pins both files.

The same shape as `statistics/kernels/run_primitive.py`, and the same reason.

    run_differential.py --features f.tsv --metadata m.tsv --group-by arm \
        --out results/ [--test lme] [--subject-col subject_id]

Inputs are the two tables MaAsLin 3 and LEfSe already take, deliberately. All
three answer the same question with different mathematics, so a person choosing
between them should not also be choosing a file format, and a chain that
prepared inputs for one has prepared them for all three.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from differential import differential_abundance          # noqa: E402


def _read(path: str) -> pd.DataFrame:
    """A table, read with the separator it actually uses.

    Not the one its name suggests. An input is staged under a name the contract
    chose, so a comma-separated file can arrive called `features.tsv`, and
    reading that by extension collapses every column into one — silently, and
    with a shape that then fails much further along.
    """
    with open(path, newline="") as fh:
        head = fh.readline()
    return pd.read_csv(path, sep="," if head.count(",") > head.count("\t") else "\t")


def _rows(result: dict) -> list[dict]:
    """Every tested feature as one flat table, whichever shape came back.

    The workflow answers in two shapes — one comparison is flat, several are
    grouped under `comparisons` — because that is the right thing to hand a
    reader. A file is not a reader. Flattened here, with the comparison on every
    row, so the output has one schema regardless of how many cohorts there were
    and nothing downstream has to branch on the count.
    """
    if "comparisons" in result:
        return [{"comparison": c["comparison"], **r}
                for c in result["comparisons"] for r in c["results"]]
    return [{"comparison": result.get("comparison", ""), **r}
            for r in result.get("results", [])]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--features", required=True)
    ap.add_argument("--metadata", required=True)
    ap.add_argument("--group-by", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--test", default="lme")
    ap.add_argument("--subject-col", default="")
    ap.add_argument("--covariates", default="auto")
    ap.add_argument("--levels", default="")
    ap.add_argument("--compare", default="")
    a = ap.parse_args()

    features, metadata = _read(a.features), _read(a.metadata)
    for name, frame, path in (("features", features, a.features),
                              ("metadata", metadata, a.metadata)):
        if frame.empty or frame.shape[1] < 2:
            print(f"{name} at {path} has no usable columns", file=sys.stderr)
            return 1

    # Whatever the first column is called, it identifies the sample. Both tables
    # are written by whoever prepared them and the header is theirs to choose;
    # requiring the literal word `sample_id` would fail on tables that are
    # correct in every way that matters.
    features = features.rename(columns={features.columns[0]: "sample_id"})
    metadata = metadata.rename(columns={metadata.columns[0]: "sample_id"})
    if a.group_by not in metadata.columns:
        print(f"metadata has no column '{a.group_by}'. It has: "
              f"{', '.join(metadata.columns[1:])}", file=sys.stderr)
        return 1

    columns = [c for c in features.columns if c != "sample_id"]
    if not columns:
        print("features has a sample column and nothing else", file=sys.stderr)
        return 1

    # A repeated-measures fit needs to know which samples came from one subject.
    # Named by the caller because only they know which column that is; absent, a
    # subject is a sample and the workflow says so in its own warning rather
    # than being quietly told these are independent observations.
    carried = ["sample_id", a.group_by]
    if a.subject_col:
        if a.subject_col not in metadata.columns:
            print(f"metadata has no column '{a.subject_col}'", file=sys.stderr)
            return 1
        metadata = metadata.rename(columns={a.subject_col: "subject_id"})
        carried.append("subject_id")
    covariates = [c.strip() for c in a.covariates.split(",")
                  if c.strip() and c.strip() != "auto"]
    carried += [c for c in covariates if c in metadata.columns]

    matrix = features.merge(metadata[list(dict.fromkeys(carried))],
                            on="sample_id", how="inner")
    if matrix.empty:
        print("no sample_id is present in both tables; they describe different "
              "sets of samples", file=sys.stderr)
        return 1

    group_map = dict(zip(matrix["sample_id"], matrix[a.group_by]))
    result = differential_abundance(
        matrix, columns, group_map,
        test=a.test,
        is_longitudinal=bool(a.subject_col),
        top_n=None,                      # the file always holds every tested feature
        levels=[x.strip() for x in a.levels.split(",") if x.strip()] or None,
        compare=[x.strip() for x in a.compare.split(",") if x.strip()] or None,
        covariates=covariates or a.covariates,
    )
    if "error" in result:
        print(result["error"], file=sys.stderr)
        for key in ("available_cohorts", "missing_features", "valid_tests"):
            if key in result:
                print(f"  {key}: {result[key]}", file=sys.stderr)
        return 1

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    rows = pd.DataFrame(_rows(result))
    rows.to_csv(out / "all_results.tsv", sep="\t", index=False)
    significant = rows[rows["p_adj_bh"] < 0.05] if "p_adj_bh" in rows else rows.iloc[:0]
    significant.to_csv(out / "significant_results.tsv", sep="\t", index=False)

    # What the workflow decided, which is not derivable from the table: which
    # cohort was the reference, which model was actually fitted, and every
    # warning it raised. A sign is meaningless without the first of those.
    (out / "model.json").write_text(json.dumps(
        {k: v for k, v in result.items()
         if k not in ("results", "comparisons")}, indent=2, default=str) + "\n")

    print(f"{len(rows)} feature-by-comparison rows, "
          f"{len(significant)} significant at q<0.05 -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
