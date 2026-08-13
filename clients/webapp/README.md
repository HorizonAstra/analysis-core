# webapp — the browser product

A multi-user web chat that drives the analysis toolkit over the API: login, multiple
chats per user, a per-chat results panel, and per-user study access. A self-contained
unit (a future separate repo): a thin FastAPI backend plus a no-build-step frontend that
reuses the engine in `../src`.

## Run

```bash
cp examples/.env.example .env   # set GEMINI_API_KEY once (server-side; never sent to browser)
./mo web                 # from the repo root: sets up if needed, opens :8000
```

Or, run-anywhere container (one command): `docker compose up --build`.

Seeded accounts (no sign-up yet): `aml@bsd.uchicago.edu`/`aml`,
`mb@bsd.uchicago.edu`/`mb`, `ts@bsd.uchicago.edu`/`ts`,
`mgx@bsd.uchicago.edu`/`mgx`, `admin`/`ad`.

### Dev vs prod (same code, different settings — not different scripts)

- **Dev (your laptop):** `./mo web`. Add `DEV_RELOAD=1` to
  auto-restart on Python edits, `PORT=8080` to change the port. Convenience, not hardened.
- **Prod (admin, one command):** put a production `.env` in the repo root (a stable
  `SESSION_SECRET`, and `COOKIE_SECURE=1` since you serve over HTTPS), then:

  ```bash
  docker compose up -d --build      # builds + runs detached; restarts on reboot
  docker compose logs -f            # watch it;  docker compose down  to stop
  ```

  Put an HTTPS reverse proxy (nginx/Caddy/a cloud load balancer) in front of port 8000.
  That's the whole deploy — the container runs identically anywhere ("platform-agnostic").

  It is the **same single process** — do **not** run multiple uvicorn workers: the app
  holds per-user state and a per-user MCP subprocess in memory, which separate workers
  wouldn't share. Scale by adding a warm-pool/eviction for MCP servers later, not workers.

## How it fits together

```
browser ──HTTP/SSE──> server.py (FastAPI, auth-gated)
                        ├─ auth.py    JWT sessions in an httponly cookie (no key inside)
                        ├─ access.py  domain + study allowlists; what a user can reach
                        ├─ paths.py   the user -> directory rule, and the three roots
                        ├─ store.py   per-user chats (JSON) — messages + which artifacts
                        ├─ render.py  presentation: step phrases, markdown, tables, links
                        ├─ results_panel.py  reading saved work back out, and undoing it
                        └─ engine.py  ── spawns ─> src/McpServer   (one per user, with that
                                                    user's ALLOWED_STUDIES + own OUTPUTS_ROOT)
                                     ── uses ───> src/providers.py, src/system_prompt.py
```

- **config.py** — loads `.env`; the LLM key lives only here, server-side, and is redacted
  from anything sent to the client. The dev picks the model (default: Google flash).
- **auth.py** — three fixed accounts + JWT sessions; gates every `/api` route so the key
  can't be spent by anyone who didn't log in. Shaped like symbiote's auth (same
  `{username, expires_at}` HS256 token; `bsd.uchicago.edu`-only except admin), so its real
  LDAP/ACL backend swaps in behind the one `backend` seam. (Not real auth yet; passwords
  in code.)
- **access.py** — who can see which studies. Enforced by launching each user's MCP server
  with `ALLOWED_STUDIES`, so the data layer itself refuses the rest (no data is copied).
  An allowlist that is present but *empty* allows nothing, never everything.
- **per-chat study scope** — the **Studies** button scopes a chat to a subset of that
  access (multi-select, all by default, saved on the chat). Applied at the start of every
  turn by calling the server's internal `set_study_scope`, which resets that process's
  live `ALLOWED_STUDIES`. Real rather than advisory: the data layer re-reads the allowlist
  per call, so it covers `load_study` inside the code space, not just a tool argument. It
  can only ever narrow, since the tool intersects with the allowlist captured at launch
  (`context.ACCESS_FLOOR`). The tool is registered only when `ENABLE_SCOPE_TOOL=1` (so the
  CLI and Desktop never see it) and is filtered out of the tool list given to the model.
