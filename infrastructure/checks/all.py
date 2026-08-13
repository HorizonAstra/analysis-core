"""Every check, as one command.

These were shell loops typed out by hand, which is how the interesting failures
got through. A render target that was never tried, a schema validation that
reported itself skipped and returned success anyway: both were passed over
because the loop only looked at exit codes, and both were caught days later on
the other machine.

    all.py                run everything, report, exit non-zero on any failure
    all.py --quiet        only what failed

What is checked, in the order a failure is worth hearing about:

    the four rules     who may import whom, across the partitions
    the schema         every entry against the format it claims to satisfy
    every render       every entry to every surface it can be rendered as
    the graph          that the capabilities order into a runnable sequence
    the methods        that what a domain says it computes is what it computes
    the data layer     that every shape of data a domain declares is still found

The last one builds its own data. Everything before it reads the tree, which is
the same on every machine; data is not, and a check that only ever saw the seven
flat studies on one laptop passed a change that broke every per-sample study on
the cluster.

Skipped is not passed. jsonschema is optional in the runner, deliberately, so a
missing library never stops work; here it is a failure, because the whole
purpose of this file is to be the thing that noticed.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
RENDER = TREE / "infrastructure" / "render-targets" / "render.py"
GRAPH = TREE / "infrastructure" / "graph" / "graph.py"
RULES = TREE / "infrastructure" / "checks" / "dependencies.py"
METHODS = TREE / "infrastructure" / "checks" / "methods.py"
DATA = TREE / "infrastructure" / "checks" / "data_layer.py"
TARGETS = ("cli", "mcp", "openapi", "nextflow", "slurm", "verify")


def entries() -> list[Path]:
    return sorted((TREE / "domains").glob("*/catalog/*.json"))


def _run(argv: list[str]) -> tuple[bool, str]:
    done = subprocess.run([sys.executable, *argv], capture_output=True, text=True)
    return done.returncode == 0, (done.stdout or "") + (done.stderr or "")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quiet", action="store_true", help="Only report failures.")
    a = ap.parse_args()
    found = []

    def say(line: str) -> None:
        if not a.quiet:
            print(line)

    ok, out = _run([str(RULES), "--known"])
    say(f"  {'ok  ' if ok else 'FAIL'}  four rules · {out.strip().splitlines()[-1] if out.strip() else ''}")
    if not ok:
        found.append(("the four rules", out.strip()))

    catalog = entries()
    passed = skipped = 0
    for path in catalog:
        good, out = _run([str(RENDER), str(path), "--as", "verify"])
        if "skipped  jsonschema" in out:
            skipped += 1
            found.append((f"{path.name}: not validated",
                          "jsonschema is not installed for this interpreter, so the "
                          "entry was not checked against the schema at all. A skip "
                          "here is a check that did not happen."))
        elif good:
            passed += 1
        else:
            found.append((f"{path.name}: schema", out.strip()[-500:]))
    say(f"  {'ok  ' if not skipped and passed == len(catalog) else 'FAIL'}  "
        f"schema · {passed} of {len(catalog)} entries validated"
        + (f", {skipped} SKIPPED" if skipped else ""))

    rendered = failed = 0
    for path in catalog:
        for target in TARGETS:
            good, out = _run([str(RENDER), str(path), "--as", target])
            if good:
                rendered += 1
            else:
                failed += 1
                found.append((f"{path.name} as {target}", out.strip()[-300:]))
    say(f"  {'ok  ' if not failed else 'FAIL'}  renders · {rendered} rendered"
        + (f", {failed} failed" if failed else ""))

    ok, out = _run([str(GRAPH), "--as", "order"])
    say(f"  {'ok  ' if ok else 'FAIL'}  graph · orders {len(catalog)} capabilities")
    if not ok:
        found.append(("the graph", out.strip()[-300:]))

    ok, out = _run([str(METHODS)])
    say(f"  {'ok  ' if ok else 'FAIL'}  methods · {out.strip().splitlines()[-1] if out.strip() else ''}")
    if not ok:
        found.append(("the methods", out.strip()))

    ok, out = _run([str(DATA)])
    say(f"  {'ok  ' if ok else 'FAIL'}  data layer · "
        f"{out.strip().splitlines()[0] if out.strip() else ''}")
    if not ok:
        found.append(("the data layer", out.strip()))

    if found:
        print(f"\n{len(found)} problem(s):\n")
        for what, detail in found:
            print(f"  {what}")
            for line in detail.splitlines()[-4:]:
                print(f"      {line}")
        return 1
    say("\neverything checks out")
    return 0


if __name__ == "__main__":
    sys.exit(main())
