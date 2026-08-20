"""Runs a machine holds that this client never submitted.

The store on a machine is the record of what has been run there. The registry
beside a client is a record of what that client asked for, which is a smaller
thing: work started from a terminal, work from an earlier session, work batched
straight onto the scheduler while a capability was being fixed — all of it lands
in the store and none of it lands here.

That difference is invisible until something reads the registry as though it
were the record. The results panel reads the store and was right. The versions
grid reads the registry, and on nineteen samples of finished work it drew two
cells for a capability with eighteen results and none at all for the one that
answers the cohort question, because those runs were submitted with `sbatch`
rather than through a client.

So this walks a site's store and records what the registry is missing. It adds;
it never rewrites a record that exists, because a record this client wrote knows
what was asked for and a reconstruction only knows what was read.

## What a reconstructed record can and cannot say

A manifest written since inputs carried their reference says outright what it
read. An older one recorded only the path, and a path cannot be turned back into
the reference that produced it: it cannot say which study or which version. The
store gets as far as `study:_/<something>` and the missing half is the study
name, which is a question about the machine rather than about the run. So it is
answered from what the machine reports holding, matching the sample the run is
about against the studies that have one by that name.

An adopted run therefore has a reconstructed identity, and it will only match a
submission that spelled the same inputs the same way. Where it does not, the
grid shows two versions of one piece of work rather than one, which is a wrong
answer in the direction of doing too much rather than of hiding it.
"""

from __future__ import annotations

import sys
from pathlib import Path

_TREE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_TREE / "interfaces" / "run"))
sys.path.insert(0, str(_TREE / "interfaces" / "naming"))

from protocol import JobRecord, JobSpec, JobState        # noqa: E402
import reference as _reference                           # noqa: E402

# Enough to cover a study's worth of work several times over. A store that holds
# more than this is one where the oldest runs are not what anybody is choosing
# between, and a listing is a walk over every manifest on the far side.
MOST = 2000


def _samples_by_study(datasets: list) -> dict:
    """Which study each sample name belongs to, from what the machine reported.

    Asked of the machine rather than parsed out of a path, because the path is
    the thing that has already lost the answer. It also survives the study being
    renamed or its data being laid out in versions, both of which happened here
    and either of which would have broken a rule written against the string.

    A name in two studies is dropped rather than guessed at: filing a run under
    the wrong study is worse than filing it under none, since only the second is
    visible to somebody reading the grid.
    """
    out: dict = {}
    seen: set = set()
    for row in datasets or []:
        study = row.get("study")
        for name in row.get("samples") or []:
            if name in seen and out.get(name) != study:
                out.pop(name, None)
                continue
            seen.add(name)
            out.setdefault(name, study)
    return out


def _reference_for(ref: str, sample: str, studies: dict) -> str:
    """One reconstructed reference, with the study filled in where it is known.

    `study:_/<x>` is the store saying "data, and this is the last thing on the
    path". When `<x>` is the sample, the reference is that sample. When it is
    anything else it is a part of the sample — a role, or the folder a role is
    kept in — and the sample is the one the run as a whole turned out to be
    about, which the store has already worked out by following what was read.
    """
    if not ref.startswith("study:_/"):
        return ref
    tail = ref[len("study:_/"):]
    study = studies.get(sample)
    if not study:
        return ref
    return (f"study:{study}/{sample}" if tail == sample
            else f"study:{study}/{sample}/{tail}")


def record_for(row: dict, site: str, studies: dict) -> JobRecord:
    """One store listing row, as the record a client would have kept."""
    capability = (f"{row['domain']}/{row['capability']}" if row.get("domain")
                  else row.get("capability", ""))
    sample = row.get("sample") or ""
    inputs = {name: _reference_for(str(ref), sample, studies)
              for name, ref in (row.get("inputs") or {}).items()}
    return JobRecord(
        job_id=row["run"],
        spec=JobSpec(capability=capability,
                     version=row.get("version") or "",
                     inputs=inputs,
                     site=site,
                     parameters=dict(row.get("parameters") or {}),
                     workspace=row.get("workspace") or "default"),
        executor=site,
        # Only finished work is adopted, so there is one state it can be in. A
        # run still going is the submitting client's to report on; a run that
        # failed left no manifest and so is not here to find.
        state=JobState.COMPLETED,
        submitted_at=row.get("finished") or "",
        updated_at=row.get("finished") or "",
        detail="adopted from the store on " + site,
    )


def reconcile(executor, registry, *, site: str = "", limit: int = MOST) -> list[str]:
    """Record what the store holds and the registry does not. Returns the ids.

    Never raises on a machine that cannot answer. This runs while a client is
    starting, beside the other things asked of every site at that moment, and a
    cluster in maintenance is not a reason for the app not to come up.
    """
    site = site or getattr(executor, "site", "") or ""
    try:
        found = executor.runs(None, None, limit)
    except Exception:                    # noqa: BLE001 - one machine, not all
        return []
    if not found:
        return []
    try:
        studies = _samples_by_study(executor.datasets())
    except Exception:                    # noqa: BLE001 - reconstruct what we can
        studies = {}
    try:
        known = {r.job_id for r in registry.all()}
    except Exception:                    # noqa: BLE001
        return []
    added = []
    for row in found:
        run = row.get("run")
        if not run or run in known:
            continue
        try:
            registry.put(record_for(row, site, studies))
        except Exception:                # noqa: BLE001 - one row, not the listing
            continue
        added.append(run)
    return added
