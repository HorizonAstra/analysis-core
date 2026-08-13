// Client for the Multiomics Analysis chat. No framework, no build step.
// Auth-gated, multi-chat, per-chat results. Native fetch streaming; prose and figures
// come rendered from the server.

const $ = (s) => document.querySelector(s);
const scroll = $("#scroll"), thread = $("#thread");
const form = $("#form"), input = $("#input"), send = $("#send");

let currentChatId = null;
let streaming = false;
let controller = null;  // aborts the in-flight turn when the user stops it
let graceWindow = false; // true while the turn can still be taken back for free
let working = null;
let liveProse = null;   // the element receiving streamed text for the turn in flight
let livePending = "";   // arrived from the stream, not yet shown
let liveText = "";      // shown so far, re-rendered as markdown each frame
let liveRaf = null;     // the frame loop draining livePending
let liveRate = 0;       // chars per ms currently being shown, smoothed over frames
let liveLast = 0;       // timestamp of the last drain, so the rate is per ms not per frame
let liveStableHtml = ""; // markdown already rendered and settled; never re-parsed
let liveStableLen = 0;  // how much of liveText that covers
let liveFinalHtml = null; // the server's rendering, held until the buffer has caught up
let liveCloseAt = 0;    // deadline for that catch-up
let liveTrace = null;      // the one process block for the turn in flight, if any
let liveThinkPara = null;  // the reasoning paragraph currently streaming into it
let liveStepCount = 0;
// how many messages this chat has stored. An edit rewinds to a position in that
// array, so the index has to be the stored one, not the count of bubbles on screen:
// a single turn writes several records (reasoning, steps, the answer).
let threadLen = 0;
let studies = [];       // the studies reachable in this chat's domain
let chatStudies = null; // this chat's selection; null means all of the above
let chatDomains = [];   // the domains this chat works in; fixed once chosen

// ── small helpers ───────────────────────────────────────────────────────────
// Follow the streaming answer only while the reader is at the bottom. Scrolling up is
// the reader saying they are reading rather than watching, and dragging them back is
// the most hostile thing a streaming view can do; arriving back at the bottom opts
// them in again, so a turn can be left and rejoined without touching a control.
//
// Two things made this a fight. The follow was a smooth scroll, so it was still
// animating toward the bottom when the next token re-issued it — the reader was
// scrolling against an animation that kept re-targeting. And the detach threshold was
// 120px, wide enough that a deliberate scroll of one notch stayed "at the bottom" and
// got overridden. The follow is now instant, and the threshold is tight.
let stickToBottom = true;
const STICK_SLACK = 64;   // px of drift still counted as at-the-bottom
function atBottom() { return scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < STICK_SLACK; }
function toBottom(force) {
  if (force) stickToBottom = true;
  if (stickToBottom) scroll.scrollTop = scroll.scrollHeight;
}
// Recomputed from position on every scroll, whoever caused it. The follow above always
// lands exactly at the bottom, so its own events re-arm the stick; only a reader moving
// away from the bottom clears it, and only a reader coming back restores it.
scroll.addEventListener("scroll", () => { stickToBottom = atBottom(); }, { passive: true });
function el(cls, html) { const d = document.createElement("div"); d.className = cls; if (html !== undefined) d.innerHTML = html; return d; }
function place(node) { if (working) thread.insertBefore(node, working); else thread.appendChild(node); toBottom(); }
function escapeHtml(s) { return String(s).replace(/[&<>"']/g, (m) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[m])); }
function formatName(s) { return String(s).replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim().split(" ").map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w)).join(" "); }
const enc = encodeURIComponent;

// ── transcript rendering ─────────────────────────────────────────────────────
function clearTranscript() { thread.innerHTML = ""; working = null; liveProse = null; resetLive(); }
function showWelcome() {
  clearTranscript();
  const w = el("welcome");
  w.innerHTML = `<h1>What would you like to look into?</h1>
    <p class="sub">Ask in plain language, or in precise technical terms. I’ll inspect the
    data, choose sound methods, and show you the results, figures included.</p>
    <div class="chips" id="chips"></div>`;
  thread.appendChild(w);
  const chips = w.querySelector("#chips");
  chips.classList.add("collapsed");                 // clips + fades the overflow
  suggestions().forEach((t) => {
    const c = document.createElement("button");
    c.className = "chip"; c.type = "button"; c.textContent = t;
    c.addEventListener("click", () => submit(t));
    chips.appendChild(c);
  });
  // Show more / less on its own line below — only if the list actually overflows
  const moreWrap = el("chips-more");
  const more = document.createElement("button");
  more.className = "chip-more"; more.type = "button"; more.textContent = "Show more";
  moreWrap.appendChild(more); w.appendChild(moreWrap);
  requestAnimationFrame(() => {
    if (chips.scrollHeight <= chips.clientHeight + 4) { moreWrap.remove(); chips.classList.remove("collapsed"); }
  });
  more.addEventListener("click", () => {
    more.textContent = chips.classList.toggle("collapsed") ? "Show more" : "Show less";
  });
}
function suggestions() {
  // built only from the studies in scope for this chat, so nothing unreachable is hinted
  // at, and phrased for the chat's domain — a microbiome prompt in a spatial chat asks
  // for analyses that do not exist there
  const s = scopedStudies();
  if (!s.length) return ["List the available studies", "Give me an overview of a study"];
  const pick = (n, i) => (s.includes(n) ? n : (s[i] ?? s[0] ?? n));
  const first = ["What studies are available, and what does each one contain?"];

  if (chatDomains.length === 1 && chatDomains[0] === "spatial-transcriptomics") {
    const st = s[0];
    return first.concat([
      `Which samples in ${st} produced a good spatial fit, and which look weak?`,
      `In ${st}, which region boundary separates the most genes?`,
      `Rank the genes in ${st} by how widespread their spatial bias is, and map the names.`,
      `Which genes come up as significant across many samples in ${st}?`,
    ]);
  }

  const ov = pick("AROW", 0), leuk = pick("Leukemia", 1), a = pick("AROW", 0), b = pick("HealthyDonors", 2);
  const out = first.concat([`What are the top microbial-to-metabolite correlations in ${leuk}?`]);
  if (a !== b) out.push(`Compare microbial diversity between ${a} and ${b}`);
  out.push(`Make three cohorts in ${leuk} by inverse Simpson alpha diversity: low below 2, medium from 2 up to 7, and high at 7 or above.`);
  out.push(`Plot a histogram showing the distribution of a metabolite in ${ov}.`);
  out.push(`Plot the trajectory of a clinical event over time in ${leuk}.`);
  return out;
}

function addUserTurn(text, index) {
  const w = thread.querySelector(".welcome"); if (w) w.remove();
  const turn = el("turn user");
  const b = el("bubble"); b.textContent = text;
  turn.appendChild(b);
  // Editing rewrites the thread from this point on. Only offered for messages whose
  // position we know, which is every message loaded from the stored chat.
  if (typeof index === "number") {
    turn.dataset.index = String(index);
    const edit = document.createElement("button");
    edit.className = "turn-edit"; edit.type = "button"; edit.title = "Edit and resend";
    edit.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14"><path d="M4 20h4l10-10-4-4L4 16zM14 6l4 4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    edit.addEventListener("click", () => startEdit(turn, text, index));
    turn.appendChild(edit);
  }
  thread.appendChild(turn); toBottom(true);
}

// Edit in place, then resend. Everything after this message goes: those turns answered
// the old text, and keeping them would leave the transcript disagreeing with itself.
function startEdit(turn, original, index) {
  if (streaming) return;
  const bubble = turn.querySelector(".bubble");
  if (!bubble || turn.querySelector(".edit-box")) return;
  const box = el("edit-box");
  const ta = document.createElement("textarea");
  ta.className = "edit-input"; ta.value = original; ta.rows = 1;
  const acts = el("edit-actions");
  const cancel = document.createElement("button");
  cancel.className = "edit-btn"; cancel.type = "button"; cancel.textContent = "Cancel";
  const send = document.createElement("button");
  send.className = "edit-btn primary"; send.type = "button"; send.textContent = "Send";
  acts.append(cancel, send); box.append(ta, acts);
  const editBtn = turn.querySelector(".turn-edit");
  if (editBtn) editBtn.hidden = true;          // redundant beside Cancel/Send
  bubble.hidden = true; turn.appendChild(box);
  // measure after layout, or scrollHeight is read off an element the browser has not
  // sized yet and the box opens several times taller than its content
  const grow = () => {
    ta.style.height = "auto";
    ta.style.height = Math.max(44, Math.min(ta.scrollHeight, 300)) + "px";
  };
  requestAnimationFrame(grow);
  ta.addEventListener("input", grow);
  setTimeout(() => { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); }, 20);

  const close = () => { box.remove(); bubble.hidden = false; if (editBtn) editBtn.hidden = false; };
  cancel.onclick = close;
  send.onclick = async () => {
    const next = ta.value.trim();
    if (!next) return;
    close();
    try {
      await fetch(`/api/chats/${currentChatId}/truncate`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ index }),
      });
    } catch { return; }
    while (turn.nextSibling) turn.nextSibling.remove();   // drop the answers below
    turn.remove();
    submit(next);
  };
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Escape") close();
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send.click(); }
  });
}
function addAssistantMessage(html) { const turn = el("turn assistant"); turn.appendChild(el("prose", html)); place(turn); }

