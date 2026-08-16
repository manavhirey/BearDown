# Workout Logging + Database Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dashboard workout logging (plan-linked + freeform) backed by SQLite (lifting_sets, cardio_sessions, weekly_plans), with a plan-vs-actual digest and direct DB query access for coach-bear.

**Architecture:** New `dashboard/db.py` module owns all SQLite access (schema, CRUD, imports, digest, read-only query CLI). `server.py` swaps `load_logs()` to the DB, adds POST/DELETE workout endpoints, mirrors plans into `weekly_plans`, and appends the digest to generation prompts. Frontend adds one modal used by both entry paths. `plans/*.md` files remain the UI source of truth.

**Tech Stack:** Python 3.12 stdlib only (sqlite3, http.server). Vanilla JS frontend. No new dependencies.

## Global Constraints

- DB file: `data/coachbear.db`; schema version via `PRAGMA user_version = 1`.
- Exactly three tables: `lifting_sets`, `cardio_sessions`, `weekly_plans` (columns per spec).
- `source` column values: `'csv-import'` | `'dashboard'`.
- CSV import is one-time; refuses to run twice (guard on existing `source='csv-import'` rows).
- Digest target < 2500 chars; digest failure must never block plan generation.
- coach-bear query access is READ-ONLY (`file:...?mode=ro` URI).
- `/api/logs` response keeps today's shape (`available, source, stats, sessions[]`) so the existing render keeps working; sessions gain `key`/`cardio_id` for deletion.
- **No git repo:** per-task commit steps are replaced by verification steps (run tests, smoke-check endpoint). Do not `git init`.
- Live service: `coachbear-dashboard` (systemd, port 8737). Backend deploys via kill → auto-restart; test on port 8799 first.

---

### Task 1: db.py — schema, connect, insert/delete/query helpers, tests

**Files:**
- Create: `dashboard/db.py`
- Test: `dashboard/test_db.py` (plain asserts, run with `python3 dashboard/test_db.py`; uses a temp-dir DB, never `data/coachbear.db`)

**Interfaces (Produces):**
- `connect(db_path: Path = DB_PATH) -> sqlite3.Connection` — creates parent dir, applies schema once (user_version guard), `row_factory = sqlite3.Row`.
- `insert_lift_session(conn, payload: dict) -> dict` — payload `{date, workout_name, start?, end?, exercises: [{name, category?, sets: [{weight_lb, reps, notes?}]}]}`; one row per set (`set_number` 1-based per exercise); returns `{key, date, workout_name, rows: n}` where `key = f"{date}|{workout_name}|{start or ''}"`. Raises `ValueError` on: missing/invalid date (YYYY-MM-DD), no exercises, exercise without sets, reps < 1 or non-int, weight < 0.
- `insert_cardio(conn, payload: dict) -> dict` — payload `{date, activity, kind?, distance_mi?, duration_min?, avg_pace?, kcal?, notes?}`; returns row as dict with `id`. Raises `ValueError` unless date valid, activity in ('run','bike'), and at least one of distance_mi/duration_min.
- `delete_lift_session(conn, key: str) -> int` (rows deleted; splits key on `|` into date, workout_name, start; start `''` matches NULL/empty)
- `delete_cardio(conn, cardio_id: int) -> int`
- `fetch_log_view(conn, limit=40) -> dict` — the full `/api/logs` payload: lifting sessions grouped by `(session_date, workout_name, session_start)` + cardio rows as single-exercise sessions (name `"Run — {kind}"` / `"Bike — {kind}"`, exercise `{name: activity, category: "Cardio", sets: [], cardio: [{distance, duration_s, kcal}]}`, `cardio_id` set); sessions sorted newest-first; `stats` computed as today (total_sessions, data_through, sessions_last_30d, sets_last_30d, top_exercises_30d) with `source: "coachbear.db"`.

**Steps:**
- [ ] Write `test_db.py` part 1: connect creates all 3 tables + user_version=1; insert_lift_session round-trip (2 exercises × 2 sets → 4 rows, correct set_numbers); insert_cardio round-trip; validation errors raise ValueError (bad date, empty exercises, reps=0, activity='swim', cardio with neither distance nor duration); delete by key removes exactly that session; fetch_log_view shape (keys present, newest first, cardio session rendered).
- [ ] Run: `python3 dashboard/test_db.py` → fails (module missing).
- [ ] Implement `db.py` with SCHEMA constant (spec SQL verbatim incl. 3 indexes), connect, validators, the five functions above.
- [ ] Run tests → all pass.
- [ ] Verify: `python3 -c "import sys; sys.path.insert(0,'dashboard'); import db; print(db.DB_PATH)"`.

### Task 2: db.py — CSV import, plans import/upsert, query CLI

**Files:**
- Modify: `dashboard/db.py`
- Test: `dashboard/test_db.py`

