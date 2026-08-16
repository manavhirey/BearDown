/* CoachBear dashboard — vanilla JS, no dependencies.
   All model/CSV text is rendered via textContent (never innerHTML with data). */
"use strict";

const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const ABBR = { Monday: "MON", Tuesday: "TUE", Wednesday: "WED", Thursday: "THU", Friday: "FRI", Saturday: "SAT", Sunday: "SUN" };
const KIND_VAR = { lift: "--k-lift", run: "--k-run", bike: "--k-bike", rest: "--k-rest", other: "--k-rest" };
const KIND_LABEL = { lift: "Lift", run: "Run", bike: "Bike", rest: "Rest", other: "Session" };
const DAY_HEADER_TEST = /^\s*(?:[#*]+\s*)*(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s*\[[^\]\n]+\]/m;
const POLL_MS = 2500;

/* state.strava caches /api/strava/status; null forces a refetch */
const state = {
  status: null,
  plans: [],          // list from /api/plans
  week: null,         // selected week key
  plan: null,         // detail for selected week (or null if none stored)
  planError: null,
  logs: null,
  job: null,          // active job object
  view: "plan",
};

/* ── tiny DOM + API helpers ─────────────────────────── */
const $ = (s) => document.querySelector(s);

function el(tag, attrs = {}, ...children) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") n.className = v;
    else if (k === "text") n.textContent = v;
    else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined) n.setAttribute(k, v);
  }
  for (const c of children) if (c) n.append(c);
  return n;
}

