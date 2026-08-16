# CoachBear Dashboard — Design Spec

Date: 2026-07-04
Status: Approved for implementation (autonomous /goal session; decisions made per project context)

## Purpose

A local dashboard for interacting with the `coach-bear` Claude Code subagent
(`.claude/agents/coach-bear.md`): generate the weekly 7-day hybrid training plan,
store every generated plan by ISO week, browse past weeks, ask Coach Bear follow-up
questions/adjustments, and see recent training history from the gym-log CSV export.

## Constraints discovered in context

- No Node.js on this machine; Python 3.12.3 available → dependency-free Python stdlib server.
- Claude CLI 2.1.201 supports `--agent <name>`, `-p --output-format json` (returns
  `result` text + `session_id`), and `-r/--resume <session_id>` → headless subagent
  invocation and multi-turn chat continuity.
- coach-bear emits plans in a STRICT format (§8 of the agent file): `<Day> [<Type>]`
  headers, numbered lift lines, `Distance/Pace/Approx Time/Splits` cardio blocks,
  `Weekly Summary` at the end → parseable into day cards, with raw-text fallback.
- Training log: `export_*.csv` in project root (Workout Start, Workout End, Exercise,
  Weight, Reps, Notes, Kcal, Distance, Duration, Category, Name, Bodyweight).
- Not a git repo (spec committed only if repo is initialized later).

## Approaches considered

1. **Python stdlib server + vanilla JS SPA (chosen).** Zero dependencies, single-user
   localhost tool, full access to the claude CLI and local files.
2. Claude.ai Artifact — rejected: CSP forbids reaching localhost/CLI; cannot generate
   or store plans.
3. Node/React app — rejected: Node not installed; build step is overhead for a
   single-user tool.

## Architecture

```
CoachBear/
├── dashboard/
│   ├── server.py          # stdlib ThreadingHTTPServer: API + static + jobs + parser
│   ├── static/index.html  # SPA shell
│   ├── static/app.js      # views + API client
│   └── static/style.css
├── plans/
│   ├── 2026-W28.md        # raw plan text exactly as coach-bear emitted it
│   └── 2026-W28.json      # metadata: generated_at, session_id, done-map, chat log
└── docs/superpowers/specs/…
```

### Server (`dashboard/server.py`)

- `ThreadingHTTPServer` on `127.0.0.1:8737` (localhost only; personal tool).
- **API**
  - `GET /api/plans` → `[{week, label, generated_at, has_json, days_done}]`
  - `GET /api/plans/<week>` → `{week, markdown, days: [...], meta}` (parsed + raw)
  - `POST /api/plans/<week>/done` → toggle per-day completion `{day, done}`
  - `POST /api/generate` `{week}` → starts background job; 409 if a job is running
  - `POST /api/chat` `{week, message}` → background job resuming the week's session
  - `GET /api/jobs/<id>` → `{status: running|done|error, result?, error?}`
  - `GET /api/logs` → parsed CSV: recent workouts grouped by session + summary stats
  - `GET /api/status` → weeks stored, claude CLI availability, active job
- **Claude invocation** (cwd = project root so the agent sees the PDF and its memory):
  - Generate: `claude --agent coach-bear -p <prompt> --output-format json
    --allowedTools "Read Glob Grep Task TodoWrite WebSearch WebFetch"`.
    Prompt supplies: target week dates (Mon–Sun), previous week's plan + completion
    map as feedback, and "emit ONLY the plan in your §8 format".
  - Chat: `claude -p --resume <session_id> ...` when the week has a stored session;
    otherwise a fresh `--agent coach-bear` call seeded with the week's plan text.
  - One job at a time (threading.Lock). Timeout 20 min. Job registry in memory;
    results persisted to `plans/` on success.
  - `COACH_MOCK=1` env: substitute the CLI call with the §12 worked-example plan
    (fixture file) for free, fast e2e testing.
- **Parser**: split on `^<Weekday> [<Type>]$` headers; capture per-day body lines;
  classify day kind (lift/run/bike/rest) from the type text; extract Weekly Summary.
  Any parse failure → day list with raw text blocks; never lose the markdown.
- **Errors surface, never swallow**: CLI non-zero exit / `is_error` / timeout → job
  `status:"error"` with stderr tail; UI renders the error verbatim.

### Frontend (vanilla JS, no external assets)

Views (tabs): **This Week** (7 day cards, type badges, done toggles, Weekly Summary
panel, Generate button with week picker defaulting to next week from Friday onward),
**History** (stored weeks list → plan view), **Coach Bear** (chat per week; job
polling; responses appended to the week's chat log), **Training Log** (stat tiles +
recent sessions from CSV).

### Data / week identity

- Week key = ISO week of the plan's Monday: `YYYY-Www` via `date.isocalendar()`.
- Done-map and chat history live in the week's `.json`; markdown stays pristine.

## Testing

1. Parser unit test against the §12 worked example extracted from the agent file.
2. Mock-mode e2e: server up, `curl` generate → poll job → plan file exists → get
   plan → chat (mock) → done toggle → logs endpoint.
3. One real generation through the pipeline (bounded), verifying the full loop.
4. Ultracode multi-agent review (correctness, subprocess/path safety, parser
   robustness, frontend bugs, silent failures) with adversarial verification.

## Out of scope (YAGNI)

Auth (localhost-only), automatic weekly cron (documented as a follow-up option),
charts beyond stat tiles, editing plans in the UI, writing back to the CSV.