// Text arrives in fragments while the model is still writing. It goes in as plain text
// (markdown is rendered server-side), then the `message` event swaps in the rendered copy.
// Markdown while the answer is still being written. The server renders the real HTML and
// swaps it in on `message`, so this only has to be right for the common marks and is
// never what the user is left with. Everything is escaped before any tag is added, and
// fenced code is lifted out first so its contents are never reinterpreted.
function mdLite(src) {
  const blocks = [];
  // Escape first, then lift out fenced code. Escaping turns every "<" into "&lt;", so a
  // "<<CODE_n>>" placeholder cannot collide with anything in the text by construction.
  let s = escapeHtml(String(src)).replace(/```[^\n]*\n?([\s\S]*?)(?:```|$)/g, (_, code) => {
    blocks.push(`<pre><code>${code}</code></pre>`);
    return `<<CODE_${blocks.length - 1}>>`;
  });
  s = s
    .replace(/`([^`\n]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*\w])\*([^*\n]+)\*/g, "$1<em>$2</em>")
    .replace(/\[([^\]\n]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');

  const out = []; let list = null, para = [], table = null;
  const flushPara = () => { if (para.length) { out.push(`<p>${para.join("<br>")}</p>`); para = []; } };
  const flushList = () => { if (list) { out.push(`</${list}>`); list = null; } };
  for (const raw of s.split("\n")) {
    const line = raw.trimEnd();
    const ph = line.match(/^<<CODE_(\d+)>>$/);
    if (ph) { flushPara(); flushList(); out.push(blocks[+ph[1]]); continue; }
    if (!line.trim()) {
      flushPara(); flushList();
      if (table) { out.push(renderTableLines(table)); table = null; }
      continue;
    }
    const h = line.match(/^(#{1,4})\s+(.*)$/);
    if (h) { flushPara(); flushList(); out.push(`<h${h[1].length}>${h[2]}</h${h[1].length}>`); continue; }
    // a table: consecutive rows of pipes, with the |---|---| separator dropped
    if (/^\s{0,3}\|.*\|\s*$/.test(line)) {
      flushPara(); flushList();
      if (!table) { table = []; }
      table.push(line);
      continue;
    }
    if (table) { out.push(renderTableLines(table)); table = null; }
    const item = line.match(/^\s*[-*+]\s+(.*)$/) || line.match(/^\s*\d+[.)]\s+(.*)$/);
    if (item) {
      flushPara();
      const want = /^\s*\d/.test(line) ? "ol" : "ul";
      if (list !== want) { flushList(); out.push(`<${want}>`); list = want; }
      out.push(`<li>${item[1]}</li>`);
      continue;
    }
    flushList(); para.push(line);
  }
  flushPara(); flushList();
  if (table) out.push(renderTableLines(table));
  return out.join("");
}

// A table mid-stream is usually half-arrived, so this renders whatever rows exist rather
// than waiting for a complete one. The server's rendering replaces it when the turn ends.
function renderTableLines(lines) {
  const rows = lines
    .map((l) => l.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim()))
    .filter((cells) => !cells.every((c) => /^:?-{2,}:?$/.test(c) || c === ""));
  if (!rows.length) return "";
  const head = rows[0].map((c) => `<th>${c}</th>`).join("");
  const body = rows.slice(1).map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join("")}</tr>`).join("");
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

// Tokens do not arrive evenly: a hundred characters land at once, then nothing for a
// couple of hundred milliseconds. Painting them as they arrive is what reads as lurching,
// and so does draining at a rate read straight off the backlog — the backlog is exactly as
// spiky as the arrivals, so the speed steps with every burst.
//
// Instead the rate itself is a smoothed quantity. Each frame it moves a fraction of the
// way toward whatever would clear the current backlog over the next fifth of a second. The
// text still speeds up while the model writes fast and slows when it stalls, and it can
// never fall behind (a fuller buffer always pulls the target up), but it gets there over
// several frames rather than in one. The rate is per millisecond rather than per frame, so
// a dropped frame costs nothing instead of showing up as a stutter.
const DRAIN_HORIZON = 200;   // ms the backlog should take to clear at the target rate
const DRAIN_SMOOTH = 0.12;   // how far toward that target the rate moves each frame
const DRAIN_MIN = 0.03;      // chars/ms floor, so a trickle still visibly moves
const DRAIN_MAX = 6;         // and a flood is not paced down into a crawl
const CLOSE_HORIZON = 80;    // once the answer is complete the tail catches up faster
const CLOSE_LIMIT = 600;     // ms; past this the remainder is simply shown

function resetLive() {
  if (liveRaf) { cancelAnimationFrame(liveRaf); clearTimeout(liveRaf); }
  liveRaf = null; livePending = ""; liveText = "";
  liveStableHtml = ""; liveStableLen = 0;
  liveRate = 0; liveLast = 0;
  liveFinalHtml = null; liveCloseAt = 0;
  settleTrace();
}
// requestAnimationFrame does not fire in a hidden tab, so a turn watched from another tab
// would arrive and then sit in the buffer, invisible, until the user came back. Nothing to
// animate there anyway: when hidden, take the whole buffer at once and schedule with a
// timer, which keeps running.
function scheduleDrain() {
  if (liveRaf) return;
  if (!liveLast) liveLast = performance.now();
  liveRaf = document.hidden ? setTimeout(drainLive, 60) : requestAnimationFrame(drainLive);
}
function drainLive() {
  liveRaf = null;
  if (!liveProse) { livePending = ""; liveText = ""; return; }
  const now = performance.now();
  // a long gap (a backgrounded tab, a blocked main thread) must not turn into one huge
  // catch-up chunk, which is the very jump this exists to avoid
  const dt = Math.min(now - liveLast, 100);
  liveLast = now;
  if (document.hidden) {
    liveText += livePending; livePending = "";
  } else {
    const closing = liveFinalHtml !== null;
    const target = livePending.length / (closing ? CLOSE_HORIZON : DRAIN_HORIZON);
    liveRate = Math.min(Math.max(liveRate + (target - liveRate) * DRAIN_SMOOTH,
                                 DRAIN_MIN), DRAIN_MAX);
    const n = Math.max(1, Math.round(liveRate * dt));
    liveText += livePending.slice(0, n);
    livePending = livePending.slice(n);
  }
  paintLive();
  toBottom();
  if (livePending && !(liveFinalHtml !== null && now > liveCloseAt)) { scheduleDrain(); return; }
  if (liveFinalHtml !== null) closeLive();
}

// Re-parsing the whole answer on every frame gets steadily slower as the answer grows,
// which is a second, separate source of stutter — the pacing can be perfect and the frames
// still arrive late. Markdown blocks are independent once separated by a blank line, so
// everything up to the last blank line is rendered once and kept as a string; only the
// block still being written is re-rendered. A blank line inside an unclosed code fence is
// not a boundary, which keeps the settled prefix always outside a fence.
function paintLive() {
  const tail = liveText.slice(liveStableLen);
  let cut = 0, m;
  const re = /\n[ \t]*\n/g;
  while ((m = re.exec(tail)) !== null) {
    const upto = m.index + m[0].length;
    if ((tail.slice(0, upto).match(/```/g) || []).length % 2 === 0) cut = upto;
  }
  if (cut) { liveStableHtml += mdLite(tail.slice(0, cut)); liveStableLen += cut; }
  liveProse.innerHTML = liveStableHtml + mdLite(liveText.slice(liveStableLen));
}
// ONE block per turn holds the whole process: the model's reasoning and the steps it
// took, interleaved in the order they happened. Deliberately not part of the answer —
// it is working-out, not a finding, and it must never read as the conclusion — and
// deliberately not several blocks, because a turn can produce twenty of these events
// and twenty collapsibles down the transcript is a log, not an answer. Absent entirely
// when a turn has neither, so nothing here changes the layout of a turn without one.
function traceBody() {
  if (liveTrace) return liveTrace.querySelector(".tr-body");
  stopWorking();
  const turn = el("turn assistant trace-turn");
  liveTrace = document.createElement("details");
  liveTrace.className = "trace";
  liveTrace.open = false;                      // available, never in the way
  liveTrace.innerHTML = '<summary><span class="tr-label">Thinking…</span></summary><div class="tr-body"></div>';
  animateDetails(liveTrace, liveTrace.querySelector(".tr-body"));
  turn.appendChild(liveTrace);
  place(turn);
  liveThinkPara = null; liveStepCount = 0;
  return liveTrace.querySelector(".tr-body");
}

// Reasoning arrives in fragments. Consecutive fragments extend one paragraph; a step in
// between ends it, so the block reads as narration broken by what the narration did.
function addThinking(text) {
  const body = traceBody();
  if (!liveThinkPara) { liveThinkPara = el("tr-think"); body.appendChild(liveThinkPara); }
  liveThinkPara.textContent += text;
  toBottom();
}

function addActivity(label, detail) {
  const body = traceBody();
  liveThinkPara = null;
  liveStepCount += 1;
  const step = el("tr-step");
  const head = el("tr-step-label");
  head.textContent = label || "Working";
  step.appendChild(head);
  if (detail) {
    const pre = document.createElement("pre");
    pre.className = "tr-detail"; pre.textContent = detail;
    step.appendChild(pre);
  }
  body.appendChild(step);
  toBottom();
}

// The block belongs to the turn that produced it. The answer arriving closes it: the
// label stops being a progress report and becomes what it is, and the next turn opens
// a new one. The step count stays on the label so a two-step turn and a twenty-step
// turn are distinguishable without opening either.
function settleTrace() {
  if (!liveTrace) return;
  liveTrace.querySelector(".tr-label").textContent = liveStepCount
    ? `Thought process · ${liveStepCount} step${liveStepCount === 1 ? "" : "s"}`
    : "Thought process";
  liveTrace = null; liveThinkPara = null; liveStepCount = 0;
}

function addDelta(text) {
  if (!liveProse) {
    stopWorking();
    settleTrace();
    const turn = el("turn assistant");
    liveProse = el("prose");
    turn.appendChild(liveProse);
    place(turn);
    livePending = ""; liveText = "";
    liveStableHtml = ""; liveStableLen = 0;
    liveRate = 0; liveLast = performance.now();
  }
  livePending += text;
  scheduleDrain();
}
// The answer is complete, but the buffer may not be: swapping the server's rendering in
// while text is still catching up would drop the last part of the answer onto the screen
// all at once, which is the most visible jump of the whole turn. So the final HTML is held
// and the drain finishes at a quicker pace, bounded so it always terminates.
function finishLive(html) {
  liveFinalHtml = html == null ? "" : html;
  liveCloseAt = performance.now() + CLOSE_LIMIT;
  if (!liveProse || !livePending) { closeLive(); return; }
  scheduleDrain();
}
function closeLive() {
  const html = liveFinalHtml;
  const prose = liveProse;
  resetLive();
  liveProse = null;
  if (!prose) { addAssistantMessage(html); return; }
  prose.innerHTML = html;
  toBottom();
}
// Finish a close that is still catching up, at once, when something else needs the live
// block done now: a new turn starting, a stop, or an error.
function flushLive() { if (liveFinalHtml !== null) closeLive(); }
function addImage(src) {
  const turn = el("turn assistant"); const fig = el("figure"); const img = document.createElement("img");
  img.src = src; img.alt = "Figure"; img.addEventListener("load", () => toBottom()); fig.appendChild(img); turn.appendChild(fig); place(turn);
}
function addNotice(text, isError) { const turn = el("turn assistant"); turn.appendChild(el("notice" + (isError ? " error" : ""), "")).textContent = text; place(turn); }
function addArtifactCard(a) {
  const turn = el("turn assistant artifact");
  const card = document.createElement("button");
  card.className = "artifact-card";
  card.innerHTML = `<span class="ac-ico">${iconForFmt(a)}</span><span class="ac-name">${escapeHtml(formatName(a.name))}</span><span class="ac-open">Open</span>`;
  card.addEventListener("click", () => { setPanelOpen(true); openItem(a.ref || a.topic, a.name); });
  turn.appendChild(card); place(turn);
}
// A run that was started and will outlive this turn. It goes in the thread so
// the conversation reads as one continuous account, and it is also in the panel,
// because by the time it lands the conversation may have moved far past here.
function addRunStarted(ev) {
  const step = el("tr-step tr-run");
  const head = el("tr-step-label");
  head.textContent = `${ev.label || "Analysis"} · started`;
  head.title = ev.site ? `Running on ${ev.site}` : "";
  step.appendChild(head);
  step.dataset.run = ev.run || "";
  traceBody().appendChild(step);
  toBottom();
  refreshGoing();
}
function startWorking() {
  working = el("turn assistant");
  working.innerHTML = '<div class="working"><span class="dots"><i></i><i></i><i></i></span><span class="label">Thinking…</span></div>';
  thread.appendChild(working); toBottom(true);
}
function setWorking(label) { if (!working) startWorking(); working.querySelector(".label").textContent = label; }
function stopWorking() { if (working) { working.remove(); working = null; } }

