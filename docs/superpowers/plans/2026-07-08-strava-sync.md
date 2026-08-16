# Strava Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline). Spec: docs/superpowers/specs/2026-07-08-strava-sync-design.md. No git repo — per-task verification instead of commits.

**Goal:** Strava OAuth + manual sync into cardio_sessions with full backfill and idempotent re-sync.

**Global constraints:** stdlib only; tests never touch prod DB/tokens (COACH_DB, COACH_STRAVA_TOKENS); client secret never sent to browser; unique external_id prevents duplicates.

### Task 1: db.py v2 migration + insert_strava_cardio
- [ ] test_db.py: fresh connect → user_version 2 with external_id column + partial unique index; building a v1 file then connect() migrates to 2 preserving rows; insert_strava_cardio inserts once, returns False on dup external_id.
- [ ] Implement (SCHEMA → v2; _migrate in connect; insert_strava_cardio). Run tests.

### Task 2: dashboard/strava.py
- [ ] test_strava.py: activity_to_row mapping (Run→run w/ pace mm:ss/mi, GravelRide→bike, Walk→None, workout_type kinds); sync with fake fetch: backfill inserts, second sync 0 new (dedup), watermark after = newest-2d; token store round-trip incl. chmod 600; refresh flow with fake _http_json (expired → refresh POST, rotated token saved).
- [ ] Implement module per spec. Run tests.

### Task 3: server endpoints + UI
- [ ] server.py: import strava; GET status/authorize/callback in do_GET; POST config/sync in do_POST; 302 helper.
- [ ] app.js: state.strava; renderLog fetches status once; Strava button (Connect → creds modal → config POST → navigate to authorize | Sync → POST, toast, refresh); index.html: .log-actions wrapper. style.css: .log-actions.
- [ ] Smoke on scratch server (COACH_DB+COACH_STRAVA_TOKENS in tmp): status endpoints, config, sync path with unconnected error, UI button renders. Browser shot of Log view.

### Task 4: deploy + handoff
- [ ] All tests green; restart live service; verify /api/strava/status live; write user setup steps.
