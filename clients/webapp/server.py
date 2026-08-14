"""FastAPI backend for the browser chat.

Serves the login + app pages, a small auth layer (signed-cookie sessions), and the
chat/results API scoped per user and per chat. The model loop lives in engine.py; this
file is HTTP + auth + streaming wiring. Binds to localhost; the LLM key never leaves the
server (see config.py). Run with `./mo web` (DEV_RELOAD=1 to auto-restart).
"""

from __future__ import annotations

import json
import os
from contextlib import asynccontextmanager
from pathlib import Path

import config   # first: loads .env and sets provider/model/secret defaults
import access
import auth
import conversations
import chats
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import (FileResponse, HTMLResponse, JSONResponse, RedirectResponse,
                               StreamingResponse)
from fastapi.staticfiles import StaticFiles

import results_panel   # reading saved work back out, and undoing it
import runs            # what is still going, asked of the machines
import viewer          # the interactive spatial viewer, over a run's bundle
from engine import Engine

_WEB = Path(__file__).resolve().parent / "web"
_COOKIE = "session"
engine = Engine()


def _finite(obj):
    """Replace NaN and the infinities with null, recursively.

    Real analysis results carry them routinely — a score with no denominator, a ratio over
    zero, a column absent for some rows — and JSON has no way to spell any of them.
    Starlette serializes with allow_nan=False, so a single one anywhere in a payload turns
    a result the user asked to see into a 500. Scrubbing at the response boundary covers
    nested structures that a per-cell converter cannot reach.
    """
    if isinstance(obj, float):
        return None if (obj != obj or obj in (float("inf"), float("-inf"))) else obj
    if isinstance(obj, dict):
        return {k: _finite(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_finite(v) for v in obj]
    return obj


class SafeJSONResponse(JSONResponse):
    """JSONResponse that tolerates non-finite floats instead of 500-ing on them."""

    def render(self, content) -> bytes:
        return super().render(_finite(content))


def _warm() -> None:
    """Ask the machines what they hold and what they can run, before anyone does.

    Both answers are ssh round trips and both are cached once taken. Left until
    the first request, the person who happens to open the page first pays twenty
    seconds for everybody, and pays it again after every restart.

    On a thread and never fatal. A machine being unreachable at start-up is
    ordinary — a laptop off the VPN, a cluster in maintenance — and the app works
    without it, so this warms what it can and says nothing when it cannot.
    """
    try:
        import reachable
        reachable.warm()                   # what each machine holds
        for _site, ex in reachable.sites().items():
            try:
                ex.available()             # and whether it answers at all
            except Exception:              # noqa: BLE001 - one machine, not all of them
                continue
        # And which capabilities can run where, which is the expensive one: an
        # environment probe per capability per site. The executors are cached, so
        # doing it here means the probes are already answered when the first
        # person opens the page.
        import offered
        for who in list(access.ACCESS) or [""]:
            try:
                offered.for_user(who)
            except Exception:              # noqa: BLE001 - one user, not all of them
                continue
    except Exception as e:                 # noqa: BLE001 - never delay start-up
        print(f"[warm] {type(e).__name__}: {e}", flush=True)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await engine.start()
    import threading
    threading.Thread(target=_warm, daemon=True).start()
    try:
        yield
    finally:
        await engine.stop()


app = FastAPI(title="Multiomics", lifespan=lifespan)


# ── auth ────────────────────────────────────────────────────────────────────
def current_user(request: Request) -> str:
    """Who is asking, or a 401.

    A session that is still signed correctly is not the same as an account that
    still exists. Someone removed from the access list, or renamed, keeps a valid
    token until it expires, and until this checked they kept a working app with
    nothing in it: every list empty, every question answerable by no data, and no
    way to tell that from a deployment that simply held nothing. They are asked to
    sign in again instead, which is the true statement.
    """
    user = auth.read_session(request.cookies.get(_COOKIE))
    if not user or user not in access.ACCESS:
        raise HTTPException(status_code=401, detail="authentication required")
    return user


@app.post("/api/login")
async def login(request: Request):
    body = await request.json()
    username = auth.authenticate(body.get("username") or "", body.get("password") or "")
    if not username:
        return JSONResponse({"error": "Invalid username or password."}, status_code=401)
    resp = JSONResponse({"ok": True, "username": username})
    resp.set_cookie(_COOKIE, auth.make_session(username), httponly=True, samesite="lax",
                    secure=config.COOKIE_SECURE, max_age=config.SESSION_TTL, path="/")
    return resp


@app.post("/api/logout")
async def logout():
    resp = JSONResponse({"ok": True})
    resp.delete_cookie(_COOKIE, path="/")
    return resp


@app.get("/api/me")
async def me(user: str = Depends(current_user)):
    return {"username": user}


# ── pages ───────────────────────────────────────────────────────────────────
# The page references app.js and styles.css by plain name, so a browser holds on to the
# copy it already has and a deployed change never appears. Stamping the asset URLs with a
# build id makes each version its own URL, which is the only reliable way to retire the
# cached one. The id changes whenever either file does.
def _asset_version() -> str:
    try:
        return str(max(int((_WEB / n).stat().st_mtime) for n in ("app.js", "styles.css")))
    except OSError:
        return "0"


def _page(name: str) -> HTMLResponse:
    html = (_WEB / name).read_text().replace("/static/app.js", f"/static/app.js?v={_asset_version()}")
    html = html.replace("/static/styles.css", f"/static/styles.css?v={_asset_version()}")
    return HTMLResponse(html)


def _signed_in(request: Request) -> str | None:
    """The account this request belongs to, if it is still an account.

    The same predicate the API dependency uses, so the page a browser is given
    and the data it is then allowed to fetch cannot disagree. A correctly signed
    token for a name that has since been removed or renamed is not a session.
    """
    user = auth.read_session(request.cookies.get(_COOKIE))
    return user if user in access.ACCESS else None


@app.get("/")
async def index(request: Request):
    if _signed_in(request):
        return _page("index.html")
    return RedirectResponse("/login")


@app.get("/login")
async def login_page(request: Request):
    if _signed_in(request):
        return RedirectResponse("/")
    return _page("login.html")


@app.get("/favicon.ico")
async def favicon():
    return FileResponse(_WEB / "favicon.ico", media_type="image/x-icon")


@app.get("/healthz")
async def healthz():
    """Liveness probe. Unauthenticated, no internals, no dependencies touched.

    Every orchestrator needs some URL it can poll to decide whether to keep or replace this
    process, and it must not require a session — `/` redirects to the login page, so probing
    it exercises auth and template reads to answer a question about the process. Deliberately
    says nothing about which capabilities are present: that is not public information, and it
    is answered at build time by `python src/capabilities.py` instead.
    """
    return {"status": "ok"}


# ── chats ───────────────────────────────────────────────────────────────────
@app.get("/api/chats")
async def list_chats(user: str = Depends(current_user)):
    return {"chats": chats.list_chats(user)}


@app.post("/api/chats")
async def new_chat(user: str = Depends(current_user)):
    return {"id": chats.create_chat(user)}


def _chat_versions_apply(user: str, domains) -> bool:
    """Whether the versions control has anything to offer this chat.

    Never fatal. This decides whether to draw a button, and a registry that
    cannot be read is not a reason to fail loading the conversation.
    """
    try:
        import versions as _versions
        return _versions.applies(user, domains)
    except Exception:                    # noqa: BLE001 - reported, not raised
        return False


@app.get("/api/chats/{cid}")
async def get_chat(cid: str, user: str = Depends(current_user)):
    from datasource import domains as _domains
    c = chats.get_chat(user, cid)
    if not c:
        raise HTTPException(status_code=404, detail="chat not found")
    selected = engine.domains_for(user, cid)
    choices = engine.accessible_domains(user)
    return {"id": c["id"], "title": c.get("title"),
            "messages": engine.visible_messages(user, c),
            # the saved selection (may be absent = all), and what it resolves to now
            "studies": c.get("studies"), "scope": engine.scope_for(user, cid),
            # the chat's domain: what is in effect, and the menu it was chosen from. A
            # null domain with more than one choice is what makes the UI ask.
            "selected_domains": selected,
            "domains": [{"name": d, "label": _domains.label(d),
                         "note": (_domains.spec(d).notes if _domains.spec(d) else "")}
                        for d in choices],
            # Which of the header controls mean anything in this chat. Decided
            # here because it is a question about the chat's domains and its
            # runs, and the page has neither. A control that can only report
            # having nothing is worse than one that is absent: it reads as the
            # feature being broken rather than not applying.
            "controls": {
                "viewers": bool(results_panel._viewer_kinds(user, within=selected)),
                "versions": _chat_versions_apply(user, selected),
            },
            "available_studies": engine.accessible_studies(user, selected)}


@app.put("/api/chats/{cid}/domain")
async def set_chat_domain(cid: str, request: Request, user: str = Depends(current_user)):
    """Fix the domains a chat works in. Chosen once, at the start: they decide the
    standing context the model was briefed with, so they are not changed mid-conversation.
    Anything outside the user's access is dropped."""
    if not chats.get_chat(user, cid):
        raise HTTPException(status_code=404, detail="chat not found")
    body = await request.json()
    selected = engine.set_domains(user, cid, body.get("domains"))
    return {"ok": True, "selected_domains": selected,
            "available_studies": engine.accessible_studies(user, selected)}


@app.patch("/api/chats/{cid}")
async def rename_chat(cid: str, request: Request, user: str = Depends(current_user)):
    body = await request.json()
    chats.rename_chat(user, cid, body.get("title", ""))
    return {"ok": True}


@app.put("/api/chats/{cid}/studies")
async def set_chat_studies(cid: str, request: Request, user: str = Depends(current_user)):
    """Scope a chat to a subset of the user's studies. An empty list means all of them.
    Only ever narrows: the engine intersects this with live access on every turn."""
    if not chats.get_chat(user, cid):
        raise HTTPException(status_code=404, detail="chat not found")
    body = await request.json()
    # drop anything the user can't reach, so a stored selection never names a study they
    # have no access to (the engine intersects again per turn regardless)
    reachable = set(engine.accessible_studies(user, engine.domains_for(user, cid)))
    picked = [str(s) for s in (body.get("studies") or []) if str(s) in reachable]
    chats.set_chat_studies(user, cid, picked)
    return {"ok": True, "scope": engine.scope_for(user, cid)}


@app.post("/api/chats/{cid}/truncate")
async def truncate_chat(cid: str, request: Request, user: str = Depends(current_user)):
    """Rewind a chat to just before one message, for editing and resending it.

    Both histories are dropped: the display messages and the model's own conversation.
    Leaving the model's history in place would mean it still remembered the turns the user
    just removed, and answered as if they had happened."""
    if not chats.get_chat(user, cid):
        raise HTTPException(status_code=404, detail="chat not found")
    body = await request.json()
    try:
        index = int(body.get("index"))
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="index must be an integer")
    dropped = chats.truncate_messages(user, cid, index)
    retired = results_panel.retire(user, cid, dropped)
    conversations.delete(user, cid)
    engine.forget_chat(user, cid)
    return {"ok": True, "retired_artifacts": retired}


