"""Beta diversity over an assembled microbiome study, from the command line.

The statistics domain holds two beta-diversity implementations and they are not
the same kind of thing.

`primitives.ordination.run_beta_diversity` takes a distance matrix that somebody
else already built, and does PCoA, PERMANOVA and PERMDISP on it. It has no
opinion about what a sample is or how far apart two of them are, which is what
makes it general.

`workflows.ordination.beta_diversity` builds the distance itself, and to do that
it decides: clade abundances arrive CLR-transformed, so plain Euclidean on them
is Aitchison distance; metabolite concentrations get log1p and a z-score first,
so features on wildly different scales contribute comparably. Those are two
statements about microbiome data. They are correct and they are worth keeping,
and they are the reason this adapter is in microbiome rather than in statistics:
by the same rule that put the differential here, an opinionated composition of
general engines with domain decisions baked into it belongs to the domain whose
decisions they are.

    run_beta_diversity.py --features F --metadata M --group-by COLUMN --out DIR

Takes the two tables `assemble` produces, so nothing here reads a study or
knows how one is laid out.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pandas as pd

_STATISTICS = Path(__file__).resolve().parents[3] / "statistics" / "kernels"
if str(_STATISTICS) not in sys.path:
    sys.path.insert(0, str(_STATISTICS))

from workflows.ordination import beta_diversity                 # noqa: E402

# What the engine calls each transform, against what a person asking for it
# would say. The engine's own words are `clade` and `metab`, which are the
# loader's vocabulary from before any of this was a capability; a parameter
# offered to a caller should say what it does to the numbers.
TRANSFORM = {
    "none": "clade",
    "log1p_zscore": "metab",
}


def _read(path: str) -> pd.DataFrame:
    frame = pd.read_csv(path, sep="\t")
    frame = frame.rename(columns={frame.columns[0]: "sample_id"})
    frame["sample_id"] = frame["sample_id"].astype(str)
    return frame


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--features", required=True)
    ap.add_argument("--metadata", required=True)
    ap.add_argument("--group-by", required=True,
                    help="The metadata column whose values are the cohorts to test.")
    ap.add_argument("--transform", default="none", choices=sorted(TRANSFORM),
                    help="none for values already CLR transformed, which is what "
                         "assemble produces for metagenomics. log1p_zscore for raw "
                         "concentrations, which is what it produces for metabolomics.")
    ap.add_argument("--permutations", type=int, default=999)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    features, metadata = _read(a.features), _read(a.metadata)
    if a.group_by not in metadata.columns:
        raise SystemExit(
            f"the metadata has no column called {a.group_by!r}. It has: "
            f"{', '.join(c for c in metadata.columns if c != 'sample_id')}")

    columns = [c for c in features.columns if c != "sample_id"]
    group_map = dict(zip(metadata["sample_id"], metadata[a.group_by]))

    result = beta_diversity(features, columns, TRANSFORM[a.transform],
                            group_map, permutations=a.permutations)
    if "error" in result:
        raise SystemExit(result["error"])

    result["grouped_by"] = a.group_by
    result["transform"] = a.transform

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "beta_diversity.json").write_text(json.dumps(result, indent=2,
                                                        default=str) + "\n")

    permanova = result.get("permanova") or {}
    print(f"{result['n_samples_used']} samples, {result['n_features_used']} features, "
          f"{result['distance']}")
    # r_squared is printed beside the p value on purpose. A p value here says the
    # cohorts separate; it says nothing about how much of the variation the
    # cohort accounts for, and on a real study those two can point opposite ways.
    print(f"grouped by {a.group_by}: PERMANOVA p={permanova.get('p_value')} "
          f"r_squared={permanova.get('r_squared')}")
    if result.get("samples_dropped_missing_group"):
        print(f"note: {result['samples_dropped_missing_group']} sample(s) had no "
              f"value for {a.group_by} and could not take part in the test")
    return 0


if __name__ == "__main__":
    sys.exit(main())