// ── streaming a turn ─────────────────────────────────────────────────────────
async function streamChat(message) {
  controller = new AbortController();
  const res = await fetch("/api/chat", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: currentChatId, message }),
    signal: controller.signal,      // stopping aborts this, which cancels the turn server-side
  });
  if (res.status === 401) { window.location.href = "/login"; return; }
  if (!res.ok || !res.body) { stopWorking(); addNotice("Couldn’t reach the analysis service.", true); return; }
  const reader = res.body.getReader(); const decoder = new TextDecoder(); let buf = "";
  while (true) {
    const { value, done } = await reader.read(); if (done) break;
    buf += decoder.decode(value, { stream: true });
    const parts = buf.split("\n\n"); buf = parts.pop();
    for (const part of parts) {
      const line = part.split("\n").find((l) => l.startsWith("data:")); if (!line) continue;
      let ev; try { ev = JSON.parse(line.slice(5).trim()); } catch { continue; }
      handle(ev);
    }
  }
}
function handle(ev) {
  switch (ev.type) {
    case "status":
      // the server marks the opening pause as undoable; every later status ends it
      graceWindow = ev.undoable === true;
      document.body.classList.toggle("grace", graceWindow);
      setWorking(ev.label);
      break;
    case "thinking": addThinking(ev.text); break;
    case "activity": addActivity(ev.label, ev.detail); break;
    case "delta": addDelta(ev.text); break;
    case "message": finishLive(ev.html); break;
    case "image": addImage(ev.src); break;
    case "run": addRunStarted(ev); break;
    case "artifact": addArtifactCard(ev); break;
    case "error":
      stopWorking(); settleTrace(); flushLive(); resetLive(); liveProse = null;
      addNotice(ev.message, true); break;
    case "done":
      // `done` lands right behind `message`, so tearing the live block down here would
      // cut short the catch-up that `message` just started. A close in flight owns its
      // own teardown and is bounded by CLOSE_LIMIT; only a turn that ended without an
      // answer is cleaned up from here.
      stopWorking(); settleTrace();
      if (liveFinalHtml === null) { resetLive(); liveProse = null; }
      refreshResults(); loadChats(); syncThreadLen();
      break;
  }
}

async function submit(text) {
  text = (text || "").trim();
  if (!text || streaming) return;
  await ensureChatExists();      // the chat becomes real at its first message
  streaming = true; graceWindow = false;
  document.body.classList.add("streaming");
  setSendEnabled();
  // its index is where it will land in the stored thread, so editing works immediately
  // rather than only after a reload
  addUserTurn(text, threadLen);
  input.value = ""; autogrow(); flushLive(); resetLive(); liveProse = null; startWorking();
  try { await streamChat(text); }
  catch (e) {
    if (e && e.name === "AbortError") endStopped(text);
    else { stopWorking(); addNotice("The connection was interrupted.", true); }
  }
  finally {
    streaming = false; controller = null; graceWindow = false;
    document.body.classList.remove("streaming", "grace");
    setSendEnabled(); input.focus();
  }
}
function stopTurn() { if (controller) controller.abort(); }
// Stopping inside the free window rewinds the send completely: nothing was requested and
// nothing was saved, so the text goes back to the composer to be fixed and sent again.
// After that window the turn really happened, so what it produced stays.
function endStopped(text) {
  stopWorking(); flushLive(); resetLive(); liveProse = null;
  if (graceWindow) {
    const sent = thread.querySelectorAll(".turn.user");
    if (sent.length) sent[sent.length - 1].remove();
    input.value = text; autogrow();
    if (!thread.querySelector(".turn")) showWelcome();
    return;
  }
  addNotice("Stopped.");
  refreshResults(); loadChats();
}

// ── composer ─────────────────────────────────────────────────────────────────
function autogrow() { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, window.innerHeight * 0.4) + "px"; }
// One control, two jobs: while a turn is running the send button is the stop button, so
// the way out sits where the user is already looking instead of somewhere else on screen.
function setSendEnabled() {
  send.disabled = !streaming && input.value.trim().length === 0;
  send.setAttribute("aria-label", streaming ? "Stop" : "Send");
}
function sendOrStop() { if (streaming) stopTurn(); else submit(input.value); }
input.addEventListener("input", () => { autogrow(); setSendEnabled(); });
input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendOrStop(); } });
form.addEventListener("submit", (e) => { e.preventDefault(); sendOrStop(); });

// ── chats ────────────────────────────────────────────────────────────────────
let chatList = [];
async function loadChats() {
  try { chatList = (await (await fetch("/api/chats")).json()).chats || []; }
  catch { chatList = []; }
  renderChatList();
}
function renderChatList() {
  const q = ($("#mpSearch").value || "").toLowerCase();
  const box = $("#mpChats"); box.innerHTML = "";
  const shown = chatList.filter((c) => !q || (c.title || "").toLowerCase().includes(q));
  if (!shown.length) { box.innerHTML = '<div class="mp-empty">No chats yet.</div>'; return; }
  for (const c of shown) {
    const row = document.createElement("div");
    row.className = "mp-chat-row" + (c.id === currentChatId ? " active" : "");
    const b = document.createElement("button");
    b.className = "mp-chat"; b.textContent = c.title || "New chat";
    b.addEventListener("click", () => switchChat(c.id));
    const acts = document.createElement("div"); acts.className = "mp-acts";
    const ren = document.createElement("button"); ren.className = "mp-act"; ren.title = "Rename";
    ren.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14"><path d="M4 20h4L18 10l-4-4L4 16v4zM14 6l4 4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    ren.addEventListener("click", (e) => { e.stopPropagation(); renameChat(c); });
    const del = document.createElement("button"); del.className = "mp-act"; del.title = "Delete";
    del.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14"><path d="M5 7h14M9 7V5h6v2M6 7l1 13h10l1-13" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    del.addEventListener("click", (e) => { e.stopPropagation(); deleteChat(c); });
    acts.append(ren, del); row.append(b, acts); box.appendChild(row);
  }
}
// a small in-app modal (no browser prompt/confirm) — resolves to the input value,
// `true` for a plain confirm, or null on cancel
function modal({ title, message, input, confirmText = "Confirm", danger = false }) {
  return new Promise((resolve) => {
    const back = el("modal-back"), card = el("modal-card");
    card.innerHTML = `<div class="modal-title">${escapeHtml(title)}</div>` +
      (message ? `<div class="modal-msg">${escapeHtml(message)}</div>` : "") +
      (input !== undefined ? '<input class="modal-input" type="text" />' : "") +
      `<div class="modal-actions"><button class="modal-btn cancel">Cancel</button>` +
      `<button class="modal-btn confirm${danger ? " danger" : ""}">${escapeHtml(confirmText)}</button></div>`;
    back.appendChild(card); document.body.appendChild(back);
    const inp = card.querySelector(".modal-input");
    if (inp) { inp.value = input || ""; setTimeout(() => { inp.focus(); inp.select(); }, 20); }
    const close = (v) => { document.removeEventListener("keydown", onKey); back.remove(); resolve(v); };
    function onKey(e) { if (e.key === "Escape") close(null); }
    document.addEventListener("keydown", onKey);
    back.addEventListener("mousedown", (e) => { if (e.target === back) close(null); });
    card.querySelector(".cancel").onclick = () => close(null);
    card.querySelector(".confirm").onclick = () => close(inp ? inp.value : true);
    if (inp) inp.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); close(inp.value); } });
  });
}
// The domain a chat works in: asked once, at the start, and only when the user actually
// has a choice to make. It is fixed for the chat because it decides the standing brief
// the model was given, so there is no cancel — the chat has no data until it is answered.
function pickDomains(options, preselected) {
  return new Promise((resolve) => {
    const back = el("modal-back"), card = el("modal-card");
    card.classList.add("wide", "domains");
    card.innerHTML = `<div class="modal-title">Domain Selection</div>` +
      `<div class="domain-grid"></div>` +
      `<div class="dm-note">Fixed for this chat once started.</div>` +
      `<div class="domain-foot"><button class="dm-all" type="button">Select all</button>` +
      `<span class="dm-count"></span></div>` +
      `<div class="modal-actions"><button class="modal-btn confirm">Start</button></div>`;
    const grid = card.querySelector(".domain-grid");
    const go = card.querySelector(".confirm");
    const all = card.querySelector(".dm-all");
    const count = card.querySelector(".dm-count");
    const chosen = new Set(preselected && preselected.length ? preselected : [options[0].name]);

    function sync() {
      for (const b of grid.children) b.classList.toggle("on", chosen.has(b.dataset.name));
      count.textContent = chosen.size === options.length
        ? `All ${options.length}` : `${chosen.size} of ${options.length}`;
      all.disabled = chosen.size === options.length;
      go.disabled = chosen.size === 0;
    }
    for (const d of options) {
      const b = document.createElement("button");
      b.type = "button"; b.className = "domain-btn"; b.dataset.name = d.name;
      b.innerHTML = `<div class="dm-name"></div>` + (d.note ? `<div class="dm-note"></div>` : "");
      b.querySelector(".dm-name").textContent = d.label || d.name;
      if (d.note) b.querySelector(".dm-note").textContent = d.note;
      b.addEventListener("click", () => {
        // never let the last one be turned off; a chat with no domain has no data
        if (chosen.has(d.name)) { if (chosen.size > 1) chosen.delete(d.name); }
        else chosen.add(d.name);
        sync();
      });
      grid.appendChild(b);
    }
    all.addEventListener("click", () => { options.forEach((d) => chosen.add(d.name)); sync(); });
    sync();
    back.appendChild(card); document.body.appendChild(back);
    go.onclick = () => { back.remove(); resolve([...chosen]); };
  });
}

