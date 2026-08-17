"""Check the four rules that hold the partitions apart.

The rules are only worth writing down if something reads them back. Each is a
statement about who may import whom, so each is decidable by reading the imports
rather than by remembering:

    1  An interface depends on nothing.
    2  Infrastructure never depends on a domain.
    3  A domain never depends on infrastructure.
    4  Nothing depends on a client.

A violation is not always a mistake to fix today. A file inherited from before
the split may break a rule and still be the best available code, so this reports
what it finds and leaves the judgement to a person. It exits non-zero so that a
new violation cannot arrive unnoticed.

    dependencies.py            report every violation
    dependencies.py --known    ignore the ones recorded in KNOWN below
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(TREE / "interfaces" / "catalog"))

import entry as C                                               # noqa: E402

PARTS = ("interfaces", "domains", "infrastructure", "clients")

# What a module name tells you about which partition it belongs to. Imports here
# are by module rather than by path, since every entry point puts its own
# dependencies on sys.path, so the mapping has to be by name.
OWNERS = {
    "entry": "interfaces", "protocol": "interfaces", "reference": "interfaces",
    "profile": "infrastructure", "registry": "infrastructure", "store": "infrastructure",
    "datasource": "infrastructure", "provenance": "infrastructure",
    "local": "infrastructure", "slurm_ssh": "infrastructure",
    "executors": "infrastructure", "reachable": "infrastructure",
}

# Violations that exist and are accepted for now, each with why. Anything not
# listed is new, and new is what this is for.
KNOWN = {
    ("domains/microbiome/kernels/python/study.py", "infrastructure"):
        "Inherited from the client era: it discovers and loads studies itself, which is "
        "infrastructure's job. Under the run interface a kernel is handed its inputs as "
        "declared paths. Not yet rewritten, and uncontracted, so nothing runs it.",
}


# Directories holding code this tree did not write: virtual environments and
# vendored packages. Skipped, and not because reading them is slow. The module
# names the rules key on are ordinary words — `local`, `profile`, `store`,
# `entry` — and a third-party file importing one of them is not this tree
# reaching across a partition. Reading them also meant the rules reported
# somebody else's syntax warnings as their own output.
VENDORED = (".venv", "venv", "site-packages", "environments", "node_modules",
            "__pycache__")


# Records of runs, rather than code. A baseline is named after the capability
# that produced it, so every one of them names a domain — which is a fact about
# what was run, not infrastructure reaching for a domain. `duplication.py` skips
# the same directory, for the same reason in its own terms.
RECORDS = ("infrastructure/artifact-store/baselines",)


def ours(path: Path) -> bool:
    """Whether a file is this tree's own code rather than something installed."""
    if any(part in VENDORED for part in path.parts):
        return False
    where = str(path.relative_to(TREE))
    return not any(where.startswith(r + "/") for r in RECORDS)


def partition(path: Path) -> str | None:
    rel = path.relative_to(TREE).parts
    return rel[0] if rel and rel[0] in PARTS else None


def imports(path: Path) -> set[str]:
    try:
        tree = ast.parse(path.read_text(errors="replace"))
    except SyntaxError:
        return set()
    out = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            out |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            out.add(node.module.split(".")[0])
    return out


def violations() -> list[tuple[str, str, str]]:
    """(file, partition it reaches into, what it imported)."""
    found = []
    for path in sorted(TREE.rglob("*.py")):
        part = partition(path)
        if part is None or not ours(path):
            continue
        rel = str(path.relative_to(TREE))
        for name in imports(path):
            owner = OWNERS.get(name)
            if owner is None or owner == part:
                continue
            broken = (
                (part == "interfaces") or
                (part == "infrastructure" and owner == "domains") or
                (part == "domains" and owner == "infrastructure") or
                (owner == "clients")
            )
            if broken:
                found.append((rel, owner, name))

    # Rule 2 has a second form that no import shows: infrastructure naming a
    # domain in a string is the same dependency, just harder to see.
    names = [p.name for p in (TREE / "domains").iterdir() if p.is_dir()]
    for path in sorted((TREE / "infrastructure").rglob("*.py")):
        if not ours(path):
            continue
        text = path.read_text(errors="replace")
        code = re.sub(r'("""|\'\'\')(?:.|\n)*?\1', "", text)      # docstrings are prose
        code = re.sub(r"#.*", "", code)
        for n in names:
            if re.search(rf"['\"]{re.escape(n)}['\"]", code):
                found.append((str(path.relative_to(TREE)), "domains", f"the name {n!r}"))

    # And a third form, which is the one that actually got through: a file in
    # infrastructure that is not Python at all. Reading imports cannot see a
    # shell script, and neither could the search above, so TumorSpace's whole
    # benchmark harness sat in `infrastructure/checks/` — `run_benchmark.sh`
    # describing itself as an end-to-end test of one domain's pipeline, calling
    # that domain's containers, while every rule about partitions held in the
    # only sense anything could see. Nine files, moved out on 2026-08-16.
    #
    # A domain's directory name is the wrong thing to look for here, because
    # those files say `bayesspace` and `tumorspace_core`, never
    # `spatial-transcriptomics`. What they do say is the names of capabilities,
    # and the catalog already holds every one of those. Nothing is listed by
    # hand: a new capability is searched for the day it is added.
    for path in sorted((TREE / "infrastructure").rglob("*")):
        if not path.is_file() or path.suffix == ".py" or not ours(path):
            continue
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        for word, domain in domain_words().items():
            if re.search(rf"\b{re.escape(word)}\b", text, re.IGNORECASE):
                found.append((str(path.relative_to(TREE)), "domains",
                              f"the {domain} capability {word!r}"))
                break
    return found


# Words that belong to one domain and to nothing else, taken from the catalog.
#
# A capability id is only usable as a signal if it could not turn up innocently
# in infrastructure prose. `chart`, `slab`, `assemble`, `correlation` and
# `harmonize` are ordinary English and this check would cry wolf on every one of
# them, so the test is that a name be long enough and not a plain word — which
# leaves the ones that are somebody's software: bayesspace, growchain, maaslin3.
_ORDINARY = {"chart", "assemble", "correlation", "harmonize", "slab",
             "run_code", "de_analysis", "differential_abundance",
             "tree_bundle", "toolchain_report", "region_finder", "cohort_sgp",
             "spatialview_bundle"}


def domain_words() -> dict[str, str]:
    out = {}
    for path in C.entry_paths(TREE):
        name = path.stem
        if len(name) >= 6 and name not in _ORDINARY:
            out[name] = path.parents[1].name
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--known", action="store_true",
                    help="Ignore the violations recorded as accepted.")
    a = ap.parse_args()

    found = violations()
    new = [v for v in found if (v[0], v[1]) not in KNOWN]
    shown = new if a.known else found

    if not shown:
        print(f"all four rules hold across {len(PARTS)} partitions"
              + (f", with {len(found)} accepted violation(s) recorded" if found else ""))
        return 0

    for rel, owner, what in shown:
        note = KNOWN.get((rel, owner))
        print(f"  {rel}")
        print(f"      reaches into {owner}: {what}")
        if note:
            print(f"      accepted: {note}")
    print(f"\n{len(shown)} violation(s).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
