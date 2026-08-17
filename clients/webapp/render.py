"""Presentation for the web product: what the reader is shown, and nothing about how it
was computed.

Split out of engine.py, which was carrying four jobs at once. Everything here is a pure
function of its arguments — no engine state, no MCP session, no per-user anything — which
is exactly why it does not belong in the orchestration loop.

Two rules shape all of it:

* **Never surface internal vocabulary.** The standing context forbids showing tool names,
  column layouts, paths, or the model's own code to ordinary users. So a step becomes a
  phrase in the reader's terms (`step_summary`), and the debugger's view of the same step
  (`tool_detail`) is kept for the developer view only.
* **Nothing the model writes reaches the browser as HTML.** `render_markdown` parses then
  sanitizes against a restrained allowlist; no scripts, styles, or raw HTML survive.
"""

from __future__ import annotations

import functools
import os
import re
import sys
from pathlib import Path
from urllib.parse import quote

import bleach
import markdown as _markdown

import config

_TREE = Path(__file__).resolve().parents[2]
if str(_TREE / "interfaces" / "catalog") not in sys.path:
    sys.path.insert(0, str(_TREE / "interfaces" / "catalog"))
import entry as C     # noqa: E402


def _tree() -> Path:
    """The tree to read the catalog from. ANALYSIS_CORE moves this folder."""
    return Path(os.environ.get("ANALYSIS_CORE", _TREE))


# How much of a step's input is shown in the activity trail.
ACTIVITY_CHARS = int(os.environ.get("LLM_ACTIVITY_CHARS", "4000"))

# Friendly, user-facing activity labels — what the system is doing, never the tool name
# (the standing presentation rules: don't surface internal vocabulary like run_code).
#
# The handful below are the platform's own, which belong to no domain and so are
# not in any catalog. Every capability's label comes from its entry instead, in
# the words the domain wrote, because a list kept here goes stale the moment
# someone adds a capability and the interface then quietly says the wrong thing.
TOOL_LABELS = {
    "list_data": "Looking over the available studies",
    "run_status": "Checking on the analysis",
    "run_result": "Reviewing a result",
    "list_runs": "Reviewing earlier work",
    "cancel_run": "Stopping the analysis",
    # One capability is overridden rather than taking its title. Its entry says
    # plainly that it runs submitted code, which is the right thing to tell the
    # model and the wrong thing to put in front of a reader: how an answer was
    # arranged internally is not part of the answer.
    "statistics_run_code": "Analyzing",
    # Their titles name the directory each one writes. What a reader wants to
    # know is that these are the things they can look at.
    "spatial-transcriptomics_spatialview_bundle": "Interactive tissue view",
    "spatial-transcriptomics_tree_bundle": "Region tree view",
}


@functools.lru_cache(maxsize=1)
def _catalog_labels() -> dict:
    """Tool name -> the title its domain gave it.

    A tool is named for its capability with the separator flattened, so the map
    is built by flattening the same way rather than by parsing the name back.
    Nothing internal reaches a reader: a title is prose written for one.
    """
    import json
    out = {}
    for path in C.entry_paths(_tree()):
        try:
            entry = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        qualified = f"{path.parents[1].name}/{entry.get('id', path.stem)}"
        out[qualified.replace("/", "_")] = entry.get("title") or entry.get("id", "")
    return out


@functools.lru_cache(maxsize=1)
def _writes_own_code() -> frozenset:
    """Capabilities whose kernel runs code written for the question.

    The distinction the results panel needs, and the domain already declares it.
    A named method produces an output that means the same thing every time it is
    run, so it can be listed, described and opened. A capability that executes
    submitted code produces whatever that code happened to write — which is why
    those rows read `saved.json` and nothing more useful could be said about
    them. They are the working material of an answer rather than the answer.

    Taken from the entry rather than by matching a name, so a second capability
    of this kind is handled by declaring itself, not by editing this.
    """
    import json
    out = set()
    for path in C.entry_paths(_tree()):
        try:
            entry = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if entry.get("executes_submitted_code"):
            out.add(entry.get("id", path.stem))
            out.add(f"{path.parents[1].name}/{entry.get('id', path.stem)}")
    return frozenset(out)


