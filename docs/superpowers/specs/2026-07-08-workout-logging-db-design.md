# Workout Logging + Database — Design

Date: 2026-07-08
Status: approved pending user spec review

## Goal

Let the user log workouts (lifts and runs/rides) directly in the dashboard's
training-log section, store all history in a SQLite database (lifting sets, cardio sessions, and a
mirror of past weekly plans), and feed that data — including plan-vs-actual
adherence — to the coach-bear agent so weekly plans use real logged
performance, account for missed workouts, and can consult past plan history.

## Decisions made during brainstorming

1. **Dashboard becomes the primary log source.** One-time import of the
   existing `export_*.csv` history (~3 years); no recurring CSV import or
   dedup logic. The CSV file stays on disk untouched as a backup.
2. **Entry UX: plan-linked + freeform.** Logging can start pre-filled from a
   plan day's prescription, or from a blank form for unplanned/past workouts.
3. **coach-bear access: digest in prompt + direct queries.** Every generation
   prompt carries a bounded server-computed digest; coach-bear can also query
   the database itself for deeper history.
4. **Adherence (user tweak):** the digest includes a plan-vs-actual comparison
   for the previous week so plans adapt to missed workouts. Computed at
   generation time (that is when it influences the next plan), not as a
   scheduled job.

## Storage

`data/coachbear.db` (SQLite, Python stdlib only; directory `data/` created on
first run). Schema versioned with `PRAGMA user_version = 1`.

```sql
CREATE TABLE lifting_sets (
    id            INTEGER PRIMARY KEY,
    session_date  TEXT NOT NULL,             -- YYYY-MM-DD
    session_start TEXT,                      -- YYYY-MM-DD HH:MM (nullable)
    session_end   TEXT,
    workout_name  TEXT,                      -- e.g. "Pull #2"
    exercise      TEXT NOT NULL,
    category      TEXT,                      -- Back, Chest, ...
    set_number    INTEGER,                   -- 1-based within exercise
    weight_lb     REAL,
    reps          INTEGER,
    notes         TEXT,
    source        TEXT NOT NULL DEFAULT 'dashboard'  -- 'csv-import' | 'dashboard'
);
CREATE INDEX idx_lift_date ON lifting_sets(session_date);
CREATE INDEX idx_lift_exercise ON lifting_sets(exercise);

CREATE TABLE cardio_sessions (
    id           INTEGER PRIMARY KEY,
    session_date TEXT NOT NULL,
    activity     TEXT NOT NULL CHECK (activity IN ('run','bike')),
    kind         TEXT,                       -- easy|intervals|long|zone2|recovery|other
    distance_mi  REAL,
    duration_min REAL,
    avg_pace     TEXT,                       -- min/mi for runs; free text ok
    kcal         INTEGER,
    notes        TEXT,
    source       TEXT NOT NULL DEFAULT 'dashboard'
);
CREATE INDEX idx_cardio_date ON cardio_sessions(session_date);

CREATE TABLE weekly_plans (
    week_key     TEXT PRIMARY KEY,          -- ISO week, e.g. 2026-W28
    generated_at TEXT,
    markdown     TEXT NOT NULL,             -- full plan text as emitted
    done_json    TEXT,                      -- completion marks {"Monday": true, ...}
    cost_usd     REAL
);
```

`weekly_plans` is a **write-through mirror** of the existing `plans/<week>.md`
+ `.json` storage, which remains the source of truth for the dashboard UI
(no frontend or endpoint behavior changes from this table). `save_plan()`
upserts the row on every generate/replace; the `/done` toggle endpoint
re-syncs `done_json`. The one-time import also loads all existing plan files.
Purpose: coach-bear can query full plan history (e.g. which Push/Pull/Legs
variant ran in which week, past mileage prescriptions) instead of seeing only
last week's plan text.

A lifting *session* is the group of `lifting_sets` rows sharing
`(session_date, workout_name, session_start)`. No separate sessions table —
this mirrors how the CSV groups today and keeps workout data in the user's
requested two-table shape (the third table, `weekly_plans`, holds plan
history, not workout data).

## Module layout

New file `dashboard/db.py`:
- `connect()` — opens/creates the DB, applies schema if `user_version` is 0.
- Insert/delete/query helpers used by `server.py`.
- `import_csv(path)` — one-time CSV import (idempotent guard: refuses if
  `lifting_sets` already contains rows with `source='csv-import'`).
- `import_plans(plans_dir)` — loads existing `plans/*.md` + sidecars into
  `weekly_plans` (upsert by week_key, safe to re-run).
- `upsert_plan(week_key, markdown, meta)` — called from `save_plan()` and the
  done-toggle path to keep the mirror current; failures are logged and never
  block the file write.
- `build_digest()` — the coach-bear digest (see below).
- CLI: `python3 dashboard/db.py import <csv>` and
  `python3 dashboard/db.py query "SELECT ..."` (read-only: opens the DB in
  SQLite read-only mode so a bad query cannot mutate data). The query CLI is
  what coach-bear uses (no sqlite3 CLI exists on this machine).

