# CoachBear

Personal hybrid-athlete training setup: the `coach-bear` Claude Code subagent
(`.claude/agents/coach-bear.md`) generates a 7-day lifting + running + cycling plan
each week from *The Pure Bodybuilding Program – PPL* and your logged numbers, and a
local dashboard stores and displays every weekly plan.

## Dashboard

```bash
python3 dashboard/server.py            # http://127.0.0.1:8737
```

No dependencies (Python 3.12 stdlib). Views:

- **Plan** — the selected week's plan as day cards with a Mon–Sun pace band;
  mark days done; Generate/Regenerate calls the coach-bear agent headlessly
  (`claude --agent coach-bear -p …`) as a background job.
- **Coach** — chat with Coach Bear about the selected week (resumes the same
  claude session). If a reply contains a revised plan you can save it as the
  week's plan.
- **History** — every stored week with completion dots.
- **Log** — stats and sessions from the newest `export_*.csv` gym-log export.

### Storage

Plans live in `plans/` — one pair per ISO week:

- `plans/2026-W28.md` — the plan exactly as coach-bear emitted it
- `plans/2026-W28.json` — metadata: generated_at, claude session id (for chat
  continuity), per-day done map, chat history

### Options

| Env var | Effect |
|---|---|
| `COACH_MOCK=1` | canned plan instead of real claude calls (free testing) |
| `COACH_CLAUDE_BIN` | path to the claude CLI (default `claude`) |
| `COACH_GEN_TIMEOUT` | generation timeout, seconds (default 1800) |
| `COACH_CHAT_TIMEOUT` | chat timeout, seconds (default 900) |

`python3 dashboard/server.py --port NNNN` to change the port.

### Weekly cadence

Generate from the dashboard whenever you want the next week (from Friday on it
defaults to next week). To automate it, schedule
`claude -p 'POST {"week":"..."} to the dashboard'`-style cron via Claude Code's
scheduler, or simply: `curl -X POST localhost:8737/api/generate -d '{}'`
(empty body = suggested week) while the server is running.

## Design docs

`docs/superpowers/specs/2026-07-04-coachbear-dashboard-design.md`