**Interfaces (Produces):**
- `import_csv(conn, csv_path: Path) -> dict` — parses the export CSV exactly like today's `load_logs()` (session = (Workout Start, Name); rows with reps/weight → `lifting_sets` with source='csv-import', set_number by order within exercise; rows with only distance/duration/kcal → `cardio_sessions` (activity guessed from Exercise/Name text: 'bike'|'cycl'|'spin' → bike, else run; Duration seconds → duration_min; source='csv-import')). Returns `{lift_rows, cardio_rows}`. Raises `RuntimeError("csv already imported")` if any `source='csv-import'` row exists.
- `upsert_plan(conn, week_key, markdown, meta: dict) -> None` — INSERT OR REPLACE into weekly_plans (`generated_at`, `cost_usd` from meta; `done_json = json.dumps(meta.get("done") or {})`).
- `import_plans(conn, plans_dir: Path) -> int` — for each `<week>.md` + optional sidecar, upsert; returns count.
- CLI (`python3 dashboard/db.py <cmd>`): `import <csv>`, `import-plans`, `query "SELECT ..."` (read-only connect via `sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)`; prints rows as JSON lines; errors to stderr, exit 1).

**Steps:**
- [ ] Add tests: import a 6-row fixture CSV written to tmp (4 lift rows across 2 sessions + 2 cardio-only rows) → row counts and grouping match; second import raises; upsert_plan then re-upsert with changed done → single row, updated done_json; import_plans on tmp dir with one md+json → 1. Query CLI: subprocess `query "SELECT COUNT(*) ..."` returns JSON; `query "DELETE FROM lifting_sets"` exits nonzero (read-only).
- [ ] Run tests → new ones fail; implement; run → pass.
- [ ] Verify: `python3 dashboard/db.py query "SELECT 1 AS ok"` against the real (auto-created, empty) DB prints `{"ok": 1}`.

### Task 3: db.py — build_digest

**Files:**
- Modify: `dashboard/db.py`
- Test: `dashboard/test_db.py`

**Interfaces (Produces):**
- `build_digest(conn, prev_monday: date, planned_days: list[dict] | None, done_marks: dict | None) -> str` — `planned_days` = parsed prior-week plan days `[{day, kind, type}]` (server supplies from `parse_plan`); `None` → adherence section says "no stored plan for last week".
  Sections (plain text, header lines starting `##`):
  1. `## Adherence — week of {prev_monday}`: per planned day (Mon..Sun date computed from prev_monday + index): `Monday (2026-07-06) — planned Push [lift]: completed` where status is `completed` (lift day: any lifting_sets rows that date; run/bike day: cardio row of that activity that date), `done differently (logged {what})` (some workout logged that date but wrong type), `missed` (nothing logged; if done_marks[day] is true append ` — but marked done manually`), or `rest day` for kind rest. Then `Extra (unplanned): ...` lines for logged sessions on dates with no matching planned day.
  2. `## Recent lifting (28 days)`: per exercise (max 20, ordered by most recent): `Bench Press: last 2026-07-03, top set 70lb x 8, 3 sessions`.
  3. `## Cardio volume by week (4 weeks)`: `2026-W27: runs 2 (7.5 mi), bike 45 min`.
  Truncate whole digest to 2500 chars at a line boundary with trailing `…(truncated)`.

**Steps:**
- [ ] Tests: synthetic prev week (planned lift Mon, run Tue, rest Sat) with DB rows for Mon lift + Wed run → Mon completed, Tue "done differently"… actually Tue run planned, run logged Wed → Tue missed + Wed extra; Sat rest; assert exact status substrings, plus recent-lifting line format and weekly cardio line, and `len(digest) <= 2500`.
- [ ] Run → fail; implement; run → pass.

### Task 4: server.py — DB-backed logs + workout endpoints + plan mirror + digest in prompt

**Files:**
- Modify: `dashboard/server.py` (`import db` after existing imports; `load_logs()`; `save_plan()`; done-toggle handler; `build_generate_prompt()`; `do_POST`; new `do_DELETE`)

**Interfaces (Consumes):** everything from Tasks 1–3. **(Produces):**
- `GET /api/logs` — now `db.fetch_log_view(db.connect())`; on exception returns `{"available": false, "reason": str(e)}`. `_LOG_CACHE` removed (DB is fast; no mtime to key on).
- `POST /api/workouts/lift` → `{ok: true, session: {...}}` (400 with message on ValueError)
- `POST /api/workouts/cardio` → `{ok: true, entry: {...}}`
- `DELETE /api/workouts/lift/<urlencoded key>` and `DELETE /api/workouts/cardio/<int id>` → `{ok: true, deleted: n}` (404 if n == 0)
- `save_plan()` calls `db.upsert_plan` inside try/except (stderr log on failure); done-toggle re-upserts after saving meta.
- `build_generate_prompt()` appends, when digest non-empty: `"Training log digest (actual logged data — use it for §5.3/§5.4 progression, the §4.3.7 mileage ramp, and adherence adjustments):\n<training_digest>\n{digest}\n</training_digest>"`, where digest = `db.build_digest(conn, prev_monday, parse_plan(prev_md)["days"] if prev plan exists else None, done_marks)` wrapped in try/except.

