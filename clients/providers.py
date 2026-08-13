"""LLM provider adapters: one agentic tool-calling loop, swappable backends.

The standalone client orchestrates the model itself, so the model vendor is a *seam*,
not a baked-in dependency. Anthropic (Claude) is the default and the production path;
Google (Gemini) is an opt-in alternate for cheap/dev use. Each provider owns its own
native conversation history, so the Claude path is byte-for-byte what it always was;
the shared loop in chat_client only ever sees a normalized step:

    provider.add_user(text)
    step = provider.step(system)          -> {"text", "tool_calls", "thoughts",
                                              "finish_reason", "usage"}
    provider.add_tool_results(results)    <- [{id, name, blocks: [neutral blocks]}]

`usage` is that one step's token account in a normalized shape (see empty_usage), so the
caller can meter what a turn cost without knowing which vendor served it.

Everything vendor-specific stays behind this seam. In particular the Claude request
features — adaptive thinking, prompt caching, and server-side compaction — are configured
inside AnthropicProvider and are invisible to the loop driving it.

Select with env:  LLM_PROVIDER=anthropic | google     (default: anthropic)
Keys:             ANTHROPIC_API_KEY, or GEMINI_API_KEY / GOOGLE_API_KEY for Gemini.
Model override:   ANTHROPIC_MODEL, or GEMINI_MODEL / GOOGLE_MODEL.
Claude tuning:    ANTHROPIC_EFFORT (low|medium|high|xhigh|max, default medium), and
                  ANTHROPIC_THINKING / ANTHROPIC_CACHE / ANTHROPIC_COMPACT = 0 to switch
                  one of the three request features off.

"""

from __future__ import annotations

import base64
import os


# The model each provider falls back to when nothing sets one. Defined once, here, so a
# deployment overrides it in the environment rather than by editing code in several places.
DEFAULT_MODELS = {"anthropic": "claude-sonnet-5", "google": "gemini-2.5-flash-lite"}


# ── token accounting ────────────────────────────────────────────────────────────────
# One shape, filled by every provider, so metering is not vendor-specific. Tokens are the
# durable unit and the only thing recorded; converting them to money is a reporting
# concern that belongs wherever prices are configured, not in the provider seam.
USAGE_FIELDS = ("input_tokens", "output_tokens",
                "cache_read_input_tokens", "cache_write_input_tokens")


def empty_usage() -> dict:
    """A zeroed token account in the normalized shape."""
    return dict.fromkeys(USAGE_FIELDS, 0)


def add_usage(total: dict | None, delta: dict | None) -> dict:
    """Sum two token accounts. Missing or unknown keys count as zero, so a provider that
    cannot report one of the fields degrades to 0 instead of breaking the caller."""
    out = empty_usage()
    for part in (total, delta):
        for field in USAGE_FIELDS:
            out[field] += int((part or {}).get(field) or 0)
    return out


def _count(obj, attr: str) -> int:
    """A token count off an SDK usage object, tolerating absent objects and null fields."""
    return int(getattr(obj, attr, 0) or 0)


