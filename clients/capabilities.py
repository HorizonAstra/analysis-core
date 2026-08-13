"""What this installation can actually do, and why not for the rest.

Capabilities are gated on whether they can really run, which is what keeps a
model from reaching for an analysis that fails minutes later. The cost of that
design is a quiet failure mode: a half-built machine simply offers fewer tools
and says nothing about it. This is the check that closes it.

    capabilities.py                 what is offered, where, and what is not
    capabilities.py --require-all   exit non-zero if anything is unavailable
    ANALYSIS_SITES=local,randi capabilities.py

Nothing is listed here by hand. Every capability comes from the catalog and
every answer comes from the site itself, so this reports the same decision the
server makes rather than a second opinion about it.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

_TREE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_TREE / "clients" / "mcp-server"))

import mcp_server                                               # noqa: E402,F401
from tools import catalog as K                                  # noqa: E402

# Imported for its side effect as much as for itself: importing the server is
# what puts the interfaces and infrastructure directories on the path, so the
# two agree on which module is which rather than each building its own idea of
# the tree.
sys.path.insert(0, str(_TREE / "interfaces" / "catalog"))
import entry as C                                               # noqa: E402
import reachable as R                                           # noqa: E402


def survey() -> dict:
    """Every capability, against every site this deployment can reach.

    Which machines exist, and how to reach one, is asked of `reachable` — the
    same module the server itself asks. This used to build its own executors out
    of a profile and a store, which meant two answers to "what can this
    deployment reach" and only one of them maintained.
    """
    sites, unreachable = {}, []
    for site, executor in R.sites().items():
        (sites.setdefault(site, executor) if executor.available()
         else unreachable.append(site))

    offered, missing = {}, {}
    for contract in K.entries():
        name = C.qualified_id(contract)
        for site, executor in sites.items():
            ok, why = executor.can_run(contract)
            if ok:
                offered[name] = site
                break
            missing.setdefault(name, []).append(f"{site}: {why}")
        else:
            continue
    return {"sites": sorted(sites), "unreachable": unreachable,
            "offered": offered,
            "unavailable": {n: r for n, r in missing.items() if n not in offered}}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--require-all", action="store_true",
                    help="Exit non-zero unless every capability can run somewhere.")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    found = survey()
    if a.json:
        print(json.dumps(found, indent=2))
    else:
        print(f"sites: {', '.join(found['sites']) or 'none'}"
              + (f"   unreachable: {', '.join(found['unreachable'])}"
                 if found["unreachable"] else ""))
        for name, site in sorted(found["offered"].items()):
            print(f"  runs      {name:44s} on {site}")
        for name, why in sorted(found["unavailable"].items()):
            print(f"  cannot    {name}")
            for line in why:
                print(f"                {line}")
        print(f"\n{len(found['offered'])} of "
              f"{len(found['offered']) + len(found['unavailable'])} capabilities "
              f"can run here.")

    return 1 if (a.require_all and found["unavailable"]) else 0


if __name__ == "__main__":
    sys.exit(main())