async function ensureDomains(chat) {
  // One domain, or a choice already made: nothing to ask.
  const options = chat.domains || [];
  const already = chat.selected_domains || [];
  if (already.length || options.length < 2) return already;
  const picked = await pickDomains(options, ["microbiome"]);
  try {
    const r = await (await fetch(`/api/chats/${chat.id}/domain`, {
      method: "PUT", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ domains: picked }),
    })).json();
    return r.selected_domains || [];
  } catch { return []; }
}

async function renameChat(c) {
  const name = await modal({ title: "Rename chat", input: c.title || "", confirmText: "Rename" });
  if (name === null || !name.trim()) return;
  await fetch(`/api/chats/${c.id}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ title: name.trim() }) });
  await loadChats();
}
async function deleteChat(c) {
  const ok = await modal({ title: "Delete chat", message: `“${c.title || "New chat"}” will be permanently deleted.`, confirmText: "Delete", danger: true });
  if (!ok) return;
  await fetch(`/api/chats/${c.id}`, { method: "DELETE" });
  if (c.id === currentChatId) {
    currentChatId = null;
    await loadChats();
    if (chatList.length) await loadChat(chatList[0].id); else await newChat(false);
  } else { await loadChats(); }
}
async function loadChat(id) {
  currentChatId = id;
  let chat; try { chat = await (await fetch(`/api/chats/${id}`)).json(); } catch { chat = { messages: [] }; }
  chat.id = chat.id || id;
  // The domain gates which studies exist here, so settle it before the study picker
  // reads its list. Returns immediately unless the user genuinely has a choice.
  chatDomains = await ensureDomains(chat);
  studies = chat.available_studies || studies;
  chatStudies = chat.studies || null; updateStudyLabel();
  const msgs = chat.messages || [];
  threadLen = msgs.length;
  if (!msgs.length) { showWelcome(); } else {
    clearTranscript();
    msgs.forEach((m, i) => {
      if (m.role === "user") { settleTrace(); addUserTurn(m.text || "", i); }
      else if (m.role === "thinking") addThinking(m.text || "");
      else if (m.role === "activity") addActivity(m.label, m.detail);
      else if (m.role === "assistant") { settleTrace(); addAssistantMessage(m.html || ""); }
      else if (m.role === "run") addRunStarted(m);
      else if (m.role === "artifact") addArtifactCard(m);
      else if (m.role === "error") addNotice(m.text || "", true);
    });
  }
  // back to the tree: an artifact left open belongs to the chat we just left, and is
  // not readable from this one
  toBottom(true); showTree(); refreshResults(); renderChatList();
}
// A new chat exists only on screen until the user actually sends something. Creating it
// server-side up front left an empty "New chat" in the sidebar every time the app was
// opened, and those are noise, not history.
async function newChat(focus = true) {
  currentChatId = null;
  chatStudies = null;                          // a new chat starts with everything in scope
  threadLen = 0;
  const health = await fetch("/api/health").then((r) => r.json()).catch(() => ({}));
  const options = health.domains || [];
  chatDomains = options.length === 1 ? [options[0].name] : [];
  if (options.length > 1) chatDomains = await pickDomains(options, ["microbiome"]);
  studies = await studiesForDomains(chatDomains);
  updateStudyLabel();
  showWelcome(); await loadChats(); showTree(); refreshResults(); refreshGoing();
  if (focus) input.focus();
}

async function studiesForDomains(domains) {
  try {
    const all = (await (await fetch("/api/health")).json());
    if (!domains || !domains.length) return all.studies || [];
    const r = await fetch("/api/studies?domains=" + enc(domains.join(",")));
    return r.ok ? (await r.json()).studies : (all.studies || []);
  } catch { return studies; }
}

// Called on the first send of an unsaved chat: create it, then fix its domains.
async function ensureChatExists() {
  if (currentChatId) return currentChatId;
  const r = await (await fetch("/api/chats", { method: "POST" })).json();
  currentChatId = r.id;
  if (chatDomains.length) {
    try {
      await fetch(`/api/chats/${currentChatId}/domain`, {
        method: "PUT", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ domains: chatDomains }),
      });
    } catch { /* the turn still runs; scope falls back to everything reachable */ }
  }
  return currentChatId;
}
async function switchChat(id) { closeMenu(); if (id === currentChatId) return; await loadChat(id); }

// ── menu popup (opens on hover of the logo; click also toggles) ──────────────
let menuTimer = null;
function openMenu() {
  clearTimeout(menuTimer);
  const pop = $("#menuPop");
  if (pop.hidden) { pop.hidden = false; $("#mpSearch").value = ""; loadChats(); }
}
function closeMenu() { clearTimeout(menuTimer); $("#menuPop").hidden = true; }
function scheduleMenuClose() {                       // delay covers moving icon -> popup
  clearTimeout(menuTimer);
  menuTimer = setTimeout(() => { if (!$("#menuPop").contains(document.activeElement)) closeMenu(); }, 220);
}
function initMenu() {
  const btn = $("#menuBtn"), pop = $("#menuPop");
  btn.addEventListener("mouseenter", openMenu);
  btn.addEventListener("mouseleave", scheduleMenuClose);
  pop.addEventListener("mouseenter", () => clearTimeout(menuTimer));
  pop.addEventListener("mouseleave", scheduleMenuClose);
  btn.addEventListener("click", () => (pop.hidden ? openMenu() : closeMenu()));   // touch/click
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeMenu(); });
  $("#mpNew").addEventListener("click", () => { closeMenu(); newChat(); });
  $("#mpSearch").addEventListener("input", renderChatList);
  $("#mpLogout").addEventListener("click", async () => { await fetch("/api/logout", { method: "POST" }); window.location.href = "/login"; });
}

// ── study scope + capabilities popups ───────────────────────────────────────
// Two separate controls on purpose: capabilities describes the product and sits by the
// name; study scope changes what this chat can reach and sits by Results.
const POPS = [["#studyBtn", "#studyPop"], ["#infoBtn", "#infoPop"],
              ["#viewBtn", "#viewPop"], ["#verBtn", "#verPop"]];
// Closing skips whatever is not on the page. This runs on every document click,
// so one missing control here would break every click in the app.
function closePops() {
  for (const [b, p] of POPS) {
    const pop = $(p), btn = $(b);
    if (pop) pop.hidden = true;
    if (btn) btn.classList.remove("on");
  }
}
function initPopover(btnSel, popSel, onOpen, surfaceSel) {
  const btn = $(btnSel), pop = $(popSel);
  // A control this deployment has no use for is taken out of the page rather
  // than left there doing nothing, so wiring one is allowed to find nothing.
  // Without this, one absent button throws here and start-up stops, taking the
  // studies list and the chat with it.
  if (!btn || !pop) return;
  btn.addEventListener("click", (e) => {
    e.stopPropagation();
    const wasClosed = pop.hidden;
    closePops();
    if (wasClosed) { pop.hidden = false; btn.classList.add("on"); if (onOpen) onOpen(); }
  });
  // clicks on the surface must not reach the document-level close handler. For the centred
  // capabilities panel the surface is the card, not the element itself, so clicking the
  // dimmed area around it closes.
  $(surfaceSel || popSel).addEventListener("click", (e) => e.stopPropagation());
}
// ── what this can do ────────────────────────────────────────────────────────
// One collapsed group per subject, because the whole of it at once is a wall
// nobody reads. The capability groups are drawn from the catalog rather than
// written here: a domain declares which stage each capability sits at and what
// it needs first, which is a graph, and the graph is the thing worth showing.
// Fetched once, because it only changes when the server does.
let capsShown = false;
async function renderCaps() {
  if (capsShown) return;
  const body = $("#ipBody");
  let d;
  try { d = await (await fetch("/api/capabilities")).json(); }
  catch { body.innerHTML = `<p class="ip-note">This could not be loaded just now.</p>`; return; }
  capsShown = true;

  const box = (it) => `
    <div class="ip-box">
      <div class="ip-box-name">${escapeHtml(it.name)}</div>
      <div class="ip-box-what">${escapeHtml(it.what)}</div>
      ${it.needs && it.needs.length
        ? `<div class="ip-box-needs">After ${it.needs.map(escapeHtml).join(", ")}</div>` : ""}
      ${it.across_samples ? `<div class="ip-box-tag">Across samples</div>` : ""}
    </div>`;

  const flow = (sts) => `<div class="ip-flow">${sts.map((s, i) => `
    ${i ? `<div class="ip-arrow" aria-hidden="true">
             <svg viewBox="0 0 24 24" width="15" height="15"><path d="M9 6l6 6-6 6" fill="none"
               stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
           </div>` : ""}
    <div class="ip-stage">
      <div class="ip-stage-head">${escapeHtml(s.stage)}</div>
      <div class="ip-stage-note">${escapeHtml(s.note)}</div>
      ${s.items.map(box).join("")}
    </div>`).join("")}</div>`;

  const points = (ps) =>
    `<ul class="ip-list">${ps.map((p) => `<li>${escapeHtml(p)}</li>`).join("")}</ul>`;

  const topics = (ts) => `<div class="ip-topics">${ts.map((t) => `
    <div class="ip-topic">
      <h5>${escapeHtml(t.name)}</h5>
      <p>${escapeHtml(t.what)}</p>
      ${t.needs && t.needs.length
        ? `<p class="ip-topic-needs">After ${t.needs.map(escapeHtml).join(", ")}</p>` : ""}
    </div>`).join("")}</div>`;

  // Each group opens on its own. A chevron that turns is the only affordance,
  // so the closed state has to read as a list of subjects rather than as text
  // that has been cut off.
  body.innerHTML = d.groups.map((g) => `
    <details class="ip-group">
      <summary>
        <svg class="ip-chev" viewBox="0 0 24 24" width="13" height="13" aria-hidden="true"><path
          d="M9 6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2.2"
          stroke-linecap="round" stroke-linejoin="round"/></svg>
        <span class="ip-gname">${escapeHtml(g.name)}</span>
        <span class="ip-gsum">${escapeHtml(g.summary || "")}</span>
      </summary>
      <div class="ip-content">
        ${g.points ? points(g.points) : ""}
        ${g.stages ? flow(g.stages) : ""}
        ${g.topics && g.topics.length ? topics(g.topics) : ""}
      </div>
    </details>`).join("");

  // The same opening as every other collapsible in the app, rather than the snap
  // a bare <details> gives.
  for (const group of body.querySelectorAll(".ip-group"))
    animateDetails(group, group.querySelector(".ip-content"));
}

// ── visualizers ─────────────────────────────────────────────────────────────
// The results panel already offers a viewer on the run that produced one, which
// means finding it depends on scrolling back to that run. This is the same thing
// reached by what it is rather than by where it came from. Every viewer is listed
// whether or not it has anything to open, because one that appears only once it
// works cannot be discovered before then; a disabled row says what would make it
// ready. Fetched on open, since a chat produces one at some point during itself.
async function renderViewers() {
  const list = $("#vwList");
  anchorPopTo("#viewPop", "#viewBtn");
  list.innerHTML = `<div class="vw-empty">Looking…</div>`;
  let d;
  try { d = await (await fetch(`/api/viewers?chat_id=${enc(currentChatId || "")}`)).json(); }
  catch { list.innerHTML = `<div class="vw-empty">Could not load these just now.</div>`; return; }
  if (!d.viewers || !d.viewers.length) {
    list.innerHTML = `<div class="vw-empty">Nothing here can be opened this way.</div>`;
    return;
  }
  list.innerHTML = "";
  for (const v of d.viewers) list.appendChild(viewerRow(v));
}

// Which samples are chosen for each viewer, kept for as long as the page is
// open. Reopening the menu to check something should not quietly undo a choice
// made a moment ago. Absent means all of them, which is what a first look means.
const viewerPick = {};

function viewerRow(v) {
  const row = el("vw-row");
  const chosen = viewerPick[v.viewer];
  const choices = v.choices || [];
  const picked = () => (viewerPick[v.viewer] || choices);

  const open = document.createElement("button");
  open.className = "vw-item"; open.type = "button";
  if (!v.ready) open.disabled = true;
  const name = document.createElement("span"); name.className = "vw-name";
  name.textContent = v.label;
  const why = document.createElement("span"); why.className = "vw-why";
  open.append(name, why);
  const say = () => {
    if (!v.ready) { why.textContent = v.why || ""; return; }
    const n = picked().length;
    why.textContent = choices.length > 1 && n < choices.length
      ? `Opens ${n} of ${choices.length} samples`
      : `${v.samples} sample${v.samples === 1 ? "" : "s"} prepared in this chat`;
  };
  say();
  open.addEventListener("click", () => {
    if (!v.ready) return;
    closePops();
    // Only when it is a narrowing. Naming every sample would say the same thing
    // as naming none, in a longer URL.
    const n = picked();
    openViewer(n.length && n.length < choices.length
      ? `${v.run}~${n.join(",")}` : v.run);
  });
  row.appendChild(open);

  // Nothing to choose between when there is one sample, and nothing to choose
  // at all when the viewer has nothing to open. Either way the control would be
  // a second thing to read that could not change the outcome.
  if (!v.ready || choices.length < 2) return row;

  const pick = document.createElement("button");
  pick.className = "vw-pick"; pick.type = "button";
  pick.setAttribute("aria-expanded", "false");
  const chev = document.createElement("span");
  chev.className = "vw-pick-chev"; chev.innerHTML = ICON.chev;
  const pickName = document.createElement("span");
  pickName.className = "vw-pick-name"; pickName.textContent = "Choose Samples";
  const count = document.createElement("span");
  count.className = "vw-pick-count";
  pick.append(chev, pickName, count);
  const tally = () => {
    const n = picked().length;
    count.textContent = n === choices.length ? `all ${n}` : `${n} of ${choices.length}`;
  };
  tally();

  const box = el("vw-samples");
  box.hidden = true;
  const hint = el("vw-hint");
  hint.textContent = "Tick the samples to open. A viewer loads every one you give it, "
                   + "so fewer open faster.";
  const bulk = el("vw-bulk");
  const checks = el("vw-checks");
  const boxes = [];
  const changed = () => {
    const on = boxes.filter((c) => c.checked).map((c) => c.value);
    // All of them is the same as no choice at all, and storing it as a choice
    // would freeze the list as it is now: a sample prepared later would arrive
    // unticked, for no reason the person could see.
    if (on.length === choices.length) delete viewerPick[v.viewer];
    else viewerPick[v.viewer] = on;
    tally(); say();
  };
  for (const s of choices) {
    const label = document.createElement("label"); label.className = "vw-check";
    const cb = document.createElement("input");
    cb.type = "checkbox"; cb.value = s;
    cb.checked = !chosen || chosen.includes(s);
    cb.addEventListener("change", changed);
    const text = document.createElement("span"); text.textContent = s;
    label.append(cb, text); checks.appendChild(label); boxes.push(cb);
  }
  for (const [text, want] of [["All", true], ["None", false]]) {
    const b = document.createElement("button");
    b.type = "button"; b.className = "vw-bulk-btn"; b.textContent = text;
    b.addEventListener("click", () => {
      // Never all-off. An empty selection opens a viewer with nothing in it,
      // which reads as broken rather than as an empty choice, so None leaves
      // the first one on as somewhere to start.
      boxes.forEach((c, i) => { c.checked = want || i === 0; });
      changed();
    });
    bulk.appendChild(b);
  }
  box.append(hint, bulk, checks);
  pick.addEventListener("click", () => {
    box.hidden = !box.hidden;
    pick.setAttribute("aria-expanded", String(!box.hidden));
    pick.classList.toggle("open", !box.hidden);
  });
  row.append(pick, box);
  return row;
}

// ── versions ────────────────────────────────────────────────────────────────
// A grid of what exists: samples down, capabilities across, one cell per pair.
// User-scoped rather than chat-scoped, unlike the results panel — this answers
// "what do I have", which is a question about the data and not about the
// conversation, and it is where work done in another chat is found.
//
// A cell shows an ordinal and nothing else. The version list is one click away
// because that is where the reason to choose lives; putting a timestamp on the
// cell would spend the widest column on the least useful fact.
let verData = null;

function capTitle(name) {
  return name.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

async function renderVersions() {
  const body = $("#verBody");
  body.innerHTML = `<div class="vw-empty">Looking…</div>`;
  try { verData = await (await fetch(`/api/versions?chat_id=${enc(currentChatId || "")}`)).json(); }
  catch { body.innerHTML = `<div class="vw-empty">These could not be loaded just now.</div>`; return; }
  drawVersions();
}

async function pickVersion(picked) {
  try {
    verData = await (await fetch("/api/versions", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: currentChatId, picked }),
    })).json();
  } catch { return; }
  drawVersions();
}

function drawVersions() {
  const body = $("#verBody"), foot = $("#verFoot");
  const cols = (verData && verData.columns) || [];
  const rows = (verData && verData.rows) || [];
  if (!cols.length) {
    body.innerHTML = '<div class="vw-empty">Nothing has finished yet. ' +
      'Once an analysis lands it appears here with its versions.</div>';
    foot.textContent = "";
    return;
  }
  body.innerHTML = "";
  const table = document.createElement("table");
  table.className = "ver-grid";

  const head = document.createElement("tr");
  head.appendChild(document.createElement("th"));
  for (const c of cols) {
    const th = document.createElement("th");
    const name = document.createElement("div");
    name.className = "ver-col"; name.textContent = capTitle(c);
    // Setting one capability across every sample at once. The common move by
    // far: a parameter is reconsidered for the study, not for one sample.
    const all = document.createElement("button");
    all.className = "ver-all"; all.type = "button"; all.textContent = "all newest";
    all.title = `Point every sample's ${capTitle(c)} at its newest version`;
    all.addEventListener("click", () => {
      const picked = {};
      for (const r of rows) if (r.cells[c] && r.cells[c].versions.length) picked[`${r.subject}::${c}`] = null;
      pickVersion(picked);
    });
    th.append(name, all);
    head.appendChild(th);
  }
  table.appendChild(head);

  for (const r of rows) {
    const tr = document.createElement("tr");
    const label = document.createElement("th");
    label.className = "ver-row"; label.textContent = r.label;
    tr.appendChild(label);
    for (const c of cols) tr.appendChild(versionCell(r.subject, c, r.cells[c]));
    table.appendChild(tr);
  }
  body.appendChild(table);

  for (const a of (verData.across || [])) {
    const note = el("ver-section");
    note.textContent = "Across samples";
    body.appendChild(note);
    const t2 = document.createElement("table");
    t2.className = "ver-grid";
    const tr = document.createElement("tr");
    const label = document.createElement("th");
    label.className = "ver-row"; label.textContent = a.label;
    tr.appendChild(label);
    for (const c of Object.keys(a.cells)) tr.appendChild(versionCell(a.subject, c, a.cells[c]));
    t2.appendChild(tr);
    body.appendChild(t2);
  }

  const filled = rows.reduce((n, r) => n + cols.filter((c) => r.cells[c] && r.cells[c].versions.length).length, 0);
  const choices = rows.reduce((n, r) => n + cols.filter((c) => r.cells[c] && r.cells[c].versions.length > 1).length, 0);
  foot.textContent = `${filled} result${filled === 1 ? "" : "s"}, ` +
    `${choices === 0 ? "none with more than one version" :
       choices + " with more than one version"}.`;
}

