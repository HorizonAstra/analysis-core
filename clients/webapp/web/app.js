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

// Which header controls this chat has any use for, as the server decides it.
// Per chat rather than per user: someone who may reach two domains still works
// in one at a time, and a tissue viewer offered in a microbiome conversation can
// only ever report having nothing to draw. Hidden rather than disabled — a
// disabled control still asks to be clicked, and answers when it is.
function applyControls(controls) {
  const shown = controls || {};
  for (const [key, sel] of [["viewers", "#viewBtn"], ["versions", "#verBtn"]]) {
    const btn = $(sel);
    if (btn) btn.hidden = !shown[key];
  }
  closePops();          // one of them may have just gone while its popover was open
}

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
// A name as a person should read it. An output inside a directory is addressed
// as `results/cohort.tsv`, because that is what opens it and what a later step
// names in a reference — but the folder it sits in is already the row above, so
// showing the path repeats it and reads as "Results/metadata Cefepime.tsv". The
// last segment is the name; the rest is where it lives.
function formatName(s) {
  const leaf = String(s).split("/").filter(Boolean).pop() || String(s);
  const stem = leaf.replace(/\.[a-z0-9]{1,5}$/i, "");
  return stem.replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim()
             .split(" ").map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w)).join(" ");
}
const enc = encodeURIComponent;

// ── theme ────────────────────────────────────────────────────────────────────
// Dark unless the person says otherwise, and their answer is remembered. Set on
// <html> before anything paints, so a light-theme user does not see one frame of
// dark on every load.
const THEMES = ["dark", "light"];
function currentTheme() {
  const t = localStorage.getItem("theme");
  return THEMES.includes(t) ? t : "dark";
}
// Two steps on purpose. The attribute is set at once, before anything paints;
// the button is labelled later, because the icon set is declared further down
// this file and reaching for it here would be a use-before-initialisation.
function applyTheme(name) {
  // The button is about to rewrite itself under the pointer, and a tooltip
  // still pointing at what it held is describing a node that is going away.
  hideTip();
  const t = THEMES.includes(name) ? name : "dark";
  document.documentElement.dataset.theme = t;
  localStorage.setItem("theme", t);
  labelTheme(t);
}
function labelTheme(t) {
  const btn = $("#mpTheme");
  if (!btn || typeof ICON === "undefined") return;
  const next = t === "dark" ? "light" : "dark";
  btn.innerHTML = t === "dark" ? ICON.sun : ICON.moon;
  tip(btn, `Switch to the ${next} theme`);
  btn.setAttribute("aria-label", `Switch to the ${next} theme`);
}
document.documentElement.dataset.theme = currentTheme();

// ── menus ────────────────────────────────────────────────────────────────────
// One menu, in a fixed layer on <body>. The version menus used to be absolutely
// positioned inside the cell they belonged to — which is inside a sticky <th>,
// inside a scrolling <div>, inside a dialog. Every one of those clips: a menu on
// a right-hand column or a bottom row was cut off or hidden outright. Measured
// from the anchor and placed in the viewport, nothing can clip it, and there is
// one implementation instead of two that drift.
let menuEl = null, menuAway = null;

function closeMenuLayer() {
  // Swept from the DOM rather than only through the handle. The handle going
  // stale is exactly how a menu got stranded on screen with its own dismissal
  // listener already unregistered, and no amount of clicking could reach it.
  for (const stray of document.querySelectorAll(".popmenu")) stray.remove();
  menuEl = null;
  if (menuAway) { document.removeEventListener("click", menuAway, true); menuAway = null; }
}
// items: {head} | {label, note, on, disabled, danger, onClick} | {sep:true}
function menuAt(anchor, items) {
  closeMenuLayer();
  hideTip();
  const m = el("popmenu");
  for (const it of items) {
    if (!it) continue;
    if (it.head !== undefined) {
      const h = el("pm-head"); h.textContent = it.head; m.appendChild(h); continue;
    }
    if (it.sep) { m.appendChild(el("pm-sep")); continue; }
    const b = document.createElement("button");
    b.type = "button";
    b.className = "pm-item" + (it.on ? " on" : "") + (it.danger ? " danger" : "");
    b.disabled = !!it.disabled;
    b.innerHTML = `<span class="pm-lead"></span><span class="pm-label"></span><span class="pm-note"></span>`;
    b.querySelector(".pm-lead").textContent = it.lead || "";
    b.querySelector(".pm-label").textContent = it.label;
    b.querySelector(".pm-note").textContent = it.note || "";
    if (!it.disabled) b.addEventListener("click", (e) => {
      // Kept from the document, which would otherwise read it as a click landing
      // outside every open popover and close the panel this menu belongs to. The
      // layer is swept before the handler runs, so by the time the document sees
      // the event the node it is asked about is no longer in the page and cannot
      // be recognised. The capture-phase dismissal has already run by now, so
      // nothing that needs this click has been skipped.
      e.stopPropagation();
      closeMenuLayer();
      it.onClick();
    });
    m.appendChild(b);
  }
  document.body.appendChild(m);
  menuEl = m;

  const r = anchor.getBoundingClientRect();
  const b = m.getBoundingClientRect();
  const gap = 4;
  let top = r.bottom + gap;
  if (top + b.height > window.innerHeight - 8) top = Math.max(8, r.top - b.height - gap);
  let left = r.left;
  if (left + b.width > window.innerWidth - 8) left = Math.max(8, r.right - b.width);
  m.style.top = Math.round(top) + "px";
  m.style.left = Math.round(left) + "px";

  // Capture phase, because the dialog card stops clicks bubbling to the document:
  // listening the ordinary way meant the only way out was to choose something, and
  // deciding to change nothing is the commonest reason to open a menu.
  //
  // Registered SYNCHRONOUSLY, on a local. The previous version deferred it with
  // setTimeout(0) and passed the module-level `menuAway` to addEventListener — so
  // if anything closed or reopened a menu before that timer fired, the variable
  // was null by then, `addEventListener("click", null, true)` is a silent no-op,
  // and the menu on screen had nothing left that could dismiss it. No timer is
  // needed either way: this runs during the click that opened the menu, whose
  // capture phase is already over, so the new listener cannot see that click.
  const away = (e) => { if (!e.target.closest(".popmenu")) closeMenuLayer(); };
  menuAway = away;
  document.addEventListener("click", away, true);
}
// The layer is measured against the viewport, so anything that moves the anchor
// invalidates it.
window.addEventListener("scroll", closeMenuLayer, true);
window.addEventListener("resize", closeMenuLayer);
window.addEventListener("blur", closeMenuLayer);
document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeMenuLayer(); });