async function api(path, opts = {}) {
  // relative to the page URL so the app works behind path-prefix proxies
  const res = await fetch(path.replace(/^\/+/, ""), {
    headers: opts.body ? { "Content-Type": "application/json" } : {},
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  let data = null;
  try { data = await res.json(); } catch { /* non-JSON error body */ }
  if (!res.ok && res.status !== 202 && res.status !== 409) {
    throw new Error((data && data.error) || `${res.status} ${res.statusText}`);
  }
  return { status: res.status, data };
}

let toastTimer = null;
function toast(msg, ms = 4000) {
  const t = $("#toast");
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, ms);
}

/* ── ISO week math (client side) ────────────────────── */
function mondayOf(weekKey) {
  const m = /^(\d{4})-W(\d{2})$/.exec(weekKey);
  if (!m) return null;
  const jan4 = new Date(Date.UTC(+m[1], 0, 4));
  const week1Mon = new Date(jan4);
  week1Mon.setUTCDate(jan4.getUTCDate() - ((jan4.getUTCDay() + 6) % 7));
  const d = new Date(week1Mon);
  d.setUTCDate(week1Mon.getUTCDate() + (+m[2] - 1) * 7);
  return d;
}

function weekKeyOf(dateUTC) {
  const d = new Date(Date.UTC(dateUTC.getUTCFullYear(), dateUTC.getUTCMonth(), dateUTC.getUTCDate()));
  d.setUTCDate(d.getUTCDate() + 4 - ((d.getUTCDay() + 6) % 7 + 1)); // nearest Thursday
  const year = d.getUTCFullYear();
  const jan1 = new Date(Date.UTC(year, 0, 1));
  const week = Math.ceil(((d - jan1) / 86400000 + 1) / 7);
  return `${year}-W${String(week).padStart(2, "0")}`;
}

function weekStep(weekKey, deltaWeeks) {
  const mon = mondayOf(weekKey);
  mon.setUTCDate(mon.getUTCDate() + deltaWeeks * 7);
  return weekKeyOf(mon);
}

function weekDates(weekKey) {
  const mon = mondayOf(weekKey);
  if (!mon) return "";
  const sun = new Date(mon);
  sun.setUTCDate(mon.getUTCDate() + 6);
  const f = (d) => d.toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
  return `${f(mon)} – ${f(sun)}, ${sun.getUTCFullYear()}`;
}

/* ── data loading ───────────────────────────────────── */
async function loadStatus() {
  state.status = (await api("/api/status")).data;
}

async function loadPlans() {
  state.plans = (await api("/api/plans")).data || [];
}

async function loadPlan(week) {
  state.planError = null;
  const { status, data } = await api(`/api/plans/${week}`).catch((e) => {
    state.planError = e.message;
    return { status: 0, data: null };
  });
  state.plan = status === 200 ? data : null;
}

/* ── navigation ─────────────────────────────────────── */
function setView(view) {
  state.view = view;
  for (const btn of document.querySelectorAll(".nav-btn")) {
    btn.toggleAttribute("aria-current", btn.dataset.view === view);
    if (btn.dataset.view === view) btn.setAttribute("aria-current", "page");
  }
  for (const sec of document.querySelectorAll(".view")) sec.hidden = true;
  $(`#view-${view}`).hidden = false;
  render();
}

async function selectWeek(week) {
  state.week = week;
  await loadPlan(week);
  render();
}

/* ── render: plan view ──────────────────────────────── */
function render() {
  renderBadges();
  if (state.view === "plan") renderPlan();
  else if (state.view === "coach") renderCoach();
  else if (state.view === "history") renderHistory();
  else if (state.view === "log") renderLog();
}

function renderBadges() {
  const mode = $("#mode-badge");
  if (state.status) {
    mode.hidden = false;
    mode.textContent = state.status.mock ? "mock mode" : "live · " + state.status.agent;
  }
  const jb = $("#job-badge");
  if (state.job && state.job.status === "running") {
    jb.hidden = false;
    $("#job-badge-text").textContent = `${state.job.kind} ${state.job.week}`;
  } else jb.hidden = true;
}

function renderPlan() {
  const week = state.week;
  $("#week-num").textContent = week ? week.slice(5) : "W—";
  $("#week-dates").textContent = week ? weekDates(week) : "";
  const isCurrent = state.status && week === state.status.current_week;
  $("#plan-eyebrow").textContent = isCurrent ? "TRAINING WEEK · CURRENT" : "TRAINING WEEK";

  const actions = $("#week-actions");
  actions.replaceChildren(
    el("button", { class: "btn btn-quiet", "aria-label": "Previous week", onclick: () => selectWeek(weekStep(week, -1)) }, "◀"),
    el("button", { class: "btn btn-quiet", "aria-label": "Next week", onclick: () => selectWeek(weekStep(week, 1)) }, "▶"),
    el("button", {
      class: "btn btn-honey",
      disabled: (state.job && state.job.status === "running") ? "" : null,
      onclick: () => generate(week),
    }, state.plan ? "Regenerate" : "Generate plan"),
  );

  const band = $("#band");
  const body = $("#plan-body");
  body.replaceChildren();

  if (state.job && state.job.status === "running" && state.job.kind === "generate" && state.job.week === week) {
    band.replaceChildren();
    body.append(el("div", { class: "empty" },
      el("div", { text: "Coach Bear is building this week's plan — reading the program, your last week, and your logs." }),
      el("div", { class: "plan-meta", text: `started ${state.job.started_at} · this can take several minutes` }),
    ));
    return;
  }

  if (state.planError && !state.plan) {
    band.replaceChildren();
    body.append(el("div", { class: "error-box", text: state.planError }));
  }

  if (!state.plan) {
    band.replaceChildren();
    body.append(el("div", { class: "empty" },
      el("div", { text: `No plan stored for ${week || "this week"} yet.` }),
      el("div", { text: "Generate one and Coach Bear will build it from the PPL program, your paces, and last week's numbers." }),
      el("button", { class: "btn btn-honey", onclick: () => generate(week) }, "Generate this week"),
    ));
    if (state.job && state.job.status === "error") body.append(el("div", { class: "error-box", text: `Last job failed: ${state.job.error}` }));
    return;
  }

  const parsed = state.plan.parsed || { days: [] };
  const done = (state.plan.meta && state.plan.meta.done) || {};

  // signature: the week strip — day, date, kind bar, done fill, today ring
  const weekMon = mondayOf(week);
  band.replaceChildren(...parsed.days.map((d) => {
    const dayIdx = DAYS.indexOf(d.day);
    let dateNum = "";
    if (weekMon && dayIdx > -1) {
      const dt = new Date(weekMon);
      dt.setUTCDate(weekMon.getUTCDate() + dayIdx);
      dateNum = String(dt.getUTCDate());
    }
    const seg = el("button", {
      class: "band-seg" + (done[d.day] ? " done" : "") + (isCurrent && DAYS[(new Date().getDay() + 6) % 7] === d.day ? " today" : ""),
      role: "tab",
      "aria-label": `${d.day}: ${d.type}${done[d.day] ? " (done)" : ""}`,
      onclick: () => {
        const card = document.getElementById(`day-${d.day}`);
        if (card) card.scrollIntoView({ behavior: "smooth", block: "start" });
      },
    },
      el("span", { class: "d", text: ABBR[d.day] || d.day }),
      el("span", { class: "n", text: dateNum }),
      el("span", { class: "k" }));
    seg.style.setProperty("--seg", `var(${KIND_VAR[d.kind] || "--k-rest"})`);
    return seg;
  }));

  if (parsed.days.length === 0) {
    body.append(el("pre", { class: "raw-lines", text: state.plan.markdown }));
    return;
  }

  parsed.days.forEach((d, i) => body.append(dayCard(d, done, week, i)));

  if (parsed.summary) {
    body.append(el("div", { class: "summary-card" },
      el("h2", { text: "Weekly summary" }),
      el("pre", { text: parsed.summary }),
    ));
  }
  const meta = state.plan.meta || {};
  const bits = [];
  if (meta.generated_at) bits.push(`generated ${meta.generated_at}`);
  if (typeof meta.cost_usd === "number") bits.push(`$${meta.cost_usd.toFixed(2)}`);
  if (!parsed.complete) bits.push("⚠ plan is missing days — check the raw text via Regenerate or Coach");
  if (bits.length) body.append(el("div", { class: "plan-meta", text: bits.join(" · ") }));
  if (state.job && state.job.status === "error") body.append(el("div", { class: "error-box", text: `Last job failed: ${state.job.error}` }));
}

function dayCard(d, done, week, index = 0) {
  const main = el("div", { class: "day-main" });

  if (d.kind === "rest" && d.exercises.length === 0 && Object.keys(d.fields).length === 0) {
    main.append(el("p", { class: "rest-line", text: d.lines.join(" ") || "Rest — full recovery" }));
  } else if (d.exercises.length > 0) {
    for (const ex of d.exercises) {
      const dash = ex.text.indexOf(" — ");
      let rx = ex.text, name = "", note = "";
      if (dash > -1) {
        rx = ex.text.slice(0, dash);
        let rest = ex.text.slice(dash + 3);
        const paren = rest.indexOf(" (");
        if (paren > -1) { name = rest.slice(0, paren); note = rest.slice(paren + 1); }
        else name = rest;
      }
      // name leads; the mono prescription and coach's note sit beneath it
      const detail = el("div", {},
        el("div", { class: "ex-name", text: name || rx }),
        name ? el("div", { class: "ex-rx", text: rx }) : null,
        note ? el("div", { class: "ex-note", text: note }) : null,
      );
      if (ex.warmup) detail.append(el("div", { class: "ex-warmup", text: ex.warmup }));
      main.append(el("div", { class: "ex-line" },
        el("span", { class: "ex-num", text: String(ex.num) }),
        detail,
      ));
    }
  }
  if (Object.keys(d.fields).length > 0) {
    main.append(el("div", { class: "cardio-fields" },
      ...Object.entries(d.fields).map(([k, v]) =>
        el("div", { class: "cf" }, el("span", { class: "l", text: k }), el("span", { class: "v", text: v }))),
    ));
    if (d.splits.length) main.append(el("ul", { class: "splits" }, ...d.splits.map((s) => el("li", { text: s }))));
  }
  if (d.exercises.length === 0 && Object.keys(d.fields).length === 0 && d.kind !== "rest") {
    main.append(el("pre", { class: "raw-lines", text: d.lines.join("\n") }));
  }

  const badge = el("span", { class: "kind-badge", text: KIND_LABEL[d.kind] });
  badge.style.setProperty("--seg", `var(${KIND_VAR[d.kind] || "--sage"})`);

  const toggle = el("button", {
    class: "done-toggle",
    "aria-pressed": done[d.day] ? "true" : "false",
    "aria-label": `Mark ${d.day} done`,
    title: "Mark done",
    onclick: async (e) => {
      const now = e.currentTarget.getAttribute("aria-pressed") !== "true";
      try {
        const res = await api(`/api/plans/${week}/done`, { method: "POST", body: { day: d.day, done: now } });
        state.plan.meta.done = res.data.done;
        render();
      } catch (err) { toast(`Couldn't save: ${err.message}`); }
    },
  }, "✓");

  const card = el("article", { class: "day-card" + (done[d.day] ? " done" : ""), id: `day-${d.day}` },
    el("div", { class: "day-side" },
      el("div", { class: "day-name", text: ABBR[d.day] }),
      badge,
      el("div", { class: "day-type", text: d.type }),
      ["lift", "run", "bike"].includes(d.kind)
        ? el("button", { class: "btn btn-quiet btn-sm log-day-btn", type: "button",
            onclick: () => openLogModal(prefillFromDay(d, week)) }, "Log workout")
        : null,
    ),
    main,
    toggle,
  );
  card.style.setProperty("--seg", `var(${KIND_VAR[d.kind] || "--k-rest"})`);
  card.style.animationDelay = `${Math.min(index * 55, 400)}ms`;
  return card;
}

/* ── generate + jobs ────────────────────────────────── */
async function generate(week) {
  if (state.plan && !confirm(`Regenerate ${week}? The stored plan is replaced (chat history is kept).`)) return;
  try {
    const { status, data } = await api("/api/generate", { method: "POST", body: { week } });
    if (status === 409) { toast(data.error); state.job = data.job; }
    else { state.job = data.job; toast(`Coach Bear is on it — generating ${week}.`); }
    render();
    pollJob();
  } catch (err) { toast(`Generate failed: ${err.message}`, 6000); }
}

let pollTimer = null;
function pollJob() {
  clearTimeout(pollTimer);
  if (!state.job || state.job.status !== "running") return;
  pollTimer = setTimeout(async () => {
    try {
      const { data } = await api(`/api/jobs/${state.job.id}`);
      if (data) state.job = data;
    } catch { /* server briefly unreachable; keep polling */ }
    if (state.job.status === "running") { renderBadges(); pollJob(); return; }
    if (state.job.status === "done") {
      toast(state.job.kind === "generate" ? `Plan for ${state.job.week} saved.` : "Coach Bear replied.");
      await loadPlans();
      if (state.job.week === state.week) await loadPlan(state.week);
    } else if (state.job.status === "error") {
      toast(`${state.job.kind} failed — see details in the view.`, 6000);
      if (state.job.week === state.week) await loadPlan(state.week);
    }
    render();
  }, POLL_MS);
}

/* ── coach view ─────────────────────────────────────── */
function renderCoach() {
  $("#coach-title").textContent = state.week ? `Coach Bear · ${state.week}` : "Coach Bear";
  const log = $("#chat-log");
  log.replaceChildren();

  if (!state.plan) {
    log.append(el("div", { class: "empty" },
      el("div", { text: `No plan for ${state.week} yet — generate one first, then bring your questions.` })));
    setChatEnabled(false);
    return;
  }

  const chat = (state.plan.meta && state.plan.meta.chat) || [];
  if (chat.length === 0) {
    log.append(el("div", { class: "empty", text: "Ask about swaps, soreness, pacing, or loads. If the coach revises the plan, you can save it from here." }));
  }
  for (const m of chat) log.append(chatMsg(m));

  if (state.job && state.job.status === "running" && state.job.kind === "chat" && state.job.week === state.week) {
    log.append(el("div", { class: "msg coach thinking" },
      el("div", { class: "who", text: "coach bear" }),
      el("div", { class: "body", text: "thinking…" })));
    setChatEnabled(false);
  } else {
    setChatEnabled(true);
  }
  if (state.job && state.job.status === "error" && state.job.kind === "chat") {
    log.append(el("div", { class: "error-box", text: state.job.error }));
  }
  log.scrollTop = log.scrollHeight;
}

/* **bold** spans in coach prose, built from text nodes — never innerHTML */
function richBody(text) {
  const body = el("div", { class: "body" });
  const parts = text.split(/\*\*([^*\n][^*]*)\*\*/g);
  parts.forEach((p, i) => {
    if (i % 2) body.append(el("strong", { text: p }));
    else if (p) body.append(document.createTextNode(p));
  });
  return body;
}

function chatMsg(m) {
  const isPlan = m.role === "coach" && DAY_HEADER_TEST.test(m.text);
  const plainBody = m.role === "user" || isPlan;
  const box = el("div", { class: `msg ${m.role === "user" ? "user" : "coach"}` },
    el("div", { class: "who", text: m.role === "user" ? "you" : "coach bear" }),
    plainBody ? el("div", { class: "body" + (isPlan ? " mono" : ""), text: m.text }) : richBody(m.text),
  );
  if (isPlan) {
    box.append(el("button", {
      class: "btn save-plan",
      onclick: async () => {
        try {
          await api(`/api/plans/${state.week}/replace`, { method: "POST", body: { markdown: m.text } });
          toast(`Saved as the ${state.week} plan.`);
          await loadPlan(state.week);
          render();
        } catch (err) { toast(`Couldn't save: ${err.message}`, 6000); }
      },
    }, "Save as this week's plan"));
  }
  return box;
}

function setChatEnabled(on) {
  $("#chat-input").disabled = !on;
  $("#chat-send").disabled = !on;
}

async function sendChat(ev) {
  ev.preventDefault();
  const input = $("#chat-input");
  const message = input.value.trim();
  if (!message || !state.week) return;
  try {
    const { status, data } = await api("/api/chat", { method: "POST", body: { week: state.week, message } });
    if (status === 409) { toast(data.error, 5000); return; }
    if (data.error) { toast(data.error, 5000); return; }
    state.job = data.job;
    input.value = "";
    if (state.plan) {
      state.plan.meta.chat = state.plan.meta.chat || [];
      state.plan.meta.chat.push({ role: "user", text: message, ts: "" }); // optimistic; server persists on completion
    }
    render();
    pollJob();
  } catch (err) { toast(`Send failed: ${err.message}`, 6000); }
}

/* ── history view ───────────────────────────────────── */
function renderHistory() {
  const body = $("#history-body");
  body.replaceChildren();
  if (state.plans.length === 0) {
    body.append(el("div", { class: "empty", text: "No weeks stored yet. Generated plans will collect here, one per ISO week." }));
    return;
  }
  for (const p of state.plans) {
    const dots = el("span", { class: "dots", "aria-label": `${p.days_done} of 7 days done` });
    for (let i = 0; i < 7; i++) dots.append(el("i", { class: i < p.days_done ? "on" : "" }));
    body.append(el("button", {
      class: "week-row",
      onclick: async () => { await selectWeek(p.week); setView("plan"); },
    },
      el("span", { class: "wk", text: p.week.slice(5) + " · " + p.week.slice(0, 4) }),
      el("span", { class: "dates", text: p.label }),
      dots,
      p.chat_count ? el("span", { class: "chats", text: `${p.chat_count} msgs` }) : null,
    ));
  }
}

/* ── training log view ──────────────────────────────── */
async function renderLog() {
  renderStravaButton();
  const body = $("#log-body");
  if (!state.logs) {
    body.replaceChildren(el("div", { class: "empty", text: "Reading the gym log export…" }));
    try { state.logs = (await api("/api/logs")).data; }
    catch (err) { body.replaceChildren(el("div", { class: "error-box", text: err.message })); return; }
  }
  const L = state.logs;
  body.replaceChildren();
  if (!L.available) {
    body.append(el("div", { class: "empty", text: `Training log unavailable: ${L.reason}` }));
    return;
  }
  const s = L.stats;
  const top = (s.top_exercises_30d && s.top_exercises_30d[0]) || null;
  body.append(el("div", { class: "tiles" },
    tile(String(s.sessions_last_30d), "sessions · last 30d", s.data_through ? `data through ${s.data_through}` : ""),
    tile(String(s.sets_last_30d), "working sets · last 30d", ""),
    tile(String(s.total_sessions), "sessions · all time", L.source),
    top ? tile(String(top[1]), "sets · top exercise", top[0]) : null,
  ));

  for (const sess of L.sessions) {
    const det = el("details", { class: "sess" });
    const canDelete = sess.key || sess.cardio_id;
    det.append(el("summary", {},
      el("span", { class: "date", text: sess.start }),
      el("span", { class: "nm", text: sess.name }),
      sess.duration_min ? el("span", { class: "dur", text: `${sess.duration_min} min` }) : null,
      canDelete ? el("button", { class: "sess-del", type: "button", title: "Delete entry",
        onclick: async (e) => {
          e.preventDefault();
          e.stopPropagation();
          if (!confirm(`Delete "${sess.name}" (${sess.start})? This removes it from the database.`)) return;
          try {
            const path = sess.cardio_id
              ? `/api/workouts/cardio/${sess.cardio_id}`
              : `/api/workouts/lift/${encodeURIComponent(sess.key)}`;
            await api(path, { method: "DELETE" });
            state.logs = null;
            toast("Entry deleted.");
            renderLog();
          } catch (err) { toast(`Delete failed: ${err.message}`); }
        } }, "×") : null,
    ));
    const inner = el("div", { class: "sess-body" });
    for (const ex of sess.exercises) {
      const sets = ex.sets.map((x) => `${x.weight || "—"}×${x.reps || "—"}`).join("  ");
      const cardio = ex.cardio.map((c) =>
        [c.distance && `${c.distance} dist`, c.duration_s && `${Math.round(c.duration_s / 60)} min`, c.kcal && `${c.kcal} kcal`]
          .filter(Boolean).join(" · ")).join("  ");
      inner.append(el("div", { class: "sess-ex" },
        el("div", { class: "exnm", text: ex.name }),
        el("div", { class: "exsets", text: sets || cardio || "—" }),
      ));
    }
    det.append(inner);
    body.append(det);
  }
}

function tile(num, label, sub) {
  return el("div", { class: "tile" },
    el("div", { class: "num", text: num }),
    el("div", { class: "lbl", text: label }),
    sub ? el("div", { class: "sub", text: sub }) : null,
  );
}

/* ── workout logging ────────────────────────────────── */
const CARDIO_KINDS = ["easy", "intervals", "long", "zone2", "recovery", "other"];
const RX_RE = /^(\d+)\s*x\s*(\d+)(?:\s*[-–]\s*\d+)?\s*reps?\s*@\s*(?:(\d+(?:\.\d+)?)\s*lb)?/i;

function todayISO() { return new Date().toISOString().slice(0, 10); }

function setRow(pre = {}) {
  return el("div", { class: "set-row" },
    el("input", { class: "in-weight", type: "number", step: "0.5", min: "0", placeholder: "lb", value: pre.weight_lb ?? "" }),
    el("span", { class: "x", text: "×" }),
    el("input", { class: "in-reps", type: "number", min: "1", placeholder: "reps", value: pre.reps ?? "" }),
    el("input", { class: "in-notes", type: "text", placeholder: "notes", value: pre.notes ?? "" }),
    el("button", { class: "row-del", type: "button", title: "Remove set",
      onclick: (e) => e.currentTarget.closest(".set-row").remove() }, "×"),
  );
}

function exerciseBlock(pre = {}) {
  const sets = el("div", { class: "sets" },
    ...((pre.sets && pre.sets.length) ? pre.sets : [{}]).map(setRow));
  return el("div", { class: "ex-block" },
    el("div", { class: "ex-head" },
      el("input", { class: "in-exname", type: "text", placeholder: "Exercise name", value: pre.name ?? "" }),
      el("button", { class: "row-del", type: "button", title: "Remove exercise",
        onclick: (e) => e.currentTarget.closest(".ex-block").remove() }, "×"),
    ),
    sets,
    el("button", { class: "btn btn-quiet btn-sm", type: "button", onclick: () => {
      const rows = sets.querySelectorAll(".set-row");
      const last = rows[rows.length - 1];
      sets.append(setRow(last
        ? { weight_lb: last.querySelector(".in-weight").value, reps: last.querySelector(".in-reps").value }
        : {}));
    } }, "+ set"),
  );
}

/* Pre-fill payload from a parsed plan day (see dayCard's "Log this workout"). */
function prefillFromDay(d, week) {
  const dayIdx = DAYS.indexOf(d.day);
  const mon = mondayOf(week);
  const dt = new Date(mon);
  dt.setUTCDate(mon.getUTCDate() + Math.max(dayIdx, 0));
  const date = dt.toISOString().slice(0, 10);

  if (d.kind === "lift") {
    const exercises = d.exercises.map((ex) => {
      const dash = ex.text.indexOf(" — ");
      let rx = ex.text, name = ex.text;
      if (dash > -1) {
        rx = ex.text.slice(0, dash);
        const rest = ex.text.slice(dash + 3);
        const paren = rest.indexOf(" (");
        name = paren > -1 ? rest.slice(0, paren) : rest;
      }
      const m = RX_RE.exec(rx.trim());
      const nSets = m ? Math.min(+m[1], 10) : 1;
      return {
        name: name.trim(),
        sets: Array.from({ length: nSets }, () => ({ weight_lb: m && m[3] ? m[3] : "", reps: m ? m[2] : "" })),
      };
    });
    return { mode: "lift", date, workout_name: d.type, exercises };
  }
  const t = d.type.toLowerCase();
  const kind = t.includes("interval") ? "intervals" : t.includes("long") ? "long"
    : t.includes("zone") ? "zone2" : t.includes("recovery") ? "recovery"
    : t.includes("easy") ? "easy" : "other";
  const num = (s) => { const m = /(\d+(?:\.\d+)?)/.exec(s || ""); return m ? m[1] : ""; };
  return { mode: d.kind === "bike" ? "bike" : "run", date, kind,
    distance_mi: num(d.fields.Distance), duration_min: num(d.fields["Approx Time"]) };
}

function openLogModal(prefill = null) {
  const dlg = $("#log-modal");
  let mode = (prefill && prefill.mode) || "lift";
  const err = el("div", { class: "form-err" });
  const fields = el("div", { class: "log-fields" });
  const dateIn = el("input", { type: "date", class: "in-date", value: (prefill && prefill.date) || todayISO() });

  let exWrap = null;   // lift mode
  let cardio = {};     // cardio mode inputs

  function buildFields() {
    fields.replaceChildren();
    err.textContent = "";
    if (mode === "lift") {
      exWrap = el("div", { class: "ex-wrap" },
        ...((prefill && prefill.mode === "lift" && prefill.exercises) ? prefill.exercises : [{}]).map(exerciseBlock));
      fields.append(
        el("label", { class: "fld" }, el("span", { text: "Workout name" }),
          el("input", { class: "in-wname", type: "text", placeholder: "Push #1",
            value: (prefill && prefill.workout_name) || "" })),
        exWrap,
        el("button", { class: "btn btn-quiet btn-sm", type: "button",
          onclick: () => exWrap.append(exerciseBlock()) }, "+ exercise"),
      );
    } else {
      const p = (prefill && prefill.mode === mode) ? prefill : {};
      cardio = {
        kind: el("select", { class: "in-kind" },
          ...CARDIO_KINDS.map((k) => {
            const o = el("option", { value: k, text: k });
            if (k === (p.kind || "easy")) o.setAttribute("selected", "");
            return o;
          })),
        distance: el("input", { type: "number", step: "0.1", min: "0", placeholder: "mi", value: p.distance_mi ?? "" }),
        duration: el("input", { type: "number", step: "1", min: "0", placeholder: "min", value: p.duration_min ?? "" }),
        pace: el("input", { type: "text", placeholder: "12:30/mi (optional)" }),
        notes: el("input", { type: "text", placeholder: "notes (optional)" }),
      };
      fields.append(
        el("label", { class: "fld" }, el("span", { text: "Kind" }), cardio.kind),
        el("div", { class: "fld-row" },
          el("label", { class: "fld" }, el("span", { text: "Distance (mi)" }), cardio.distance),
          el("label", { class: "fld" }, el("span", { text: "Duration (min)" }), cardio.duration)),
        el("label", { class: "fld" }, el("span", { text: "Pace" }), cardio.pace),
        el("label", { class: "fld" }, el("span", { text: "Notes" }), cardio.notes),
      );
    }
  }

  const tabs = el("div", { class: "mode-tabs" }, ...["lift", "run", "bike"].map((m) => {
    const b = el("button", { class: "mode-tab" + (m === mode ? " on" : ""), type: "button", onclick: () => {
      mode = m;
      tabs.querySelectorAll(".mode-tab").forEach((t, i) => t.classList.toggle("on", ["lift", "run", "bike"][i] === m));
      buildFields();
    } }, KIND_LABEL[m]);
    return b;
  }));

  async function submit() {
    err.textContent = "";
    try {
      let path, body;
      if (mode === "lift") {
        const exercises = [...exWrap.querySelectorAll(".ex-block")].map((b) => ({
          name: b.querySelector(".in-exname").value.trim(),
          sets: [...b.querySelectorAll(".set-row")].map((r) => ({
            weight_lb: r.querySelector(".in-weight").value || null,
            reps: r.querySelector(".in-reps").value,
            notes: r.querySelector(".in-notes").value.trim() || null,
          })),
        })).filter((x) => x.name);
        path = "/api/workouts/lift";
        body = { date: dateIn.value, workout_name: fields.querySelector(".in-wname").value.trim(), exercises };
      } else {
        path = "/api/workouts/cardio";
        body = { date: dateIn.value, activity: mode, kind: cardio.kind.value,
          distance_mi: cardio.distance.value || null, duration_min: cardio.duration.value || null,
          avg_pace: cardio.pace.value.trim() || null, notes: cardio.notes.value.trim() || null };
      }
      await api(path, { method: "POST", body });
      dlg.close();
      toast("Logged ✓");
      state.logs = null;
      if (state.view === "log") renderLog();
    } catch (e2) {
      err.textContent = e2.message;
    }
  }

  dlg.replaceChildren(
    el("div", { class: "log-form" },
      el("div", { class: "log-form-head" },
        el("h2", { text: prefill ? "Log this workout" : "Log a workout" }),
        el("button", { class: "row-del", type: "button", title: "Close", onclick: () => dlg.close() }, "×"),
      ),
      tabs,
      el("label", { class: "fld" }, el("span", { text: "Date" }), dateIn),
      fields,
      err,
      el("div", { class: "log-form-foot" },
        el("button", { class: "btn btn-quiet", type: "button", onclick: () => dlg.close() }, "Cancel"),
        el("button", { class: "btn btn-honey", type: "button", onclick: submit }, "Save workout"),
      ),
    ),
  );
  buildFields();
  dlg.showModal();
}

/* ── strava ─────────────────────────────────────────── */
async function renderStravaButton() {
  const slot = $("#strava-btn-slot");
  if (!state.strava) {
    try { state.strava = (await api("/api/strava/status")).data; }
    catch { slot.replaceChildren(); return; }
  }
  const s = state.strava;
  const btn = el("button", { class: "btn", type: "button" },
    s.connected ? "Sync Strava" : "Connect Strava");
  btn.addEventListener("click", async () => {
    if (!s.connected) {
      if (!s.configured) return openStravaConfigModal();
      location.href = "api/strava/authorize";
      return;
    }
    btn.disabled = true;
    btn.textContent = "Syncing…";
    try {
      const { data } = await api("/api/strava/sync", { method: "POST", body: {} });
      toast(`Strava sync: ${data.new} new ${data.new === 1 ? "activity" : "activities"}`);
      state.strava = null;
      state.logs = null;
      renderLog();
    } catch (err) {
      toast(`Strava sync failed: ${err.message}`, 6000);
      btn.disabled = false;
      btn.textContent = "Sync Strava";
    }
  });
  slot.replaceChildren(btn);
}

function openStravaConfigModal() {
  const dlg = $("#log-modal");
  const err = el("div", { class: "form-err" });
  const idIn = el("input", { type: "text", placeholder: "Client ID", autocomplete: "off" });
  const secretIn = el("input", { type: "password", placeholder: "Client secret", autocomplete: "off" });
  dlg.replaceChildren(
    el("div", { class: "log-form" },
      el("div", { class: "log-form-head" },
        el("h2", { text: "Connect Strava" }),
        el("button", { class: "row-del", type: "button", title: "Close", onclick: () => dlg.close() }, "×"),
      ),
      el("div", { class: "fld" },
        el("span", { text: "Create an API app at strava.com/settings/api with callback domain bear.kunigami.cloud, then paste its credentials. They are stored on your server only." })),
      el("label", { class: "fld" }, el("span", { text: "Client ID" }), idIn),
      el("label", { class: "fld" }, el("span", { text: "Client secret" }), secretIn),
      err,
      el("div", { class: "log-form-foot" },
        el("button", { class: "btn btn-quiet", type: "button", onclick: () => dlg.close() }, "Cancel"),
        el("button", { class: "btn btn-honey", type: "button", onclick: async () => {
          err.textContent = "";
          try {
            await api("/api/strava/config", { method: "POST",
              body: { client_id: idIn.value, client_secret: secretIn.value } });
            location.href = "api/strava/authorize";
          } catch (e2) { err.textContent = e2.message; }
        } }, "Authorize on Strava"),
      ),
    ),
  );
  dlg.showModal();
}

/* ── init ───────────────────────────────────────────── */
async function init() {
  document.querySelectorAll(".nav-btn").forEach((b) =>
    b.addEventListener("click", () => { location.hash = b.dataset.view; }));
  window.addEventListener("hashchange", () => setView(location.hash.slice(1) || "plan"));
  $("#chat-form").addEventListener("submit", sendChat);
  $("#log-add-btn").addEventListener("click", () => openLogModal());
  $("#chat-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("#chat-form").requestSubmit(); }
  });

  try {
    await Promise.all([loadStatus(), loadPlans()]);
  } catch (err) {
    $("#main").prepend(el("div", { class: "error-box", text: `Can't reach the CoachBear server: ${err.message}` }));
    return;
  }

  const stored = new Set(state.plans.map((p) => p.week));
  const st = state.status;
  state.week =
    (stored.has(st.current_week) && st.current_week) ||
    (stored.has(st.suggested_week) && st.suggested_week) ||
    (state.plans[0] && state.plans[0].week) ||
    st.suggested_week;
  await loadPlan(state.week);

  if (st.running_job && st.running_job.status === "running") {
    state.job = st.running_job;
    pollJob();
  }

  const view = ["plan", "coach", "history", "log"].includes(location.hash.slice(1)) ? location.hash.slice(1) : "plan";
  setView(view);
}

init();
