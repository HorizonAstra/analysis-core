"""Naming a piece of data without saying where it is.

A path says three things, and a client has no business knowing any of them:
which machine, which directory layout, and whether the caller can see it. Yet a
client was composing them, which is how a path from one machine could be handed
to a capability that runs on another. The mistake is not that the path was
wrong; it is that a client was in a position to get it wrong at all.

So an input is a reference. A reference says what the data is, and the machine
about to read it works out where. That machine is always the right one to ask,
because for a cluster job the runner is already on the cluster: the reference
travels unchanged and resolves on the far side, so nothing in between needs to
know anything.

    study:<name>/<role>              a role the domain declared, in one study
    study:<name>/<sample>            one sample of a study
    study:<name>@<version>/<sample>  that sample, in one version of the data
    study:<name>/<sample>/<role>     a role within one sample
    study:<name>/<sample>/<role>/x   something inside a role that is a folder
    run:<id>/<output>                an output of an earlier run
    run:<id>                         everything that run produced
    /some/path                       a literal path, still accepted

The last form is deliberate. A person at a terminal has a path in their hand and
should not have to invent a reference for it, and every script written before
this keeps working. What changed is that nothing is now *required* to know one.

There are exactly two places data comes from, which is the same distinction the
stages make: something recognised on disk, and something an earlier run
produced. A reference names one or the other, so a caller chaining one analysis
into the next says `run:...` and means it, rather than repeating a layout.
"""

from __future__ import annotations

import os
from pathlib import Path

from . import domains as _domains
from . import local as _local

# A third kind, beside a study's data and a run's output: something the machine
# itself provides. A deconvolution reference belongs to no study and is produced
# by no run, so without this it can only be a path someone types, which means the
# model cannot reach it and the capability is unreachable on every machine that
# has it. What each name points at is the site's answer, so a deployment that
# keeps its references elsewhere says so once in its profile.
SCHEMES = ("study", "run", "site")


class Unresolvable(Exception):
    """A reference that names nothing, said in terms of the reference."""


def looks_like_reference(value: str) -> bool:
    return isinstance(value, str) and value.split(":", 1)[0] in SCHEMES


def resolve(value, *, data_root: str | None = None,
            results_root: str | None = None,
            references: dict | None = None) -> Path:
    """One reference, as a path on this machine.

    Anything that is not a reference is taken to be a path already, so this is
    safe to put in front of every input rather than only the ones expected to
    carry one.
    """
    if not looks_like_reference(str(value)):
        return Path(value).expanduser().resolve()
    scheme, rest = str(value).split(":", 1)
    rest = rest.strip("/")
    if scheme == "study":
        return _study(rest, data_root or os.environ.get("DATA_ROOT", "data"))
    if scheme == "site":
        return _site(rest, references or {})
    return _run(rest, results_root or os.environ.get(
        "ANALYSIS_RESULTS", "~/.analysis-core/results"))


def _site(rest: str, references: dict) -> Path:
    """A reference this machine provides, by the name a profile gives it.

    Named rather than pathed, so a capability says what it needs and each
    deployment says where it keeps it. A machine that does not have one says so
    in those terms, because "this cluster has no tumorspace reference" is
    something an operator can act on and a missing path is not.
    """
    name, _, deeper = rest.partition("/")
    where = references.get(name)
    if not where:
        known = ", ".join(sorted(references)) or "none"
        raise Unresolvable(
            f"this machine provides no reference called '{name}'. It has: {known}. "
            f"A profile names each one under `references`.")
    root = Path(where).expanduser()
    return _within(root, deeper, f"site:{rest}") if deeper else root.resolve()


# How a reference names one version of a study's data:
#
#     study:NSCLC-Neoadjuvant/1N                 the newest version
#     study:NSCLC-Neoadjuvant@2026-08-13/1N      that one
#
# In the reference rather than beside it, and that is the whole point. A
# reference is resolved by the machine that does the work, and it is also what a
# run records as having read. Put the version anywhere else and two things break
# at once: the far side cannot know which data to open, and two runs over
# different data look identical to anything comparing what they read — which is
# exactly how re-use would hand back a result built from data that has since been
# replaced.
AT = "@"


def _versioned(name: str) -> tuple:
    """A study name split from the version it asks for, if it asks for one."""
    study, _, version = name.partition(AT)
    return study, version


def study_parts(reference) -> list:
    """A `study:` reference, split into the study and whatever it named inside.

    The study name comes back with no version on it, and that is the point of
    having this at all. A version says which copy of the data to read; it never
    says what the data is. So everything that asks "which study is this" — does
    this machine hold it, which sample was that run about, which study to file a
    result under — gets the same answer whether or not somebody pinned a
    version, and none of them has to learn that versions exist.

    There were six of these written out by hand, one wherever the question came
    up, and adding versions broke four of them at once: a reference carrying a
    version named a study called `NSCLC@2026-08-13`, which no machine holds, so
    the work was routed to whichever machine was first in the list. Splitting a
    reference is this file's job, and it is one line, which is exactly why it got
    written six times.

    Empty for anything that is not a study reference, so a caller can ask without
    checking first.
    """
    text = str(reference or "")
    if not text.startswith("study:"):
        return []
    parts = [p for p in text[len("study:"):].strip("/").split("/") if p]
    if parts:
        parts[0] = _versioned(parts[0])[0]
    return parts