- **store.py** — per-user chats, their messages (for reload), the artifacts each chat
  produced (for per-chat results), and the chat's study scope. This is the *display*
  history. A chat file that cannot be parsed is quarantined rather than treated as empty:
  every writer is read-modify-write, so "unreadable means no chats" would let one bad read
  silently erase a user's whole history on the next save.
- **conversations.py** — the *model's* history, one file per chat, in native provider
  blocks. Written at the end of every turn, rehydrated on a cache miss, so a restart does
  not leave the user looking at a transcript the model has no memory of. Not derivable
  from `store.py`: thinking signatures and compaction blocks have to round-trip
  byte-exact. `Engine.conversations` is an LRU cache over this (`LLM_MAX_LIVE_CHATS`,
  default 50), not the record.
- **outputs are per user** — each user's MCP server runs with `OUTPUTS_ROOT` pointed at
  `outputs/<user>/`, so the model can only ever write into that user's own store. There is one
  tree, not two: whether an artifact was *presented* is a flag on its manifest. Admin gets its
  own folder and, in the panel, a read-only merged view of every user's results.
- **engine.py** — one MCP session per user; turns a message into user-facing events:
  `status`, `message` (sanitized markdown), `image`, `artifact` (a clickable card that
  opens the result), `done`/`error`. Tool names and paths never cross to the client.
  **The turn loop and nothing else** — it was 1021 lines carrying four jobs, and the other
  three now have their own modules.
- **render.py** — everything the reader is shown: a step as a phrase in their terms
  (never a tool name), model prose parsed then bleached into safe HTML, table cells at full
  float precision, parameter rows, artifact links. Pure functions; no engine state.
- **results_panel.py** — the panel: what a chat produced (not only what was *presented* —
  the un-presented artifact is often the full table a top-30 came from), one artifact
  shaped for inline viewing, its raw bytes, and retirement for undo. Re-authorizes every
  read, so access follows who the user is *now*.
- **paths.py** — the one implementation of the user→directory rule. It used to exist twice,
  byte-identical, in `engine.py` and `store.py`; had they drifted, half the app would write
  `outputs/a_b` while the other half read `outputs/a-b`.
- **web/** — `login.html`, `index.html`, `app.js`, `styles.css`, `favicon.svg`, `icons/`.
  No framework, no build step. Prose rendered + sanitized server-side; figures are PNGs
  from the engine (no client charting lib). The results panel renders figures, tables
  (csv/tsv), JSON, and written results (txt/md, rendered as markdown so a summary reads as
  prose rather than raw source); anything else offers a download. Table cells are
  formatted for reading and carry full float precision from the server, so a p-value of
  1e-14 stays 1e-14 instead of rounding to zero.
  Two top-bar controls, deliberately separated: an **info button beside the name** opens a
  capabilities panel (grouped and collapsible: study selection, orientation, cohort
  creation, analysis, visualization), and the **Studies button on the right** sets this
  chat's scope. One describes the product, the other changes state.
  The send button doubles as **stop** while a turn runs. Every turn opens with a
  cancel-free window (`LLM_SEND_GRACE`, default 1.5s) in which nothing has been sent or
  saved, so stopping there rewinds the send and returns the text to the composer; after it,
  stopping keeps whatever was produced, because those tokens were spent.

## Deliberate scope (for now)

- Auth is minimal (fixed accounts, plaintext); it exists to separate users and gate the
  key. A real org auth layer swaps in behind `auth.py`, the session machinery stays.
- One MCP server per user (3 users → 3 processes); a warm pool / eviction comes with more
  users. Turns serialize per user; different users run in parallel.
- Chat display history and the model's own history both persist; a restart keeps a chat
  continuable (`conversations.py`).
- Turn-level streaming (status → figures → prose), not token-level.