@functools.lru_cache(maxsize=1)
def _domain_by_capability() -> dict:
    """Which domain declares each capability, by bare id and by qualified id."""
    import json
    out = {}
    for path in C.entry_paths(_tree()):
        try:
            entry = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        domain, name = path.parents[1].name, entry.get("id", path.stem)
        out[name] = domain
        out[f"{domain}/{name}"] = domain
    return out


def domain_of(capability: str) -> str:
    """The domain a capability belongs to, however it was spelled.

    A capability is written qualified in one place and bare in another, so a
    caller holding one spelling cannot answer this by splitting on a slash that
    may not be there. Asked of the catalog, which is where the answer lives.
    """
    return _domain_by_capability().get(capability, "")


def is_working_material(capability: str) -> bool:
    """Whether a run's output is a person's result or an analysis's scratch work.

    Asked by the results panel, which lists the first and not the second. The run
    is kept either way and is still readable; this is about what is presented.
    """
    return bool(capability) and capability in _writes_own_code()


def activity_label(name: str) -> str:
    """What to show while a step runs. Never the tool name, never a path."""
    if name in TOOL_LABELS:
        return TOOL_LABELS[name]
    title = _catalog_labels().get(name)
    return title if title else "Working on the analysis"


def capability_title(name: str) -> str:
    """What a finished run is called.

    A manifest records the capability by its own id rather than by domain and
    id, since that is what the entry says, so the bare id is matched too. Two
    domains may use one id — differential abundance means something in both —
    and the entry titles differ, so a qualified name is preferred where there is
    one and the bare match is a fallback.
    """
    if not name:
        return "Analysis"
    labels = _catalog_labels()
    flat = name.replace("/", "_")
    tail = name.split("/")[-1]
    # An override wins wherever it is found, including on a bare id. A manifest
    # records the capability by its own id, so a check against the qualified
    # name alone would miss, and the one entry whose own title must not be shown
    # would be shown.
    if flat in TOOL_LABELS:
        return TOOL_LABELS[flat]
    for key, label in TOOL_LABELS.items():
        if key == tail or key.endswith("_" + tail):
            return label
    if flat in labels:
        return labels[flat]
    for key, title in labels.items():
        if key.endswith("_" + tail):
            return title
    return pretty_topic(tail)
def tool_detail(payload: dict) -> str:
    """The raw arguments of a tool call, for the developer view only.

    For the scratch space that is the code itself. This is deliberately not shown to
    ordinary users: it carries tool names, column layouts, file paths and the model's own
    working code — internal vocabulary the standing context says never to surface, and a
    debugger's view of a step rather than an account of it. See step_summary.
    """
    if not isinstance(payload, dict):
        return str(payload)[:ACTIVITY_CHARS]
    code = payload.get("code")
    if isinstance(code, str) and code.strip():
        text = code.strip()
    else:
        text = "\n".join(f"{k}: {v}" for k, v in payload.items()
                          if k not in ("code",) and v not in (None, ""))
    return text[:ACTIVITY_CHARS] + ("\n… (truncated)" if len(text) > ACTIVITY_CHARS else "")


# What each step is doing, in a reader's terms. The step trail exists so the process is
# followable, not so it can be audited line by line — the code and the exact arguments are
# already kept in the run log and on each artifact's manifest, which is where an audit
# belongs. A phrase per step also keeps internal vocabulary out of the transcript.
def _phrase(payload: dict, key: str, one: str, many: str) -> str:
    """'sample 5R' / '19 samples' / 'every sample', from an argument that may be a name,
    a list, or absent (which means all of them)."""
    v = payload.get(key)
    if v in (None, "", "all", "*"):
        return f"every {one}"
    if isinstance(v, (list, tuple, set)):
        return f"{len(v)} {many}" if len(v) > 1 else f"{one} {next(iter(v), '')}"
    return f"{one} {v}"