// ── tooltips ─────────────────────────────────────────────────────────────────
// One floating element for the whole app, instead of the browser's own tooltip.
// The native one cannot be styled, arrives after a delay nobody chose, wraps
// where it likes, and renders a `·`-joined string as one grey run — which is how
// "finished · ran on randi · not reproducible" ended up being the least legible
// text in the product. This takes the same facts as structure and draws them.
//
//   tip(node, "one line")
//   tip(node, ["a line", "another"])
//   tip(node, [["Finished", "14 Aug, 2:14 pm"], ["Site", "randi"]])
//
// A pair list becomes a two-column grid; anything else becomes lines. Bold with
// **text**. Passing a falsy value removes the tooltip.
let tipEl = null, tipTimer = null, tipFor = null;

function tipNode() {
  if (!tipEl) {
    tipEl = el("tip");
    tipEl.setAttribute("role", "tooltip");
    document.body.appendChild(tipEl);
  }
  return tipEl;
}
// The one rich-text helper: escape first, then allow **bold** and line breaks.
// Shared by the tooltip and the modal so a message reads the same in both.
function fmtText(t) {
  return escapeHtml(String(t))
    .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
    .replace(/\n/g, "<br>");
}
function tipMarkup(content) {
  const bold = fmtText;
  const pairs = Array.isArray(content) && content.length
    && content.every((r) => Array.isArray(r) && r.length === 2);
  if (pairs) {
    return `<div class="tip-rows">${content
      .filter(([, v]) => v !== "" && v !== null && v !== undefined)
      .map(([k, v]) => `<span class="tip-k">${bold(k)}</span><span class="tip-v">${bold(v)}</span>`)
      .join("")}</div>`;
  }
  const lines = (Array.isArray(content) ? content : String(content).split("\n")).filter(Boolean);
  return lines.map((l) => `<div class="tip-line">${bold(l)}</div>`).join("");
}
// Placed after it is measured, and flipped above the target when there is no
// room below — a tooltip clipped by the window edge is worse than none.
function showTip(node, content) {
  const t = tipNode();
  t.innerHTML = tipMarkup(content);
  t.classList.add("on");
  const r = node.getBoundingClientRect();
  const b = t.getBoundingClientRect();
  const gap = 7;
  let top = r.bottom + gap;
  if (top + b.height > window.innerHeight - 8) top = Math.max(8, r.top - b.height - gap);
  let left = r.left + r.width / 2 - b.width / 2;
  left = Math.max(8, Math.min(left, window.innerWidth - b.width - 8));
  t.style.top = Math.round(top) + "px";
  t.style.left = Math.round(left) + "px";
  tipFor = node;
}
function hideTip() {
  clearTimeout(tipTimer);
  tipFor = null;
  if (tipEl) tipEl.classList.remove("on");
}
function tip(node, content) {
  if (!node) return node;
  node.removeAttribute("title");          // never both
  node._tip = content || null;
  if (node.dataset.tipWired) return node;
  node.dataset.tipWired = "1";
  const open = () => {
    if (!node._tip) return;
    clearTimeout(tipTimer);
    tipTimer = setTimeout(() => showTip(node, node._tip), 320);
  };
  node.addEventListener("mouseenter", open);
  node.addEventListener("focus", open);
  node.addEventListener("mouseleave", hideTip);
  node.addEventListener("blur", hideTip);
  node.addEventListener("mousedown", hideTip);   // a click has its own answer
  return node;
}
// Anything that moves the target invalidates the position, and re-measuring on
// scroll is cheaper than being wrong about where the thing being described is.
window.addEventListener("scroll", () => { if (tipFor) hideTip(); }, true);
window.addEventListener("resize", () => { if (tipFor) hideTip(); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape") hideTip(); });
// A tooltip is dismissed by its own node's mouseleave, which assumes the node
// outlives the tooltip. Several do not: a panel redraws, or a button swaps its
// contents in response to being clicked. The old node leaves the page with the
// pointer still inside where it used to be, so the mouseleave that would have
// hidden the tooltip never fires and it stays on screen until something
// unrelated clears it. Switching the theme did exactly that — the button
// rewrites itself to the other icon under the cursor, and its description hung
// there afterwards.
//
// So the tooltip also answers for itself: on any pointer movement, if the node
// it describes has left the document or the pointer is no longer within it, it
// goes. Cheap, because it does nothing at all unless a tooltip is showing.
document.addEventListener("mouseover", (e) => {
  if (!tipFor) return;
  if (!tipFor.isConnected || !tipFor.contains(e.target)) hideTip();
}, true);
document.addEventListener("mouseleave", () => { if (tipFor) hideTip(); });

// ── transcript rendering ─────────────────────────────────────────────────────
function clearTranscript() { thread.innerHTML = ""; working = null; liveProse = null; resetLive(); }
// The empty thread. One sentence, centred, and nothing else — the capabilities
// panel is reached from the chats menu, which is where it stays reachable once
// this heading is gone.
function showWelcome() {
  clearTranscript();
  const w = el("welcome");
  w.innerHTML = `<h1>What&rsquo;s today&rsquo;s research question?</h1>`;
  thread.appendChild(w);
}

// Opened from the chats menu. Kept as its own function so the wiring is one place.
function openCaps() {
  const pop = $("#infoPop");
  if (!pop) return;
  const wasClosed = pop.hidden;
  closePops();
  if (wasClosed) { pop.hidden = false; renderCaps(); }
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
    edit.className = "turn-edit"; edit.type = "button";
    edit.innerHTML = ICON.pencil;
    tip(edit, "Edit and resend.");
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
  liveTrace.innerHTML = '<summary><span class="tr-label">Steps</span></summary><div class="tr-body"></div>';
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
    ? `${liveStepCount} step${liveStepCount === 1 ? "" : "s"}`
    : "Reasoning";
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
  card.innerHTML = `<span class="ac-ico">${iconForFmt(a)}</span>` +
                   `<span class="ac-name">${escapeHtml(formatName(a.name))}</span>` +
                   `<span class="ac-go">${ICON.chevSm}</span>`;
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
  if (ev.site) tip(head, [["Running on", ev.site]]);
  step.appendChild(head);
  step.dataset.run = ev.run || "";
  traceBody().appendChild(step);
  toBottom();
  refreshGoing();
}
function startWorking() {
  working = el("turn assistant");
  working.innerHTML = '<div class="working"><span class="pulse"></span><span class="label">Working</span></div>';
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
  if (!res.ok || !res.body) { stopWorking(); addNotice("Couldn’t reach the server.", true); return; }
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
    else { stopWorking(); addNotice("Connection lost.", true); }
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
  if (!shown.length) { box.innerHTML = '<div class="mp-empty">No chats</div>'; return; }
  for (const c of shown) {
    const row = document.createElement("div");
    row.className = "mp-chat-row" + (c.id === currentChatId ? " active" : "");
    const b = document.createElement("button");
    b.className = "mp-chat"; b.textContent = c.title || "New chat";
    b.addEventListener("click", () => switchChat(c.id));
    const acts = document.createElement("div"); acts.className = "mp-acts";
    const ren = document.createElement("button"); ren.className = "mp-act";
    ren.innerHTML = ICON.pencil; tip(ren, "Rename");
    ren.addEventListener("click", (e) => { e.stopPropagation(); renameChat(c); });
    const del = document.createElement("button"); del.className = "mp-act";
    del.innerHTML = ICON.trash; tip(del, "Delete");
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
      (message ? `<div class="modal-msg">${fmtText(message)}</div>` : "") +
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
    // One footer row, not three: the note, the count and the two controls were
    // stacking into more chrome than the choice itself.
    card.innerHTML = `<div class="modal-title">Domain</div>` +
      `<div class="domain-grid"></div>` +
      `<div class="domain-foot">` +
        `<button class="dm-all" type="button">All</button>` +
        `<span class="dm-note">Fixed once the chat starts</span>` +
        `<span class="dm-count"></span>` +
        `<button class="modal-btn confirm">Start</button>` +
      `</div>`;
    const grid = card.querySelector(".domain-grid");
    const go = card.querySelector(".confirm");
    const all = card.querySelector(".dm-all");
    const count = card.querySelector(".dm-count");
    const chosen = new Set(preselected && preselected.length ? preselected : [options[0].name]);

    function sync() {
      for (const b of grid.children) b.classList.toggle("on", chosen.has(b.dataset.name));
      count.textContent = `${chosen.size} of ${options.length}`;
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
  const ok = await modal({ title: "Delete chat", message: c.title || "New chat", confirmText: "Delete", danger: true });
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
  applyControls(chat.controls);
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
  applyControls(await fetch(`/api/controls?domains=${enc(chatDomains.join(","))}`)
    .then((r) => r.json()).catch(() => ({})));
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
  // stopPropagation, or the document click handler that closes popovers runs next
  // on this very event, sees a target outside .info-card, and shuts it again.
  $("#mpCaps").addEventListener("click", (e) => { e.stopPropagation(); closeMenu(); openCaps(); });
  $("#mpSearch").addEventListener("input", renderChatList);
  $("#mpTheme").addEventListener("click", (e) => {
    e.stopPropagation();
    applyTheme(currentTheme() === "dark" ? "light" : "dark");
    // And let it go again. This menu closes when the pointer leaves it, unless
    // focus is still inside — a guard that exists so the menu does not vanish
    // from under somebody typing in the search field. A button keeps focus
    // after being clicked, which is not somebody typing, and every other
    // control in here closes the menu as part of what it does. This one does
    // not, so it sat holding focus and the close declined for as long as it
    // did: switch the theme, move away, and the menu stayed open for good.
    e.currentTarget.blur();
  });
  $("#mpLogout").addEventListener("click", async () => { await fetch("/api/logout", { method: "POST" }); window.location.href = "/login"; });
}

// ── study scope + capabilities popups ───────────────────────────────────────
// Two separate controls on purpose: capabilities describes the product and sits by the
// name; study scope changes what this chat can reach and sits by Results.
// Button, popover, and the surface a click may land on without closing it. The
// surface is the popover itself unless the popover is a full-screen overlay with
// a card in the middle, where clicking the dimmed area around the card is how a
// person closes it.
const POPS = [["#studyBtn", "#studyPop"], ["#infoBtn", "#infoPop", ".info-card"],
              ["#viewBtn", "#viewPop"], ["#verBtn", "#verPop", ".ver-card"]];

// Whether a click happened inside the surface of a popover that is currently
// open. Asked of the event at the moment it happens, rather than by hanging a
// stopPropagation listener on the surface when the popover is wired up. Those
// listeners were attached once, at start-up, to whatever node matched then — and
// the capabilities panel builds its card contents on first open, so the listener
// ended up on a node that had been replaced. Every click inside the panel
// reached the document and closed it. Reading the event cannot go stale, and it
// is one rule for every popover instead of one listener per popover.
function insideOpenPop(target) {
  // The version menu is drawn in a fixed layer on <body> so that nothing can
  // clip it, which puts it outside the card it belongs to. To this question it
  // is inside: choosing a version is working within the panel, not leaving it.
  // Read literally, every choice made from a menu counted as a click outside
  // and closed the panel underneath it — so the grid shut the moment it was
  // used, and staying open required changing nothing.
  if (menuEl && menuEl.contains(target)) return true;
  for (const [, popSel, surfaceSel] of POPS) {
    const pop = $(popSel);
    if (!pop || pop.hidden) continue;
    const surface = surfaceSel ? pop.querySelector(surfaceSel) : pop;
    if (surface && surface.contains(target)) return true;
  }
  return false;
}
// Closing skips whatever is not on the page. This runs on every document click,
// so one missing control here would break every click in the app.
function closePops() {
  // The version menu lives inside one of these, so hiding the card would leave
  // it in the page with its watcher still registered, waiting to close a menu
  // nobody can see and then reappearing on top of the next one.
  closeVersionMenu();
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
  // Nothing is attached to the surface here. Which clicks close a popover is
  // decided by insideOpenPop when the click happens, so content built later
  // behaves the same as content present at start-up.
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
  catch { body.innerHTML = `<p class="ip-note">Couldn’t load</p>`; return; }
  capsShown = true;

  const box = (it) => `
    <div class="ip-box">
      <div class="ip-box-name">${escapeHtml(it.name)}</div>
      <div class="ip-box-what">${escapeHtml(it.what)}</div>
      ${it.needs && it.needs.length
        ? `<div class="ip-box-needs">After ${it.needs.map(escapeHtml).join(", ")}</div>` : ""}
      ${it.across_samples ? `<div class="ip-box-tag">Across samples</div>` : ""}
    </div>`;

  // The stage note said in prose what the left-to-right order already says. The
  // heading alone is the stage; a sentence under each one is three sentences of
  // caption above the thing being captioned.
  const flow = (sts) => `<div class="ip-flow">${sts.map((s, i) => `
    ${i ? `<div class="ip-arrow" aria-hidden="true">${ICON.chevSm}</div>` : ""}
    <div class="ip-stage">
      <div class="ip-stage-head">${escapeHtml(s.stage)}</div>
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
        <span class="ip-chev">${ICON.chevSm}</span>
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
  list.innerHTML = `<div class="vw-empty">Loading</div>`;
  let d;
  try { d = await (await fetch(`/api/viewers?chat_id=${enc(currentChatId || "")}`)).json(); }
  catch { list.innerHTML = `<div class="vw-empty">Couldn’t load</div>`; return; }
  if (!d.viewers || !d.viewers.length) {
    list.innerHTML = `<div class="vw-empty">Nothing to open</div>`;
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
    // Nothing ticked is a real state and it is said, rather than prevented by
    // leaving a sample on that nobody asked for. What must not happen is opening
    // a viewer with nothing in it, so that is what is stopped, at the button.
    open.disabled = n === 0;
    why.textContent = n === 0
      ? "No samples selected"
      : (choices.length > 1 && n < choices.length
        ? `${n} of ${choices.length} samples`
        : `${v.samples} sample${v.samples === 1 ? "" : "s"}`);
  };
  say();
  open.addEventListener("click", () => {
    if (!v.ready || !picked().length) return;
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
  pickName.className = "vw-pick-name"; pickName.textContent = "Samples";
  const count = document.createElement("span");
  count.className = "vw-pick-count";
  pick.append(chev, pickName, count);
  const tally = () => {
    const n = picked().length;
    count.textContent = `${n} of ${choices.length}`;
  };
  tally();

  const box = el("vw-samples");
  box.hidden = true;
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
      boxes.forEach((c) => { c.checked = want; });
      changed();
    });
    bulk.appendChild(b);
  }
  box.append(bulk, checks);
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
  body.innerHTML = `<div class="vw-empty">Loading</div>`;
  try { verData = await (await fetch(`/api/versions?chat_id=${enc(currentChatId || "")}`)).json(); }
  catch { body.innerHTML = `<div class="vw-empty">Couldn’t load</div>`; return; }
  drawVersions();
}

async function pickVersion(picked) {
  // A version is chosen for one conversation, so there has to be one to choose
  // it for. A new chat exists only on screen until its first message, which is
  // exactly what this card sees when the app has just been opened, and the
  // choice was refused. Created here the same way sending a message creates it,
  // rather than making somebody send something before the grid will work.
  let id = currentChatId;
  if (!id) { try { id = await ensureChatExists(); } catch { id = null; } }
  if (!id) { versionsNote("Start a chat first."); return; }

  let got = null, ok = false;
  try {
    const res = await fetch("/api/versions", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: id, picked }),
    });
    ok = res.ok;
    got = await res.json();
  } catch { got = null; }
  // Whatever came back is only drawn if it is a grid. A refusal is a small
  // problem — one choice did not register — and drawing it as the answer turned
  // it into a large one: the body has no columns, so a screen full of real
  // results redrew as "nothing has finished yet".
  if (!ok || !got || !got.columns) {
    versionsNote((got && got.error) || "Couldn’t save");
    return;
  }
  verData = got;
  drawVersions();
}

