"""Check that no file exists twice in two partitions.

`dependencies.py` enforces who may import whom, and it enforces it by reading
imports. That catches infrastructure calling into a domain. It cannot catch
infrastructure that simply *contains* a domain, because a copied file imports
nothing — it is the same code, in a second place, answering to nobody.

Which is how the whole of `domains/spatial-transcriptomics/kernels` came to sit
a second time under `infrastructure/render-targets/`, 66 files of it. Every rule
about partitions held, in the sense the checker could see: no import crossed
anything. The science was there all the same, and a change to either copy left
the other one wrong — which by the time anyone looked had happened to 22 of them.

So this reads content rather than references. Two files with the same bytes in
two different partitions are one file that somebody duplicated, whatever the
import graph says about it. And where a copy is already recorded, two files at
one path that no longer match are the same problem after somebody edited one.

    duplication.py            report every duplicate
    duplication.py --known    ignore the ones recorded in KNOWN below

Same shape as `dependencies.py` deliberately, including the accepted list: a
duplicate that exists today is not always a duplicate to resolve today, and the
point of recording one is that a *new* one cannot arrive unnoticed.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import sys
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
PARTS = ("interfaces", "domains", "infrastructure", "clients")

# Code, rather than every file. Data, fixtures and lockfiles are legitimately
# identical in two places — a lockfile is *supposed* to be the same bytes
# wherever it pins the same environment — and reporting those would bury the one
# case this exists for.
SOURCE = (".py", ".R", ".r", ".jl", ".sh", ".js", ".ipynb")

# Below this, sameness means nothing. An empty `__init__.py` is identical to
# every other empty `__init__.py` and neither is a copy of the other.
ENOUGH = 200

# Directories holding code this tree did not write. The same list, and the same
# reason, as in `dependencies.py`: a vendored package appearing under two
# environments is two installs of somebody else's library, not duplication here.
VENDORED = (".venv", "venv", "site-packages", "environments", "node_modules",
            "__pycache__", ".git", ".retired")

# Duplicates that exist and are accepted for now, each with why.
#
# By directory pair rather than by file, because what is there is one copied
# tree and not thirty-three coincidences. Recording it file by file would say
# something false about how it happened, and would quietly accept a thirty-fourth
# the day somebody added one.
#
# It stays scoped: a duplicate anywhere else, or between either of these
# directories and a third place, is not covered and still fails.
KNOWN = {
    ("domains/spatial-transcriptomics/kernels",
     "infrastructure/render-targets/nextflow/workflow_scripts"):
        "TumorSpace shipped its Nextflow template as a self-contained directory "
        "and the copy came across with it: 66 files, the spatial kernels a "
        "second time inside infrastructure. NOT deletable as a unit. 39 files "
        "are identical, 22 have diverged from their twin in the domain — "
        "including sg_diff_abundance.jl, which the differential_abundance entry "
        "pins by hash, so the two are different science under one name — and 5 "
        "exist only here. Resolve file by file: confirm the Nextflow render "
        "target sources from the domain, reconcile each divergence against the "
        "pinned entry, and move what is unique to whoever owns it.",
}


def accepted(first: str, other: str) -> str:
    """Why this pair is on the list, or "" when it is not."""
    for (a, b), note in KNOWN.items():
        if (first.startswith(a + "/") and other.startswith(b + "/")) or \
           (first.startswith(b + "/") and other.startswith(a + "/")):
            return note
    return ""


def ours(path: Path) -> bool:
    return not any(part in VENDORED for part in path.parts)


def partition(path: Path) -> str | None:
    rel = path.relative_to(TREE).parts
    return rel[0] if rel and rel[0] in PARTS else None


def duplicates() -> list[tuple[str, str, str]]:
    """Every (path, other path, note) where one file's bytes appear twice.

    Sorted, and each pair reported once, so the output is stable enough to paste
    into KNOWN.
    """
    seen: dict[str, list[Path]] = {}
    for part in PARTS:
        for path in sorted((TREE / part).rglob("*")):
            if path.suffix not in SOURCE or not path.is_file() or not ours(path):
                continue
            try:
                body = path.read_bytes()
            except OSError:
                continue
            if len(body) < ENOUGH:
                continue
            seen.setdefault(hashlib.sha256(body).hexdigest(), []).append(path)

    out = []
    for paths in seen.values():
        if len({partition(p) for p in paths}) < 2:
            continue
        rel = sorted(str(p.relative_to(TREE)) for p in paths)
        for other in rel[1:]:
            out.append((rel[0], other, accepted(rel[0], other)))
    return sorted(out)


# Identical bytes is the easy half, and it is not the dangerous half.
#
# Hashing content finds the copy that was never touched. It cannot find the copy
# somebody edited, because editing it changes the hash and the two files stop
# looking related to anything measuring sameness — which is the exact moment
# they become worth reporting. Two files at the same path under a pair of
# directories that is known to be a copy, with different contents, are not two
# files: they are one file that has drifted, and if either is pinned by a
# catalog entry then the two are different science under one name.
#
# So divergence is looked for only where a copy has already been recorded. Doing
# it everywhere would compare unrelated files that happen to share a name, and
# `run_analysis.sh` appears in a lot of directories.
def diverged() -> list[tuple[str, str, int]]:
    """(path, its twin, lines differing) for same-path files in a KNOWN pair."""
    out = []
    for a, b in KNOWN:
        first, second = TREE / a, TREE / b
        if not first.is_dir() or not second.is_dir():
            continue
        for path in sorted(second.rglob("*")):
            if not path.is_file() or not ours(path):
                continue
            twin = first / path.relative_to(second)
            if not twin.is_file():
                continue
            try:
                if twin.read_bytes() == path.read_bytes():
                    continue
                lines = sum(1 for _ in difflib.unified_diff(
                    twin.read_text(errors="replace").splitlines(),
                    path.read_text(errors="replace").splitlines()))
            except OSError:
                continue
            out.append((str(twin.relative_to(TREE)),
                        str(path.relative_to(TREE)), lines))
    return sorted(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--known", action="store_true",
                    help="Ignore the duplicates recorded as accepted.")
    a = ap.parse_args()

    found = duplicates()
    drift = diverged()
    shown = [d for d in found if not (a.known and d[2])]

    if not a.known:
        for first, other, lines in drift:
            print(f"  {first}")
            print(f"      has DIVERGED from its copy at {other} ({lines} diff lines)")
        if drift:
            print()

    if not shown:
        print("no file appears in two partitions"
              + (f", with {len(found)} accepted duplicate(s) recorded" if found else "")
              + (f" ({len(drift)} of which have diverged)" if drift else ""))
        return 0

    for first, other, note in shown:
        print(f"  {first}")
        print(f"      is byte-identical to {other}")
        if note:
            print(f"      accepted: {note}")
    print(f"\n{len(shown)} duplicate(s), {len(drift)} diverged.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