def step_summary(name: str, payload) -> str:
    """One line saying what a step did, in the user's terms.

    A capability's own title carries the sentence, so this adds only what the
    title cannot know: which study or sample it was pointed at. The alternative
    is a phrase written here per capability, which is the arrangement that left
    every step in this product reading "Worked on the analysis" the moment the
    capabilities were renamed.
    """
    p = payload if isinstance(payload, dict) else {}
    if name == "list_data":
        return (f"Looked over {p['study']}" if p.get("study")
                else "Checked which studies are available")
    if name == "run_result":
        return "Read the result back"
    if name == "run_status":
        return "Checked whether the analysis had finished"
    if name == "cancel_run":
        return "Stopped the analysis"
    if name == "list_runs":
        return "Reviewed the results so far"

    label = activity_label(name)
    where = p.get("sample") or p.get("study") or ""
    return f"{label} · {where}" if where and isinstance(where, str) else label


def scope_note(studies: list[str]) -> str:
    """The scope the user picked, stated to the model. Enforcement is real and lives in
    the data layer; this exists so the model knows the shape of its world up front rather
    than discovering it by getting a not-found back."""
    names = ", ".join(studies) if studies else "(none available)"
    return ("\n\n## Studies in scope for this conversation\n\n"
            f"{names}\n\n"
            "This scope is the user's own choice and it is the whole world here. Work "
            "within it. Do not mention, offer, or speculate about any study outside it; "
            "nothing outside it will load.")


def file_url(chat_id: str, ref: str, name: str) -> str:
    """Link to an artifact's bytes. Both parts are escaped: a ref carries a workspace path
    ("cross-study/A-B") and, for admin, an owner prefix ("someone::"), neither of which
    survives being pasted into a query string raw."""
    return (f"/api/results/file?chat_id={quote(chat_id)}"
            f"&ref={quote(ref, safe='')}&name={quote(name, safe='')}")

# A restrained allowlist: the model writes prose, lists, tables, code, and links — no
# raw HTML, scripts, or styles reach the browser.
_ALLOWED_TAGS = [
    "p", "br", "hr", "strong", "em", "del", "code", "pre", "blockquote",
    "ul", "ol", "li", "h1", "h2", "h3", "h4", "a", "span",
    "table", "thead", "tbody", "tr", "th", "td",
]
_ALLOWED_ATTRS = {"a": ["href", "title", "rel"], "span": ["class"], "code": ["class"]}


_LIST_ITEM = re.compile(r"^\s{0,3}(?:[-*+]|\d{1,9}[.)])\s+\S")
_TABLE_ROW = re.compile(r"^\s{0,3}\|.*\|\s*$")
_FENCE = re.compile(r"^\s*(?:```|~~~)")


def _loosen_blocks(text: str) -> str:
    """Insert the blank line python-markdown needs before a list or a table.

    Strict markdown only starts either one when a blank line separates it from the
    paragraph above. Models write a lead-in line and then the block with nothing between,
    which parses as one long paragraph full of literal dashes or pipes — the most visible
    rendering bug in chat prose, and the reason a perfectly good table arrives as a wall
    of vertical bars. A blank line is added only for the *first* row of a run, and never
    inside a fenced block or inside a block that has already started, so an item's wrapped
    continuation lines are not split off.
    """
    out: list[str] = []
    in_fence = in_block = False
    prev = ""
    for line in (text or "").split("\n"):
        if _FENCE.match(line):
            in_fence = not in_fence
        elif not in_fence:
            if not line.strip():
                in_block = False
            elif _LIST_ITEM.match(line) or _TABLE_ROW.match(line):
                if prev.strip() and not in_block:
                    out.append("")
                in_block = True
            else:
                in_block = False
        out.append(line)
        prev = line
    return "\n".join(out)


def render_markdown(text: str) -> str:
    """Model prose -> sanitized HTML. python-markdown for structure, bleach for safety."""
    html = _markdown.markdown(_loosen_blocks(text or ""),
                              extensions=["fenced_code", "tables", "sane_lists"])
    return bleach.clean(html, tags=_ALLOWED_TAGS, attributes=_ALLOWED_ATTRS, strip=True)


