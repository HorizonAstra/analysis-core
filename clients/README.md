# LLM-Orchestrated Analysis Environment

**Version 3.9**

An analysis environment for multi-omic study data (metagenomics, metabolomics,
and clinical) that a Claude model drives directly. Instead of a fixed menu of analyses, it gives
the model two surfaces: **curated, guardrailed tools** for the common operations,
and a **code scratch space** where any cohort, derived quantity, novel analysis, or
figure is built from composable primitives. Every result is recorded with full
provenance.

It is built for repeated-measures (longitudinal) data and handles it correctly when
present (subject-aware correlation, mixed-effects models), but it is not limited to
it: cross-sectional studies, cross-study comparisons, and arbitrary cohorts are all
ordinary cases here.

## What it gives the model

- **Curated tools.** Study discovery, within-subject correlation, beta diversity
  (distance → PCoA → PERMANOVA), differential abundance, alpha diversity. They carry the
  correctness guardrails and auto-save their results.
- **bioBakery's own stats**, run as-is: MaAsLin 3 (multivariable, two-part,
  repeated-measures aware), LEfSe (LDA effect size), HAllA (taxa ↔ metabolite blocks).
  Local and synchronous.
- **Shotgun pipelines on a cluster.** KneadData → MetaPhlAn → HUMAnN/StrainPhlAn, submitted
  over SSH. Asynchronous: the model gets a job handle in seconds and polls later, so raw
  reads and downstream interpretation live behind one interface.
- **A scratch space** (`run_code`). The study data, pandas/numpy, the blessed
  primitives and multi-stage workflows, a general charting library, and a
  provenance workspace, all in one place. Cohort construction and anything no tool
  expresses live here.
- **Composable primitives + workflows** under `src/analysis/`: atomic statistical engines
  (general, batch-first, no policy), workflows that compose them with the project's
  defaults, a general chart library, and a small validation/error library.
- **Provenance.** Every derived artifact (cohort, table, result, plot) lands in a
  workspace with a manifest recording what it is, when, what produced it, which
  source studies it drew on, and what it depended on. The model reads results back
  through the system, never by guessing file paths.
- **One output tree.** `outputs/` holds everything, and whether an artifact answers the
  question is a `presented` flag on its manifest — filed under a topic, not copied into a
  second directory. Nothing a tool computes is unreachable from the UI.
- **Tools you can actually run.** A tool is offered only when the user's data domain is
  reachable and its backend is built, so the model is never invited to reach for an analysis
  that would fail. `./mo capabilities` shows the state and why anything is missing.

## Running it

Everything starts from one command, `./mo`:

| Command | What it does |
| --- | --- |
| `./mo setup` | Install once: `.venv`, dependencies, the external analysis envs, `data/`, `outputs/`, and the data cache |
| `./mo web` | The browser app on http://127.0.0.1:8000 (sets up first if needed) |
| `./mo cli` | The terminal chat |
| `./mo desktop` | Register the tools with Claude Desktop |
| `./mo docker` | Build and run the container |
| `./mo status` | What is installed and configured right now |

Run `./mo` on its own for the same list. Settings go in front of the command:
`PORT=8080 ./mo web`, `DEV_RELOAD=1 ./mo web`, `LLM_PROVIDER=google ./mo cli`.

After cloning, run `./mo setup`, then pick a way to run it. All of them drive the same
engine.

### Option A: browser chat (the product)

The user-facing surface: a multi-user web chat (login, multiple chats, a results panel)
that drives the toolkit over the API. The model key stays server-side.

```bash
cp .env.example .env   # add your API key (set once; never sent to the browser)
./mo web                 # sets up on first run, then opens http://127.0.0.1:8000
```

Run-anywhere container instead (one command): `docker compose up --build`.

Sign in with one of the seeded accounts (e.g. `aml@bsd.uchicago.edu` / `aml`).
Lives in [webapp/](webapp/); see [webapp/README.md](webapp/README.md), including the
**dev vs prod** notes (same code: dev is `./mo web` + `DEV_RELOAD`; prod is `docker
compose up` with a stable `SESSION_SECRET` and `COOKIE_SECURE=1` behind HTTPS).

### Option B: Claude Desktop (no API key, cheap dev path)