@app.delete("/api/chats/{cid}")
async def delete_chat(cid: str, user: str = Depends(current_user)):
    results_panel.retire_chat(user, cid)   # move its outputs aside before the record goes
    chats.delete_chat(user, cid)
    engine.forget_chat(user, cid)   # drop the model's copy too, in memory and on disk
    return {"ok": True}


# ── chat turn (SSE) ─────────────────────────────────────────────────────────
@app.post("/api/chat")
async def chat(request: Request, user: str = Depends(current_user)):
    body = await request.json()
    message = (body.get("message") or "").strip()
    chat_id = body.get("chat_id")
    if not chat_id or not chats.get_chat(user, chat_id):
        return JSONResponse({"error": "unknown chat"}, status_code=400)
    if not message:
        return JSONResponse({"error": "empty message"}, status_code=400)

    async def event_stream():
        # Stopping is the browser aborting this request. That cancels the turn where it
        # stands; closing it explicitly rather than leaving it to be collected means the
        # turn's own cleanup (persisting what it produced) runs now, not eventually.
        turn = engine.run_turn(user, chat_id, message)
        try:
            async for ev in turn:
                yield f"data: {json.dumps(ev)}\n\n"
                if await request.is_disconnected():
                    break
        finally:
            try:
                await turn.aclose()
            except Exception:  # noqa: BLE001 - already unwinding; the turn has cleaned up
                pass

    return StreamingResponse(event_stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ── results (scoped to a chat) ──────────────────────────────────────────────
@app.get("/api/results")
async def results(chat_id: str, user: str = Depends(current_user)):
    return SafeJSONResponse(results_panel.tree(user, chat_id))


@app.get("/api/results/item")
async def results_item(chat_id: str, ref: str, name: str, user: str = Depends(current_user)):
    """`ref` locates the artifact (its workspace, owner-prefixed for admin) — not the
    subject heading it is grouped under, which is display-only."""
    return SafeJSONResponse(results_panel.item(user, chat_id, ref, name))


@app.get("/api/results/file")
async def results_file(chat_id: str, ref: str, name: str, user: str = Depends(current_user)):
    path, media = results_panel.file_bytes(user, chat_id, ref, name)
    if not path:
        return JSONResponse({"error": "not found"}, status_code=404)
    return FileResponse(path, media_type=media)


# ── work still going ────────────────────────────────────────────────────────
# Answered from the machines rather than from the conversation. A run outlives
# the turn that started it, so its state is not something the chat can be relied
# on to know, and asking the model would spend a turn to learn what the
# filesystem already holds.
@app.get("/api/runs")
async def running(user: str = Depends(current_user)):
    return SafeJSONResponse({"running": runs.live(user)})


@app.post("/api/runs/{run}/cancel")
async def cancel_running(run: str, user: str = Depends(current_user)):
    """Stop a run. Anything it already wrote stays where it is."""
    return SafeJSONResponse(runs.cancel(user, run))


@app.get("/api/studies")
async def studies_for_domains(domains: str = "", user: str = Depends(current_user)):
    """The studies reachable in a set of domains. Lets a chat that has not been saved yet
    show the right study list before it has an id to store anything against."""
    picked = [d.strip() for d in domains.split(",") if d.strip()]
    return {"studies": engine.accessible_studies(user, picked or None)}


@app.get("/api/health")
async def health(user: str = Depends(current_user)):
    return SafeJSONResponse(engine.info(user))


@app.get("/api/controls")
async def controls(domains: str = "", user: str = Depends(current_user)):
    """Which header controls mean anything for a set of domains.

    The same answer `/api/chats/{id}` carries, asked before a chat exists. A new
    conversation has picked its domains and has no id yet, and drawing the
    controls for the previous chat until it is saved is how a viewer appears in a
    conversation that will never have one.
    """
    chosen = [d.strip() for d in domains.split(",") if d.strip()]
    return {"viewers": bool(results_panel._viewer_kinds(user, within=chosen or None)),
            "versions": _chat_versions_apply(user, chosen or None)}


@app.get("/api/capabilities")
async def capabilities(user: str = Depends(current_user)):
    """What this person can find out, and how a chat is set up to ask it.

    The capabilities are read from the catalog rather than written into the page,
    so one added to a domain appears here without anyone remembering to add it.
    """
    import offered
    return SafeJSONResponse(offered.for_user(user))


@app.get("/api/versions")
async def versions_grid(chat_id: str = "", user: str = Depends(current_user)):
    """Every version of everything this user has, and which one is in play here.

    User-scoped on purpose, unlike the results panel beside it. The panel answers
    "what did this conversation produce", which is why opening a new chat shows
    nothing. This answers "what do I have", which is a question about the data
    and not about the conversation, and it is the surface where cluster work done
    in another chat is found.
    """
    import versions as _versions
    return SafeJSONResponse(_versions.panel(user, chat_id))


@app.post("/api/versions")
async def versions_set(request: Request, user: str = Depends(current_user)):
    """Choose versions. `{"chat_id": ..., "picked": {"<subject>::<capability>": id}}`

    An identity selects that version, `""` clears the cell on purpose, and `null`
    goes back to following the newest. Three states rather than two, because "I
    have not chosen" and "I chose nothing" lead to different behaviour: the first
    tracks new work as it lands, the second waits to be told.
    """
    body = await request.json()
    chat_id = str(body.get("chat_id") or "")
    picked = body.get("picked") or {}
    if not chat_id or not isinstance(picked, dict):
        return JSONResponse({"error": "chat_id and picked are required"},
                            status_code=400)
    n = chats.set_versions(user, chat_id, picked)
    import versions as _versions
    return SafeJSONResponse({"set": n, **_versions.panel(user, chat_id)})


@app.get("/api/viewers")
async def viewers(chat_id: str = "", user: str = Depends(current_user)):
    """Every viewer, and whether this chat has produced something to open in one.

    Listed even when there is nothing to open. A control that appears only once
    it works cannot be found before then, and someone who does not know a result
    can be looked at will not ask for one.
    """
    return SafeJSONResponse(results_panel.viewers(user, chat_id))


# The interactive viewer, mounted over the bundle a run produced. It is
# third-party software we do not ship, so this does nothing until a deployment
# installs it and points SPATIALVIEW_ROOT at the copy. Entitlement is checked
# per request, in there, against the same session as everything else.
app.include_router(viewer.router(bundles_for=results_panel.bundles_for,
                                 current_user=current_user))

app.mount("/static", StaticFiles(directory=_WEB), name="static")


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", "8000"))
    host = os.environ.get("HOST", "127.0.0.1")   # 0.0.0.0 in a container (set by compose)
    if os.environ.get("DEV_RELOAD") in ("1", "true", "True"):
        here = Path(__file__).resolve().parent
        uvicorn.run("server:app", host=host, port=port, log_level="info",
                    reload=True, app_dir=str(here),
                    reload_dirs=[str(here), str(here.parent)])
    else:
        uvicorn.run(app, host=host, port=port, log_level="info")