function versionsNote(text) {
  const foot = $("#verFoot");
  if (foot) foot.textContent = text;
}

// The grid. Samples down, capabilities across, one cell per pair.
//
// The controls are folded into the headings rather than sitting beside them. It
// used to carry a "Newest" button under every column heading plus an "All cells"
// bar above the table — thirteen visible buttons before a single version was
// chosen, and still no way to act on one sample. Now the heading IS the control:
// a column heading acts on its column, a row label on its row, and the corner
// cell on everything. Same three scopes, no extra furniture, and the one scope
// that was missing is the one a person actually asks for ("redo this sample").
function drawVersions() {
  closeMenuLayer();          // the anchors below are about to be replaced
  const body = $("#verBody"), foot = $("#verFoot");
  const cols = (verData && verData.columns) || [];
  const rows = (verData && verData.rows) || [];
  if (!cols.length) {
    body.innerHTML = '<div class="vw-empty">Nothing yet</div>';
    foot.textContent = "";
    return;
  }
  body.innerHTML = "";
  const table = document.createElement("table");
  table.className = "ver-grid";

  const head = document.createElement("tr");
  const corner = document.createElement("th");
  corner.className = "ver-corner";
  corner.dataset.col = 0;
  corner.appendChild(scopeButton("All", () => everyCell(),
    `Every cell · ${rows.length} sample${rows.length === 1 ? "" : "s"} × ${cols.length}`));
  head.appendChild(corner);
  cols.forEach((c, ci) => {
    const th = document.createElement("th");
    th.className = "ver-colcell";
    th.dataset.col = ci + 1;
    // The data column is named by the domain that owns the data — "Space Ranger"
    // rather than "Data" — because that is what the people reading this call the
    // thing every analysis starts from.
    const label = c === verDataColumn()
      ? ((verData && verData.data_label) || "Data") : capTitle(c);
    th.appendChild(scopeButton(label, () => cellsInColumn(c), label, "ver-col"));
    head.appendChild(th);
  });
  table.appendChild(head);

  for (const r of rows) {
    const tr = document.createElement("tr");
    const label = document.createElement("th");
    label.className = "ver-row";
    label.dataset.col = 0;
    label.appendChild(scopeButton(r.label, () => cellsInRow(r.subject), r.label));
    tr.appendChild(label);
    cols.forEach((c, ci) => {
      const td = versionCell(r.subject, c, r.cells[c]);
      td.dataset.col = ci + 1;
      tr.appendChild(td);
    });
    table.appendChild(tr);
  }

  // The cross-sample rows go in THIS table, under a divider, rather than in a
  // second one below it. A separate table sizes its own columns, so "Cohort"
  // and its values landed under nothing in particular while the grid above them
  // was still lined up — the one thing a matrix may not do.
  const across = verData.across || [];
  if (across.length) {
    const sep = document.createElement("tr");
    sep.className = "ver-seprow";
    const th = document.createElement("th");
    th.colSpan = cols.length + 1;
    th.textContent = "Across samples";
    sep.appendChild(th);
    table.appendChild(sep);
    for (const a of across) {
      const tr = document.createElement("tr");
      const label = document.createElement("th");
      label.className = "ver-row";
      label.dataset.col = 0;
      label.appendChild(scopeButton(a.label, () => cellsInRow(a.subject), a.label));
      tr.appendChild(label);
      // Walked over the grid's own columns, so a capability this row has no cell
      // for leaves a gap in the right place instead of shifting everything left.
      cols.forEach((c, ci) => {
        const td = versionCell(a.subject, c, a.cells[c]);
        td.dataset.col = ci + 1;
        tr.appendChild(td);
      });
      table.appendChild(tr);
    }
  }
  body.appendChild(table);
  // Same crosshair as a result table. A matrix nineteen rows deep and ten across
  // is the place it earns most: a cell in the middle of it is a version of some
  // capability for some sample, and without both arms lit you are counting
  // across with a finger.
  crosshair(table);

  // Counted over the capability columns only. The data column is what the
  // results were computed from, not a result, and counting it as one would
  // report work that nobody did.
  const made = cols.filter((c) => c !== verDataColumn());
  const filled = rows.reduce((n, r) => n + made.filter((c) => r.cells[c] && r.cells[c].versions.length).length, 0);
  const choices = rows.reduce((n, r) => n + made.filter((c) => r.cells[c] && r.cells[c].versions.length > 1).length, 0);
  foot.textContent = `${filled} result${filled === 1 ? "" : "s"}` +
    (choices ? ` · ${choices} with more than one version` : "");
}