function versionCell(subject, capability, cell) {
  const td = document.createElement("td");
  td.className = "ver-cell";
  if (!cell || !cell.versions.length) { td.textContent = "—"; td.classList.add("ver-none"); return td; }
  if (cell.cleared) {
    const b = document.createElement("button");
    b.className = "ver-pill ver-cleared"; b.type = "button"; b.textContent = "empty";
    b.title = "Cleared on purpose. Asking for this again runs it fresh.";
    b.addEventListener("click", () => openVersionMenu(td, subject, capability, cell));
    td.appendChild(b);
    return td;
  }
  const active = cell.versions.find((v) => v.identity === cell.active) || cell.versions[0];
  const b = document.createElement("button");
  b.className = "ver-pill" + (active.identity === cell.newest ? "" : " ver-old");
  b.type = "button";
  b.textContent = "v" + active.ordinal + (cell.versions.length > 1 ? " ▾" : "");
  b.title = [capTitle(capability), active.label, active.identity === cell.newest ? "" : "not the newest",
             active.runs > 1 ? `${active.runs} runs produced this same result` : ""]
    .filter(Boolean).join(" · ");
  b.addEventListener("click", () => openVersionMenu(td, subject, capability, cell));
  td.appendChild(b);
  return td;
}

function openVersionMenu(td, subject, capability, cell) {
  closeVersionMenu();
  const menu = el("ver-menu");
  const head = el("ver-menu-head");
  head.textContent = `${subject || "across samples"} · ${capTitle(capability)}`;
  menu.appendChild(head);
  for (const v of cell.versions) {
    const b = document.createElement("button");
    b.className = "ver-opt" + (v.identity === cell.active ? " on" : "");
    b.type = "button";
    const n = document.createElement("span"); n.className = "ver-opt-n"; n.textContent = "v" + v.ordinal;
    const t = document.createElement("span"); t.className = "ver-opt-t";
    t.textContent = v.label || new Date(v.at).toLocaleString();
    const w = document.createElement("span"); w.className = "ver-opt-w";
    w.textContent = v.identity === cell.newest ? "newest" : new Date(v.at).toLocaleDateString();
    b.append(n, t, w);
    b.addEventListener("click", () => { closeVersionMenu(); pickVersion({ [`${subject}::${capability}`]: v.identity }); });
    menu.appendChild(b);
  }
  const clear = document.createElement("button");
  clear.className = "ver-opt ver-clear" + (cell.cleared ? " on" : "");
  clear.type = "button";
  clear.textContent = "Clear — run this fresh next time";
  clear.title = "Nothing is selected for this cell. Asking for it again computes it "
              + "again instead of handing back what is already there.";
  clear.addEventListener("click", () => { closeVersionMenu(); pickVersion({ [`${subject}::${capability}`]: "" }); });
  menu.appendChild(clear);
  td.appendChild(menu);
  setTimeout(() => document.addEventListener("click", closeVersionMenu, { once: true }), 0);
}

