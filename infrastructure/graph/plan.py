#!/usr/bin/env python3
"""What has to run, in what order, for one capability on one sample.

Asking for a result usually means asking for four things. The interactive view
of a sample needs the sample prepared, then clustered, then its marker genes
found, and only then assembled, and every one of those is a separate call whose
output has to be threaded into the next by hand. Done by hand it is slow and it
is wrong sometimes, and the wrong one is the expensive kind: a bundle built
without markers looks finished and shows an empty list where the genes should
be.

None of that ordering is a judgement. It is written down already, in the entries
themselves:

    produced_by / produced_output   this input is an output of that capability
    from_role                       this input is a role a study sample holds
    is_sample_name                  this parameter is the sample's own name

So the chain is derived rather than typed out. Two rules decide it:

  * A sample that already holds something is not made to produce it again. A
    prepared sample is not prepared twice, and the tissue image can only come
    from the instrument's own run, so it is taken from there or the plan fails
    saying so.

  * What was asked for is filled as completely as it can be, including the
    optional inputs, because an optional input is usually the difference between
    a result and a result worth looking at. What that needs in turn is run only
    as far as it must be, or asking for one thing would run a whole domain.

Nothing here submits anything or touches a filesystem. It is handed what a
sample holds and returns the steps; the caller submits them, which is what keeps
this usable from a tool, from a script, and in a test.

    plan.py <domain>/<capability> --study S --sample X       print the plan
    plan.py ... --json                                       as data
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

_TREE = Path(__file__).resolve().parents[2]
for _p in (_TREE / "interfaces" / "catalog",):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))
import entry as C     # noqa: E402


class Impossible(Exception):
    """A chain that cannot be built, said in terms of what is missing."""


@dataclass
class Step:
    """One capability to run, with everything it needs already named."""
    capability: str                       # qualified, as in domain/id
    inputs: dict = field(default_factory=dict)
    parameters: dict = field(default_factory=dict)
    after: list = field(default_factory=list)   # qualified ids, earlier in this plan

    def as_dict(self) -> dict:
        return {"capability": self.capability, "inputs": dict(self.inputs),
                "parameters": dict(self.parameters), "after": list(self.after)}


def catalog(tree: Path | None = None) -> dict:
    """Every entry, by qualified id."""
    root = tree or _TREE
    out = {}
    for path in sorted((root / "domains").glob("*/catalog/*.json")):
        contract = C.load(path)
        out[C.qualified_id(contract)] = contract
    return out


def holdings(row: dict, sample: str) -> set:
    """Which roles are held, from what a site reported.

    With no sample named, the study's own roles: a study whose data is a set of
    tables describing every sample at once holds them itself, and there is no
    sample to ask. Discovery already reports those as `roles`, and reading only
    the per-sample keys said such a study held nothing — so nothing about it
    could be planned, and its preparation stayed hand-written.

    With a sample, what that sample holds. A cohort is rarely uniform, so what
    every sample has and what some have are reported separately, and the second
    names which ones. Reading only the first would say a sample lacks what it has.
    """
    if not sample:
        return set(row.get("roles") or [])
    holds = set(row.get("each_sample_has") or [])
    for role, who in (row.get("some_samples_have") or {}).items():
        if sample in (who.get("samples") or []):
            holds.add(role)
    return holds


def _from_site(spec) -> str | None:
    """The reference a machine-provided input gives.

    Not checked against anything here. Which machine will run this is not
    settled while planning, and only that machine can say whether it has one, so
    the reference is written and the resolving end answers for it.
    """
    return f"site:{spec}" if spec else None


def _asked_for(contract, given: dict) -> dict:
    """The parameters of one step, from what a caller asked for.

    A caller names parameters in free text, so what arrives here is whatever it
    chose to write rather than anything the contract vouched for. Two kinds of
    name are wrong, and they fail differently.

    A name the contract does not declare at all is dropped. The entry already
    carries a default for everything it takes, so the step still runs, correctly,
    with the value the catalog chose.

    A name that belongs to an *input* is refused. It cannot be quietly dropped,
    because a caller writing one believes it has chosen that input, and it cannot
    be passed on, because inputs and parameters are written into one flag
    namespace on the command line: the later one wins, so a parameter sharing an
    input's name silently replaces the reference the plan resolved. That is how
    `ref_dir` went from `site:tumorspace` to a bare relative path, which resolved
    against whatever directory the job happened to start in and did not exist.
    An input is chosen by naming a reference, and this says so in those terms.
    """
    declared = {p["name"] for p in contract.get("parameters", [])}
    clashes = sorted((set(given) & {i["name"] for i in contract["inputs"]}) - declared)
    if clashes:
        raise Impossible(
            f"{', '.join(clashes)} is an input of {C.qualified_id(contract)}, not a "
            f"parameter. An input is chosen by naming a reference for it, and this "
            f"one is already filled in. It takes: {', '.join(sorted(declared)) or 'no parameters'}.")
    return {k: v for k, v in given.items() if k in declared}


def _from_role(spec, study: str, sample: str, holds: set) -> str | None:
    """The reference a role gives, or None when it is not held.

    A role may be named with something inside it, since a role can be a
    directory and the thing wanted is often one folder of it. Only the role
    itself is checked against what is held; what is inside it is the resolving
    machine's business, and it is the only one that can look.

    With no sample, the role belongs to the study. Not every domain's data is
    per sample: a spatial study is a folder of Space Ranger runs and its roles
    live inside one of them, while a microbiome study is five tables describing
    every sample at once, and `study:Leukemia/metagenomics` is the whole of what
    there is to name. This built a sample segment unconditionally, so the second
    kind could not be planned for at all — a domain either fit the per-sample
    shape or did without any of this, which is why its preparation was being
    written out by hand each time.
    """
    for role in ([spec] if isinstance(spec, str) else list(spec or [])):
        where = f"{study}/{sample}" if sample else study
        if role == ".":
            return f"study:{where}"
        if role.split("/", 1)[0] in holds:
            return f"study:{where}/{role}"
    return None


def plan(target: str, *, study: str, sample: str, holds: set,
         entries: dict | None = None, parameters: dict | None = None) -> list:
    """The steps to get `target` for one sample, in the order they must run.

    `holds` is what that sample already has, as role names. `parameters` are
    keyed by qualified capability id, so a caller can set the clustering's
    parameters without knowing it is not the capability being asked for.
    """
    entries = entries if entries is not None else catalog()
    parameters = parameters or {}
    if target not in entries:
        raise Impossible(f"no capability called {target}. "
                         f"There is: {', '.join(sorted(entries))}")

    needed: dict = {}          # qualified id -> contract, in the order decided

    def require(qualified: str, *, optional_too: bool) -> None:
        if qualified in needed:
            return
        contract = entries.get(qualified)
        if contract is None:
            raise Impossible(f"{qualified} is named as a producer and is not a capability")
        needed[qualified] = contract
        for i in contract["inputs"]:
            wanted = i.get("required", True) or optional_too
            if not wanted:
                continue
            if i.get("from_site") or _from_role(i.get("from_role"), study, sample, holds):
                continue
            producer = i.get("produced_by")
            if producer:
                require(C.resolve_ref(producer, C.domain(contract)), optional_too=False)

    require(target, optional_too=True)

    # Fill each input now that it is known which capabilities are running. What
    # the sample already holds wins over running something to produce it again,
    # which is both less work and the only correct answer where the two are not
    # interchangeable: a capability that reads a sample directory is reading a
    # layout, and a run directory is not that layout however much of the same
    # data it holds.
    steps = []
    for qualified, contract in needed.items():
        domain = C.domain(contract)
        step = Step(capability=qualified)
        for i in contract["inputs"]:
            producer = i.get("produced_by")
            producer = C.resolve_ref(producer, domain) if producer else None
            role_ref = (_from_site(i.get("from_site"))
                        or _from_role(i.get("from_role"), study, sample, holds))
            if role_ref:
                step.inputs[i["name"]] = role_ref
            elif producer and producer in needed and producer != qualified:
                # '.' asks for the run itself rather than one output of it, which
                # is what an input wanting a directory of the producer's work
                # means. A reference with no output already says that.
                output = i.get("produced_output") or i["name"]
                step.inputs[i["name"]] = (f"run:{{{producer}}}"
                                          + ("" if output == "." else f"/{output}"))
                step.after.append(producer)
            elif i.get("required", True):
                raise Impossible(_missing(qualified, i, sample, holds))
        for p in contract.get("parameters", []):
            if p.get("is_sample_name"):
                step.parameters[p["name"]] = sample
        step.parameters.update(_asked_for(contract, parameters.get(qualified, {})))
        step.after = sorted(set(step.after))
        steps.append(step)

    return _ordered(steps)


def compose(target: str, *, study: str, sample: str, holds: set, have: dict,
            entries: dict | None = None, parameters: dict | None = None) -> Step:
    """One step, wired to runs that already exist rather than to runs to come.

    `plan` answers "what has to happen". This answers "what would it be, given
    what has already happened", which is the question when something is being
    rebuilt: a sample was clustered again, and the view of it should follow
    without re-running everything behind it.

    `have` maps a qualified capability id to a finished run id. An optional
    input with nothing to fill it is left out, which is how a rebuild stays
    possible before every optional piece exists.
    """
    entries = entries if entries is not None else catalog()
    parameters = parameters or {}
    contract = entries.get(target)
    if contract is None:
        raise Impossible(f"no capability called {target}")
    domain = C.domain(contract)
    step = Step(capability=target)
    for i in contract["inputs"]:
        producer = i.get("produced_by")
        producer = C.resolve_ref(producer, domain) if producer else None
        role_ref = (_from_site(i.get("from_site"))
                    or _from_role(i.get("from_role"), study, sample, holds))
        if role_ref:
            step.inputs[i["name"]] = role_ref
        elif producer and have.get(producer):
            output = i.get("produced_output") or i["name"]
            step.inputs[i["name"]] = (f"run:{have[producer]}"
                                      + ("" if output == "." else f"/{output}"))
        elif i.get("required", True):
            raise Impossible(_missing(target, i, sample, holds))
    for p in contract.get("parameters", []):
        if p.get("is_sample_name"):
            step.parameters[p["name"]] = sample
    step.parameters.update(_asked_for(contract, parameters.get(target, {})))
    return step


def viewer_targets(entries: dict | None = None) -> dict:
    """Capabilities that produce something to look at, and what feeds each.

    Read from the entries because that is where it is written: an output says
    which viewer opens it, and an input says which capability produces it. So
    "a view is out of date when one of these finishes" is derived rather than
    listed somewhere that would go stale when a domain adds a second viewer.
    """
    entries = entries if entries is not None else catalog()
    out = {}
    for qualified, contract in entries.items():
        if not any(o.get("viewer") for o in contract.get("outputs", [])):
            continue
        domain = C.domain(contract)
        out[qualified] = {C.resolve_ref(i["produced_by"], domain)
                          for i in contract["inputs"] if i.get("produced_by")}
    return out


def _missing(qualified: str, i: dict, sample: str, holds: set) -> str:
    """Why an input could not be filled, in terms of the data rather than the code."""
    role = i.get("from_role")
    roles = [role] if isinstance(role, str) else list(role or [])
    said = f"{qualified} needs '{i['name']}' and nothing here can supply it."
    if roles:
        said += (f" It comes from the sample itself, as "
                 f"{' or '.join(roles)}, and {sample} holds "
                 f"{', '.join(sorted(holds)) or 'nothing'}.")
    if not roles and not i.get("produced_by"):
        said += " It is not produced by any capability, so it has to be given."
    return said


def _ordered(steps: list) -> list:
    """The steps sorted so nothing runs before what it waits for."""
    by_id = {s.capability: s for s in steps}
    out, done = [], set()

    def place(name: str, seen: tuple = ()) -> None:
        if name in done:
            return
        if name in seen:
            raise Impossible(f"these wait on each other: {' -> '.join(seen + (name,))}")
        for earlier in by_id[name].after:
            place(earlier, seen + (name,))
        done.add(name)
        out.append(by_id[name])

    for s in steps:
        place(s.capability)
    return out


def describe(steps: list) -> str:
    """The plan as something to read before agreeing to run it."""
    lines = []
    for n, s in enumerate(steps, 1):
        lines.append(f"{n}. {s.capability}"
                     + (f"   after {', '.join(s.after)}" if s.after else ""))
        for name, ref in s.inputs.items():
            lines.append(f"     {name:16} {ref}")
        for name, value in s.parameters.items():
            lines.append(f"     {name:16} = {value}")
    return "\n".join(lines)


def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", help="Qualified capability, as domain/id.")
    ap.add_argument("--study", required=True)
    ap.add_argument("--sample", required=True)
    ap.add_argument("--data-root", default=None,
                    help="Where to look, when the sample is on this machine.")
    ap.add_argument("--holds", default=None,
                    help="Comma separated roles, instead of looking at a filesystem.")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    if a.holds is not None:
        holds = {r.strip() for r in a.holds.split(",") if r.strip()}
    else:
        sys.path.insert(0, str(_TREE / "infrastructure"))
        import os
        from datasource.discover import survey
        rows = survey(a.data_root or os.environ.get("DATA_ROOT", "data"))
        row = next((r for r in rows if r["study"] == a.study), None)
        if row is None:
            print(f"no study called {a.study} here", file=sys.stderr)
            return 2
        holds = holdings(row, a.sample)

    try:
        steps = plan(a.target, study=a.study, sample=a.sample, holds=holds)
    except Impossible as e:
        print(e, file=sys.stderr)
        return 1
    print(json.dumps([s.as_dict() for s in steps], indent=2) if a.json
          else describe(steps))
    return 0


if __name__ == "__main__":
    sys.exit(main())
