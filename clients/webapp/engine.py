"""The orchestration bridge for the web product.

The web backend is just another front end that owns the model loop — the same shape as
the standalone CLI, but driven by HTTP requests and emitting a stream of events instead
of printing to a terminal. It reuses, unchanged:
  * the MCP server (spawned over stdio) as the one tool surface,
  * providers.py for the Claude/Gemini seam,
  * system_prompt.py for the methodological guardrails.

Events are deliberately *user-facing*: the standing context says never surface tool
names or internal wiring, so the stream carries generic activity ("Analyzing…"),
rendered prose, and the figures the analysis produced — never a tool name or a path.
"""

from __future__ import annotations

import asyncio
import os
import re
import sys
import uuid
from pathlib import Path

# This is one client among several, so it reaches the tree the same way the others
# do: the client modules beside it, the interfaces and infrastructure it needs, and
# nothing from any domain. ANALYSIS_CORE overrides the root so this folder can move
# out to its own repository later.
_CLIENTS = Path(__file__).resolve().parent.parent
_TREE = Path(os.environ.get("ANALYSIS_CORE", _CLIENTS.parent))
# `datasource` is a package, so its parent goes on the path rather than itself.
# The artifact store is reached through artifacts.py beside this file instead of
# being flattened onto the path: it holds a `store` module and so does this
# folder, and which one won would be an accident of ordering.
for _p in (_CLIENTS, _TREE / "infrastructure"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from providers import (DEFAULT_MODELS, add_usage, empty_usage, extract_error_message,
                       get_provider, normalize_tool_result)
from system_prompt import build_system_prompt


def _slug(s: str) -> str:
    """A name reduced to something safe to compare and to put in a path.

    The same rule the artifact store applies, so a name slugged on either side
    of the boundary comes out the same.
    """
    return re.sub(r"[^A-Za-z0-9._-]+", "-", str(s)).strip("-") or "unnamed"


def _leaf_names(output: dict, prefix: str = "") -> list[str]:
    """The openable things inside one output.

    A capability whose result is a directory is carded as its contents, because
    a folder is not something a reader can look at, and a card named for the
    folder opens nothing.
    """
    name = prefix + (output.get("name") or "")
    if output.get("kind") != "directory":
        return [name] if name else []
    return [n for child in (output.get("files") or [])
            for n in _leaf_names(child, prefix=name + "/")]


def _select_provider():
    """The model backend this deployment serves, and the model within it.

    Here rather than beside the results panel, which never called it: choosing a
    provider is part of driving the model loop, and that is this file's job.
    """
    name = os.environ.get("LLM_PROVIDER", "anthropic").lower()
    model = (os.environ.get("GEMINI_MODEL") or os.environ.get("GOOGLE_MODEL")
             if name in ("google", "gemini") else os.environ.get("ANTHROPIC_MODEL"))
    return get_provider(name, model, _MAX_TOKENS)

import access  # per-user study allowlist
import paths   # where each user's data lives on disk (one safe_user, one store root)
import render  # user-facing presentation: prose, phrases, tables, links
import config   # loads .env and sets the provider/model/secret defaults; key stays server-side
import conversations   # durable model history per chat (survives restarts)
import chats

_MCP_SERVER = str(_TREE / "clients" / "mcp-server" / "mcp_server.py")
# Control plumbing, not an analysis capability: it narrows the running server's study
# scope to what the chat selected. Filtered out of the tool list the model is given, so
# the model never sees it, and it can only ever narrow within the user's access anyway.
_SCOPE_TOOL = "set_study_scope"
# Output budget for one model response. Thinking is billed and bounded as output, so this
# has to leave room for the model to reason AND answer; too low and a turn gets truncated
# mid-thought. It is a ceiling, not a reservation: only tokens actually produced are billed.
# The Claude path streams, so the SDK's non-streaming size guard does not apply to it. That
# guard is derived from the client timeout (ANTHROPIC_TIMEOUT), which is generous, so the
# non-streaming CLI path clears this value too.
_MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS") or os.environ.get("ANTHROPIC_MAX_TOKENS", "32000"))
# Ceiling on model->tool->model round trips in a single user turn. The model decides when
# it is done; this is the backstop for when it never does (a tool that keeps failing, a
# goal it cannot reach), so one question cannot bill indefinitely.
_MAX_STEPS = int(os.environ.get("LLM_MAX_STEPS", "25"))
_STEP_LIMIT_NOTE = ("This analysis reached its step limit before it finished. Anything "
                    "already computed has been saved. Try narrowing the question.")
# How many chats keep a live provider in memory. Beyond this the least recently used is
# dropped; its history is on disk, so the next message in it rehydrates transparently.
# Only ever a memory bound, never a correctness one.
_MAX_LIVE_CHATS = int(os.environ.get("LLM_MAX_LIVE_CHATS", "50"))
# A pause between the user pressing send and anything actually happening. Stopping inside
# it is free in the strict sense: no request has been made, so no tokens are billed, and
# the message has not been saved, so the chat is untouched and the text goes back to the
# composer to be fixed. The cost is that every turn starts this much later; 0 disables it.
_SEND_GRACE = float(os.environ.get("LLM_SEND_GRACE", "1"))

from datasource import resolve_data_root as _resolve_data_root

# DATA_ROOT when it names a directory that exists, else the repo-local data/ folder.
# Written back into the environment as an absolute path so the MCP server this process
# spawns inherits the same answer: it does not share our working directory, so a relative
# DATA_ROOT would otherwise resolve to a different place on each side.
_DATA_ROOT = _resolve_data_root(_TREE / "data")
os.environ["DATA_ROOT"] = _DATA_ROOT


class Engine:
    """Owns per-user MCP sessions and per-chat provider state for the web backend.

    Access control by isolation: each user gets their OWN MCP server, launched with their
    study allowlist (ALLOWED_STUDIES), so the data layer in that process refuses anything
    outside their access. Studies a user can't see don't exist for that user's model."""

    def __init__(self):
        from collections import OrderedDict
        from contextlib import AsyncExitStack
        self._stack = AsyncExitStack()              # holds every user's session
        self._sessions: dict[str, dict] = {}        # user -> {session, tools}
        self._user_locks: dict[str, asyncio.Lock] = {}
        # domain -> assembled prompt. Built on first use rather than at startup, because
        # the brief now depends on which domain a chat runs in.
        self._prompts: dict[str, str] = {}
        # chat_id -> live provider, most-recently-used last. A cache, not the record: the
        # history behind each one is persisted (conversations.py) and rehydrated on a miss.
        self.conversations: OrderedDict[str, object] = OrderedDict()
        self.provider_name = os.environ.get("LLM_PROVIDER", "anthropic").lower()

    def system_prompt(self, user: str, chat_id: str) -> str:
        """The standing brief for one chat: shared context plus a section per domain it
        works in.

        Cached by the domain set, not per chat, since the brief is identical for every chat
        over the same domains. A chat with nothing chosen yet gets the shared brief alone
        rather than a guessed one."""
        domains = self.domains_for(user, chat_id)
        key = ",".join(domains)
        if key not in self._prompts:
            self._prompts[key] = build_system_prompt(domains)
        return self._prompts[key]

    async def start(self) -> None:
        # Ask the machines what data they hold, once, off the event loop and before
        # anyone is waiting. Asking a cluster means an ssh, and doing that inside a
        # request would block every other request in this process until it answered.
        # Held afterwards, and refreshed behind whoever asks next.
        from executors import reachable
        await asyncio.to_thread(reachable.warm)

        # Spawn each known user's MCP server NOW, in the lifespan task scope, so its stdio
        # streams live for the whole app. Spawning lazily inside a request task binds the
        # streams to that task; when the request ends they close -> ClosedResourceError on
        # the next tool call (the bug we just fixed).
        for user in access.ACCESS:
            await self._spawn_session(user)

    async def stop(self) -> None:
        await self._stack.aclose()

    def _user_env(self, user: str) -> dict:
        """Environment for a user's MCP server: their study allowlist plus their own
        results/outputs roots, so the model can only write into this user's folders."""
        env = {**os.environ}
        allow = access.allowed_studies(user)
        if allow is not None:
            # an empty list stays empty here on purpose: a user with no granted studies
            # gets an allowlist that allows nothing, not a wildcard (see local.py)
            env["ALLOWED_STUDIES"] = ",".join(allow)    # restricts the data layer
        else:
            env.pop("ALLOWED_STUDIES", None)            # full study access
        domains = access.allowed_domains(user)
        if domains is not None:
            env["ALLOWED_DOMAINS"] = ",".join(domains)  # the second, independent gate
        else:
            env.pop("ALLOWED_DOMAINS", None)            # full domain access
        env.pop("RESULTS_ROOT", None)        # retired: one store, see paths.OUTPUTS_BASE above
        # This user's own results root. Separation is by filesystem rather than by
        # everyone choosing different workspace names, which is not something a
        # model deciding its own workspace could be relied on to do.
        env["ANALYSIS_RESULTS"] = paths.user_outputs_root(user)
        env["OUTPUTS_ROOT"] = os.path.join(paths.OUTPUTS_BASE, paths.safe_user(user))
        # And this user's own record of what they submitted. Shared, it was one
        # file per site for everybody: one person's running work showed in
        # another's, and a handle out of it could be polled or cancelled by
        # whoever had seen it.
        env["ANALYSIS_STATE"] = paths.user_state_root(user)
        # Which subdirectory of a remote site's results root is theirs. A site
        # reached over ssh writes into its own tree rather than the one above,
        # so without this every user's results on that machine sit together.
        env["ANALYSIS_OWNER"] = paths.safe_user(user)
        env["ENABLE_SCOPE_TOOL"] = "1"       # we drive per-chat scope; see _apply_scope
        return env

    async def _spawn_session(self, user: str) -> dict:
        params = StdioServerParameters(command=sys.executable, args=[_MCP_SERVER], env=self._user_env(user))
        read, write = await self._stack.enter_async_context(stdio_client(params))
        session = await self._stack.enter_async_context(ClientSession(read, write))
        await session.initialize()
        s = {"session": session, "tools": (await session.list_tools()).tools}
        self._sessions[user] = s
        return s

    async def _session_for(self, user: str) -> dict:
        s = self._sessions.get(user)
        return s if s is not None else await self._spawn_session(user)

    def _lock_for(self, user: str) -> asyncio.Lock:
        self._user_locks.setdefault(user, asyncio.Lock())
        return self._user_locks[user]

    def _outcomes_note(self, user: str, cid: str) -> str:
        """What finished since this chat was last spoken to.

        A run outlives the turn that started it. The model that submitted it has
        long since answered, and the machine that finished it has no way to
        interrupt. So the outcome is carried into the next turn as a fact rather
        than made into something the model has to ask about: asking costs a turn
        per question, and the answer was already sitting in a registry.

        Told once. A finished run mentioned on every subsequent turn would be
        read as new each time.
        """
        import runs as _runs
        landed = _runs.outcomes(user, chats.runs_untold(user, cid))
        if not landed:
            return ""
        chats.mark_told(user, cid, [r["run"] for r in landed])
        lines = [f"- {r['label']}: {r['state']}"
                 + (f" ({r['detail']})" if r["state"] != "completed" and r["detail"] else "")
                 + f"  [{r['run']}]" for r in landed]
        return ("\n\n## Analyses that finished since your last turn\n\n"
                + "\n".join(lines)
                + "\n\nThese were started earlier in this conversation and have now "
                  "landed. Read the ones that matter to what is being asked. You do "
                  "not need to check whether work has finished: you are told here, "
                  "once, and asking instead spends a turn to learn the same thing.")

    def _provider_for(self, user: str, cid: str, tools):
        """The live provider for a chat, rehydrating its stored history on a cache miss.

        The miss is the whole point: it happens after a restart, after an eviction, and
        after a deploy, and in every one of those cases the user still sees their full
        transcript, so the model has to still have its side of it.
        """
        prov = self.conversations.get(cid)
        if prov is not None:
            self.conversations.move_to_end(cid)
            return prov
        prov = _select_provider()                # raises SystemExit if no key
        prov.prepare_tools([t for t in tools if t.name != _SCOPE_TOOL])
        history = conversations.load(user, cid, prov.name, getattr(prov, "model", ""))
        if history:
            prov.import_history(history)
            print(f"[rehydrate] chat={cid} messages={len(history)}", flush=True)
        self.conversations[cid] = prov
        while len(self.conversations) > _MAX_LIVE_CHATS:
            old, _ = self.conversations.popitem(last=False)     # least recently used
            print(f"[evict] chat={old} (history on disk; rehydrates on next use)", flush=True)
        return prov

    def forget_chat(self, user: str, chat_id: str) -> None:
        """Drop a chat's model history when the chat is deleted. Without this the provider
        stays in memory and its history stays on disk after the user removed the chat."""
        self.conversations.pop(chat_id, None)
        conversations.delete(user, chat_id)

    # -- per-chat domain -----------------------------------------------------
    def accessible_domains(self, user: str) -> list[str]:
        """Every domain this user may reach: the menu a chat's domain is chosen from.
        One element means there is nothing to ask; the UI only prompts past that."""
        return access.accessible_domains(user)

    def domains_for(self, user: str, chat_id: str) -> list[str]:
        """The domains this chat works in: its saved choice intersected with what the user
        can reach now, so a stale selection can only narrow and never grant. Empty means
        the choice is genuinely open and the UI has to ask; with exactly one domain
        available there is nothing to ask, so it is filled in."""
        available = access.accessible_domains(user)
        chosen = chats.chat_domains(user, chat_id) or []
        picked = [d for d in available if d in set(chosen)]
        if picked:
            return picked
        return available if len(available) == 1 else []

    def set_domains(self, user: str, chat_id: str, domains) -> list[str]:
        """Record a chat's domains, dropping anything outside the user's access. Returns
        what is now in effect."""
        available = set(access.accessible_domains(user))
        picked = [d for d in (domains or []) if d in available]
        if picked:
            chats.set_chat_domains(user, chat_id, picked)
        return self.domains_for(user, chat_id)

    # -- per-chat study scope ------------------------------------------------
    def accessible_studies(self, user: str, domains=None) -> list[str]:
        """Every study this user may reach: the menu a chat's scope is chosen from.
        Narrowed to the chat's domains, since those are its whole world."""
        return access.accessible_studies(user, domains)

    def scope_for(self, user: str, chat_id: str) -> list[str]:
        """The studies this chat works with: the user's saved selection, intersected with
        what they can access now. An empty or stale selection falls back to full access,
        so a selection can only ever narrow, never grant."""
        accessible = access.accessible_studies(user, self.domains_for(user, chat_id))
        chosen = chats.chat_studies(user, chat_id)
        if not chosen:
            return accessible
        picked = [s for s in accessible if s in set(chosen)]
        return picked or accessible

    async def _apply_scope(self, session, scope: list[str],
                           domains: list[str] | None = None,
                           runs: list[str] | None = None,
                           cleared: list[str] | None = None,
                           data: list[str] | None = None) -> None:
        """Point the user's running MCP server at this chat's studies.

        The user's own boundary is not this: each user gets their own server,
        launched with their allowlist, and nothing outside it exists in that
        process. This narrows further, to the studies the chat is about, within
        what that user may already see.

        A missing tool is not silently accepted any more. It was, and the tool
        did not exist, so every chat ran with its owner's whole allowlist while
        the only thing describing the narrower scope was a sentence in the brief
        asking the model to respect it. A boundary nobody enforces is not one.
        """
        user = self._user_of(session)
        if not any(t.name == _SCOPE_TOOL
                   for t in self._sessions.get(user, {}).get("tools", [])):
            raise RuntimeError(
                "this server cannot be narrowed to one chat's studies, so the chat "
                "would run with everything its owner can reach. Check that "
                "ENABLE_SCOPE_TOOL is set for it.")
        # Runs are sent every turn including when there are none, because a chat
        # that has produced nothing has to mean nothing rather than everything.
        # Cleared cells go with the runs, and for the same reason: a cell that
        # was emptied and then chosen again has to stop being empty, and only a
        # value sent every turn can say so.
        await session.call_tool(_SCOPE_TOOL, {"studies": ",".join(scope),
                                              "domains": ",".join(domains or []),
                                              "runs": ",".join(runs or []),
                                              "cleared": ",".join(cleared or []),
                                              "data": ",".join(data or [])})

    @staticmethod
    def _data_pins(user: str, chat_id: str) -> list[str]:
        """Which version of its data each sample in this chat is read from.

        Travels with the scope for the same reason the cleared cells do: it has
        to reach the process that builds the job, it has to be able to change
        between turns, and only a value sent every turn can say that a pin was
        removed.

        Empty is the ordinary case and means the newest of everything, which is
        what a reference without a version already means.
        """
        try:
            import versions as _versions
            return _versions.data_pins(user, chat_id)
        except Exception:              # noqa: BLE001 - scope must not fail on this
            return []

    @staticmethod
    def _cleared_cells(user: str, chat_id: str) -> list[str]:
        """Which cells of the versions grid this chat has emptied on purpose.

        Emptying a cell is the only way somebody can ask for work to be done
        again when nothing about the request has changed, so it has to reach the
        thing that decides whether to re-use a finished run. It travels with the
        scope, which is already sent every turn.

        Absent and empty are different and both are kept: a cell nobody has
        touched follows the newest result, and a cell that was emptied waits to
        be filled. Only the second is sent.
        """
        try:
            return sorted(k for k, v in (chats.get_chat(user, chat_id) or {})
                          .get("versions", {}).items() if v == "")
        except Exception:              # noqa: BLE001 - scope must not fail on this
            return []

    def _user_of(self, session) -> str:
        return next((u for u, s in self._sessions.items() if s["session"] is session), "")

    @staticmethod
    def _parse_runs(blocks: list[dict]) -> list[dict]:
        """The runs a tool call started or reported on, from its JSON result.

        Two shapes arrive. Submitting a capability returns a handle and a state,
        because the work has been started rather than finished. Reading one back
        returns its outputs. Both name the run, and the run is what is recorded
        against the chat: a run is one thing the user asked for, and what it
        produced is the store's to say. Recording files here instead would mean
        this file had to be kept in step with whatever every capability emits.
        """
        import json as _json
        found: dict[str, dict] = {}

        def take(data: dict) -> None:
            run = data.get("run")
            if not run:
                return
            entry = found.setdefault(run, {"run": run})
            if data.get("state"):
                entry["state"] = data["state"]
            if data.get("capability"):
                entry["capability"] = data["capability"]
            if data.get("site"):
                entry["site"] = data["site"]
            # Present only once it has something to show. A handle on its own is
            # progress, not a result, and carding it would put an empty entry in
            # the answer that fills in later or never.
            if data.get("outputs"):
                entry["outputs"] = [n for o in data["outputs"] for n in _leaf_names(o)]

        for b in blocks:
            if b.get("type") != "text":
                continue
            try:
                data = _json.loads(b["text"])
            except Exception:  # noqa: BLE001 - not every tool result is our JSON
                continue
            if not isinstance(data, dict):
                continue
            # One run at the top, which is what submitting a single capability
            # returns, and any list of them further in, which is what submitting
            # a whole chain returns. Both are read, because a run that is not
            # recorded against the chat is invisible everywhere afterwards: the
            # panel lists none of it, the next turn's scope excludes it, and the
            # user is told their own finished work does not exist. Read by shape
            # rather than by the key a particular tool happens to use, so a tool
            # that reports runs some other way is still covered.
            take(data)
            for value in data.values():
                if isinstance(value, list):
                    for item in value:
                        if isinstance(item, dict):
                            take(item)
            # Sites carry the run's own, but a chain reports the site once for
            # all of its steps.
            if data.get("site"):
                for entry in found.values():
                    entry.setdefault("site", data["site"])
        return list(found.values())

    async def _model_step(self, provider, system: str):
        """Run one model call and yield ("delta", text) as it streams, then ("step", result).

        The provider call is blocking, so it runs in a worker thread; the deltas it hands
        back on that thread are pushed onto a queue this coroutine drains. The worker always
        posts the sentinel in a finally, so the drain loop ends even if the call raises, and
        awaiting the task afterwards re-raises that error here where run_turn can report it.
        """
        loop = asyncio.get_running_loop()
        queue: asyncio.Queue = asyncio.Queue()
        done = object()

        def on_delta(chunk: str) -> None:          # called on the worker thread
            loop.call_soon_threadsafe(queue.put_nowait, ("delta", chunk))

        def on_thinking(chunk: str) -> None:       # reasoning, kept apart from the answer
            loop.call_soon_threadsafe(queue.put_nowait, ("thinking", chunk))

        def run() -> dict:
            try:
                return provider.step(system, on_delta, on_thinking)
            finally:
                loop.call_soon_threadsafe(queue.put_nowait, done)

        task = asyncio.create_task(asyncio.to_thread(run))
        while True:
            item = await queue.get()
            if item is done:
                break
            yield item
        yield "step", await task

    async def _execute_tools(self, session, tool_calls, results, rec_msgs, rec_runs,
                             carded, user):
        """Run a step's tool calls: yield the UI events for them and append each
        tool's result to `results` for the provider. Split out so run_turn stays
        shallow."""
        for tc in tool_calls:
            print(f"[tool] {tc['name']} {tc['input']}", flush=True)
            # What the step did, in a sentence. The raw arguments and the model's own code
            # go with it only for an admin: for everyone else they are a debugger's view
            # of the process and leak internal vocabulary the answer never uses.
            act = {"role": "activity", "label": render.step_summary(tc["name"], tc["input"])}
            if access.is_admin(user):
                act["detail"] = render.tool_detail(tc["input"])
            rec_msgs.append(act)
            yield {"type": "activity", **{k: act[k] for k in act if k != "role"}}
            out = await session.call_tool(tc["name"], tc["input"])
            blocks = normalize_tool_result(out)
            for b in blocks:
                if b["type"] == "image":                 # not persisted (size)
                    yield {"type": "image", "src": f"data:{b['mime_type']};base64,{b['data']}"}

            for r in self._parse_runs(blocks):
                if r["run"] not in rec_runs:
                    rec_runs.append(r["run"])
                if r.get("state") and not r.get("outputs"):
                    # Started, not finished. The conversation says so and moves
                    # on; what it is doing now is the panel's to report, polled
                    # from the machine rather than asked of the model.
                    if r["run"] not in carded:
                        carded.add(r["run"])
                        started = {"role": "run", "run": r["run"],
                                   "label": render.capability_title(r.get("capability", "")),
                                   "site": r.get("site", "")}
                        rec_msgs.append(started)
                        yield {"type": "run", **{k: started[k] for k in
                                                 ("run", "label", "site")}}
                for name in r.get("outputs", []):
                    key = f"{r['run']}/{name}"
                    if key in carded:
                        continue
                    carded.add(key)
                    card = {"role": "artifact", "ref": r["run"], "name": name}
                    rec_msgs.append(card)
                    yield {"type": "artifact", **{k: card[k] for k in ("ref", "name")}}
            results.append({"id": tc["id"], "name": tc["name"], "blocks": blocks})

    # -- the agentic turn, as a stream of UI events --------------------------
    async def run_turn(self, user: str, chat_id: str, text: str):
        """Drive one user turn for a chat, yielding event dicts: status / message / image /
        artifact / done / error. Persists messages + presented artifacts to the chat.

        Stopping is the client closing the connection, which cancels this generator; the
        `finally` still records whatever the turn managed to produce, because those tokens
        were spent whether or not the user waited for the answer. The one exception is the
        grace window at the top: cancel there and nothing has been sent or saved at all.
        """
        if _SEND_GRACE > 0:
            # `undoable` tells the client this is still the free window, so a stop here
            # returns the text to the composer instead of leaving a half-turn in the chat
            yield {"type": "status", "label": "Sending…", "undoable": True}
            await asyncio.sleep(_SEND_GRACE)
            # Close the window on the client before saving anything, not after the setup
            # work below. Otherwise there is a stretch where the client still believes a
            # stop is free while the message has already been stored, and a stop there
            # would clear the bubble on screen but leave it in the chat on reload.
            yield {"type": "status", "label": "Thinking…"}
        chats.append_message(user, chat_id, {"role": "user", "text": text}, set_title_from=text)
        rec_msgs: list[dict] = []   # assistant-side records to persist (no bulky images)
        rec_runs: list[str] = []
        carded: set[str] = set()    # artifacts this turn gave a card, so no image repeats one

        async with self._lock_for(user):
            try:
                sess = await self._session_for(user)
                provider = self._provider_for(user, chat_id, sess["tools"])
            except SystemExit as e:
                m = render.redact(str(e))
                chats.append_message(user, chat_id, {"role": "error", "text": m})
                yield {"type": "error", "message": m}
                return
            session = sess["session"]

            # A previous turn may have died between the model asking for a tool and the
            # tool answering, which leaves a history the API refuses. Repair before adding
            # to it, or every later message in this chat fails too.
            provider.seal()
            provider.add_user(text)
            turn_usage = empty_usage()
            try:
                # Narrow the server to this chat's studies before anything runs, and tell
                # the model the same thing. Re-applied every turn: the server is shared
                # across this user's chats, so whichever turn is running sets the scope.
                scope = self.scope_for(user, chat_id)
                await self._apply_scope(session, scope,
                                        self.domains_for(user, chat_id),
                                        chats.chat_runs(user, chat_id),
                                        self._cleared_cells(user, chat_id),
                                        self._data_pins(user, chat_id))
                system = (self.system_prompt(user, chat_id) + render.scope_note(scope)
                          + self._outcomes_note(user, chat_id))
                for _ in range(_MAX_STEPS):
                    yield {"type": "status", "label": "Thinking…"}
                    step = None
                    think = []
                    async for kind, payload in self._model_step(provider, system):
                        if kind == "delta":
                            yield {"type": "delta", "text": payload}
                        elif kind == "thinking":
                            # reasoning, shown separately and never mixed into the answer;
                            # absent entirely when thinking is switched off
                            think.append(payload)
                            yield {"type": "thinking", "text": payload}
                        else:
                            step = payload
                    # Recorded, not just streamed. A reload that dropped the reasoning and
                    # the steps would leave the user with an answer and no way to see how
                    # it was reached, which is the opposite of the point of showing them.
                    if think:
                        rec_msgs.append({"role": "thinking", "text": "".join(think)})
                    turn_usage = add_usage(turn_usage, step.get("usage"))

                    if step["text"].strip():
                        # the streamed text was plain; the rendered copy is what gets kept,
                        # and the client swaps it in over what it already showed
                        html = render.render_markdown(step["text"])
                        rec_msgs.append({"role": "assistant", "html": html})
                        yield {"type": "message", "html": html, "text": step["text"]}
                    if not step["tool_calls"]:
                        if not step["text"].strip():
                            # the model returned nothing usable — log WHY for diagnosis
                            # (STOP / MAX_TOKENS / SAFETY ...); it is a model outcome, not a crash
                            print(f"[empty-response] finish_reason={step.get('finish_reason')}", flush=True)
                            note = render.empty_response_note(step)
                            rec_msgs.append({"role": "error", "text": note})
                            yield {"type": "error", "message": note}
                        break

                    yield {"type": "status",
                           "label": render.TOOL_LABELS.get(step["tool_calls"][0]["name"], "Working") + "…"}
                    results: list[dict] = []
                    async for ev in self._execute_tools(session, step["tool_calls"], results,
                                                        rec_msgs, rec_runs, carded, user):
                        yield ev
                    provider.add_tool_results(results)
                else:
                    # the loop ran to its limit without the model ever stopping on its own
                    print(f"[step-limit] chat={chat_id} hit {_MAX_STEPS} steps", flush=True)
                    rec_msgs.append({"role": "error", "text": _STEP_LIMIT_NOTE})
                    yield {"type": "error", "message": _STEP_LIMIT_NOTE}
                yield {"type": "done"}
            except Exception as e:  # noqa: BLE001 - surface any failure as a clean event
                print(f"[error] {type(e).__name__}: {e}", flush=True)
                m = render.redact(extract_error_message(e) or "Something went wrong while running that analysis.")
                rec_msgs.append({"role": "error", "text": m})
                yield {"type": "error", "message": m}
            finally:
                for m in rec_msgs:
                    chats.append_message(user, chat_id, m)
                if rec_runs:
                    chats.add_runs(user, chat_id, rec_runs)
                # Persist the model's own history alongside the display transcript, so a
                # restart cannot leave the user looking at a conversation the model has no
                # memory of. Saved even when the turn failed: the partial history is still
                # what the next turn has to continue from.
                conversations.save(user, chat_id, provider.name,
                                   getattr(provider, "model", ""), provider.export_history())
                # metered even when the turn failed partway: those tokens were still spent
                chats.record_usage(user, chat_id, turn_usage)
                print(f"[usage] chat={chat_id} in={turn_usage['input_tokens']} "
                      f"out={turn_usage['output_tokens']} "
                      f"cache_read={turn_usage['cache_read_input_tokens']} "
                      f"cache_write={turn_usage['cache_write_input_tokens']}", flush=True)

    def info(self, user: str) -> dict:
        """Status for the UI — the studies list is filtered to what this user may access,
        so the front end never advertises a study the user can't reach."""
        from datasource import capabilities
        prov_model = {"anthropic": os.environ.get("ANTHROPIC_MODEL") or DEFAULT_MODELS["anthropic"],
                      "google": os.environ.get("GEMINI_MODEL") or os.environ.get("GOOGLE_MODEL")
                      or DEFAULT_MODELS["google"]}.get(self.provider_name, "")
        from datasource import domains as _domains
        # Whether this user's domains have any viewer at all. Not whether one has
        # been built: a control that is there but never able to do anything is a
        # promise to someone working on data no viewer draws, and they will keep
        # opening it to find out why.
        import results_panel as _panel
        return {"provider": self.provider_name, "model": prov_model,
                "studies": access.accessible_studies(user), "data_layer": capabilities(),
                "any_viewer": bool(_panel._viewer_kinds(user)),
                "domains": [{"name": d, "label": _domains.label(d),
                             "note": (_domains.spec(d).notes if _domains.spec(d) else "")}
                            for d in access.accessible_domains(user)]}

    # -- the results panel ---------------------------------------------------
    # Two different keys are at work here and they used to be the same string, which is
    # why the panel could only ever show presented artifacts. A group's key is a *heading*
    # — the subject the model filed the result under. An item's `ref` is a *location* —
    # the workspace to read it from. Topic is metadata on the manifest, not a folder, so
    # the two no longer coincide and each item carries its own ref.
    def visible_messages(self, user: str, chat: dict) -> list:
        """A chat's history as this user may see it.

        The developer detail on a step is gated when the step is recorded, but a record
        outlives the rule that wrote it: chats saved before the gate existed still carry
        it, and an account can stop being admin. Deciding again at read time means what a
        user sees is governed by who they are now, not by who they were then.
        """
        msgs = chat.get("messages", [])
        if access.is_admin(user):
            return msgs
        return [{k: v for k, v in m.items() if k != "detail"}
                if m.get("role") == "activity" else m for m in msgs]