// A row highlights itself with tr:hover. A column has no selector at all — CSS
// cannot reach "the cells above and below this one" — so the cells in it are
// marked as the pointer moves. Delegated to the table, and the marks are only
// rewritten when the column index actually changes, so travelling along a row
// costs one comparison per event rather than 240 class writes.
//
// The label column is skipped: highlighting a column of sample names says
// nothing, and it would fight the sticky background that keeps that column
// readable over the scrolling grid.
function trackColumnHover(table) {
  let current = -1;
  const paint = (idx) => {
    if (idx === current) return;
    for (const c of table.querySelectorAll(".col-hot")) c.classList.remove("col-hot");
    current = idx;
    if (idx < 1) return;
    for (const row of table.rows) {
      const c = row.cells[idx];
      // A divider row is one cell spanning the grid, so it has nothing at idx.
      if (c && !row.classList.contains("ver-seprow")) c.classList.add("col-hot");
    }
  };
  table.addEventListener("mousemove", (e) => {
    const cell = e.target.closest("td, th");
    paint(cell && table.contains(cell) ? cell.cellIndex : -1);
  });
  table.addEventListener("mouseleave", () => paint(-1));
}

// A heading that acts on what it heads. The chevron appears on hover so a closed
// grid still reads as a grid rather than as a row of dropdowns.
function scopeButton(text, cellsFn, _unused, extraClass) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "ver-scope" + (extraClass ? " " + extraClass : "");
  b.innerHTML = `<span class="vs-text"></span><span class="vs-chev">${ICON.chevSm}</span>`;
  b.querySelector(".vs-text").textContent = text;
  b.addEventListener("click", (e) => { e.stopPropagation(); openScopeMenu(b, text, cellsFn()); });
  return b;
}