`server.py` changes:
- `load_logs()` reads from the DB instead of the CSV (same response shape as
  today, plus cardio sessions rendered alongside lifting sessions, plus `id`s
  so entries can be deleted).
- New endpoints (below).
- `build_generate_prompt()` appends the digest.

## API

- `POST /api/workouts/lift`
  Body: `{date, workout_name, start?, end?, exercises: [{name, category?,
  sets: [{weight_lb, reps, notes?}]}]}` → inserts one row per set. Returns the
  created session (with row ids). Validation: date required and parseable,
  at least one exercise with at least one set, reps integer ≥ 1, weight ≥ 0
  (0 = bodyweight).
- `POST /api/workouts/cardio`
  Body: `{date, activity, kind?, distance_mi?, duration_min?, avg_pace?,
  kcal?, notes?}` → one row. Validation: date + activity required; at least
  one of distance/duration present.
- `DELETE /api/workouts/lift/<session_key>` — deletes all sets of one lifting
  session (`session_key` = url-encoded `date|workout_name|start`).
- `DELETE /api/workouts/cardio/<id>` — deletes one cardio row.
- Errors follow the existing `_error()` JSON convention; body size stays
  under the existing `MAX_BODY` cap.

## Frontend (training-log section + plan view)

1. **Freeform:** "+ Log workout" button in the training-log section → modal
   form. Toggle Lift / Run / Bike. Lift: date, workout name, exercise rows
   each with set rows (weight × reps; "add set" clones the previous set's
   values). Cardio: date, kind, distance, duration, optional pace/notes.
   Save → POST → refresh log list.
2. **Plan-linked:** on plan days with kind lift/run/bike, a "Log this
   workout" button opens the same modal pre-filled from the day's parsed
   prescription. Client-side parser extracts from exercise text like
   `3 x 8 reps @ 70lb — Bench Press (...)`: sets count, reps (range → lower
   bound), weight (calibration brackets `[calibrate: ...]` → empty weight),
   name (text before the first parenthetical). Unparseable lines pre-fill as
   a named exercise with one empty set. Cardio days pre-fill distance/kind
   from the day's fields. Date defaults to that day's date in the plan week.
3. Log entries in the list get a delete control (with confirm).
4. No edit-in-place in v1 — delete and re-add covers corrections (YAGNI).

## coach-bear integration

### Digest (injected into every generate prompt)

`build_digest()` returns a compact plain-text block (target < 2500 chars):

1. **Adherence, last week:** for each day of the previous week's stored plan:
   planned type vs. what the DB shows for that date → `completed` /
   `missed` / `done differently (…)`; plus any logged workouts that matched
   no planned day (`extra`). Matching rule: a lift day matches any lifting
   session on that date; run/bike days match a cardio row of that activity
   on that date (±0 days). Falls back to the existing "done" checkmarks
   when the DB has nothing for that week.
2. **Recent lifting:** per exercise trained in the last 28 days: most recent
   date, top set (max weight × its reps) that day, and number of sessions.
3. **Cardio volume:** per ISO week for the last 4 weeks: run miles, run
   count, bike minutes.

### coach-bear.md updates

- New section "Training Database" documenting the DB path, all three table
  schemas, and the read-only query CLI with example queries (exercise
  history, weekly mileage, past plan lookup from `weekly_plans` — e.g. which
  lift variants ran in recent weeks, replacing guesswork in §5.1 rotation
  tracking).
- Ingest step (§10.1) updated: the prompt digest is the primary log source;
  query the DB directly when deciding a progression that needs more history.
- New adherence rules: a missed lift day → repeat, do not progress that
  slot's loads; a missed long/quality run → do not apply the +10% ramp on a
  phantom baseline (ramp from actual logged volume, which the digest gives);
  the same slot missed 2+ consecutive weeks → restructure the skeleton and
  flag it in the Weekly Summary.

## Error handling

- DB writes use a single connection per request with a `with conn:`
  transaction; a failed insert leaves nothing partial.
- `load_logs()` DB errors degrade to `{"available": false, "reason": ...}`
  exactly like the CSV path does today.
- Digest computation failures never block plan generation — on exception the
  prompt simply omits the digest section (logged to stderr).

## Testing / verification

- Unit-style checks run via a small `dashboard/test_db.py` (plain asserts,
  no framework): schema creation, CSV import row counts vs. source CSV,
  insert/delete round-trip, digest with a synthetic plan+logs fixture
  (verifies missed/completed classification).
- Manual end-to-end after deploy: import real CSV, check `/api/logs` matches
  old CSV view, create a lift + a cardio entry via the UI on
  bear.kunigami.cloud, delete one, generate a plan and confirm the digest
  appears in the prompt (mock mode).

## Deployment

Frontend changes are live on refresh. Backend: run `test_db.py` +
`caddy`-independent local smoke test on a second port first, then restart the
live service (kill -9; systemd `Restart=on-failure` restarts it) and re-verify
`https://bear.kunigami.cloud`. The one-time CSV import runs once after deploy.

## Out of scope (v1)

- Editing existing log entries in place.
- Recurring CSV re-import / dedup.
- A scheduled weekly digest report (digest is computed at generation time).
- Auth changes (basicauth already fronts everything).
