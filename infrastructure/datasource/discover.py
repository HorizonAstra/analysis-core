"""What data one machine holds, as an answer it can give about itself.

Discovery used to read a local filesystem and report the result as if it were
the whole world. On a deployment where the work runs somewhere else, that is
wrong twice over: it hides the data that is actually there, and it offers data
that the capability will never be able to reach.

So this is the same shape as asking a site whether it can run something. A
machine answers for itself, and a client asks each of them. It runs over ssh on
the far side exactly as the store does, which is why it is a command as well as
a function.

    discover.py [--root DATA_ROOT]

Nothing here knows a domain. What a dataset looks like comes from
`domains/<name>/study.json`, so a new kind of data is a file in a domain rather
than a change in this layer.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

if __package__ in (None, ""):                      # run as a script, over ssh
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from datasource import domains as _domains
    from datasource import local as _local
else:
    from . import domains as _domains
    from . import local as _local


def survey(data_root: str) -> list[dict]:
    """Every dataset under a root, with what it is and what it holds."""
    out = []
    for name, entry in sorted(_local.scan_studies(data_root).items()):
        directory, domain = entry["dir"], entry["domain"]
        found = _domains.identify(directory, domain)
        if not found:
            continue
        dataset, roles = found
        samples = _domains.sample_dirs(directory, domain)
        row = {
            "study": name,
            "domain": domain,
            "kind": dataset.id,
            "is": dataset.label or dataset.id,
            "roles": sorted(roles),
        }
        if dataset.notes:
            row["about"] = dataset.notes
        if samples:
            row["samples"] = samples
            row.update(_across_samples(
                _domains.sample_root(directory, domain), samples, domain))
        out.append(row)
    return out


_NAMED = 25          # samples named for a role only some of them have


def _across_samples(root: str, samples: list[str], domain: str) -> dict:
    """What the samples hold, separating what all of them have from what some do.

    Every sample is looked at rather than the first one. A cohort is rarely
    uniform: one sample keeps the instrument's own run and the rest do not, one
    arrives before a stage has been run over it. Reporting the first sample's
    roles as the cohort's says both that the others have something they do not
    and that this one lacks something it has, and a caller then either asks for
    what is missing or never learns what is there.
    """
    holders: dict[str, list[str]] = {}
    for name in samples:
        found = _domains.identify(os.path.join(root, name), domain)
        for role in (found[1] if found else {}):
            holders.setdefault(role, []).append(name)
    every = sorted(r for r, n in holders.items() if len(n) == len(samples))
    # Which samples, not how many. A count says something exists and leaves the
    # only useful question unanswered, so a caller then opens samples one at a
    # time until it finds one, which is a round trip per sample and reads as
    # aimless. Naming them costs nothing and ends the search.
    some = {r: {"count": len(n), "samples": n[:_NAMED]}
            for r, n in sorted(holders.items()) if len(n) < len(samples)}
    out: dict = {}
    if every:
        out["each_sample_has"] = every
    if some:
        out["some_samples_have"] = some
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.environ.get("DATA_ROOT", "data"))
    a = ap.parse_args(argv)
    print(json.dumps(survey(a.root), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
