"""What data is available, as one question.

A capability takes file paths. A model can only supply one if something tells it
which files exist and what each one is, so this is the join between the data on
disk and the arguments a capability declares.

It is one tool rather than four. The four it replaces were a listing, a file
listing, an overview and a feature search, which existed because they were added
one at a time. What a caller actually needs is the study, its domain, and the
path for each role the domain declares, and that is a single answer.

Nothing here knows a domain. The roles, the file extensions and whether a study
is one wide table or a tree of samples all come from `domains/<name>/study.json`,
which the domain owns. Adding a domain adds a file.

Scope is not a tool. Which studies and domains a caller may see comes from the
session it is running in, enforced in the data layer, and there is deliberately
no way to ask for more from in here.
"""

from __future__ import annotations

import json
import os
from typing import Annotated

from pydantic import Field

import datasource as D


def _reference(row: dict) -> dict:
    """One site's answer, turned into references a caller can pass on."""
    name = row["study"]
    out = {k: row[k] for k in ("study", "domain", "kind", "is", "about", "site",
                               "also_on") if k in row}
    out["use"] = f"study:{name}"
    out["files"] = {role: f"study:{name}/{role}" for role in row.get("roles", [])}
    if row.get("samples"):
        out["samples"] = [f"study:{name}/{s}" for s in row["samples"]]
        out["sample_count"] = len(row["samples"])
    for key in ("each_sample_has", "some_samples_have"):
        if row.get(key):
            out[key] = row[key]
    return out


def _across(sites) -> list[dict]:
    """Every dataset every reachable site holds, asked of each of them.

    The asking is in infrastructure rather than here, because the web app needs
    the same answer to build its own menus and was reading one filesystem
    instead.
    """
    from executors import reachable
    return reachable.datasets(sites)


def register(mcp, *, sites) -> list[str]:
    def list_data(
        study: Annotated[str, Field(
            description="One study by name, for its full file list. Omit for all of them.",
        )] = "",
    ) -> str:
        """Study data available to this session, and how to name each part of it.

        Every value under `files` and `samples` is a reference. Pass one
        straight to a capability's input. Do not build paths and do not guess
        where anything is: the machine that runs the work resolves the
        reference, and it is the only one that can.

        An earlier run's output is named the same way, as `run:<id>/<output>`,
        which is how one analysis is fed into the next.

        This describes data, and only data. It does not know what has been
        computed from it, so a study appearing here in its raw form is not
        evidence that nothing has been run on it — results are held separately
        and are listed separately. Do not conclude from this answer that a study
        is unanalysed; ask for the runs as well.
        """
        rows = [r for r in _across(sites)
                if D.study_allowed(r["study"]) and D.domain_allowed(r["domain"])]
        visible = {r["study"]: _reference(r) for r in rows}
        if study:
            if study not in visible:
                raise KeyError(f"no study called {study}. Available: "
                               f"{', '.join(sorted(visible)) or 'none'}")
            return json.dumps(visible[study], indent=2)
        return json.dumps({"studies": [visible[k] for k in sorted(visible)]}, indent=2)

    mcp.add_tool(list_data, name="list_data",
                 description=("What study data is available, and the reference for "
                              "each part of it. Call this before any analysis: a "
                              "capability input takes one of these references, and "
                              "an earlier run's output is named run:<id>/<output>. "
                              "Data only: it cannot say what has already been "
                              "computed, so pair it with the run listing before "
                              "describing what a study does or does not have."))
    return ["list_data"]