function verDataColumn() {
  return (verData && verData.data_column) || "";
}

// Every cell there is, as [subject, column, cell]. Both sections, because the
// rows that span samples are cells like any other and a control that said "all"
// while quietly meaning "all except those" would be worse than not having one.
function everyCell() {
  const out = [];
  for (const r of [...(verData.rows || []), ...(verData.across || [])]) {
    for (const c of Object.keys(r.cells || {})) {
      if (r.cells[c] && r.cells[c].versions.length) out.push([r.subject, c, r.cells[c]]);
    }
  }
  return out;
}
function cellsInColumn(col) {
  return everyCell().filter(([, c]) => c === col);
}
function cellsInRow(subject) {
  return everyCell().filter(([sub]) => sub === subject);
}

// One menu for all three scopes. Only the actions that would change something
// are offered: a scope whose cells are all on their newest version has nothing
// to point at newest, and the data column cannot be cleared at all.
function openScopeMenu(anchor, title, cells) {
  const clearable = cells.filter(([, , cell]) => cell.clearable !== false);
  const stale = cells.filter(([, , cell]) => cell.cleared || cell.active !== cell.newest);
  const set = (list, value) => () => {
    const picked = {};
    for (const [subject, c] of list) picked[`${subject}::${c}`] = value;
    pickVersion(picked);
  };
  menuAt(anchor, [
    { head: `${title} · ${cells.length} cell${cells.length === 1 ? "" : "s"}` },
    { label: "Newest", note: stale.length ? `${stale.length} to change` : "already newest",
      disabled: !stale.length, onClick: set(cells, null) },
    { label: "Clear", note: clearable.length ? `${clearable.length} cell${clearable.length === 1 ? "" : "s"}` : "not clearable",
      disabled: !clearable.length, onClick: set(clearable, "") },
  ]);
}

// A version of a result is named by when it was submitted, and a version of data
// is named by whoever laid the folder out. So a name is shown as a date only when
// it is one, and otherwise shown as what it says.
function verWhen(at) {
  const d = new Date(at);
  return isNaN(d.getTime()) ? at : d.toLocaleDateString();
}

// A cell is text you can click, not a capsule. Two hundred bordered pills in a
// grid read as an answer sheet: every cell drew its own outline, so the outlines
// became the pattern and the values disappeared between them. State is carried by
// weight and by one dashed underline, which is what the values needed all along.
function versionCell(subject, capability, cell) {
  const td = document.createElement("td");
  td.className = "ver-cell";
  if (!cell || !cell.versions.length) {
    td.classList.add("ver-none");
    td.textContent = "—";
    return td;
  }
  const b = document.createElement("button");
  b.type = "button";
  b.className = "ver-val";
  if (cell.cleared) {
    b.classList.add("is-cleared");
    b.textContent = "empty";
    tip(b, "Cleared. The next request runs it fresh.");
  } else {
    const active = cell.versions.find((v) => v.identity === cell.active) || cell.versions[0];
    if (active.identity !== cell.newest) b.classList.add("is-old");
    if (cell.versions.length === 1) b.classList.add("is-only");
    b.textContent = "v" + active.ordinal;
    tip(b, [
      ["Version", active.label || verWhen(active.at)],
      ["State", active.identity === cell.newest ? "Newest" : "Not the newest"],
      active.runs > 1 ? ["Runs", `${active.runs} produced this same result`] : ["", ""],
      ["", cell.versions.length > 1 ? `${cell.versions.length} versions to choose from` : ""],
    ]);
  }
  b.addEventListener("click", (e) => { e.stopPropagation(); openVersionMenu(b, subject, capability, cell); });
  td.appendChild(b);
  return td;
}

function openVersionMenu(anchor, subject, capability, cell) {
  const items = [{ head: `${subject || "Across samples"} · ${capTitle(capability)}` }];
  for (const v of cell.versions) {
    items.push({
      lead: "v" + v.ordinal,
      label: v.label || verWhen(v.at),
      note: v.identity === cell.newest ? "newest" : verWhen(v.at),
      on: v.identity === cell.active,
      onClick: () => pickVersion({ [`${subject}::${capability}`]: v.identity }),
    });
  }
  // Emptying a cell asks for the work to be done again, and data is not work.
  // It is on disk or it is not, so this column offers the choice without it.
  if (cell.clearable !== false) {
    items.push({ sep: true });
    items.push({ label: "Clear", note: "recomputed next time", on: !!cell.cleared,
                 onClick: () => pickVersion({ [`${subject}::${capability}`]: "" }) });
  }
  menuAt(anchor, items);
}

function closeVersionMenu() { closeMenuLayer(); }

