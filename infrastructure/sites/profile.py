"""Loading a machine description.

Separate from the catalog reader because a site file is infrastructure and the
catalog format is an interface, and an interface depends on nothing.
"""

from __future__ import annotations

import json
from pathlib import Path

PROFILES = Path(__file__).resolve().parent


def load_profile(name: str) -> dict:
    """A profile is chosen explicitly. An unknown name is an error rather than
    a silent fallback to some other host's settings."""
    # is_file, not exists: a bare name like "local" can collide with a directory
    # in the working tree, and opening that fails several frames from the cause.
    path = Path(name)
    if not path.is_file():
        path = PROFILES / f"{name}.json"
    if not path.is_file():
        available = sorted(p.stem for p in PROFILES.glob("*.json"))
        raise SystemExit(f"unknown profile '{name}'. available: {', '.join(available)}")
    with open(path) as fh:
        return json.load(fh)