function closeVersionMenu() {
  for (const m of document.querySelectorAll(".ver-menu")) m.remove();
}

function initPops() {
  initPopover("#studyBtn", "#studyPop", () => { anchorStudyPop(); renderStudyPop(); });
  initPopover("#infoBtn", "#infoPop", renderCaps, ".info-card");
  initPopover("#verBtn", "#verPop", renderVersions, ".ver-card");
  initPopover("#viewBtn", "#viewPop", renderViewers);
  $("#ipClose").addEventListener("click", closePops);
  $("#verClose")?.addEventListener("click", closePops);
  document.addEventListener("click", closePops);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closePops(); });
  $("#spAll").addEventListener("click", () => applyStudies(studies.slice()));
  window.addEventListener("resize", anchorStudyPop);
  // The button rides on the chat column, which resizes whenever the results panel opens,
  // closes, or is dragged. Watching the column catches all of that, including the frames
  // in the middle of the open/close transition, which a single measurement would miss.
  const col = $(".main-col");
  const reanchor = () => { anchorStudyPop(); anchorPopTo("#viewPop", "#viewBtn"); };
  window.addEventListener("resize", reanchor);
  if (window.ResizeObserver && col) new ResizeObserver(reanchor).observe(col);
}
// The popup is fixed-position but belongs to its button, and the button moves whenever the
// results panel opens or is dragged. Measure the button instead of assuming the viewport
// edge, so the two stay lined up in every layout.
function anchorStudyPop() { anchorPopTo("#studyPop", "#studyBtn"); }
function anchorPopTo(popSel, btnSel) {
  const pop = $(popSel), btn = $(btnSel);
  if (!pop || !btn || pop.hidden) return;
  const r = btn.getBoundingClientRect();
  pop.style.right = Math.max(12, Math.round(window.innerWidth - r.right)) + "px";
  pop.style.top = Math.round(r.bottom + 8) + "px";
}
// <details> snaps open. Animate the height ourselves: quick enough not to be in the way,
// slow enough not to read as a jump. Skipped entirely when the user asks for less motion.
// One implementation for every collapsible in the app — the capabilities panel and the
// per-turn reasoning and step blocks all open at the same speed, because a second copy of
// this would drift from the first the moment either was touched.
function animateDetails(group, content) {
  group.querySelector("summary").addEventListener("click", (e) => {
    e.preventDefault();
    if (group.dataset.busy) return;
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const opening = !group.hasAttribute("open");
    // Toggle outright when motion is unwanted, or when the tab is hidden: a hidden tab's
    // animation clock is frozen, so animating there would never advance.
    if (still || document.hidden) { group.toggleAttribute("open"); return; }
    group.dataset.busy = "1";
    if (opening) group.setAttribute("open", "");
    const frames = [{ height: "0px", opacity: 0 },
                    { height: content.scrollHeight + "px", opacity: 1 }];
    const anim = content.animate(opening ? frames : frames.slice().reverse(),
      { duration: 190, easing: "cubic-bezier(.22,.61,.36,1)" });
    // Settle on whichever lands first. The timeout is what stops a section being stuck
    // half-toggled: an animation in a throttled or backgrounded tab can run forever, and
    // the close only takes effect when it ends.
    let settled = false;
    const settle = () => {
      if (settled) return;
      settled = true;
      if (!opening) group.removeAttribute("open");
      delete group.dataset.busy;
    };
    anim.onfinish = settle;
    anim.oncancel = settle;
    setTimeout(settle, 400);
  });
}

function scopedStudies() {
  // a stored selection is filtered against current access, so a study the user lost
  // access to can never come back through an old chat
  if (!chatStudies) return studies.slice();
  const keep = studies.filter((s) => chatStudies.includes(s));
  return keep.length ? keep : studies.slice();
}
function updateStudyLabel() {
  const sel = scopedStudies(), label = $("#studyLabel");
  if (!studies.length) label.textContent = "Studies";
  else if (sel.length === studies.length) label.textContent = studies.length === 1 ? studies[0] : "All studies";
  else if (sel.length === 1) label.textContent = sel[0];
  else label.textContent = `${sel.length} studies`;
}
function renderStudyPop() {
  const box = $("#spList"); box.innerHTML = "";
  if (!studies.length) { box.innerHTML = '<div class="mp-empty">No studies available.</div>'; }
  const sel = new Set(scopedStudies());
  for (const name of studies) {
    const b = document.createElement("button"); b.type = "button";
    b.className = "sp-item" + (sel.has(name) ? " on" : "");
    b.innerHTML = `<span class="sp-box">${ICON.check}</span><span class="sp-name"></span>`;
    b.querySelector(".sp-name").textContent = name;
    b.addEventListener("click", () => toggleStudy(name));
    box.appendChild(b);
  }
  const all = sel.size === studies.length;
  $("#spAll").disabled = all;
  $("#spCount").textContent = all ? `All ${studies.length}` : `${sel.size} of ${studies.length}`;
}
function toggleStudy(name) {
  const sel = new Set(scopedStudies());
  if (sel.has(name)) { if (sel.size === 1) return; sel.delete(name); }   // never empty
  else sel.add(name);
  applyStudies(studies.filter((s) => sel.has(s)));
}
async function applyStudies(list) {
  const all = list.length === studies.length;
  chatStudies = all ? null : list;
  renderStudyPop(); updateStudyLabel();
  if (!thread.querySelector(".turn")) showWelcome();     // refresh the suggestion chips
  if (!currentChatId) return;
  // an empty list means "all" server-side, which is also what a fresh chat starts as
  try {
    await fetch(`/api/chats/${currentChatId}/studies`, {
      method: "PUT", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ studies: all ? [] : list }),
    });
  } catch { /* the next turn re-reads the stored selection; a failed save just keeps the old one */ }
}

// ── results panel ──────────────────────────────────────────────────────────
const tree = $("#tree"), viewer = $("#viewer");
const expanded = new Set();
let resultsData = { topics: [] };
const ICON = {
  chev: '<svg class="chev" viewBox="0 0 24 24" width="14" height="14"><path d="M9 6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  folder: '<svg viewBox="0 0 24 24" width="16" height="16"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="none" stroke="currentColor" stroke-width="1.7"/></svg>',
  table: '<svg viewBox="0 0 24 24" width="15" height="15"><path d="M4 5h16v14H4zM4 10h16M4 15h16M10 5v14" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>',
  image: '<svg viewBox="0 0 24 24" width="15" height="15"><path d="M4 5h16v14H4z" fill="none" stroke="currentColor" stroke-width="1.6"/><circle cx="9" cy="10" r="1.6" fill="currentColor"/><path d="M5 18l5-5 4 4 2-2 3 3" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>',
  doc: '<svg viewBox="0 0 24 24" width="15" height="15"><path d="M6 3h8l4 4v14H6z" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M13 3v5h5M9 13h6M9 16h6" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>',
  stop: '<svg viewBox="0 0 24 24" width="12" height="12"><rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor"/></svg>',
  check: '<svg viewBox="0 0 24 24" width="11" height="11"><path d="M5 12.5l4.5 4.5L19 7" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
};
function iconForFmt(it) {
  const k = (it.kind || "").toLowerCase();
  if (k === "image") return ICON.image;
  if (k === "table") return ICON.table;
  return ICON.doc;
}
async function refreshResults() {
  if (!currentChatId) { resultsData = { topics: [] }; renderTree(); return; }
  try { resultsData = await (await fetch(`/api/results?chat_id=${currentChatId}`)).json(); }
  catch { resultsData = { topics: [] }; }
  renderTree();
}

