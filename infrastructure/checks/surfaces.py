"""Check that the surface we describe is the surface we serve.

A capability is offered to a model twice over. `render.py --as mcp` writes the
tool schema — that is the surface, the thing you can read, diff and hand to
somebody integrating against this. And the MCP server builds a live tool at
registration, which is what a model actually receives. Both are generated from
the same catalog entry, and for a while both generated it separately.

They drifted, in the way this always goes. The live one told a caller that an
input is a *reference* and how to write one, and said whether a capability
reasons about one sample or about the set. The rendered one said neither. So the
published description of the surface was a weaker document than the surface, and
anybody working from it would write calls that a model was being told not to
write.

Nothing noticed, because the render check asks whether each entry *renders* — it
runs the target and looks at the exit code. A render that succeeds and disagrees
with reality passes that, and passed it for as long as the two existed.

Both now compose their text from `interfaces/catalog/entry.py`, which is the
vocabulary each already imports, so the drift is fixed. This is what keeps it
fixed: it renders every entry, asks the server what it serves, and compares.

The server is reached by running it rather than importing it. Infrastructure does
not depend on a client, and a check is not the place to make an exception — so
this shells out exactly as `all.py` shells out to everything else.

    surfaces.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
RENDER = TREE / "infrastructure" / "render-targets" / "render.py"

# Ask the server what it serves. Run in the clients partition because that is
# where its imports resolve from, and printed as JSON because that is the one
# thing a subprocess boundary carries without either side knowing the other.
_ASK = """
import sys, json, asyncio
sys.path.insert(0, "mcp-server")
import mcp_server
mcp, _ = mcp_server.build()
print(json.dumps([{"name": t.name, "description": t.description,
                   "inputSchema": t.inputSchema}
                  for t in asyncio.run(mcp.list_tools())]))
"""


def served() -> dict[str, dict]:
    """Every tool the MCP server offers, by name."""
    # This machine's own environment, not a scrubbed one. Which capabilities are
    # offered depends on what each site can actually run, so a stripped PATH
    # hides every capability whose interpreter it hid — and the check quietly
    # compares six of them instead of fourteen while still reporting success.
    done = subprocess.run([sys.executable, "-c", _ASK], capture_output=True, text=True,
                          cwd=str(TREE / "clients"),
                          env={**os.environ, "ANALYSIS_SITES": "local"})
    if done.returncode != 0:
        raise RuntimeError((done.stderr or done.stdout).strip()[-600:])
    return {t["name"]: t for t in json.loads(done.stdout)}


def rendered(path: Path) -> dict | None:
    """One entry as the MCP surface, or None when it does not render as one."""
    done = subprocess.run([sys.executable, str(RENDER), str(path), "--as", "mcp"],
                          capture_output=True, text=True)
    return json.loads(done.stdout) if done.returncode == 0 else None


def main() -> int:
    try:
        live = served()
    except RuntimeError as e:
        print(f"could not ask the server what it serves:\n{e}", file=sys.stderr)
        return 1

    wrong, compared = [], 0
    for path in sorted((TREE / "domains").glob("*/catalog/*.json")):
        r = rendered(path)
        if r is None:
            continue
        # A capability no machine here can run is not offered, which is correct
        # and is not a disagreement. Only what is served can be compared.
        t = live.get(r["name"])
        if t is None:
            continue
        compared += 1
        if r["description"] != t["description"]:
            wrong.append((r["name"], "the tool description"))
        for field, spec in r["inputSchema"]["properties"].items():
            mine = t["inputSchema"]["properties"].get(field)
            if mine is None:
                wrong.append((r["name"], f"{field} is rendered but not served"))
            elif spec.get("description") != mine.get("description"):
                wrong.append((r["name"], f"what {field} says"))

    if wrong:
        print("the rendered surface and the served surface disagree:\n")
        for name, what in wrong:
            print(f"  {name}: {what}")
        print("\nBoth are built from the catalog entry. Whatever differs is being "
              "composed in one of them rather than taken from "
              "interfaces/catalog/entry.py.")
        return 1

    print(f"{compared} served capabilities match what they render as")
    return 0


if __name__ == "__main__":
    sys.exit(main())
