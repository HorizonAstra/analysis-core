"""The standing brief, assembled: what the model is told before anything is asked.

Factored out of any one front end so that every surface driving the model builds
the same prompt. What is in it is documented beside it, in `context/README.md`;
this file only decides which folders are read and in what order.

The brief comes from two places, and the split is the same one the rest of the
tree makes. What is true of every conversation is a client's to say, and lives
here. What is true of one kind of data is the domain's to say, and lives in
`domains/<name>/context/` beside that domain's catalog and its study
declaration, so that adding a domain never means editing a client.

A conversation is told about the domains it can actually reach and no others.
Passing none yields the shared brief alone, which is the honest state before
anything has been chosen.
"""

from __future__ import annotations

from pathlib import Path

_HERE = Path(__file__).resolve().parent
_TREE = _HERE.parent

_BASE_PROMPT = """You are an analyst working with a researcher on their own \
research data, through capabilities you call. What you can do, how work happens \
here, where judgment is required, and how to talk about it are described below. \
Follow it."""

_SEVERAL_DOMAINS = """This conversation spans more than one kind of data: {names}. \
Each section above applies only to data of its own kind. Their measurements, \
their units and their guardrails are not interchangeable, so do not carry a \
method, a threshold or an interpretation across from one to the other, and say \
which one a result came from whenever both are in play."""


def _read_dir(d: Path) -> list[str]:
    """Non-empty markdown in one folder, in filename order.

    Order is the filename because the brief is read as prose and its sections
    build on each other. README.md is developer-facing and skipped: it describes
    the brief rather than being part of it.
    """
    if not d.is_dir():
        return []
    return [t for md in sorted(d.glob("*.md")) if md.name.lower() != "readme.md"
            and (t := md.read_text().strip())]


def context_root() -> Path:
    """The shared brief: what every conversation is told."""
    return _HERE / "context"


def domain_context(domain: str) -> Path:
    """One domain's own brief, which the domain owns."""
    return _TREE / "domains" / domain / "context"


def build_system_prompt(domains=None) -> str:
    """The base frame, the shared brief, and a section per domain in scope.

    Every section is optional: a tree with no brief at all yields the frame
    alone rather than an error, which keeps a checkout usable before anything
    has been written. A single domain name is accepted as well as a list.
    """
    if isinstance(domains, str):
        domains = [domains]
    sections = [_BASE_PROMPT]

    shared = _read_dir(context_root())
    if shared:
        sections.append("=== HOW YOU WORK ===\n" + "\n\n".join(shared))

    named = []
    for domain in (domains or []):
        parts = _read_dir(domain_context(domain))
        if parts:
            named.append(domain)
            sections.append(f"=== THE DATA IN SCOPE: {domain} ===\n"
                            + "\n\n".join(parts))
    if len(named) > 1:
        sections.append("=== MORE THAN ONE KIND OF DATA IS IN SCOPE ===\n"
                        + _SEVERAL_DOMAINS.format(names=", ".join(named)))

    return "\n\n".join(sections)
