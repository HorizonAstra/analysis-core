"""What a person is offered, as the panel behind the info button.

Two kinds of thing belong in that panel and they come from different places.

What the client does is written here. How a chat picks its domains, what a study
selection means, how a group is defined: none of that is declared anywhere a
program could read, so a sentence about it has to be a sentence someone wrote.
It changes when this client changes, which is why it sits next to this client.

What the science does is read from the catalog. A domain says what each
capability is, which stage it sits at, and what it needs before it can run. That
was written by hand once and described a product two rewrites old, listing
measurements that are not loaded any more and tools that no longer exist. A
hand-written list of capabilities is wrong the first time someone adds one.

Between those sits a third case. Most of the statistics domain is not a
capability at all: it is methods that submitted code imports, and nothing
declared them, so nothing could show them and the panel offered two entries
where there are twenty one methods. The domain now declares them in
`methods.json`, and a check fails when that stops matching the files.

Everything is gated by the same access rules as the rest of the app, so nobody
is shown work they could not start.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import access

_TREE = Path(__file__).resolve().parents[2]
if str(_TREE / "interfaces" / "catalog") not in sys.path:
    sys.path.insert(0, str(_TREE / "interfaces" / "catalog"))
import entry as C     # noqa: E402

# What each stage means, in the terms the format's own schema uses. Named here
# rather than in the page, because the page should not know what a level is.
STAGES = {
    0: ("Preparation",
        "Turns what the instrument produced into the files every later step reads."),
    1: ("From One Sample",
        "Needs nothing except that sample's own measurements."),
    2: ("Built On An Earlier Result",
        "Reads what an earlier step produced for the same sample."),
    3: ("Built On That",
        "Describes a result that an earlier step already found."),
    4: ("Across Samples",
        "Answers for the whole set rather than for one sample in it."),
}

# How the client itself works. There is no declaration to read this off, so it is
# written, and it is kept to things that stay true as domains and capabilities
# come and go.
HOW_A_CHAT_WORKS = (
    {
        "name": "Domain Selection",
        "summary": "The kind of data a chat works in",
        "points": [
            "A domain is a kind of data. A chat works in one or more of them, "
            "chosen when it starts.",
            "They cannot be changed afterwards. Start a new chat to work with "
            "different ones.",
            "The domain decides which studies can be selected and which analyses "
            "apply.",
        ],
    },
    {
        "name": "Study Selection",
        "summary": "The studies a chat draws on",
        "points": [
            "Pick studies from the Studies button. Everything else applies to that "
            "selection.",
            "Select more than one to analyse them together. The study name stays in "
            "the comparison as a label.",
            "Each chat holds its own selection.",
        ],
    },
    {
        "name": "Orientation",
        "summary": "What a study holds, and what has already been done to it",
        "points": [
            "Every study you can reach, what kind of data it is, and how many "
            "samples it holds.",
            "What each sample carries, and which samples are missing a part the "
            "others have.",
            "Results already on the machine, including work finished before this "
            "chat started.",
        ],
    },
    {
        "name": "Cohort Creation",
        "summary": "Defining groups to compare",
        "points": [
            "Split on a field, a threshold, a time window, an earlier result, or a "
            "value derived from one.",
            "Conditions combine freely. Describe the split you want in words.",
            "A group is saved as a labelled table and can be used again in later "
            "questions.",
        ],
    },
)

# Ecosystems whose capabilities read a table rather than study data. They are
# offered alongside whatever a chat is about, so they are described on their own
# terms rather than folded into a science.
#
# This was the tuple ("statistics", "visualization"), written out here. Which
# ecosystems are general is a fact about them, not about this web page, and
# holding it here meant the client had to be edited for the tree to gain one —
# quietly, since nothing would have failed. Each ecosystem now says so itself,
# in its `domain.json`, and this reads the answer.
WORKS_ON_A_TABLE = tuple(
    sorted({p.parents[1].name for p in C.entry_paths(_TREE, general=True)}))


def _entries() -> list[dict]:
    return C.entries(_TREE)


def _title(contract: dict) -> str:
    """What to call a capability in front of a reader.

    Through the same helper the rest of the app uses, so a capability is called
    one thing everywhere a person sees it. One entry's own title describes how it
    works rather than what it answers, and that override already lives there.
    """
    import render
    return render.capability_title(f"{C.domain(contract)}/{contract['id']}")


def _shown(contract: dict) -> bool:
    """Whether an entry belongs in a description of what can be found out.

    Some entries exist to keep the system honest rather than to answer anything.
    They are still offered, because something has to be able to call them, but
    listing them here answers a question nobody asked.
    """
    return contract.get("purpose", "analysis") != "operations"


def _one(contract: dict, by_id: dict, *, ordered: bool = True) -> dict:
    """One capability, as a reader needs it.

    The sentence is the domain's own, written for a reader. Where a domain has
    not written one the summary's first sentence stands in, which says how the
    thing works rather than what it answers, and is the reason to write one.

    Whether it crosses samples is said only where samples are the subject. On a
    capability that reads whatever table it is handed the distinction is not
    about anything, and saying it there is noise that reads as meaning.
    """
    said = contract.get("for_people") or (
        contract.get("summary", "").split(". ")[0].rstrip(".") + ".")
    return {
        "name": _title(contract),
        "what": said,
        "needs": [_title(by_id[c]) for c in contract.get("consumes", []) if c in by_id],
        "across_samples": ordered and contract.get("scope") == "cross_sample",
    }


def _stages(contracts: list[dict]) -> list[dict]:
    """One domain's capabilities, in stage order.

    Empty stages are dropped rather than drawn empty, so a domain whose work is
    all of one kind reads as one column instead of a mostly blank row.
    """
    by_id = {c["id"]: c for c in contracts}
    out = []
    for level in sorted(STAGES):
        here = [c for c in contracts if c.get("level") == level]
        if not here:
            continue
        name, note = STAGES[level]
        out.append({"stage": name, "note": note,
                    "items": [_one(c, by_id) for c in
                              sorted(here, key=lambda c: _title(c))]})
    return out


def _methods(domain: str) -> list[dict]:
    """What a domain says it can compute beyond its catalog entries.

    Absent for most domains, whose science is all capabilities. Where it is
    present it is the larger part of what that domain can do.
    """
    path = _TREE / "domains" / domain / "methods.json"
    if not path.is_file():
        return []
    return [{"name": m["name"], "what": m["what"]}
            for m in json.loads(path.read_text()).get("methods", [])]


def _viewers(by_domain: dict, reachable: set) -> list[dict]:
    """Capabilities that produce something to look at rather than to read.

    Asked of the catalog, since a domain declares which of its outputs a viewer
    opens. Nothing on this side knows what a viewer is or which one it would be.
    """
    out = []
    for name, contracts in by_domain.items():
        if name not in reachable:
            continue
        by_id = {c["id"]: c for c in contracts}
        for c in contracts:
            if any(o.get("viewer") for o in c.get("outputs", [])):
                out.append(_one(c, by_id, ordered=False))
    return sorted(out, key=lambda x: x["name"])


def for_user(user: str) -> dict:
    """The panel this person may be shown."""
    from datasource import domain_allowed, domains as _domains
    reachable = set(access.accessible_domains(user))

    by_domain: dict[str, list[dict]] = {}
    for contract in _entries():
        if _shown(contract):
            by_domain.setdefault(C.domain(contract), []).append(contract)

    groups = [dict(g) for g in HOW_A_CHAT_WORKS]

    # One group per study domain, in the order a person meets them: the domains
    # they work in first, then what applies to any result from any of them.
    for name in sorted(reachable):
        contracts = by_domain.get(name, [])
        if not contracts:
            continue
        spec = _domains.spec(name)
        groups.append({
            "name": _domains.label(name),
            "summary": spec.notes if spec else "",
            "stages": _stages(contracts),
        })

    if by_domain.get("statistics") and domain_allowed("statistics"):
        methods = _methods("statistics")
        submitted = any(c.get("executes_submitted_code")
                        for c in by_domain["statistics"])
        if submitted:
            methods = methods + [{
                "name": "Anything Else",
                "what": "Questions the methods above do not cover. An analysis "
                        "written for the occasion is reported with its method and "
                        "its caveats.",
            }]
        groups.append({
            "name": "Statistics",
            "summary": "Applies to any table an analysis produced",
            "points": [
                "These read a table, whatever produced it. Nothing has to run "
                "first.",
                "Ask for the method by name, or describe the question and let it "
                "be chosen.",
            ],
            "topics": methods,
        })

    if by_domain.get("visualization") and domain_allowed("visualization"):
        points = [
            "Charts are drawn from any table an analysis produced, on the machine "
            "the table is on.",
            "Ask for a chart directly, or ask for the analysis and say you want it "
            "plotted.",
        ]
        seen = _viewers(by_domain, reachable)
        if seen:
            points.append("Some results can be opened and moved around rather than "
                          "read. Those are listed below.")
        groups.append({
            "name": "Visualization",
            "summary": "Charts, and results you can look at",
            "points": points,
            "topics": seen,
        })

    return {"groups": [g for g in groups if _has_content(g)]}


def _has_content(group: dict) -> bool:
    return bool(group.get("points") or group.get("topics") or group.get("stages"))


def as_json(user: str) -> str:
    return json.dumps(for_user(user), indent=2)