On **macOS**, run `./mo desktop`. Then fully quit Claude Desktop (Cmd+Q) and reopen it;
the `analysis-toolkit` tools appear.

On **Windows/Linux** (or to set it up by hand), add this to your Claude Desktop
config file, replacing `/ABSOLUTE/PATH/TO/llm-analysis-orchestrator` with the real
repo path:

```json
{
  "mcpServers": {
    "analysis-toolkit": {
      "command": "/ABSOLUTE/PATH/TO/llm-analysis-orchestrator/.venv/bin/python3",
      "args": ["/ABSOLUTE/PATH/TO/llm-analysis-orchestrator/src/McpServer/mcp_server.py"]
    }
  }
}
```

The config file lives at:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

A copy-pasteable template is in
[claude_desktop_config.example.json](claude_desktop_config.example.json). Restart Claude
Desktop afterward. (This is exactly what `./mo desktop` writes for you on macOS; the actual
file Claude Desktop reads is the one above, not anything in the repo. No API key goes in
it. Desktop uses your own Claude account, which is why it's the cheap dev path.)

### Option C: standalone API client (terminal)

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./mo cli
# optional: ANTHROPIC_MODEL=claude-opus-4-8   ANTHROPIC_MAX_TOKENS=4096
# alternate free backend: LLM_PROVIDER=google GEMINI_API_KEY=... ./mo cli
```

`./mo cli` spawns the same server and runs an agentic loop with the `context/` brief as
its system prompt: the same engine the browser chat uses, in a terminal.

### Option D: Claude Code

The repo ships a project-scoped [.mcp.json](.mcp.json), so opening the repo in Claude
Code exposes the `analysis-toolkit` tools automatically (it runs `.venv/bin/python3`, so
`./mo setup` first). Same tools, in your editor agent.

> **Where do outputs go for B / C / D?** When the toolkit is driven directly (Desktop,
> the terminal client, or Claude Code) there is no signed-in user, so it writes to
> `outputs/local/`, a dedicated local sandbox kept separate from the browser app's per-user
> `outputs/<user>/`.

### Add studies

Drop a study folder into the data root for this machine (`DATA_ROOT`, or the
`data_root` in its site profile). What a study of a given kind looks like is
declared by the domain that owns it, in `domains/<name>/study.json`, so a shape
this tree does not yet recognise is a declaration rather than a code change.
What was found, and the reference for each part of it, comes back from
`list_data`.

## Try

> List the studies, give me an overview of one, then bin its samples into
> low/medium/high inverse simpson diversity and tell me which species differ between the
> diversity groups, with a figure.

## Layout

Two units, structured to become two repos (`src/` the engine, `webapp/` the product):

```
src/     the engine (future repo)
  analysis/primitives/     atomic statistical engines (general, batch-first, no policy)
  analysis/workflows/      guardrailed compositions of primitives
  analysis/domains/        code that hardcodes one data shape (microbiome, spatial)
  analysis/visualization/  general charting library (charts + composition)
  analysis/errors/         validation + exception helpers
  compute/                 work that runs outside this process:
                             backends/ HOW (local R, local Python CLI, remote SLURM)
                             sites/    WHERE (one module per machine)
                             secondary/ tertiary/  WHAT, by pipeline phase
  datasource/              the data layer: DataSource port + Parquet/DuckDB read engine
  provenance/              workspace + artifact store, with presentation as a manifest flag
  McpServer/               the MCP server: entry + shared context + tools/
  capabilities.py          what this installation can actually do
  providers.py             LLM provider seam (Claude / Gemini)
  system_prompt.py         the shared system prompt (guardrails)
  chat_client.py           the standalone terminal client
webapp/  the browser product (future repo)
  server.py engine.py web/ the FastAPI backend + no-build-step UI
context/                   the always-on standing brief, shared by every conversation
envs/                      pinned environments for the external programs (R, HAllA)
documentation/             detailed docs, one per part of the system
data/  outputs/            studies in (by domain); everything derived out
```

Co-location, not microservices: the data layer is a module *inside* the engine, next
to compute, because at this scale the right move is to read data where you compute it,
not ship it across a network. Full details for every part are in
[documentation/](documentation/).