function initPops() {
  initPopover("#studyBtn", "#studyPop", () => { anchorStudyPop(); renderStudyPop(); });
  initPopover("#infoBtn", "#infoPop", renderCaps, ".info-card");
  initPopover("#verBtn", "#verPop", renderVersions, ".ver-card");
  initPopover("#viewBtn", "#viewPop", renderViewers);
  $("#ipClose").addEventListener("click", closePops);
  $("#verClose")?.addEventListener("click", closePops);
  document.addEventListener("click", (e) => { if (!insideOpenPop(e.target)) closePops(); });
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
  if (!studies.length) { box.innerHTML = '<div class="mp-empty">No studies</div>'; }
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
  $("#spCount").textContent = `${sel.size} of ${studies.length}`;
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
  if (!thread.querySelector(".turn")) showWelcome();
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
// One set, one grammar: a 24 viewBox, a 1.5 stroke, round caps and joins, two shapes at
// most. The ones that were three overlapping shapes at 1.6 and 1.7 read as clutter at
// 15px — at that size an icon is a silhouette and detail is noise.
//
// Solid is used only where solid IS the meaning, and there it overrides the stroke rule:
// a stop square, a warning triangle, the dot of an i, and the tick — which carries 2.2
// because it is knocked out of a filled box at 12px and 1.5 would read as a hairline
// crack. The info glyph in index.html is the one three-shape icon, for the same reason:
// a circle, a stem and a dot is what the letter is.
const STROKE = 'fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"';
const ICON = {
  chev:   `<svg class="chev" viewBox="0 0 24 24" width="12" height="12"><path d="M9.5 6l6 6-6 6" ${STROKE}/></svg>`,
  chevSm: `<svg viewBox="0 0 24 24" width="12" height="12"><path d="M9.5 6l6 6-6 6" ${STROKE}/></svg>`,
  // A table is rows; a figure is a frame with a horizon; a document is a page with lines.
  table:  `<svg viewBox="0 0 24 24" width="14" height="14"><path d="M4 8.5h16M4 15.5h16" ${STROKE}/><rect x="4" y="4.5" width="16" height="15" rx="1.5" ${STROKE}/></svg>`,
  image:  `<svg viewBox="0 0 24 24" width="14" height="14"><rect x="4" y="4.5" width="16" height="15" rx="1.5" ${STROKE}/><path d="M4.5 15.5l4.5-4 4 3.2 2.5-2.2 4 3.5" ${STROKE}/></svg>`,
  doc:    `<svg viewBox="0 0 24 24" width="14" height="14"><rect x="5.5" y="3.5" width="13" height="17" rx="1.5" ${STROKE}/><path d="M9 10h6M9 14h6" ${STROKE}/></svg>`,
  pencil: `<svg viewBox="0 0 24 24" width="14" height="14"><path d="M4.5 19.5h4l11-11-4-4-11 11z" ${STROKE}/></svg>`,
  trash:  `<svg viewBox="0 0 24 24" width="14" height="14"><path d="M4.5 7h15M9.5 4.5h5" ${STROKE}/><path d="M7 7l.8 12.5h8.4L17 7" ${STROKE}/></svg>`,
  back:   `<svg viewBox="0 0 24 24" width="15" height="15"><path d="M14.5 18l-6-6 6-6" ${STROKE}/></svg>`,
  stop:   '<svg viewBox="0 0 24 24" width="11" height="11"><rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor"/></svg>',
  check:  '<svg viewBox="0 0 24 24" width="12" height="12"><path d="M5.5 12.5l4.5 4.5L18.5 7.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  warn:   '<svg viewBox="0 0 24 24" width="13" height="13"><path d="M12 4.5L21.5 20.5H2.5z" fill="currentColor" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg>',
  sun:    `<svg viewBox="0 0 24 24" width="14" height="14"><circle cx="12" cy="12" r="4.2" ${STROKE}/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.8 5.8l1.4 1.4M16.8 16.8l1.4 1.4M18.2 5.8l-1.4 1.4M7.2 16.8l-1.4 1.4" ${STROKE}/></svg>`,
  moon:   `<svg viewBox="0 0 24 24" width="14" height="14"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z" ${STROKE}/></svg>`,
  info:   '<svg viewBox="0 0 24 24" width="16" height="16"><circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M12 11.4v5.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><circle cx="12" cy="7.6" r="1.05" fill="currentColor"/></svg>',
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
                    `<span class="go-time"></span><button class="go-stop">${ICON.stop}</button>`;
    row.querySelector(".go-name").textContent = r.label || "Analysis";
    row.querySelector(".go-time").textContent = r.elapsed || "";
    tip(row, [["Running on", r.site || ""], ["Elapsed", r.elapsed || ""]]);
    tip(row.querySelector(".go-stop"), "Stop this run.");
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
// When a run finished, at the resolution a reader needs: the clock for today,
// the date for anything older, and the year only once it stops being obvious.
function whenLabel(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d)) return "";
  const time = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return time;
  const day = d.toLocaleDateString([], d.getFullYear() === now.getFullYear()
    ? { day: "numeric", month: "short" }
    : { day: "numeric", month: "short", year: "2-digit" });
  return `${day}, ${time}`;
}
function fullWhen(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return isNaN(d) ? "" : d.toLocaleString();
}
// One run, as a folder of the things it produced. Built on its own so it can be
// dropped straight into the panel or inside a sample, without the two cases
// being two copies of the same code.
function runFolder(t) {
  const folder = document.createElement("div");
  folder.className = "folder" + (expanded.has(t.key) ? " open" : "");
  const row = document.createElement("button"); row.className = "folder-row";
  // The flag goes FIRST, in a slot every row reserves whether or not it is
  // filled. Appended last it pushed nothing, but it did mean a flagged row's
  // trailing elements sat at different offsets from every unflagged row beside
  // it, so the column of counts stopped being a column.
  const bad = t.verified === false || t.reproducible === false;
  // When it ran is shown on every row, not only when two share a heading. It is
  // the one fact that orders the panel, and it was being withheld until a
  // collision made it necessary.
  const when = whenLabel(t.finished);
  // The flag leads the trailing group — before the stamp and the count, not
  // before the name. Its slot is reserved on every row, so the stamp and the
  // count sit at the same offset whether a row is flagged or not.
  row.innerHTML = `${ICON.chev}<span class="name">${escapeHtml(t.label)}</span>` +
                  `<span class="flag-slot">${bad ? ICON.warn : ""}</span>` +
                  `<span class="when">${escapeHtml(when)}</span>` +
                  `<span class="count">${t.items.length}</span>`;
  if (bad) row.querySelector(".flag-slot").classList.add("on");
  // The facts about a run, as facts rather than as one dot-joined sentence.
  tip(row, [
    ["Finished", fullWhen(t.finished)],
    ["Ran on", t.site || ""],
    ["Outputs", String(t.items.length)],
    t.verified === false
      ? ["Warning", "The pinned code had changed when this ran, so it may not match the recorded version."]
      : t.reproducible === false
        ? ["Warning", "Not reproducible: the same inputs may not give the same answer."]
        : ["", ""],
  ]);
  row.addEventListener("click", () => { const open = folder.classList.toggle("open"); if (open) expanded.add(t.key); else expanded.delete(t.key); });
  const items = document.createElement("div"); items.className = "items";
  // Something to open in a viewer, when the domain said one can open it.
  if (t.viewer) {
    const v = document.createElement("button"); v.className = "item item-view";
    v.innerHTML = `<span class="ico">${ICON.image}</span><span class="name">Viewer</span>`;
    v.addEventListener("click", () => openViewer(`${t.viewer}/${t.key}`));
    items.appendChild(v);
  }
  for (const it of t.items) {
    const b = document.createElement("button"); b.className = "item";
    b.innerHTML = `<span class="ico">${iconForFmt(it)}</span><span class="name">${escapeHtml(formatName(it.name))}</span>`;
    if (it.description) tip(b, it.description);
    b.addEventListener("click", () => openItem(it.ref, it.name));
    items.appendChild(b);
  }
  // Named, not hidden. An analysis that produced something which cannot leave
  // the machine it ran on has still produced it, and a user who is not told
  // that concludes it produced nothing.
  for (const name of (t.stays || [])) {
    const st = document.createElement("div"); st.className = "item item-stays";
    st.innerHTML = `<span class="ico">${ICON.doc}</span><span class="name"></span>`;
    st.querySelector(".name").textContent = formatName(name);
    tip(st, "Stays on the machine it was computed on.");
    items.appendChild(st);
  }
  folder.appendChild(row); folder.appendChild(items);
  return folder;
}

