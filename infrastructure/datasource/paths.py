"""Where the study data lives.

One resolver, used by every process that needs the data root, so the web app and the
tool server it spawns can never disagree about which directory they are reading.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def resolve_data_root(fallback, env_var: str = "DATA_ROOT") -> str:
    """The data directory: the env var if it names one that exists, else `fallback`.

    Two halves, and the second is the point. An unset variable falls back, which is what
    keeps a fresh checkout working with the bundled `data/` folder and no configuration.
    A variable that is set but points at nothing — a volume that did not mount, a path
    copied from another machine, a typo — also falls back, rather than being taken at its
    word and yielding an empty study list. An empty list reads as "this deployment has no
    data", which sends you looking in the wrong place; the fallback plus a line on stderr
    says what actually happened.

    The result is absolute. A relative DATA_ROOT would otherwise resolve against each
    process's working directory, and the tool server does not share the web app's.
    """
    fallback_path = Path(fallback).expanduser()
    configured = (os.environ.get(env_var) or "").strip()
    if not configured:
        return str(fallback_path.resolve())

    chosen = Path(configured).expanduser()
    if chosen.is_dir():
        return str(chosen.resolve())

    print(f"[datasource] {env_var}={configured!r} is not a directory; "
          f"falling back to {fallback_path.resolve()}", file=sys.stderr)
    return str(fallback_path.resolve())
