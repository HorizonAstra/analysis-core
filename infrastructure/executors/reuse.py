"""Whether this exact work has already been done.

One sample was harmonised seven times in a day. Not seven variations: the same
sample, the same parameters, the same pinned kernel, seven runs that each read
the same bytes and wrote the same bytes. Their manifests agree digit for digit
on all five output hashes. Nothing asked whether the work already existed, so
the answer was always to do it again, at about two minutes and eighty megabytes
a time.

The identity of a run is what decides what it will produce:

    the capability, and the contract version
    the pinned kernel digests, from the catalog entry
    the container image digests, likewise
    the parameters
    what it reads

and nothing else. Not when it ran, not who asked, not which directory it landed
in. Two runs with the same identity produce the same bytes, which is not an
assumption here but the thing the manifests already record.

The subtle half is "what it reads". A reference like `run:harmonize-6aabda02/matrix`
names a *place*, and two identical harmonize runs sit in two places, so comparing
references would call two identical requests different and run both. So a run
reference is replaced by the identity of the run it names, worked out the same
way, all the way down. Identical inputs then compare equal however they were
produced, and a chain built on one copy is recognised as the chain built on the
other.

What this rests on: the catalog entry pins the kernel by digest, so editing a
kernel changes the entry and therefore the identity. An edit that does not
update the entry is a broken pin, which is what the freeze check exists to
catch, and it would have failed the run anyway.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

_TREE = Path(__file__).resolve().parents[2]
if str(_TREE / "interfaces" / "run") not in sys.path:
    sys.path.insert(0, str(_TREE / "interfaces" / "run"))
from protocol import JobRecord, JobState              # noqa: E402


def _contract_for(capability: str) -> dict:
    """The catalog entry for a capability, or {} when it cannot be read.

    Read rather than passed in, because the two executors reach it differently
    and neither of them should have to explain that here. An unreadable entry
    yields no pins, which makes a run's identity weaker and so makes reuse less
    likely rather than more: the safe direction to be wrong in.
    """
    if "/" not in capability:
        return {}
    domain, cap = capability.split("/", 1)
    path = _TREE / "domains" / domain / "catalog" / f"{cap}.json"
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def identity(records: dict, spec, seen: frozenset = frozenset()) -> str:
    """A digest of everything that decides what this run will produce.

    `records` is the registry's runs by id, used to follow a `run:` input back
    to what made it. `seen` stops a cycle; one cannot arise from legitimate use
    because a run is submitted before anything can reference it.
    """
    contract = _contract_for(spec.capability)
    env = contract.get("environment") or {}
    key = {
        "capability": spec.capability,
        "version": spec.version,
        # The pins, straight from the entry, which is exactly what the manifest
        # will record. So a run's identity here and its recorded identity after
        # the fact are the same thing computed at two different times.
        "kernel": (contract.get("kernel") or {}).get("sha256") or {},
        "images": env.get("digests") or {},
        "pinned_env": env.get("pinned_env"),
        "parameters": {k: spec.parameters[k] for k in sorted(spec.parameters or {})},
        "inputs": {name: _reads(records, ref, seen)
                   for name, ref in sorted((spec.inputs or {}).items())},
        # A shelf, not a destination — but two people keeping separate
        # workspaces are keeping them apart on purpose, and quietly serving one
        # of them the other's run would undo that.
        "workspace": spec.workspace,
    }
    return hashlib.sha256(
        json.dumps(key, sort_keys=True, default=str).encode()).hexdigest()


def _reads(records: dict, ref, seen: frozenset) -> str:
    """One input, as what it is rather than as where it is.

    A `run:` reference becomes the identity of the run that produced it, so two
    copies of the same result compare equal. Everything else is already a name
    for the data itself: `study:` names a study's own file, `site:` names
    something the machine provides, and a literal path names one place.
    """
    ref = str(ref)
    if not ref.startswith("run:"):
        return ref
    rest = ref[len("run:"):].strip("/")
    earlier, _, output = rest.partition("/")
    if earlier in seen:
        return ref                       # a cycle; fall back to the reference
    record = records.get(earlier)
    if record is None:
        return ref                       # not ours to see, so not comparable
    return f"{identity(records, record.spec, seen | {earlier})}/{output}"


def finished_match(registry, spec) -> JobRecord | None:
    """A completed run that already did exactly this, or None.

    Only completed runs. A failed one has nothing to hand back, and one still
    going is a different question: reusing it would mean returning a handle that
    is not finished, and every caller here treats a returned record as its own.

    Newest first, so that when several copies exist the one handed back is the
    one whose outputs are least likely to have been tidied away.

    A caller asking for this to be done anyway is answered with nothing, which
    is what `fresh` means: the point of asking is to have the work performed.
    """
    if getattr(spec, "fresh", False):
        return None
    try:
        records = {r.job_id: r for r in registry.all()}
    except Exception:                    # noqa: BLE001 - reuse is an optimisation
        return None
    if not records:
        return None
    try:
        wanted = identity(records, spec)
    except Exception:                    # noqa: BLE001 - as above, never fatal
        return None
    best = None
    for record in records.values():
        if record.state is not JobState.COMPLETED:
            continue
        if record.spec.capability != spec.capability:
            continue                     # cheap check before the expensive one
        try:
            if identity(records, record.spec) != wanted:
                continue
        except Exception:                # noqa: BLE001
            continue
        if best is None or (record.submitted_at or "") > (best.submitted_at or ""):
            best = record
    return best