// ── work still going ─────────────────────────────────────────────────────────
// Polled from the server, which asks the machines. Nothing here asks the model:
// whether a job has finished is a fact about a machine, and spending a turn of
// the conversation to look it up would cost the user tokens to learn something
// already known. The poll is slow on purpose — this is a progress indicator,
// not a stopwatch — and stops entirely while nothing is running.
let goingTimer = null;
let goingCount = 0;
async function refreshGoing() {
  const box = $("#going");
  let running = [];
  try { running = (await (await fetch("/api/runs")).json()).running || []; } catch { running = []; }
  box.innerHTML = "";
  box.hidden = !running.length;
  for (const r of running) {
    const row = el("go-row");
    row.innerHTML = `<span class="go-dot"></span><span class="go-name"></span>` +
                    `<span class="go-time"></span><button class="go-stop" title="Stop">${ICON.stop || "&times;"}</button>`;
    row.querySelector(".go-name").textContent = r.label || "Analysis";
    row.querySelector(".go-time").textContent = r.elapsed || "";
    row.title = `Running on ${r.site}`;
    row.querySelector(".go-stop").addEventListener("click", async () => {
      row.querySelector(".go-time").textContent = "stopping";
      try { await fetch(`/api/runs/${enc(r.run)}/cancel`, { method: "POST" }); } catch {}
      refreshGoing();
    });
    box.appendChild(row);
  }
  // Something finished since the last look, so what it produced is now in the
  // panel. Refreshed here rather than made the user's job.
  if (running.length < goingCount) refreshResults();
  goingCount = running.length;
  clearTimeout(goingTimer);
  goingTimer = setTimeout(refreshGoing, running.length ? 4000 : 20000);
}
// One run, as a folder of the things it produced. Built on its own so it can be
// dropped straight into the panel or inside a sample, without the two cases
// being two copies of the same code.
function runFolder(t) {
  const folder = document.createElement("div");
  folder.className = "folder" + (expanded.has(t.key) ? " open" : "");
  const row = document.createElement("button"); row.className = "folder-row";
  row.innerHTML = `${ICON.chev}<span class="ico">${ICON.folder}</span><span class="name">${escapeHtml(t.label)}</span><span class="count">${t.items.length}</span>`;
  // Where it ran and when, on hover rather than on screen. A row per run is
  // already the answer to "what did I do"; the rest is for the moment someone
  // asks whether they can rely on it, and that moment is rare enough that it
  // should not cost every row a second line.
  const when = t.finished ? new Date(t.finished).toLocaleString() : "";
  row.title = [t.label, when && `finished ${when}`, t.site && `ran on ${t.site}`,
               t.reproducible === false && "not reproducible",
               t.verified === false && "the pinned code had changed when this ran"]
    .filter(Boolean).join(" · ");
  // Said out loud only when it is not fine. Silence is the normal case.
  if (t.verified === false || t.reproducible === false) {
    const flag = el("folder-flag");
    flag.textContent = "!";
    flag.title = t.verified === false
      ? "The pinned code had changed when this ran, so it may not match the recorded version."
      : "This run is not reproducible: the same inputs may not give the same answer.";
    row.appendChild(flag);
  }
  row.addEventListener("click", () => { const open = folder.classList.toggle("open"); if (open) expanded.add(t.key); else expanded.delete(t.key); });
  const items = document.createElement("div"); items.className = "items";
  // Something to open in a viewer, when the domain said one can open it.
  if (t.viewer) {
    const v = document.createElement("button"); v.className = "item item-view";
    v.innerHTML = `<span class="ico">${ICON.image}</span><span class="name">Open in viewer</span>`;
    v.addEventListener("click", () => openViewer(`${t.viewer}/${t.key}`));
    items.appendChild(v);
  }
  for (const it of t.items) {
    const b = document.createElement("button"); b.className = "item";
    b.innerHTML = `<span class="ico">${iconForFmt(it)}</span><span class="name">${escapeHtml(formatName(it.name))}</span>`;
    b.title = it.description || formatName(it.name);
    b.addEventListener("click", () => openItem(it.ref, it.name));
    items.appendChild(b);
  }
  // Named, not hidden. An analysis that produced something which cannot leave
  // the machine it ran on has still produced it, and a user who is not told
  // that concludes it produced nothing.
  for (const name of (t.stays || [])) {
    const s = document.createElement("div"); s.className = "item item-stays";
    s.innerHTML = `<span class="ico">${ICON.doc}</span><span class="name"></span>`;
    s.querySelector(".name").textContent = formatName(name);
    s.title = "This stays on the machine it was computed on and cannot be downloaded.";
    items.appendChild(s);
  }
  folder.appendChild(row); folder.appendChild(items);
  return folder;
}

function renderTree() {
  tree.innerHTML = "";
  const topics = resultsData.topics || [];
  if (!topics.length) {
    tree.innerHTML = '<div class="tree-empty"><div class="te-title">Nothing here yet!</div>' +
      '<div class="te-sub">Ask for an analysis, and the results you want to keep (tables, figures, summaries) will appear here.</div></div>';
    return;
  }
  // Nearly every capability works on one sample, so a study's worth of work is
  // a flat list of sixty rows in which finding one means reading all of them.
  // Filed under the sample instead, it is nineteen rows and the one being worked
  // on is the one that opens.
  //
  // Only when there is more than one sample to tell apart. A single sample
  // grouped under itself is a level of nesting that hides the results and
  // distinguishes nothing.
  const named = topics.filter((t) => t.sample);
  const order = [...new Set(named.map((t) => t.sample))];   // newest run first
  if (order.length < 2) { for (const t of topics) tree.appendChild(runFolder(t)); return; }

  // A run about no single sample — a cohort analysis, submitted code, a chart —
  // stays at the top level. Better an honest mixture of levels than a group
  // named for a thing these runs have in common only by not being it.
  for (const t of topics) if (!t.sample) tree.appendChild(runFolder(t));

  for (const name of order) {
    const mine = named.filter((t) => t.sample === name);
    const key = "sample:" + name;
    // Open the sample holding the newest run, closed for the rest. Folding away
    // eighteen samples is the point; folding away the one just worked on is not.
    if (!expanded.size && name === named[0].sample) expanded.add(key);
    const group = document.createElement("div");
    group.className = "folder group" + (expanded.has(key) ? " open" : "");
    const row = document.createElement("button"); row.className = "folder-row";
    row.innerHTML = `${ICON.chev}<span class="ico">${ICON.folder}</span>` +
                    `<span class="name"></span><span class="count">${mine.length}</span>`;
    row.querySelector(".name").textContent = name;
    row.title = `Sample ${name} · ${mine.length} ${mine.length === 1 ? "result" : "results"}`;
    row.addEventListener("click", () => {
      const open = group.classList.toggle("open");
      if (open) expanded.add(key); else expanded.delete(key);
    });
    const inner = document.createElement("div"); inner.className = "items";
    for (const t of mine) inner.appendChild(runFolder(t));
    group.appendChild(row); group.appendChild(inner); tree.appendChild(group);
  }
}
// `ref` locates the artifact (its workspace); the folder it sits in is a subject
// heading and is not where it lives, so the item carries its own.
// The interactive viewer, over the bundle one run produced. Full screen because
// it is a whole application and there is nothing useful to see beside it, and an
// overlay rather than a new tab so leaving it puts the conversation back exactly
// where it was. The frame is served from this origin behind the same session, so
// nothing about the data leaves the server that already holds it.
function openViewer(where) {
  const back = el("viewer-overlay");
  const frame = document.createElement("iframe");
  frame.className = "vo-frame";
  // `<viewer>/<key>`, already assembled by whoever knew both: the panel knows
  // which viewer a run declared, and the Visualizers menu is per viewer.
  frame.src = `/viewer/${where.split("/").map(enc).join("/")}/`;
  const close = document.createElement("button");
  close.className = "vo-close"; close.textContent = "Close";
  const leave = () => { back.remove(); document.removeEventListener("keydown", onKey); };
  const onKey = (e) => { if (e.key === "Escape") leave(); };
  close.addEventListener("click", leave);
  document.addEventListener("keydown", onKey);
  back.appendChild(frame); back.appendChild(close);
  document.body.appendChild(back);
}

async function openItem(ref, name) {
  let item; try { item = await (await fetch(`/api/results/item?chat_id=${currentChatId}&ref=${enc(ref)}&name=${enc(name)}`)).json(); } catch { return; }
  viewer.innerHTML = "";
  const vhead = el("v-head");
  const back = document.createElement("button"); back.className = "v-back";
  back.innerHTML = '<svg viewBox="0 0 24 24" width="17" height="17"><path d="M15 18l-6-6 6-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg><span>Results</span>';
  back.addEventListener("click", showTree);
  const dl = document.createElement("a"); dl.className = "v-dl"; dl.href = `/api/results/file?chat_id=${currentChatId}&ref=${enc(ref)}&name=${enc(name)}`;
  dl.setAttribute("download", `${name}.${item.format || "bin"}`);
  dl.innerHTML = '<svg viewBox="0 0 24 24" width="15" height="15"><path d="M12 4v11m0 0l-4-4m4 4l4-4M5 20h14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg><span>Download</span>';
  vhead.appendChild(back); vhead.appendChild(dl); viewer.appendChild(vhead);

  const head = document.createElement("div");
  head.innerHTML = `<div class="v-name">${escapeHtml(formatName(item.name || name))}</div>`;
  viewer.appendChild(head);
  // an unreadable artifact used to fall through to the "no preview" branch, which reads
  // as a format problem rather than a missing file
  if (!item || item.error) {
    dl.remove();
    const n = el("v-note"); n.textContent = "This result could not be opened. It may have been removed.";
    viewer.appendChild(n); tree.hidden = true; viewer.hidden = false; return;
  }
  if (item.description_html) {
    const wrap = el("v-desc-wrap collapsed"); const d = el("v-desc"); d.innerHTML = item.description_html;
    wrap.appendChild(d); viewer.appendChild(wrap);
    const more = document.createElement("button"); more.className = "v-more"; more.textContent = "Show more"; viewer.appendChild(more);
    requestAnimationFrame(() => { if (d.scrollHeight <= wrap.clientHeight + 4) { more.remove(); wrap.classList.remove("collapsed"); } });
    more.addEventListener("click", () => { more.textContent = wrap.classList.toggle("collapsed") ? "Show more" : "Show less"; });
  }
  if (item.parameters) viewer.appendChild(buildParams(item.parameters));
  if (item.view === "image") { const img = document.createElement("img"); img.src = item.src; img.alt = item.name || name; viewer.appendChild(img); }
  else if (item.view === "table") { viewer.appendChild(buildTable(item)); }
  else if (item.view === "json") { viewer.appendChild(buildJson(item.data)); }
  // written results (summaries, notes) arrive as markdown rendered server-side; the raw
  // text is the fallback if it was not markdown-shaped
  else if (item.view === "text") {
    if (item.html) { const d = el("v-md", item.html); viewer.appendChild(d); }
    else { const d = el("v-text"); d.textContent = item.text || ""; viewer.appendChild(d); }
  }
  else { const n = el("v-note"); n.textContent = "No inline preview for this file type. Use Download above."; viewer.appendChild(n); }
  tree.hidden = true; viewer.hidden = false;
}
// The settings an analysis ran with. Defaults are shown, and shown as defaults: they are
// the ones nobody typed and nobody can otherwise see, and they are exactly what a reader
// checking a result needs — that the test was lme, that the rank was species, that the
// correction was BH — none of which appear anywhere else.
function buildParams(groups) {
  const box = el("v-params");
  const d = document.createElement("details");
  d.className = "vp";
  const n = groups.reduce((t, g) => t + g.values.length, 0);
  const what = groups.length === 1 ? groups[0].function : `${groups.length} analyses`;
  d.innerHTML = `<summary><span class="vp-label">Settings used · ${escapeHtml(what)}</span></summary>`;
  const body = el("vp-body");
  for (const g of groups) {
    if (groups.length > 1) { const h = el("vp-fn"); h.textContent = g.function; body.appendChild(h); }
    const tbl = document.createElement("table"); tbl.className = "vp-table";
    for (const v of g.values) {
      const tr = document.createElement("tr");
      if (v.defaulted) tr.className = "is-default";
      const k = document.createElement("th"); k.textContent = v.name;
      const val = document.createElement("td");
      val.textContent = v.value === null || v.value === undefined ? "none"
        : (typeof v.value === "object" ? JSON.stringify(v.value) : String(v.value));
      const tag = document.createElement("td"); tag.className = "vp-tag";
      tag.textContent = v.defaulted ? "default" : "";
      tr.appendChild(k); tr.appendChild(val); tr.appendChild(tag);
      tbl.appendChild(tr);
    }
    body.appendChild(tbl);
  }
  d.appendChild(body);
  animateDetails(d, body);
  box.appendChild(d);
  return box;
}