_DESC_MARKERS = re.compile(r"\s*\b((?:caveats?|notes?|warning|important)\s*:)", re.I)
_PARA_HEADER = re.compile(r"^([A-Z][^.:\n]{0,40}:)\s*(.*)$", re.S)


def format_description(text: str) -> str:
    """Artifact descriptions are free-form and often arrive as one dense paragraph. We add
    readability without imposing any format on what the model writes:
      * break before common markers (Caveat/Note/Warning/Important) into paragraphs;
      * bold a short leading 'Header:' prefix on each paragraph and capitalize the first
        letter after it.
    """
    if not text:
        return ""
    text = _DESC_MARKERS.sub(r"\n\n\1", text).strip()
    paras = []
    for para in text.split("\n\n"):
        para = para.strip()
        if not para:
            continue
        m = _PARA_HEADER.match(para)
        if m:
            prefix, rest = m.group(1), m.group(2).lstrip()
            if rest:
                rest = rest[0].upper() + rest[1:]
            para = f"**{prefix}** {rest}".rstrip()
        paras.append(f"- {para}")        # one bullet per paragraph
    return "\n".join(paras)


def json_cell(v):
    """One table cell as a JSON-safe Python value, at full float precision.

    Not a detail: pandas' to_json rounds doubles to 10 decimal places, so a p-value of
    1e-12 was reaching the browser as exactly 0. That is the one column in a differential
    result that must never be rounded, so cells are converted here instead.
    """
    def _finite(x):
        # NaN and the infinities have no JSON spelling, and the serializer rejects rather
        # than approximates them, so they become null here
        return None if (x != x or x in (float("inf"), float("-inf"))) else x

    if v is None:
        return None
    if isinstance(v, float):
        return _finite(v)
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, str)):
        return v
    if hasattr(v, "item"):                       # numpy scalar -> its Python equivalent
        try:
            n = v.item()
            return _finite(n) if isinstance(n, float) else n
        except Exception:  # noqa: BLE001 - fall through to the string form
            pass
    if hasattr(v, "isoformat"):                  # datetime / Timestamp
        return v.isoformat()
    return str(v)


def param_rows(params) -> list[dict] | None:
    """The manifest's parameter record, flattened for display.

    Two shapes reach here: a curated tool records the one call it is (`function`/`values`),
    and scratch code records the toolkit analyses a run invoked (`calls`). Both come out as
    a list of {function, values:[{name, value, defaulted}]}, because the reader wants the
    same thing either way — what was set, and what was merely left alone.
    """
    if not isinstance(params, dict):
        return None
    calls = params.get("calls") if "calls" in params else [params]
    out = []
    for c in calls or []:
        if not isinstance(c, dict) or not isinstance(c.get("values"), dict):
            continue
        defaulted = set(c.get("defaulted") or [])
        out.append({"function": c.get("function") or "analysis",
                    "values": [{"name": k, "value": v, "defaulted": k in defaulted}
                               for k, v in c["values"].items()]})
    return out or None


def pretty_topic(s: str) -> str:
    """A results folder is named by the topic the model chose, which may arrive slugged
    ("diversity-and-outcome"). Show it as a sentence, not as a filename."""
    text = str(s or "").replace("_", " ").replace("-", " ").strip()
    return (text[0].upper() + text[1:]) if text else str(s)

def empty_response_note(step: dict) -> str:
    """A clear message when a turn yields no text and no tool call (truncated or blocked),
    so the user never sees a blank turn."""
    fr = (step.get("finish_reason") or "").upper()
    if "MAX_TOKEN" in fr:
        return ("The response was cut off before any text came back. Try a shorter "
                "request, or raise the output limit (LLM_MAX_TOKENS).")
    if any(k in fr for k in ("SAFETY", "BLOCK", "PROHIBIT", "RECITATION")):
        return "The model declined to answer that."
    return "The model returned an empty response. Please try again."


def redact(msg: str) -> str:
    """Defense in depth: never let the API key surface in anything sent to the client,
    even if some upstream error were to echo it."""
    key = config.api_key()
    if key and len(key) >= 8 and msg and key in msg:
        return msg.replace(key, "[redacted]")
    return msg

