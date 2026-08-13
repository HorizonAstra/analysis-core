#!/usr/bin/env python3
"""That what a domain says it can compute is what it can compute.

Most of a domain's science is catalog entries, and those are checked against the
schema. One thing is not: the methods that submitted code imports rather than
calling as a capability. Nothing declares those, so nothing could show them, and
a person reading what the product does was shown two entries where there are
twenty one methods.

A domain that has them writes `methods.json` beside its catalog. This checks the
two directions that matter:

    every module in kernels/primitives/ is accounted for, as a method or as a
    helper the domain has said is not one

    every module named in the file is a file that exists

A list of abilities is worth having and goes stale the moment someone adds a
module and forgets it. That is what this is for. It is a failure either way,
because a method nobody is told about is as wrong as one that is not there.

    methods.py           check every domain, report, exit non-zero on a problem
    methods.py --quiet   only what failed
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]


def _modules(domain: Path) -> set[str]:
    where = domain / "kernels" / "primitives"
    if not where.is_dir():
        return set()
    return {p.stem for p in where.glob("*.py") if not p.stem.startswith("_")}


def check(domain: Path) -> list[str]:
    """What is wrong with one domain's declaration, or nothing."""
    declared = json.loads((domain / "methods.json").read_text())
    methods = declared.get("methods", [])
    helpers = set(declared.get("not_methods", []))

    named = {m.get("module", "") for m in methods}
    on_disk = _modules(domain)
    wrong = []

    for missing in sorted(on_disk - named - helpers):
        wrong.append(f"{missing} is a method here and nothing says what it does. "
                     f"Add it to methods.json, or to not_methods if it is a helper.")
    for absent in sorted((named | helpers) - on_disk):
        wrong.append(f"methods.json names {absent}, which is not in kernels/primitives/.")
    for m in methods:
        if not m.get("name") or not m.get("what"):
            wrong.append(f"{m.get('module', '?')} has no name or no description.")
    return wrong


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quiet", action="store_true", help="Only report failures.")
    a = ap.parse_args()

    found = []
    counted = 0
    for path in sorted((TREE / "domains").glob("*/methods.json")):
        domain = path.parent
        wrong = check(domain)
        counted += len(json.loads(path.read_text()).get("methods", []))
        for line in wrong:
            found.append(f"{domain.name}: {line}")

    if found:
        for line in found:
            print(f"  {line}")
        return 1
    if not a.quiet:
        print(f"{counted} methods declared, all present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