// Numbers come back at full float precision, which makes a table of p-values or CLR
// values unreadable. Show something a human can scan, without lying about magnitude:
// very small and very large values keep exponent form, the rest round.
function fmtCell(v) {
  if (v === null || v === undefined) return "";
  if (typeof v !== "number" || !Number.isFinite(v) || Number.isInteger(v)) return String(v);
  const a = Math.abs(v);
  if (a < 1e-4 || a >= 1e7) return v.toExponential(3);
  return String(Math.round(v * 1e6) / 1e6);
}
function buildTable(item) {
  const wrap = el("v-tablewrap"); const tbl = document.createElement("table"); tbl.className = "v-table";
  const thead = document.createElement("thead"); const htr = document.createElement("tr");
  for (const c of item.columns) { const th = document.createElement("th"); th.textContent = c; htr.appendChild(th); }
  thead.appendChild(htr); tbl.appendChild(thead);
  const tb = document.createElement("tbody");
  for (const row of item.rows) { const tr = document.createElement("tr"); for (const cell of row) { const td = document.createElement("td"); td.textContent = fmtCell(cell); tr.appendChild(td); } tb.appendChild(tr); }
  tbl.appendChild(tb); wrap.appendChild(tbl);
  const c = document.createElement("div"); c.appendChild(wrap);
  if (item.truncated) { const n = el("v-note"); n.textContent = `Showing ${item.rows.length} of ${item.shape[0]} rows.`; c.appendChild(n); }
  return c;
}
// A curated result is a JSON object whose interesting part is almost always a list of
// records — the genes, the regions, the comparisons. Showing that as raw JSON hands the
// user braces to read instead of a result. So: scalars become a compact summary, record
// lists become real tables, and anything that fits neither stays as raw JSON rather than
// being coerced into a shape it does not have.
// Only a list of *flat* records becomes a table. A record holding a nested list (a
// differential result carries its per-feature rows inside each comparison) would put an
// array in a cell, which reads worse than the JSON it replaced, so those stay as JSON.
function isRecordList(v) {
  return Array.isArray(v) && v.length > 0
    && v.every((r) => r && typeof r === "object" && !Array.isArray(r)
      && Object.values(r).every((c) => c === null || typeof c !== "object"));
}
function columnsOf(rows) {
  const cols = [];
  for (const r of rows) for (const k of Object.keys(r)) if (!cols.includes(k)) cols.push(k);
  return cols;
}
function prettyKey(k) { return String(k).replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase()); }

function buildJson(data) {
  const box = el("v-jsonview");
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    if (isRecordList(data)) { box.appendChild(recordTable(data)); return box; }
    const p = document.createElement("pre"); p.className = "v-json";
    p.textContent = JSON.stringify(data, null, 2); box.appendChild(p); return box;
  }
  const scalars = [], tables = [], rest = {};
  for (const [k, v] of Object.entries(data)) {
    if (v === null || ["string", "number", "boolean"].includes(typeof v)) scalars.push([k, v]);
    else if (isRecordList(v)) tables.push([k, v]);
    else if (Array.isArray(v) && v.every((x) => x === null || typeof x !== "object")) {
      scalars.push([k, v.length ? v.join(", ") : "(none)"]);
    } else rest[k] = v;
  }
  if (scalars.length) {
    const dl = el("v-facts");
    for (const [k, v] of scalars) {
      const row = el("v-fact");
      const a = el("v-fact-k"); a.textContent = prettyKey(k);
      const b = el("v-fact-v"); b.textContent = v === null ? "" : (typeof v === "number" ? fmtCell(v) : String(v));
      row.append(a, b); dl.appendChild(row);
    }
    box.appendChild(dl);
  }
  for (const [k, rows] of tables) {
    const h = el("v-section"); h.textContent = `${prettyKey(k)} (${rows.length})`;
    box.append(h, recordTable(rows));
  }
  if (Object.keys(rest).length) {
    const p = document.createElement("pre"); p.className = "v-json";
    p.textContent = JSON.stringify(rest, null, 2); box.appendChild(p);
  }
  return box;
}
function recordTable(rows) {
  const cols = columnsOf(rows);
  return buildTable({
    columns: cols,
    rows: rows.map((r) => cols.map((c) => (r[c] === undefined ? null : r[c]))),
    shape: [rows.length, cols.length],
    truncated: false,
  });
}

// The server decides how many records a turn wrote, so the count is read back rather
// than guessed at; guessing would put a later edit at the wrong position.
async function syncThreadLen() {
  if (!currentChatId) return;
  try {
    const c = await (await fetch(`/api/chats/${currentChatId}`)).json();
    threadLen = (c.messages || []).length;
  } catch { /* the next load corrects it */ }
}

document.addEventListener("visibilitychange", () => { if (livePending) scheduleDrain(); });

function showTree() { viewer.hidden = true; tree.hidden = false; }

// ── panel open/resize ────────────────────────────────────────────────────────
function setPanelOpen(open) { document.body.classList.toggle("panel-open", open); anchorStudyPop(); }
// The results panel is not capped in its own right. What is reserved is the *chat*: the
// panel may grow until the conversation column would drop below CHAT_MIN. On a wide screen
// that lets a table take most of the window, which is what a wide table is for.
//
// The width the user asked for is kept separately from the width actually applied, and only
// the applied one is clamped to the current window. That is the whole fix for shrinking a
// maximized window: the panel narrows to fit, the chat keeps its minimum, and widening the
// window restores the size that was chosen. Storing only the clamped value forgets the
// request the first time it does not fit, which is what left the layout collapsed against
// the edge and needed a drag to the far side to recover.
const CHAT_MIN = 520;
const PANEL_MIN = 320;
// Half the window by default: the panel holds tables and figures, and an even split is
// the honest starting point for "read the result next to the conversation".
let desiredPanelW = Math.round(window.innerWidth / 2);

function panelMax() { return Math.max(PANEL_MIN, window.innerWidth - CHAT_MIN); }

function applyPanelWidth() {
  const w = Math.max(PANEL_MIN, Math.min(desiredPanelW, panelMax()));
  document.documentElement.style.setProperty("--panel-w", w + "px");
  anchorStudyPop();
  return w;
}

function setPanelWidth(px) {
  // remember the request itself, bounded only by something physically sensible
  desiredPanelW = Math.max(PANEL_MIN, Math.min(px, Math.max(window.innerWidth, 620)));
  return applyPanelWidth();
}

function initResize() {
  const handle = $("#resize");
  const saved = parseInt(localStorage.getItem("panelW") || "", 10);
  if (saved) { setPanelWidth(saved); }
  else {
    // no stored preference: stay at half the window as it resizes, until the user drags
    desiredPanelW = Math.round(window.innerWidth / 2);
    window.addEventListener("resize", () => {
      if (!localStorage.getItem("panelW")) desiredPanelW = Math.round(window.innerWidth / 2);
    });
    applyPanelWidth();
  }
  // Re-fit on every window change without touching the stored preference, so maximizing
  // and restoring is reversible rather than destructive.
  window.addEventListener("resize", applyPanelWidth);
  let dragging = false;
  handle.addEventListener("mousedown", (e) => { dragging = true; document.body.classList.add("resizing"); e.preventDefault(); });
  window.addEventListener("mousemove", (e) => { if (dragging) setPanelWidth(window.innerWidth - e.clientX); });
  window.addEventListener("mouseup", () => {
    if (!dragging) return;
    dragging = false; document.body.classList.remove("resizing");
    localStorage.setItem("panelW", String(Math.round(desiredPanelW)));
  });
}
function initPanel() {
  $("#panelToggle").addEventListener("click", () => setPanelOpen(!document.body.classList.contains("panel-open")));
  $("#backdrop").addEventListener("click", () => setPanelOpen(false));
  initResize(); setPanelOpen(false);
}

// ── boot ──────────────────────────────────────────────────────────────────
async function boot() {
  // auth gate
  let me; try { me = await fetch("/api/me"); } catch { me = { ok: false }; }
  if (!me.ok) { window.location.href = "/login"; return; }
  const who = await me.json(); $("#mpUser").textContent = who.username || "";

  let health = {};
  try { health = await (await fetch("/api/health")).json(); } catch { health = {}; }
  studies = health.studies || [];
  updateStudyLabel();
  // No viewer draws anything in this user's domains, so the control goes rather
  // than sitting there able only to say it has nothing. Removed, not disabled:
  // a disabled button still asks to be clicked.
  if (!health.any_viewer) $("#viewBtn")?.remove();

  initPanel(); initMenu(); initPops();
  await loadChats();
  // resume the last real conversation; an empty one is not worth resuming and would
  // skip the domain prompt a fresh chat gives
  const resumable = chatList.find((c) => (c.title || "New chat") !== "New chat");
  if (resumable) await loadChat(resumable.id);
  else await newChat(false);
  setSendEnabled();
}
boot();