**Steps:**
- [ ] Make each change; keep endpoint bodies thin (parse JSON → db call → `_json`/`_error`).
- [ ] Smoke test on alt port: `python3 dashboard/server.py --port 8799 &`; curl POST lift (2 sets), POST cardio, GET /api/logs shows both + stats, DELETE each, GET shows them gone, POST with reps=0 → 400. Kill test server.
- [ ] Verify digest path: temporary `python3 - <<'EOF'` harness calling `build_generate_prompt` for the week after 2026-W28 and printing it — confirm `<training_digest>` block appears and generation doesn't crash with an empty DB either.

### Task 5: frontend — log modal (freeform + plan-linked) and delete controls

**Files:**
- Modify: `dashboard/static/index.html` (add `<dialog id="log-modal">` before toast; "+ Log workout" button in `#view-log` header)
- Modify: `dashboard/static/app.js` (modal open/build/submit; prescription parser; "Log this workout" button in plan-day rendering; delete buttons + confirm in `renderLog`; `state.logs = null` refresh after mutations)
- Modify: `dashboard/static/style.css` (modal, form rows, delete button styles matching existing tokens)

**Behavior (concrete):**
- Modal fields — mode toggle Lift/Run/Bike. Lift: date (`<input type=date>`, default today), workout name text, exercise blocks: name + category + set rows (weight, reps, notes) with "+ set" (clones previous values) and "+ exercise". Cardio: date, kind select (easy/intervals/long/zone2/recovery/other), distance mi, duration min, pace text, notes.
- Submit → POST to the matching endpoint; on ok: close, toast "Logged ✓", invalidate `state.logs`, re-render log view. On error: inline error text, keep modal open.
- Plan-linked: in the plan day rendering, for kinds lift/run/bike add button "Log this workout" → opens modal pre-filled. Lift prescription parser (regex on `ex.text`): `/^(\d+)\s*x\s*([\d]+)(?:-\d+)?\s*reps?\s*@\s*(?:(\d+(?:\.\d+)?)\s*lb|\[calibrate[^\]]*\])\s*—\s*([^(]+)/i` → sets count, reps (lower bound), weight (empty if calibrate), name (trimmed). Unmatched lines → exercise `{name: text before first '(' or full text, sets: [one empty set]}`. Cardio pre-fill from `day.fields` (Distance → number, kind from day.type keywords). Date = plan-week Monday + day index (`mondayOf(state.week)` helpers already exist).
- Delete: each session `<summary>` gets an `×` button (`sess.key` → lift endpoint, `sess.cardio_id` → cardio endpoint) with `confirm()`.

**Steps:**
- [ ] index.html + app.js + style.css edits.
- [ ] Verify in real browser via Playwright (Chromium at ~/.cache/ms-playwright) against the test-port server: open log view, add freeform lift, see it at top, delete it; open plan view W28, "Log this workout" on a lift day pre-fills correctly.

### Task 6: coach-bear.md — Training Database section + adherence rules

**Files:**
- Modify: `/home/manav/CoachBear/.claude/agents/coach-bear.md`

**Steps:**
- [ ] Append section: DB path, three schemas (short form), read-only CLI usage `python3 dashboard/db.py query "..."`, 3 example queries (exercise history, weekly run mileage, past plan variants from weekly_plans), and rules: digest is primary; query DB before progressing any lift whose digest line is ambiguous; missed lift day → repeat that slot without load progression; missed long/quality run → ramp from actual logged mileage, never plan-text mileage; same slot missed 2+ consecutive weeks → restructure skeleton and flag in Weekly Summary; §5.1 variant rotation should be read from weekly_plans, not memory.

### Task 7: deploy — import real data, restart live service, e2e verify

**Steps:**
- [ ] `python3 dashboard/db.py import "export_Jul 2, 2026.csv"`; `python3 dashboard/db.py import-plans` → sanity: `query "SELECT COUNT(*) FROM lifting_sets"` ≈ CSV data rows; `SELECT week_key FROM weekly_plans"` = 2026-W28.
- [ ] Run full `test_db.py` once more; then `kill -9 $(pgrep -f 'dashboard/server.py.*8737')` → systemd restarts; `curl -u` check `https://bear.kunigami.cloud/api/logs` shows DB-backed stats.
- [ ] Playwright e2e on the live site (with basicauth): log a real-looking test entry, verify, delete it.
- [ ] Update memory + report.
