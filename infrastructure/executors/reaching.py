"""Whether a machine can reach what a reference names.

One question, asked of every executor, and answered the same way by each: a
study is checked against what that machine reported holding, a run against its
own store, and anything that is not a reference is a path, which is not this
layer's to judge.

Here rather than in each executor because it was in each executor, written out
twice, identical. That is fine until the reference grows a part — which it did,
when data started being kept in versions — and then it is two places to change
and one of them gets missed. Both copies read the version as part of the study
name and asked whether the machine held a study called `NSCLC@2026-08-13`. It
does not, so nothing could reach it, so work was routed to whichever machine
happened to come first.

An executor is passed in rather than inherited from, because what differs
between machines is how they answer, not what the question means.
"""

from __future__ import annotations

import sys
from pathlib import Path

_TREE = Path(__file__).resolve().parents[2]
if str(_TREE / "infrastructure") not in sys.path:
    sys.path.insert(0, str(_TREE / "infrastructure"))

from datasource import refs as _refs                            # noqa: E402

# How far back to look for a run when answering whether this machine holds it.
# Deep enough to cover a cohort's worth of work, since the answer decides where a
# submission goes and a wrong no sends it to the wrong machine.
LIMIT = 5000


def holds(executor, reference: str) -> bool:
    """Whether this machine can resolve one reference."""
    ref = str(reference or "")
    scheme, _, rest = ref.partition(":")
    if scheme == "study":
        named = _refs.study_parts(ref)
        return bool(named) and any(d.get("study") == named[0]
                                   for d in executor.datasets())
    if scheme == "run":
        run = rest.strip("/").split("/", 1)[0]
        return any(r.get("run") == run for r in executor.runs(limit=LIMIT))
    return True
