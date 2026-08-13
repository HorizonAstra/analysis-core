"""The artifact store, reached without putting it on the import path.

Both this folder and `infrastructure/artifact-store/` contain a module called
`store`, and one is chat persistence while the other is where results live.
Flattening both onto `sys.path` would make which one answers `import store` an
accident of ordering, and the failure would be a chat writing into the results
tree or the reverse. So the store is loaded from its file, once, and everything
in the product goes through here.

What the product needs from it is small, and deliberately kept that way: what has
been run, and enough of one run's outputs to show someone.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

_TREE = Path(os.environ.get("ANALYSIS_CORE",
                            Path(__file__).resolve().parents[2]))
_STORE = _TREE / "infrastructure" / "artifact-store" / "store.py"


def _load():
    # The store imports the catalog reader by module name, so that has to be
    # reachable before it is executed.
    for p in (_TREE / "interfaces" / "catalog",):
        if str(p) not in sys.path:
            sys.path.insert(0, str(p))
    spec = importlib.util.spec_from_file_location("analysis_core_store", _STORE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_module = _load()
ArtifactStore = _module.ArtifactStore
MANIFEST = _module.MANIFEST


def for_site(profile: dict) -> ArtifactStore:
    """The store for one machine, at the root that machine's profile names."""
    return ArtifactStore(profile.get("artifact_root") or "~/.analysis-core/results")