def versions_of(study: str, data_root: str = "") -> list:
    """Every version of one study's data, newest first, empty when it has none.

    Which folders those are is not decided here. Discovery walks the tree once
    and already has to know a version from a sample to answer at all, so it says
    so in what it found, and this reads the answer. Working it out again from the
    directory is how the two came apart the first time: this file guessed, and in
    a harmonised spatial study every sample folder answered to the guess.
    """
    root = data_root or os.environ.get("DATA_ROOT", "data")
    return list((_local.scan_studies(root).get(study) or {}).get("versions") or [])


def _at_version(entry: dict, name: str, version: str) -> str:
    """The study directory for the version asked for, or for the newest.

    A study with no versions ignores this entirely, which is how a tree that has
    never been laid out in versions keeps resolving exactly as it did.

    Asking for no version asks for the newest, and discovery already reports the
    newest as the study's directory, so both cases are the same lookup.
    """
    if not version:
        return entry["dir"]
    found = entry.get("versions") or []
    if version not in found:
        raise Unresolvable(
            f"{name} has no version '{version}'. It has: "
            f"{', '.join(found) or 'no versions, so name it without @'}")
    return os.path.join(entry["root"], version)


def _study(rest: str, data_root: str) -> Path:
    """`<study>`, `<study>/<role>`, `<study>/<sample>`, `<study>/<sample>/<role>`.

    The allowlist is applied here and not only where studies are listed. Listing
    is how a caller learns what exists, and gating only that leaves the door
    open to anyone who names a study without being shown it: the reference
    resolved, the analysis ran, and the data came back. A menu is not a lock.

    A study that may not be seen is answered exactly as one that is not there,
    and the studies named in that answer are the permitted ones. Distinguishing
    the two cases would confirm the existence of everything it refused.
    """
    if not rest:
        raise Unresolvable("study: needs a study name")
    name, _, tail = rest.partition("/")
    name, version = _versioned(name)
    found = {k: v for k, v in _local.scan_studies(data_root).items()
             if _local.study_allowed(k)}
    if name not in found:
        raise Unresolvable(
            f"no study called {name}. Available: {', '.join(sorted(found)) or 'none'}")
    domain = found[name]["domain"]
    directory = _at_version(found[name], name, version)
    if not tail:
        return Path(directory).resolve()

    first, _, second = tail.partition("/")
    roles = _domains.match_roles(directory, domain)
    if first in roles:
        return _within(Path(roles[first]), second, f"{name}/{first}")

    # Otherwise the first part names a sample, and the second, if present, names
    # a role inside it. A domain whose data is per sample says so in its own
    # declaration, which is why nothing here has to know the tree's shape.
    samples = _domains.sample_dirs(directory, domain)
    if first not in samples:
        options = ", ".join(sorted(roles) + samples) or "nothing"
        raise Unresolvable(f"{name} has no '{first}'. It has: {options}")
    sample_dir = Path(_domains.sample_root(directory, domain)) / first
    if not second:
        return sample_dir.resolve()
    role, _, deeper = second.partition("/")
    within = _domains.match_roles(str(sample_dir), domain)
    if role not in within:
        raise Unresolvable(f"{name}/{first} has no '{role}'. It has: "
                           f"{', '.join(sorted(within)) or 'nothing'}")
    return _within(Path(within[role]), deeper, f"{name}/{first}/{role}")


def _within(target: Path, deeper: str, said_as: str) -> Path:
    """A resolved role, and whatever was named inside it.

    A role may be a directory, and a directory is often not the thing wanted:
    an instrument's run holds several folders and a capability asks for one of
    them. Naming it as part of the reference keeps that within the vocabulary of
    the data, rather than sending the caller back to building paths, which is
    the one thing references exist to prevent.

    It stays a reference and not a path. Nothing here can name a machine, a
    root, or anything outside the role it started from.
    """
    if not deeper:
        return target.resolve()
    if ".." in Path(deeper).parts:
        raise Unresolvable(f"{said_as}/{deeper} points outside {said_as}")
    inside = (target / deeper).resolve()
    if not inside.exists():
        holds = ", ".join(sorted(p.name for p in target.iterdir())) \
            if target.is_dir() else "nothing, it is a file"
        raise Unresolvable(f"{said_as} has no '{deeper}'. It holds: {holds}")
    return inside


def _run(rest: str, results_root: str) -> Path:
    """`<run>` or `<run>/<output>`, against the store on this machine."""
    if not rest:
        raise Unresolvable("run: needs a run id")
    run, _, output = rest.partition("/")
    store = _store(results_root)
    found = store.find(run)
    if not found:
        raise Unresolvable(f"no run called {run} under {results_root}")
    directory = found[0]
    if not output:
        return directory
    # Through the store rather than by joining a path, so an output the domain
    # said may not leave its machine is refused here too rather than reachable
    # by anyone who guesses its name.
    available = store.outputs(run)
    if output not in available:
        raise Unresolvable(f"run {run} has no output '{output}'. It has: "
                           f"{', '.join(sorted(available)) or 'none'}")
    return Path(available[output])


def _store(results_root: str):
    """The artifact store, loaded from its file.

    Imported here rather than at the top because the data layer does not
    otherwise depend on it, and because both this package and that directory
    contain modules whose names would collide if either were flattened onto the
    import path.
    """
    import importlib.util
    import sys
    tree = Path(__file__).resolve().parents[2]
    for p in (tree / "interfaces" / "catalog",):
        if str(p) not in sys.path:
            sys.path.insert(0, str(p))
    spec = importlib.util.spec_from_file_location(
        "analysis_core_store", tree / "infrastructure" / "artifact-store" / "store.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.ArtifactStore(results_root)
