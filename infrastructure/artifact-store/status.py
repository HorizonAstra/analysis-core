#!/usr/bin/env python3
"""One screen showing where every capability stands.

    status.py            all capabilities
    status.py --blocking only what is unpinned, and what is blocking it
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# The catalog reader lives with the schema it reads; profiles live with sites.
_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_ROOT / "interfaces" / "catalog"))
sys.path.insert(0, str(_ROOT / "infrastructure" / "sites"))
import entry as C
import profile as P

CAPS = Path(__file__).resolve().parent.parent / "capabilities"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--blocking", action="store_true")
    args = ap.parse_args()

    rows, blocked = [], []
    for path in sorted(CAPS.glob("*.json")):
        c = C.load(path)
        _, ok = C.kernel_check(c)
        stages = C.stages(c)
        fan = next((s["fan_out_over"] for s in stages if s.get("fan_out_over")), None)

        det = "yes" if not c["determinism"]["consumes_rng"] else (
            "seeded" if c["determinism"].get("seed_env") else "NO SEED")

        unpinned = [t["name"] for t in c["kernel"].get("third_party", [])
                    if not t.get("version")]
        if unpinned:
            blocked.append((c["id"], unpinned))

        # Two separate claims: the kernels have not moved, and this contract
        # still calls them the way they demand to be called. A contract can
        # pass the first and fail the second.
        call, call_ok = C.arity_check(c)
        checked = sum(1 for line in call if line.strip().startswith(("ok", "WRONG")))
        calls = "FAIL" if not call_ok else (
            f"{checked}/{len(call)}" if call else "-")

        rows.append((c["id"], c.get("level", "?"), len(stages),
                     "yes" if fan else "no", det,
                     "pass" if ok else "FAIL", calls,
                     c["resources"]["bound_by"]))

    if not args.blocking:
        head = ("capability", "lvl", "stages", "fans out", "reproducible",
                "verify", "calls", "bound by")
        w = [max(len(str(r[i])) for r in rows + [head]) for i in range(len(head))]
        print("  ".join(h.ljust(w[i]) for i, h in enumerate(head)))
        print("  ".join("-" * w[i] for i in range(len(head))))
        for r in rows:
            print("  ".join(str(v).ljust(w[i]) for i, v in enumerate(r)))
        print()

    if blocked:
        print("Unpinned dependencies, which is what every verify failure is:")
        for cid, names in blocked:
            print(f"  {cid}")
            for n in names:
                print(f"    - {n}")
        print("\nUntil a version is recorded for each, those capabilities cannot be")
        print("executed through the contract layer, and no result from them can be")
        print("attributed to a known build.")
    else:
        print("Every capability is fully pinned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
