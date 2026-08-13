"""Which studies carry raw reads for SECONDARY analysis, and where those reads live.

A study declares its secondary-analysis input with a `secondary.json` manifest in its
folder:

    {"input_path": "/gpfs/.../reads",      # READ-ONLY reads on the compute side (Randi)
     "pair_identifier": "_R1_001",          # optional: how paired FASTQs are named
     "description": "..."}                  # optional: shown to the user

This is what makes secondary-analysis data DISCOVERABLE and ACCESS-CONTROLLED. The model
lists only studies the user is allowed to see (the data layer's ALLOWED_STUDIES gate),
and the reads path comes from this trusted manifest inside the study folder — never from
an arbitrary path the model or user typed. A study progresses: raw reads (this manifest)
-> pipeline -> reshaped tables -> a fully analyzable study.
"""

from __future__ import annotations

import json
import os

MANIFEST = "secondary.json"
_DEFAULT_DOMAIN = "microbiome"   # matches datasource.domains.DEFAULT_DOMAIN (pre-domain layout)


def _read(path: str) -> dict | None:
    """A manifest dict with a usable input_path, or None."""
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception:  # noqa: BLE001 - a malformed manifest is simply "no input here"
        return None
    return d if isinstance(d, dict) and d.get("input_path") else None


def _entry(domain: str, sdir: str, d: dict) -> dict:
    return {"domain": domain, "dir": sdir, "input_path": d.get("input_path"),
            "pair_identifier": d.get("pair_identifier"), "description": d.get("description")}


def find_manifests(data_root: str) -> dict[str, dict]:
    """{study -> {domain, dir, input_path, pair_identifier, description}} for every study under
    data_root carrying a secondary.json. Handles both data/<domain>/<study>/ and data/<study>/."""
    out: dict[str, dict] = {}
    root = os.path.abspath(data_root)
    if not os.path.isdir(root):
        return out
    for a in sorted(os.listdir(root)):
        if a.startswith("."):
            continue
        adir = os.path.join(root, a)
        if not os.path.isdir(adir):
            continue
        d = _read(os.path.join(adir, MANIFEST))       # data/<study>/ (pre-domain layout)
        if d:
            out[a] = _entry(_DEFAULT_DOMAIN, adir, d)
            continue
        for b in sorted(os.listdir(adir)):            # data/<domain>/<study>/
            if b.startswith("."):
                continue
            bdir = os.path.join(adir, b)
            if not os.path.isdir(bdir):
                continue
            d = _read(os.path.join(bdir, MANIFEST))
            if d:
                out[b] = _entry(a, bdir, d)
    return out


def resolve(data_root: str, study: str) -> dict | None:
    """The secondary-input manifest for one study, or None if it has none."""
    return find_manifests(data_root).get(study)
