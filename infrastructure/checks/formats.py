"""Check that every format a domain declares can be turned into a filename.

An output is stored under the name its entry gave it — `all_results`, with no
extension — because the entry already says what it is. Everything that hands one
to a person has to put the extension back, and the store is where that happens,
from a table keyed by the formats the catalog uses.

Two lists, then, that have to agree: the formats domains declare, and the
formats the store can name a file for. Nothing makes them agree on its own. A
domain adding an output in a format the store has not heard of gets a download
with no extension and a content type of "unknown bytes", and it gets them
silently — the run succeeds, the file is correct, and it arrives as something
the person's computer will not open.

So this is the same arrangement as `methods.py`: the domain declares, the
infrastructure implements, and a check fails when one moves without the other.

Outputs only. An input's format describes how a kernel should read a staged
file; it never becomes a filename, and `spaceranger_or_harmonised` is a true
statement about an input that would be a nonsense extension.

    formats.py
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(TREE / "interfaces" / "catalog"))

import entry as C                                               # noqa: E402


def _store():
    """The store, loaded from its file, which is not on an import path."""
    sys.path.insert(0, str(TREE / "interfaces" / "catalog"))
    sys.path.insert(0, str(TREE / "interfaces" / "naming"))
    spec = importlib.util.spec_from_file_location(
        "analysis_core_store", TREE / "infrastructure" / "artifact-store" / "store.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.ArtifactStore


def declared() -> dict[str, list[str]]:
    """Every output format any domain declares, and who declares it."""
    out: dict[str, list[str]] = {}
    for path in C.entry_paths(TREE):
        try:
            entry = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        for o in entry.get("outputs", []):
            fmt = (o.get("format") or "").lower()
            if fmt:
                out.setdefault(fmt, []).append(f"{path.name}:{o['name']}")
    return out


def main() -> int:
    known = _store().formats()
    found = declared()
    unknown = {f: w for f, w in found.items() if f not in known}

    if unknown:
        print("formats the store cannot name a file for:\n")
        for fmt, where in sorted(unknown.items()):
            print(f"  {fmt}")
            for one in where:
                print(f"      declared by {one}")
        print("\nAdd each to _EXTENSION in infrastructure/artifact-store/store.py, "
              "with the extension a person's computer should see, and to _MEDIA if "
              "it is not already covered by that extension.")
        return 1

    # The other direction is not a failure. The store knowing how to name a
    # `.svg` that nothing currently produces costs nothing and is exactly what
    # should already be true the day something does.
    print(f"{len(found)} output format(s) declared across the catalog, all nameable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