def _flag(name: str, default: bool = True) -> bool:
    """A boolean switch from the environment; '0'/'false'/'no'/'off' turn a feature off."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() not in ("0", "false", "no", "off", "")


def extract_error_message(exc: Exception) -> str | None:
    """A human-readable message from a provider SDK exception, or None if it isn't one.

    Provider-agnostic on purpose: both the Anthropic and google-genai SDKs put the
    server's own message on `.message` (e.g. a quota/rate-limit explanation), so this
    surfaces that directly and a newly added provider usually needs no extra work. Returns
    None for ordinary Python errors so the caller can fall back to a generic message
    rather than leaking an internal traceback.
    """
    top = (type(exc).__module__ or "").split(".")[0]
    is_api = top in ("anthropic", "google") or hasattr(exc, "status_code") or hasattr(exc, "status")
    if not is_api:
        return None
    msg = getattr(exc, "message", None)
    if not msg:
        body = getattr(exc, "body", None) or getattr(exc, "details", None)
        if isinstance(body, dict) and isinstance(body.get("error"), dict):
            msg = body["error"].get("message")
    return str(msg).strip() if msg else None


# ── durable conversation history ────────────────────────────────────────────────────
# A provider's history is native (SDK block objects) so the request is byte-for-byte what
# the vendor expects. To survive a restart it has to become JSON and come back unchanged:
# a thinking block carries a signature the API verifies, and a compaction block is what
# lets the API drop the summarized history instead of us resending it. Both are dropped by
# any "just keep the text" approach, which is why the whole block goes through here.
_INTERRUPTED_TOOL = "This tool did not finish: the analysis was interrupted before it returned."


def _plain(value):
    """A JSON-safe copy of native content that preserves every field.

    Provider SDKs return pydantic block objects, and the same blocks are accepted as plain
    dicts on the way back in; that symmetry is what makes a conversation persistable.
    Nothing is filtered out, because we cannot tell which fields the vendor will check.
    """
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json", exclude_none=True)
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(v) for v in value]
    return value


def _field(block, name):
    """One field off a content block, whether it is an SDK object or a plain dict."""
    return block.get(name) if isinstance(block, dict) else getattr(block, name, None)


# Providers cap how large an image may be. Anthropic refuses anything over 8000 pixels on
# a side with a 400, which kills the whole turn, and the image is usually a figure the
# model asked to look at rather than anything the user needs at that resolution. Downscale
# on the way in instead: a readable figure is the point, not the pixel count.
_MAX_IMAGE_PX = int(os.environ.get("LLM_MAX_IMAGE_PX", "7000"))


def _shrink_image(data_b64: str, mime: str) -> tuple[str, str]:
    """Downscale a base64 image if either side exceeds the provider limit.

    Returns the original untouched when it already fits, or when Pillow is unavailable —
    a slightly-too-large image reaching the API is a better failure than crashing here.
    """
    try:
        from io import BytesIO

        from PIL import Image
    except Exception:  # noqa: BLE001 - no Pillow: pass it through unchanged
        return data_b64, mime
    try:
        raw = base64.b64decode(data_b64)
        img = Image.open(BytesIO(raw))
        if max(img.size) <= _MAX_IMAGE_PX:
            return data_b64, mime
        scale = _MAX_IMAGE_PX / max(img.size)
        img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))),
                         Image.LANCZOS)
        buf = BytesIO()
        img.convert("RGB").save(buf, format="PNG", optimize=True)
        return base64.b64encode(buf.getvalue()).decode(), "image/png"
    except Exception:  # noqa: BLE001 - unreadable image: leave it alone
        return data_b64, mime


def normalize_tool_result(mcp_result) -> list[dict]:
    """Turn an MCP tool result into provider-neutral blocks: {type: text|image, ...}.
    Carries text through and keeps images as base64 + mime so each provider can map them
    to its own format (Anthropic image blocks; Gemini inline-data parts)."""
    blocks: list[dict] = []
    for block in mcp_result.content:
        btype = getattr(block, "type", None)
        if btype == "text":
            blocks.append({"type": "text", "text": block.text})
        elif btype == "image":
            data, mime = _shrink_image(block.data, getattr(block, "mimeType", "image/png"))
            blocks.append({"type": "image", "mime_type": mime, "data": data})
        else:
            blocks.append({"type": "text", "text": getattr(block, "text", str(block))})
    return blocks or [{"type": "text", "text": "(no content)"}]


class AnthropicProvider:
    """Claude via the Anthropic Messages API. History is kept in native Anthropic
    message form, so the loop driving this never has to know the wire shape.

    Three request features are configured here and nowhere else:
      * adaptive thinking + an effort level — the model picks its own reasoning depth per
        step, which is what the methodological judgement calls need;
      * prompt caching — the system prompt (the standing context brief) and the tool
        schemas are a large fixed prefix re-sent on every step of every loop, so caching
        turns steps 2..N of an analysis into cache reads;
      * server-side compaction — long analyses would otherwise die at the context ceiling.
    Each is independently switchable so a cheap shallow run is one env var away.
    """

    name = "anthropic"

    # Compaction is server-side: once a request approaches the trigger threshold (~150K
    # input tokens by default) the API summarizes the earlier conversation itself and
    # returns a compaction block. That block MUST be carried into the next request, which
    # it is, because step() appends the whole response content rather than just its text.
    _COMPACT_BETA = "compact-2026-01-12"
    _COMPACT_EDIT = {"type": "compact_20260112"}

    def __init__(self, model: str, max_tokens: int):
        if not os.environ.get("ANTHROPIC_API_KEY"):
            raise SystemExit("Set ANTHROPIC_API_KEY for the Anthropic provider.")
        from anthropic import Anthropic
        # A generous request timeout. This bounds the MODEL call only: tool execution
        # happens between calls, in our own process, and is not covered by it. Raising it
        # also raises the SDK's non-streaming size guard, which is derived from it.
        timeout = float(os.environ.get("ANTHROPIC_TIMEOUT", "1200"))
        self.client = Anthropic(timeout=timeout)
        self.model = model
        self.max_tokens = max_tokens
        self.tools: list[dict] = []
        self.messages: list[dict] = []
        self.thinking = _flag("ANTHROPIC_THINKING")
        self.effort = os.environ.get("ANTHROPIC_EFFORT", "medium").strip().lower()
        self.cache = _flag("ANTHROPIC_CACHE")
        self.compact = _flag("ANTHROPIC_COMPACT")

    def prepare_tools(self, mcp_tools) -> None:
        self.tools = [{"name": t.name, "description": t.description or "",
                       "input_schema": t.inputSchema} for t in mcp_tools]

    def add_user(self, text: str) -> None:
        self.messages.append({"role": "user", "content": text})

    # -- request assembly ----------------------------------------------------
    def _system_blocks(self, system: str):
        """The system prompt, carrying the cache breakpoint when caching is on.

        Render order is tools -> system -> messages, so a single marker on the last system
        block caches the tool schemas and the standing context together.
        """
        if not self.cache:
            return system
        return [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}]

    def _cached_messages(self) -> list[dict]:
        """History with a rolling cache breakpoint on the newest turn, so each step reads
        back the transcript the previous step wrote instead of paying for it again.

        The marker goes on a copy: self.messages stays clean, so breakpoints never
        accumulate (the API allows at most four). step() is always called with a user turn
        last (the question, or the tool results) and those are dicts we built ourselves,
        so this never has to reach inside an SDK response object to place the marker.
        """
        if not self.cache or not self.messages:
            return self.messages
        last = self.messages[-1]
        if last.get("role") != "user":
            return self.messages
        content = last["content"]
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        elif isinstance(content, list) and content and isinstance(content[-1], dict):
            content = list(content)
        else:                                   # unexpected shape: send it through as-is
            return self.messages
        content[-1] = {**content[-1], "cache_control": {"type": "ephemeral"}}
        return self.messages[:-1] + [{**last, "content": content}]

    def _request(self, system: str) -> dict:
        """Assemble one request. Separate from step() so everything we send is readable in
        one place and each feature contributes exactly one clause."""
        params: dict = {
            "model": self.model,
            "max_tokens": self.max_tokens,
            "system": self._system_blocks(system),
            "tools": self.tools,
            "messages": self._cached_messages(),
        }
        if self.thinking:
            # display="summarized" is required to get any reasoning *text* back. On the
            # current models it defaults to "omitted", which still streams thinking blocks
            # — the blocks just carry an empty string. The model reasons and is billed for
            # it either way; this only decides whether we are allowed to see a summary of
            # it. Without this the UI's reasoning panel is correctly wired to nothing.
            params["thinking"] = {"type": "adaptive", "display": "summarized"}
        if self.effort:
            params["output_config"] = {"effort": self.effort}
        if self.compact:
            params["context_management"] = {"edits": [self._COMPACT_EDIT]}
            params["betas"] = [self._COMPACT_BETA]
        return params

    def step(self, system: str, on_delta=None, on_thinking=None) -> dict:
        """One model call. With on_delta the call goes over the streaming endpoint and each
        text fragment is handed over as it arrives; the return value is identical either
        way, so streaming never changes the caller's control flow.

        on_thinking receives the model's reasoning as it streams, when thinking is enabled
        (ANTHROPIC_THINKING). It is separate from on_delta on purpose: reasoning is not the
        answer, and a caller that does not ask for it never sees it. Neither callback
        affects what goes into history; the full content list is preserved either way."""
        params = self._request(system)
        if on_delta is None:
            resp = self.client.beta.messages.create(**params)
        else:
            with self.client.beta.messages.stream(**params) as stream:
                for event in stream:
                    if event.type == "text":
                        on_delta(event.text)
                    elif event.type == "thinking" and on_thinking is not None:
                        on_thinking(event.thinking)
                resp = stream.get_final_message()
        # the whole content list goes back into history: thinking and compaction blocks
        # are part of the model's state and must survive into the next request untouched
        self.messages.append({"role": "assistant", "content": resp.content})
        text = "".join(b.text for b in resp.content if b.type == "text")
        tool_calls = [{"id": b.id, "name": b.name, "input": b.input}
                      for b in resp.content if b.type == "tool_use"]
        return {"text": text, "tool_calls": tool_calls, "thoughts": "",
                "finish_reason": getattr(resp, "stop_reason", None),
                "usage": self._usage(resp)}

    @staticmethod
    def _usage(resp) -> dict:
        u = getattr(resp, "usage", None)
        return {"input_tokens": _count(u, "input_tokens"),
                "output_tokens": _count(u, "output_tokens"),
                "cache_read_input_tokens": _count(u, "cache_read_input_tokens"),
                "cache_write_input_tokens": _count(u, "cache_creation_input_tokens")}

    def add_tool_results(self, results: list[dict]) -> None:
        content = [{"type": "tool_result", "tool_use_id": r["id"],
                    "content": [self._block(b) for b in r["blocks"]]} for r in results]
        self.messages.append({"role": "user", "content": content})

    @staticmethod
    def _block(b: dict) -> dict:
        if b["type"] == "image":
            return {"type": "image",
                    "source": {"type": "base64", "media_type": b["mime_type"], "data": b["data"]}}
        return {"type": "text", "text": b["text"]}

    # -- durable history -----------------------------------------------------
    def export_history(self) -> list:
        return [{"role": m["role"], "content": _plain(m["content"])} for m in self.messages]

    def import_history(self, data: list) -> None:
        self.messages = [{"role": m["role"], "content": m["content"]}
                         for m in data if m.get("role") and m.get("content") is not None]

    def seal(self) -> None:
        """Make the history valid to continue from, before a new user turn is added.

        Every tool_use block must be answered by a tool_result; the API rejects a request
        where one dangles. A turn that dies between the model asking for a tool and the
        tool answering (a transport failure, a crash, a restart) leaves exactly that, which
        would otherwise poison the chat permanently: every later message in it would fail.
        Answering with an error result is both valid and honest, since the tool really did
        not return, and it lets the model see what happened rather than silently forgetting
        that it had asked.
        """
        if not self.messages or self.messages[-1].get("role") != "assistant":
            return
        pending = [_field(b, "id") for b in (self.messages[-1].get("content") or [])
                   if _field(b, "type") == "tool_use"]
        if not pending:
            return
        self.messages.append({"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tid, "is_error": True,
             "content": [{"type": "text", "text": _INTERRUPTED_TOOL}]} for tid in pending]})


class GeminiProvider:
    """Gemini via the google-genai SDK. Automatic function calling is disabled so the
    shared loop stays in control; history is kept in native `Content`/`Part` form."""

    name = "google"

    def __init__(self, model: str, max_tokens: int):
        try:
            from google import genai
            from google.genai import types
        except ImportError as e:  # pragma: no cover - optional dependency
            raise SystemExit("Gemini provider needs the SDK: pip install google-genai") from e
        key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
        if not key:
            raise SystemExit("Set GEMINI_API_KEY (or GOOGLE_API_KEY) for the Google provider.")
        self._genai, self._types = genai, types
        self.client = genai.Client(api_key=key)
        self.model = model
        self.max_tokens = max_tokens
        self.tools = None
        self.contents: list = []
        # 2.5 models think by default, which can silently eat the whole output budget on
        # a small model and return an empty answer. Off by default for reliable tool-use;
        # set GEMINI_THINKING_BUDGET>0 to re-enable (will matter for thinking display).
        self._thinking_budget = int(os.environ.get("GEMINI_THINKING_BUDGET", "0"))

    def prepare_tools(self, mcp_tools) -> None:
        types = self._types
        decls = [types.FunctionDeclaration(name=t.name, description=t.description or "",
                                           parameters=t.inputSchema or {"type": "object"})
                 for t in mcp_tools]
        self.tools = [types.Tool(function_declarations=decls)]

    def add_user(self, text: str) -> None:
        types = self._types
        self.contents.append(types.Content(role="user", parts=[types.Part(text=text)]))

    def step(self, system: str, on_delta=None, on_thinking=None) -> dict:
        # on_delta/on_thinking are accepted for contract parity and ignored: this backend is the cheap
        # dev path and stays non-streaming, so a turn simply arrives all at once.
        types = self._types
        config = types.GenerateContentConfig(
            system_instruction=system,
            tools=self.tools,
            max_output_tokens=self.max_tokens,
            automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
            thinking_config=types.ThinkingConfig(thinking_budget=self._thinking_budget),
        )
        resp = self.client.models.generate_content(
            model=self.model, contents=self.contents, config=config)
        # Defensive: a blocked / truncated response can come back with no candidate,
        # no content, or no parts. Never assume the happy path, so the loop never silently
        # goes blank — surface the finish reason instead.
        cand = (resp.candidates or [None])[0]
        content = getattr(cand, "content", None) if cand is not None else None
        if content is not None:
            self.contents.append(content)        # store the assistant turn natively
        parts = (getattr(content, "parts", None) or []) if content is not None else []
        text_parts, thoughts, tool_calls = [], [], []
        for i, part in enumerate(parts):
            fc = getattr(part, "function_call", None)
            if fc:
                tool_calls.append({"id": f"{fc.name}_{i}", "name": fc.name,
                                   "input": dict(fc.args or {})})
            elif getattr(part, "text", None):
                (thoughts if getattr(part, "thought", False) else text_parts).append(part.text)
        finish = getattr(cand, "finish_reason", None) if cand is not None else None
        return {"text": "".join(text_parts), "tool_calls": tool_calls,
                "thoughts": "".join(thoughts), "finish_reason": str(finish) if finish else None,
                "usage": self._usage(resp)}

    @staticmethod
    def _usage(resp) -> dict:
        """Gemini's counts mapped onto the normalized shape. Thinking is billed as output
        here, and there is no cache-write figure to report."""
        um = getattr(resp, "usage_metadata", None)
        return {"input_tokens": _count(um, "prompt_token_count"),
                "output_tokens": _count(um, "candidates_token_count") + _count(um, "thoughts_token_count"),
                "cache_read_input_tokens": _count(um, "cached_content_token_count"),
                "cache_write_input_tokens": 0}

    def add_tool_results(self, results: list[dict]) -> None:
        types = self._types
        parts = []
        for r in results:
            text = "\n".join(b["text"] for b in r["blocks"] if b["type"] == "text")
            parts.append(types.Part.from_function_response(
                name=r["name"], response={"result": text or "(no text)"}))
            # Gemini can't carry images inside a function response, so attach any image
            # blocks as separate inline-data parts in the same tool-results turn.
            for b in r["blocks"]:
                if b["type"] == "image":
                    parts.append(types.Part.from_bytes(
                        data=base64.b64decode(b["data"]), mime_type=b["mime_type"]))
        self.contents.append(types.Content(role="user", parts=parts))

    # -- durable history -----------------------------------------------------
    def export_history(self) -> list:
        return [_plain(c) for c in self.contents]

    def import_history(self, data: list) -> None:
        self.contents = [self._types.Content.model_validate(c) for c in data]

    def seal(self) -> None:
        """Answer any function call the last turn left hanging. Same reasoning as the
        Anthropic provider: a call with no response is an invalid history to continue
        from, and a turn can die between the two."""
        if not self.contents or getattr(self.contents[-1], "role", None) != "model":
            return
        names = [fc.name for fc in
                 (getattr(p, "function_call", None) for p in (self.contents[-1].parts or []))
                 if fc]
        if not names:
            return
        types = self._types
        self.contents.append(types.Content(role="user", parts=[
            types.Part.from_function_response(name=n, response={"result": _INTERRUPTED_TOOL})
            for n in names]))


def get_provider(name: str | None, model: str | None, max_tokens: int):
    """Construct the selected provider. `model` may be None to take the provider default."""
    name = (name or "anthropic").lower()
    if name in ("anthropic", "claude"):
        return AnthropicProvider(model or DEFAULT_MODELS["anthropic"], max_tokens)
    if name in ("google", "gemini"):
        return GeminiProvider(model or DEFAULT_MODELS["google"], max_tokens)
    raise SystemExit(f"Unknown LLM_PROVIDER '{name}' (use 'anthropic' or 'google').")
