"""The tool surface, assembled.

This file decides three things and nothing else: which machines this deployment
can reach, which capabilities each of them can run, and what a caller may see.
No capability is named here. Nothing about any science is written here. Adding a
domain, a capability or a machine changes no line of this file.

What is offered
    Every catalog entry that some reachable site can actually run, generated
    from the entry itself, plus one tool for finding data and four for handling
    a run. Offering a capability whose environment is not built anywhere invites
    the model to reach for an analysis that fails minutes later, so each site is
    asked, and each site answers for itself.

Where things run
    ANALYSIS_SITES is an ordered preference, `local` alone by default. Order is
    the whole routing rule: a capability whose environment is built here has no
    reason to cross a network, and one that needs a container image goes where
    the images are. A site whose profile describes a scheduler is reached over
    ssh; anything else runs in a subprocess here.

What a caller may see
    ALLOWED_DOMAINS and ALLOWED_STUDIES narrow it, read by the data layer.
    Scope is not a tool. It belongs to the session a caller is in, so there is
    no way to ask for more of it from inside the conversation.

    ANALYSIS_SITES=local,randi  DATA_ROOT=...  python3 mcp_server.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

_TREE = Path(__file__).resolve().parents[2]
for _p in ("interfaces/catalog", "interfaces/run", "infrastructure/sites",
           "infrastructure/executors", "infrastructure/artifact-store"):
    if str(_TREE / _p) not in sys.path:
        sys.path.insert(0, str(_TREE / _p))
# datasource is a package rather than a directory of scripts, so its parent goes
# on the path and not the directory itself. It also holds a `local.py`, and the
# executors hold another; flattening both would make which one wins an accident
# of ordering.
sys.path.insert(0, str(_TREE / "infrastructure"))

from mcp.server.fastmcp import FastMCP

from tools import catalog, data, prepare, scope


def build(mcp: FastMCP | None = None) -> tuple[FastMCP, dict]:
    """The server, and where each tool was routed. Returned so a check can read it."""
    mcp = mcp or FastMCP("analysis-core")

    # Which machines this deployment reaches, and how each one is built, is
    # infrastructure's answer rather than this file's. The web app needs the
    # same one to build its own menus, and when it had its own copy it was the
    # copy that was wrong.
    from executors import reachable
    sites = reachable.sites()

    import datasource as D
    routed = catalog.register(mcp, sites=sites, domain_allowed=D.domain_allowed)
    # Each site answers for the data it holds. One machine reading its own
    # filesystem and reporting that as everything both hides what is really
    # there and offers what the work will never reach.
    for name in data.register(mcp, sites=sites):
        routed[name] = "any"
    # Asking for a result several steps past the data, without threading each
    # handle into the next call by hand. The order comes from the same entries
    # every tool above is built from.
    for name in prepare.register(mcp, sites=sites, domain_allowed=D.domain_allowed):
        routed[name] = "any"
    # Which of this user's studies one conversation may reach. Offered only when
    # the client says it drives it, and never shown to the model.
    for name in scope.register(mcp):
        routed[name] = "here"
    return mcp, routed


def main() -> int:
    from executors import reachable
    mcp, routed = build()
    # To stderr: stdout is the protocol, and anything written there is a
    # malformed message rather than a log line.
    print(f"analysis-core: {len(routed)} tools across sites "
          f"{', '.join(reachable.names())}", file=sys.stderr)
    mcp.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
