"""That every shape of data a domain declares is still found and still resolves.

Written because a change to how studies are recognised broke one domain's data
and passed every check there was. The reason it passed is worth stating plainly:
the checks only ever saw the data on the machine running them. That was seven
microbiome studies, all one flat folder of tables, and the break was in the shape
nobody had locally — a spatial study laid out as one folder per sample, where
every sample folder was mistaken for a version of the study and the samples then
resolved to nothing.

So this builds the data instead of looking for it. Each domain already declares
what its data looks like, in `domains/<name>/study.json`, and that declaration is
enough to lay out a folder that satisfies it. Every shape of every domain gets
one, including the shapes this machine has never held, and each is put through
the two questions that matter:

    discovery       is it found, as the right domain and the right shape
    resolution      do the references anyone would write against it resolve

Then the same folder again with its data kept in versions, because that is the
one layout where the two questions can disagree — a study can be found and its
samples still resolve to the wrong place.

Adding a domain adds nothing here. It declares its shape, and its shape is
checked, which is the same arrangement as the catalog: infrastructure runs on the
description rather than on a list kept beside it.

    data_layer.py           run it
    data_layer.py --quiet   only what failed
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(TREE / "infrastructure"))

from datasource import domains as D                                  # noqa: E402
from datasource import local as L                                    # noqa: E402
from datasource import refs as R                                     # noqa: E402

VERSION = "2026-01-01"          # any name will do; a version is not a date


def _named(keyword: str, extensions: tuple) -> str:
    """A filename that fills a role, given one of the keywords naming it.

    A role is matched by substring against the file's name, and only files with
    one of the shape's extensions are looked at, so the name has to satisfy both.
    A keyword that already carries an extension is used as it stands.
    """
    if any(keyword.lower().endswith(e) for e in extensions):
        return keyword
    return keyword + (extensions[0] if extensions else ".csv")


def _roles_into(where: Path, dataset) -> None:
    where.mkdir(parents=True, exist_ok=True)
    for keys in dataset.roles.values():
        if keys:
            (where / _named(keys[0], dataset.extensions)).touch()


def _lay_out(study: Path, dataset) -> list[str]:
    """A folder shaped the way one declaration says this domain's data looks.

    Where a shape says its samples *are* its children, the roles describe a
    sample and not the study, so the study itself holds nothing but folders.
    Putting role files at the root too would build a study no instrument writes,
    and a check that passes on data nobody has is worth nothing.
    """
    study.mkdir(parents=True, exist_ok=True)
    if dataset.sample_dir != ".":
        _roles_into(study, dataset)
    if not dataset.sample_dir:
        return []
    root = study if dataset.sample_dir == "." else study / dataset.sample_dir
    made = ["S1", "S2"]
    for name in made:
        _roles_into(root / name, dataset)
    return made


def _versioned(study: Path) -> None:
    """The same study, with everything it holds moved under one named version."""
    holding = study.parent / (study.name + ".moving")
    study.rename(holding)
    study.mkdir()
    holding.rename(study / VERSION)


def _check(root: Path, name: str, domain: str, dataset, made: list[str],
           versioned: bool) -> list[str]:
    """Both questions, asked of one laid-out study."""
    said = []

    def wrong(what: str) -> None:
        said.append(f"{domain} · {dataset.id}{' · versioned' if versioned else ''}: {what}")

    found = L.scan_studies(str(root))
    if name not in found:
        wrong(f"not discovered at all. Found: {', '.join(sorted(found)) or 'nothing'}")
        return said                       # nothing else can be asked
    if found[name]["domain"] != domain:
        wrong(f"discovered as domain '{found[name]['domain']}'")
    kind = D.dataset_of(found[name]["dir"], domain)
    if kind != dataset.id:
        wrong(f"discovered as shape '{kind or 'nothing'}'")

    kept = R.versions_of(name, str(root))
    if versioned and kept != [VERSION]:
        wrong(f"versions are {kept or 'not reported'}, expected ['{VERSION}']")
    if not versioned and kept:
        wrong(f"reports versions {kept}, but its data is not kept in versions. "
              f"Anything asking for the newest would read one of those instead "
              f"of the study")

    def resolves(reference: str, why: str) -> None:
        try:
            got = R.resolve(reference, data_root=str(root))
        except Exception as e:            # noqa: BLE001 - that is the finding
            wrong(f"{reference} does not resolve ({e})")
            return
        if not Path(got).exists():
            wrong(f"{reference} resolves to {got}, which is not there")
        elif why == "sample" and Path(got).name != reference.rsplit("/", 1)[-1]:
            wrong(f"{reference} resolves to {got}, which is not that sample")

    resolves(f"study:{name}", "study")
    # Where the samples are the study's own children, a role is something a
    # sample has. Asking for it at the study is asking the wrong question, so the
    # check asks the one somebody would actually write.
    for role in dataset.roles:
        if dataset.sample_dir == ".":
            for sample in made:
                resolves(f"study:{name}/{sample}/{role}", "role")
        else:
            resolves(f"study:{name}/{role}", "role")
    for sample in made:
        resolves(f"study:{name}/{sample}", "sample")
        if versioned:
            resolves(f"study:{name}@{VERSION}/{sample}", "sample")

    if versioned:
        try:
            R.resolve(f"study:{name}@no-such-version", data_root=str(root))
            wrong("a version that does not exist resolved instead of being refused")
        except R.Unresolvable:
            pass
        except Exception as e:            # noqa: BLE001
            wrong(f"an unknown version failed with {type(e).__name__}, not Unresolvable")
    return said


def run() -> list[str]:
    """Every shape of every domain, flat and in versions."""
    said = []
    for domain, spec in sorted(D.DOMAINS.items()):
        for dataset in spec.datasets:
            for versioned in (False, True):
                root = Path(tempfile.mkdtemp(prefix="data-layer-"))
                try:
                    name = f"Check{dataset.id.title().replace('_', '')}"
                    study = root / domain / name
                    made = _lay_out(study, dataset)
                    if versioned:
                        _versioned(study)
                    said += _check(root, name, domain, dataset, made, versioned)
                finally:
                    shutil.rmtree(root, ignore_errors=True)
    return said


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quiet", action="store_true", help="Only report failures.")
    a = ap.parse_args()
    shapes = sum(len(s.datasets) for s in D.DOMAINS.values())
    said = run()
    if said:
        print(f"{len(said)} problem(s) across {shapes} shapes in {len(D.DOMAINS)} domains:\n")
        for line in said:
            print(f"  {line}")
        return 1
    if not a.quiet:
        print(f"{shapes} shapes in {len(D.DOMAINS)} domains, "
              f"flat and in versions, all found and all resolving")
    return 0


if __name__ == "__main__":
    sys.exit(main())
