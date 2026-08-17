"""Check that the same file does not exist in two places.

`dependencies.py` enforces who may import whom, and it does it by reading
imports. That catches infrastructure calling into a domain. It cannot catch
infrastructure that simply *contains* a domain, because a copied file imports
nothing — it is the same code, in a second place, answering to nobody. Which is
how the whole of `domains/spatial-transcriptomics/kernels` came to sit a second
time under `infrastructure/render-targets/`, 66 files of it, with every rule
about partitions holding in the only sense the checker could see.

## What it took to make this actually work

The first version of this hashed file contents and compared them across
partitions. It reported nothing, and reporting nothing is what a check like this
does when it is broken, so it was worth trying to defeat before trusting. Four
attempts, all of which it missed:

  * a copy with one line changed, which is a different hash and therefore, to
    anything comparing hashes, an unrelated file;
  * an exact copy of a `.nf` file, and of a `.json` — neither extension was on
    the list it looked at, and the Nextflow pipeline is `.nf`;
  * an exact copy under the size floor it used to skip empty `__init__.py`.

The first is the one that matters. A copy nobody has touched is harmless and
findable; the danger is the copy somebody edited, because that is the one that
has started to disagree — and editing it is exactly what stops a hash from
relating it to anything. So similarity is the measure, not equality, and a size
floor and an extension list are both replaced by asking whether a file has
enough substance to be worth comparing at all.

The second version still had a hole, and a real file was sitting in it. Near
copies were looked for only among files *sharing a name*, on the reasoning that
comparing everything to everything would turn up files that merely resemble each
other. `infrastructure/sites/randi-main.json` was 96% the same as `randi.json`,
in the same directory, and went unreported for as long as the check existed —
because somebody renaming a copy is the most ordinary thing in the world, and
the check happened to be blind to exactly that. So every pair is compared now,
and what stops that costing anything is a cheap filter, not a narrow question.

    duplication.py            report every duplicate
    duplication.py --known    ignore the ones recorded in KNOWN below

Same shape as `dependencies.py`, including the accepted list: a duplicate that
exists today is not always one to resolve today, and the point of recording one
is that a *new* one cannot arrive unnoticed.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import sys
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
PARTS = ("interfaces", "domains", "infrastructure", "clients")

# Anything text, rather than a list of languages. The list was the bug: it held
# seven extensions and the tree contains Nextflow, JSON catalogs, configs and
# shell in a dozen more. Read a chunk and let the bytes say whether it is text.
_SAMPLE = 8192

# Files whose contents are legitimately identical wherever they appear, because
# something generated them to be. A lockfile pinning one environment is supposed
# to be the same bytes in every copy of that environment.
EXPECTED_SAME = ("lock", "requirements.txt", "renv.lock", ".sum", ".sha256")

# Records of things that happened, rather than code. A baseline is what one run
# produced on one date, and the next one is the same shape with different
# numbers in it — two records of two runs, not one file in two places. They were
# being reported at 84% alike, and there is one more of them after every run, so
# left alone this is a check that grows noisier the more the tree is used.
RECORDS = ("infrastructure/artifact-store/baselines",)

# How alike two files must be before this calls them one file in two places.
# Below this and they are simply two files that do a similar job, which is not
# the same claim and not one worth a check.
ALIKE = 0.80

# How much substance a file needs before sameness means anything. An empty
# `__init__.py` is identical to every other empty `__init__.py` and neither is a
# copy of the other. Counted in lines that say something rather than in bytes,
# because a byte floor also skips a short file that is a real duplicate.
SUBSTANCE = 8

# What it takes to be worth a real comparison. Comparing every file to every
# other one is 337 files and 56,616 pairs, and `difflib` on each of those is
# minutes; these two make it a second, by throwing out the pairs that cannot
# reach ALIKE before the expensive part runs.
#
# Length first, because it costs a subtraction: a sequence matcher's ratio is
# 2·matches ÷ total, so two files whose lengths differ by more than the shorter
# one cannot reach 0.80 however well they line up. Then shared lines, as a
# fraction of the shorter file — an upper bound on how much can possibly match,
# since a line that appears in only one of them can never be a match in either.
# Both are bounds rather than guesses, so nothing real is filtered out.
SHORTEST = 0.60
SHARED = 0.50

VENDORED = (".venv", "venv", "site-packages", "environments", "node_modules",
            "__pycache__", ".git", ".retired", ".cache", "outputs", ".userdata")

# Duplicates that exist and are accepted for now, each with why. Empty, and that
# is the intended state: the one large duplication in this tree is a migration
# copy, and migration copies are already written down. See `_migration`, below.
KNOWN: dict[tuple[str, str], str] = {}


# Where a file came from, when it came from the migration.
#
# Three repositories were copied into this one so they could be left untouched
# while this was built, and `_migration/manifest.tsv` records every placement:
# repo, source, destination, what was done, and why.
#
# This check did not read it at first. It found the largest of those copies, had
# no way to know it was recorded, and reported it as though it were a discovery.
# So the manifest was read — and used to *excuse* a pair, which was a worse
# mistake than not reading it. A destination is usually a directory, so one row
# excused everything that would ever be written into that directory, for good.
# `contracts/bin/baseline.py` is a single file the migration placed, and its row
# was silently excusing every artifact-store baseline; `contracts/profiles/`
# placed three site files, and its row was excusing a fourth that arrived later
# and duplicated one of them at 96%.
#
# The mistake underneath was treating provenance as an explanation. It is not.
# Knowing a file arrived by copy says nothing about whether it exists twice, and
# no source in this manifest was ever copied to two destinations — so the
# migration created no duplicate here at all. The one large duplication it was
# blamed for already existed in TumorSpace, between two of its own directories,
# and the migration carried both faithfully.
#
# So the manifest says where a side came from, printed beside the pair, and
# never decides anything. What is accepted is written in KNOWN, on purpose.
_MANIFEST = TREE / "_migration" / "manifest.tsv"


def _migrated() -> list[tuple[str, str]]:
    """(destination, where it came from) for every row the migration recorded."""
    rows = []
    try:
        text = _MANIFEST.read_text()
    except OSError:
        return rows
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        repo, source, dest = parts[0], parts[1], parts[2]
        if dest and dest != "-":
            rows.append((dest.rstrip("/"), f"{repo} {source}"))
    return rows


MIGRATED = _migrated()


def came_from(path: str) -> str:
    """Which repository this path was migrated out of, if the manifest says.

    Context printed beside a duplicate, never a reason to hide one. The longest
    matching destination wins, so a row for a file beats the row for the
    directory holding it.
    """
    best = ""
    for dest, source in MIGRATED:
        if (path == dest or path.startswith(dest + "/")) and len(dest) > len(best):
            best, found = dest, source
    return found if best else ""


def accepted(first: str, other: str) -> str:
    """Why this pair is not news, or "" when it is."""
    for (a, b), note in KNOWN.items():
        if (first.startswith(a + "/") and other.startswith(b + "/")) or \
           (first.startswith(b + "/") and other.startswith(a + "/")):
            return note
    return ""


def ours(path: Path) -> bool:
    if any(part in VENDORED for part in path.parts):
        return False
    where = str(path.relative_to(TREE))
    return not any(where.startswith(r + "/") for r in RECORDS)


def partition(path: Path) -> str | None:
    rel = path.relative_to(TREE).parts
    return rel[0] if rel and rel[0] in PARTS else None


def _lines(path: Path) -> list[str] | None:
    """A file's substantive lines, or None when it is not worth comparing.

    None means: not text, generated to be identical, or too slight for sameness
    to mean anything. Blank lines are dropped and indentation is normalised, so
    a copy that was reindented is still a copy. Comments are kept — a copy whose
    only change is a comment has still diverged, and that is worth seeing.
    """
    name = path.name.lower()
    if any(mark in name for mark in EXPECTED_SAME):
        return None
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if b"\0" in raw[:_SAMPLE]:
        return None                     # binary
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    kept = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return kept if len(kept) >= SUBSTANCE else None


def _files() -> dict[Path, list[str]]:
    """Every file in the four partitions worth comparing, with its lines."""
    out = {}
    for part in PARTS:
        for path in sorted((TREE / part).rglob("*")):
            if not path.is_file() or not ours(path):
                continue
            lines = _lines(path)
            if lines is not None:
                out[path] = lines
    return out


def duplicates(files: dict[Path, list[str]]) -> list[tuple[str, str, float, str]]:
    """Every (path, other, similarity, note) where one file exists twice.

    Identical content anywhere, and near-identical content anywhere. The second
    is what the hash-only version could not see, and it is the half that
    matters: a copy stops hashing alike the moment somebody edits it, which is
    the moment it starts to disagree with its original.

    Every pair is considered, under a name or under two. The version that only
    compared files sharing a name was answering a narrower question than the one
    worth asking, and it missed a 96% copy sitting beside its original under a
    different name. What keeps the wider question affordable is SHORTEST and
    SHARED above: both are bounds on what a pair could score, so a pair they
    reject could not have been reported anyway.
    """
    found: dict[tuple[str, str], tuple[float, str]] = {}
    paths = sorted(files)

    same: dict[str, list[Path]] = {}
    for path, lines in files.items():
        same.setdefault(hashlib.sha256("\n".join(lines).encode()).hexdigest(),
                        []).append(path)
    for alike in same.values():
        rel = sorted(str(p.relative_to(TREE)) for p in alike)
        for other in rel[1:]:
            found[(rel[0], other)] = (1.0, accepted(rel[0], other))

    marks = {p: frozenset(files[p]) for p in paths}
    for i, first in enumerate(paths):
        for other in paths[i + 1:]:
            short, long = sorted((len(files[first]), len(files[other])))
            if short < long * SHORTEST:
                continue
            if len(marks[first] & marks[other]) < short * SHARED:
                continue
            key = (str(first.relative_to(TREE)), str(other.relative_to(TREE)))
            key = (min(key), max(key))
            if key in found:
                continue
            ratio = difflib.SequenceMatcher(None, files[first],
                                            files[other]).ratio()
            if ratio >= ALIKE:
                found[key] = (ratio, accepted(*key))

    return sorted((a, b, r, n) for (a, b), (r, n) in found.items())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--known", action="store_true",
                    help="Ignore the duplicates recorded as accepted.")
    ap.add_argument("--across-partitions", action="store_true",
                    help="Only report a duplicate that crosses a partition.")
    a = ap.parse_args()

    files = _files()
    found = duplicates(files)
    if a.across_partitions:
        found = [d for d in found
                 if partition(TREE / d[0]) != partition(TREE / d[1])]
    shown = [d for d in found if not (a.known and d[3])]

    if not shown:
        print(f"{len(files)} files compared, none duplicated"
              + (f"; {len(found)} accepted duplicate(s) recorded" if found else ""))
        return 0

    for first, other, ratio, note in shown:
        how = "identical to" if ratio == 1.0 else f"{ratio * 100:.1f}% the same as"
        print(f"  {first}\n      is {how} {other}")
        for path in (first, other):
            source = came_from(path)
            if source:
                print(f"      {path} was migrated from {source}")
        if note:
            print(f"      accepted: {note}")
    print(f"\n{len(shown)} duplicate(s) across {len(files)} files compared.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
