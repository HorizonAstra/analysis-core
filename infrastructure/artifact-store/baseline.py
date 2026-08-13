#!/usr/bin/env python3
"""Record what a seeded run produced, or hold a later run against it.

`verify` proves the inputs to a computation are unchanged. A baseline proves the
outputs are. Those are different claims and only the second settles whether a
refactor was safe.

    baseline.py --record <outdir>          keep this run as the reference
    baseline.py --check  <outdir>          compare this run against it

Both read the run_manifest.json that run.py leaves in the output directory, so
there is nothing to keep in step by hand.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import date
from pathlib import Path

BASELINES = Path(__file__).resolve().parent / "baselines"   # beside the tool that writes them


def manifest(outdir: Path) -> dict:
    path = outdir / "run_manifest.json"
    if not path.exists():
        raise SystemExit(f"no run_manifest.json under {outdir}. Was this "
                         f"produced by run.py?")
    return json.loads(path.read_text())


def fingerprint(m: dict) -> str:
    """Short hash over the inputs and parameters a run was given.

    A baseline is a claim about one computation on one set of inputs. Without
    this in the name, a second sample either overwrites the first or looks like
    a duplicate, and neither is right: they are two legitimate baselines for the
    same capability. Parameters are included because the same files at a
    different seed are a different run.
    """
    inputs = m.get("inputs") or {}
    parts = [f"{k}={v.get('sha256')}" for k, v in sorted(inputs.items())]
    parts += [f"{k}={v}" for k, v in sorted((m.get("parameters") or {}).items())]
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:8]


def name(m: dict, when: str | None = None) -> str:
    return (f"{m['capability']}-{m['profile']}-{fingerprint(m)}-"
            f"{when or date.today().isoformat()}.json")


def existing(m: dict) -> list[Path]:
    """Every baseline for this capability on this site, any inputs."""
    return sorted(BASELINES.glob(f"{m['capability']}-{m['profile']}-*.json"))


def matching(m: dict) -> list[Path]:
    """Those recorded against the same inputs and parameters as this run."""
    fp = fingerprint(m)
    out = []
    for p in existing(m):
        try:
            if fingerprint(json.loads(p.read_text())) == fp:
                out.append(p)
        except (json.JSONDecodeError, KeyError):
            continue
    return out


def record(outdir: Path, force: bool, reason: str | None = None) -> int:
    m = manifest(outdir)

    # A baseline of a run that cannot be reproduced is worse than none: it
    # invites a later comparison that was always going to fail, and makes the
    # failure look like a regression.
    if not m.get("reproducible", False):
        print(f"Refusing: this run drew from the RNG with no seed, so it will "
              f"not reproduce.\nA baseline has to be something a later run can "
              f"match. Re-run with --seed.", file=sys.stderr)
        return 1

    if m.get("resumed_steps"):
        print(f"note: {m['resumed_steps']} step(s) were carried over from an "
              f"earlier invocation.\n      The identity was checked to be "
              f"identical, so the outputs stand, but this\n      was not one "
              f"continuous execution.")

    # Only a baseline over the same inputs is a duplicate. A different sample is
    # a different baseline and coexists with this one.
    prior = matching(m)
    if prior and not force:
        print(f"{m['capability']} already has a baseline on {m['profile']} for "
              f"these exact inputs:")
        for p in prior:
            print(f"  {p.name}")
        others = [p for p in existing(m) if p not in prior]
        if others:
            print(f"({len(others)} more for this capability over other inputs, "
                  f"which are untouched.)")
        print("\nPass --force with --reason to record another over the same inputs. "
              "That is a\nclaim that something legitimately changed, so it has to say what.")
        return 1

    # A forced re-record says the old reference is wrong. Keeping the reason and
    # what it replaced is the difference between a corrected baseline and a
    # laundered regression, and it costs one line at the moment someone knows
    # the answer.
    if prior:
        m["supersedes"] = [q.name for q in prior]
        m["superseded_reason"] = reason

    target = BASELINES / name(m)
    target.write_text(json.dumps(m, indent=2) + "\n")
    print(f"recorded {target.name}")
    print(f"  {len(m.get('outputs', {}))} output(s), "
          f"{len(m.get('inputs', {}))} input(s), by content hash")
    return 0


def check(outdir: Path) -> int:
    m = manifest(outdir)

    # Compare against the baseline built from the same inputs. Picking the most
    # recent one regardless would compare this sample against another sample and
    # report every output as changed.
    prior = matching(m)
    if not prior:
        others = existing(m)
        if others:
            print(f"no baseline for {m['capability']} on {m['profile']} over "
                  f"these inputs.\nThere are {len(others)} for other inputs:",
                  file=sys.stderr)
            for p in others:
                print(f"  {p.name}", file=sys.stderr)
            print("\nComparing across different inputs would report every "
                  "output as changed and\nmean nothing. Record a baseline for "
                  "this one.", file=sys.stderr)
        else:
            print(f"no baseline for {m['capability']} on {m['profile']}. "
                  f"Record one first.", file=sys.stderr)
        return 1
    base = json.loads(prior[-1].read_text())
    print(f"against {prior[-1].name}\n")

    problems = 0

    # Inputs first. Identical outputs from different inputs would be the
    # surprising result, and different outputs from different inputs is not a
    # finding at all, so this has to be settled before the outputs mean anything.
    for label, key in (("input", "inputs"), ("parameter", "parameters")):
        was, now = base.get(key) or {}, m.get(key) or {}
        for k in sorted(set(was) | set(now)):
            a = was.get(k, {}).get("sha256") if key == "inputs" else was.get(k)
            b = now.get(k, {}).get("sha256") if key == "inputs" else now.get(k)
            if a != b:
                print(f"  {label} '{k}' differs: {a} -> {b}")
                problems += 1
    if problems:
        print("\nThe two runs were not given the same thing, so any difference "
              "in the outputs\nbelow says nothing about the code.")

    for key, label in (("kernel_sha256", "kernel file"),
                       ("image_digests", "image")):
        was, now = base.get(key) or {}, m.get(key) or {}

        # A digest says what the code is; a path says only where it currently
        # sits. The same bytes under a new path is a relocation, and reporting
        # that as a changed computation is how people learn to ignore this
        # check. Compare the digests first, and name the moves.
        if sorted(was.values()) == sorted(now.values()):
            gone = {d: p for p, d in was.items() if p not in now}
            for path in sorted(k for k in now if k not in was):
                where = gone.get(now[path])
                print(f"  {label} relocated, contents unchanged:"
                      f"\n               {where}\n            -> {path}")
            continue

        for k in sorted(set(was) | set(now)):
            if was.get(k) != now.get(k):
                print(f"  {label} '{k}' changed since the baseline")
                problems += 1

    print("\noutputs:")
    was, now = base.get("outputs") or {}, m.get("outputs") or {}
    volatile = m.get("volatile_outputs") or {}
    if volatile != (base.get("volatile_outputs") or {}):
        print("  note: the two runs filtered different lines before hashing, so "
              "the digests\n        below are not answering the same question")
        problems += 1
    same = 0
    for k in sorted(set(was) | set(now)):
        a, b = was.get(k), now.get(k)
        if a == b:
            note = "  (ignoring " + ", ".join(volatile[k]) + ")" if k in volatile else ""
            print(f"  identical  {k}{note}")
            same += 1
        elif a is None:
            print(f"  NEW        {k}, absent from the baseline")
            problems += 1
        elif b is None:
            print(f"  MISSING    {k}, the baseline has it")
            problems += 1
        else:
            print(f"  DIFFERS    {k}")
            print(f"               baseline {a[:16]}")
            print(f"               this run {b[:16]}")
            problems += 1

    print()
    if problems == 0:
        print(f"PASS: all {same} output(s) byte identical to the baseline.")
        return 0
    print(f"FAIL: {problems} difference(s). Either the computation moved, or "
          f"something\n      unpinned changed underneath it.")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--record", metavar="OUTDIR")
    g.add_argument("--check", metavar="OUTDIR")
    ap.add_argument("--reason", help="Why the previous baseline is no longer right. Required with --force, and stored in the new baseline.")
    ap.add_argument("--force", action="store_true",
                    help="Record even when a baseline already exists.")
    args = ap.parse_args()

    if args.record:
        if args.force and not args.reason:
            print("--force needs --reason. Replacing a reference without saying why "
                  "is how a\nregression becomes the new normal.", file=sys.stderr)
            return 2
        return record(Path(args.record), args.force, args.reason)
    return check(Path(args.check))


if __name__ == "__main__":
    sys.exit(main())