function renderTree() {
  tree.innerHTML = "";
  const topics = resultsData.topics || [];
  const count = $("#phCount");
  if (count) count.textContent = topics.length ? String(topics.length) : "";
  if (!topics.length) {
    tree.innerHTML = '<div class="tree-empty"><div class="te-title">Nothing here yet!</div>'
      + '<div class="te-sub">Tables and figures will show up here as analyses finish.</div></div>';
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
    row.innerHTML = `${ICON.chev}<span class="name"></span>` +
                    `<span class="flag-slot"></span><span class="count">${mine.length}</span>`;
    row.querySelector(".name").textContent = name;
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
  back.innerHTML = `${ICON.back}<span>Results</span>`;
  back.addEventListener("click", showTree);
  const dl = document.createElement("a"); dl.className = "v-dl"; dl.href = `/api/results/file?chat_id=${currentChatId}&ref=${enc(ref)}&name=${enc(name)}`;
  // The name the server gave it. This used to append the format to the output's
  // name, and the format was never sent, so every download arrived as `.bin` —
  // and for a file that already carried its extension, as `.tsv.bin`. What an
  // output is called is the store's answer, from what the domain declared.
  dl.setAttribute("download", item.filename || name.split("/").pop());
  dl.textContent = "Download";
  vhead.appendChild(back); vhead.appendChild(dl); viewer.appendChild(vhead);

  const head = document.createElement("div");
  head.innerHTML = `<div class="v-name">${escapeHtml(formatName(item.name || name))}</div>`;
  viewer.appendChild(head);
  // an unreadable artifact used to fall through to the "no preview" branch, which reads
  // as a format problem rather than a missing file
  if (!item || item.error) {
    dl.remove();
    const n = el("v-note"); n.textContent = "Couldn’t open this — it may have been removed";
    viewer.appendChild(n); tree.hidden = true; viewer.hidden = false; return;
  }
  if (item.description_html) {
    const wrap = el("v-desc-wrap collapsed"); const d = el("v-desc"); d.innerHTML = item.description_html;
    wrap.appendChild(d); viewer.appendChild(wrap);
    const more = document.createElement("button"); more.className = "v-more"; more.textContent = "More"; viewer.appendChild(more);
    requestAnimationFrame(() => { if (d.scrollHeight <= wrap.clientHeight + 4) { more.remove(); wrap.classList.remove("collapsed"); } });
    more.addEventListener("click", () => { more.textContent = wrap.classList.toggle("collapsed") ? "More" : "Less"; });
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
  else { const n = el("v-note"); n.textContent = "No preview for this file type"; viewer.appendChild(n); }
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
  // The manifest records the function by its own id, so it arrives as
  // `alpha_diversity`. Titled here rather than shown raw: an underscore in the
  // interface is an internal name that escaped.
  const what = groups.length === 1 ? capTitle(groups[0].function) : `${groups.length} analyses`;
  d.innerHTML = `<summary><span class="vp-label">Settings · ${escapeHtml(what)}</span></summary>`;
  const body = el("vp-body");
  for (const g of groups) {
    if (groups.length > 1) { const h = el("vp-fn"); h.textContent = capTitle(g.function); body.appendChild(h); }
    const tbl = document.createElement("table"); tbl.className = "vp-table";
    for (const v of g.values) {
      const tr = document.createElement("tr");
      if (v.defaulted) tr.className = "is-default";
      // Left exactly as recorded, unlike the capability name above. A capability
      // is a concept a reader has a word for; a parameter name IS the setting,
      // and someone checking that the rank was `species` wants the spelling the
      // method uses, not a prettified version of it.
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

// ── display utilities ────────────────────────────────────────────────────────
// Everything that draws data goes through here: one table, one fact list, one
// number formatter. The panel used to build a <table> inline at each call site
// with every column left-aligned, so a column of p-values and a column of
// species names were typeset identically and neither could be scanned. A table
// of numbers is read down the column, which needs the digits to line up.

// A column of numbers is read down, so the decision is the column's and not the
// cell's. The comment above has said so since this was written; `fmtCell` did
// not do it, and rounded each value on its own, which is how one column came out
// as 0.0637 / 5.55 / 1483 with the decimal point in three places and nothing to
// scan along. Decided once per column, every value in it formatted the same way.
//
// Three shapes, chosen by what the column actually holds:
//   whole numbers      no decimal point at all
//   very small or very large    exponent form, same precision throughout
//   everything else    a fixed number of decimals, from the column's own magnitude
function columnFormat(values) {
  const nums = values.filter((v) => typeof v === "number" && Number.isFinite(v));
  if (!nums.length) return (v) => (v === null || v === undefined ? "" : String(v));
  const abs = nums.map(Math.abs).filter((v) => v > 0);
  const big = abs.length ? Math.max(...abs) : 0;
  const small = abs.length ? Math.min(...abs) : 0;

  if (nums.every(Number.isInteger) && big < 1e15) {
    return (v) => (typeof v === "number" ? v.toLocaleString() : plain(v));
  }
  if (big >= 1e7 || (small > 0 && small < 1e-4)) {
    return (v) => (typeof v === "number" && Number.isFinite(v) ? v.toExponential(2) : plain(v));
  }
  // Enough decimals to separate values of this size, and the same count for all
  // of them. Four significant places past the leading digit is the most this
  // ever needs, and a column in the thousands needs none.
  const mag = big > 0 ? Math.floor(Math.log10(big)) : 0;
  const dp = Math.min(6, Math.max(0, 3 - mag));
  return (v) => (typeof v === "number" && Number.isFinite(v) ? v.toFixed(dp) : plain(v));
}
function plain(v) {
  return v === null || v === undefined ? "" : String(v);
}

// One value on its own, for a fact list, where there is no column to line up
// with. Keeps exponent form at the extremes and rounds the rest.
function fmtOne(v) {
  if (typeof v !== "number" || !Number.isFinite(v)) return plain(v);
  if (Number.isInteger(v)) return v.toLocaleString();
  const a = Math.abs(v);
  if (a < 1e-4 || a >= 1e7) return v.toExponential(2);
  return String(Math.round(v * 1e6) / 1e6);
}

// Whether a column holds numbers, asked of the column rather than of each cell:
// one stray null or "NA" among four hundred floats does not make it a text
// column, and aligning it as one would undo the point.
function numericColumns(columns, rows) {
  return columns.map((_, i) => {
    let seen = 0;
    for (const r of rows) {
      const v = r[i];
      if (v === null || v === undefined || v === "") continue;
      if (typeof v !== "number") return false;
      seen++;
    }
    return seen > 0;
  });
}

// The one table.
//
// Built to the rules at the top of the stylesheet rather than around them.
// "Hierarchy from space, weight" and "no bordered cards" — this used to be a
// rounded box with zebra striping and uppercased headings, which is decoration
// standing in for structure, and it made every result look the same whatever it
// held.
//
// What carries the structure instead:
//   the first column is the row's identity, so it holds the left edge and stays
//     put while the rest scrolls sideways. A hundred-column result is unreadable
//     without it — you scroll right and lose which row you are on.
//   numbers are right-aligned with tabular figures and one format per column,
//     so the digits form a column that can be scanned down.
//   the header is quiet: read once, against data read many times, and never
//     uppercased, because these are identifiers and `DA_Object` is not
//     `DA_OBJECT`.
//   hovering marks the row and the column, so a value in the middle of a wide
//     table can be traced back to both of its labels.
function dataTable({ columns, rows, truncated, shape, note }) {
  const box = document.createElement("div");
  const wrap = el("v-tablewrap");
  const tbl = document.createElement("table");
  tbl.className = "v-table";
  const num = numericColumns(columns, rows);
  const fmt = columns.map((_, i) => columnFormat(rows.map((r) => r[i])));

  const thead = document.createElement("thead");
  const htr = document.createElement("tr");
  columns.forEach((c, i) => {
    const th = document.createElement("th");
    th.textContent = c;
    th.dataset.col = i;
    if (num[i]) th.classList.add("is-num");
    if (i === 0) th.classList.add("is-key");
    htr.appendChild(th);
  });
  thead.appendChild(htr); tbl.appendChild(thead);

  const tb = document.createElement("tbody");
  for (const row of rows) {
    const tr = document.createElement("tr");
    row.forEach((cell, i) => {
      const td = document.createElement("td");
      td.textContent = num[i] ? fmt[i](cell) : plain(cell);
      td.dataset.col = i;
      if (num[i]) td.classList.add("is-num");
      if (i === 0) td.classList.add("is-key");
      if (cell === null || cell === undefined || cell === "") td.classList.add("is-empty");
      tr.appendChild(td);
    });
    tb.appendChild(tr);
  }
  tbl.appendChild(tb); wrap.appendChild(tbl); box.appendChild(wrap);
  crosshair(tbl);

  const said = note || (truncated && shape
    ? `${rows.length.toLocaleString()} of ${shape[0].toLocaleString()} rows`
    : rows.length > 12 ? `${rows.length.toLocaleString()} rows` : "");
  if (said) { const n = el("v-note"); n.textContent = said; box.appendChild(n); }
  return box;
}

// Row and column, marked together, on any grid whose cells carry a column index.
// A column cannot be selected in CSS — there is no parent of a cell that stands
// for the column it is in — so the column half is the only thing here that needs
// script, and the row half is left to `:hover` where it belongs.
//
// Delegated, so a table that is rebuilt keeps working, and cleared on leaving so
// nothing is left marked when the pointer goes somewhere else entirely.
function crosshair(table) {
  if (table.dataset.crosshair) return;
  table.dataset.crosshair = "1";
  let marked = [];
  const clear = () => { for (const c of marked) c.classList.remove("is-cross"); marked = []; };
  table.addEventListener("mouseover", (e) => {
    const cell = e.target.closest("td, th");
    if (!cell || !table.contains(cell)) return;
    const i = cell.dataset.col;
    if (i === undefined) return clear();
    clear();
    marked = [...table.querySelectorAll(`[data-col="${i}"]`)];
    for (const c of marked) c.classList.add("is-cross");
  });
  table.addEventListener("mouseleave", clear);
}

// The one fact list: a short block of name/value pairs, for the scalars at the
// top of a curated result and for anything else shaped like a record of one.
function factList(pairs) {
  const dl = el("v-facts");
  for (const [k, v] of pairs) {
    const row = el("v-fact");
    const a = el("v-fact-k"); a.textContent = k;
    const b = el("v-fact-v");
    b.textContent = v === null || v === undefined ? "" : (typeof v === "number" ? fmtOne(v) : String(v));
    if (typeof v === "number") b.classList.add("is-num");
    row.append(a, b); dl.appendChild(row);
  }
  return dl;
}

// A section heading inside the viewer, with its size beside it rather than
// inside the same string.
function sectionHead(title, count) {
  const h = el("v-section");
  h.innerHTML = `<span>${escapeHtml(title)}</span>`;
  if (count !== undefined) {
    const c = document.createElement("span");
    c.className = "v-section-n"; c.textContent = count.toLocaleString();
    h.appendChild(c);
  }
  return h;
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
    box.appendChild(codeBlock(JSON.stringify(data, null, 2)));
    return box;
  }
  const scalars = [], tables = [], rest = {};
  for (const [k, v] of Object.entries(data)) {
    if (v === null || ["string", "number", "boolean"].includes(typeof v)) scalars.push([prettyKey(k), v]);
    else if (isRecordList(v)) tables.push([k, v]);
    else if (Array.isArray(v) && v.every((x) => x === null || typeof x !== "object")) {
      scalars.push([prettyKey(k), v.length ? v.join(", ") : "none"]);
    } else rest[k] = v;
  }
  if (scalars.length) box.appendChild(factList(scalars));
  for (const [k, rows] of tables) {
    box.append(sectionHead(prettyKey(k), rows.length), recordTable(rows));
  }
  if (Object.keys(rest).length) box.appendChild(codeBlock(JSON.stringify(rest, null, 2)));
  return box;
}
function recordTable(rows) {
  const cols = columnsOf(rows);
  return dataTable({
    columns: cols,
    rows: rows.map((r) => cols.map((c) => (r[c] === undefined ? null : r[c]))),
    shape: [rows.length, cols.length],
    truncated: false,
  });
}
function codeBlock(text) {
  const p = document.createElement("pre");
  p.className = "v-json"; p.textContent = text;
  return p;
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
  initPanel(); initMenu(); initPops();
  labelTheme(currentTheme());   // ICON exists by now, so the switch can be drawn
  await loadChats();
  // Always a new conversation. Opening the page is not the same as asking to
  // carry on with something, and resuming the last one put a person back in the
  // middle of work they may have finished days ago, with its studies and domain
  // still in scope. Everything earlier is one click away in the chat list.
  await newChat(false);
  setSendEnabled();
}
boot();
