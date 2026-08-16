# Strava Sync — Design

Date: 2026-07-08
Status: approved (user chose: full history backfill; manual sync button only)

## Goal

Pull the athlete's Strava runs and rides into `cardio_sessions` so coach-bear
plans against real cardio history. Connection and sync both happen from the
dashboard UI; no background polling (user's choice).

## Decisions

1. **Full backfill** on first sync (CSV history had only 8 cardio rows).
2. **Manual sync only** — a "Sync Strava" button in the Log view; no
   background thread, no webhook.
3. In-dashboard OAuth: works behind basicauth because Strava redirects the
   *user's browser*, which already holds the basicauth session.

## Schema migration (user_version 1 → 2)

- `ALTER TABLE cardio_sessions ADD COLUMN external_id TEXT` (Strava activity id)
- `CREATE UNIQUE INDEX idx_cardio_ext ON cardio_sessions(external_id)
   WHERE external_id IS NOT NULL` — re-sync can never duplicate.
- Fresh databases get the v2 schema directly; v1 databases are altered in
  `db.connect()`.

## New module: `dashboard/strava.py` (stdlib urllib only)

- Token store `data/strava_tokens.json` (mode 600; path overridable via
  `COACH_STRAVA_TOKENS` for tests): `{client_id, client_secret, access_token,
  refresh_token, expires_at, athlete}`. The client secret never leaves the
  server.
- OAuth: authorize URL with `scope=activity:read_all`; code exchange and
  refresh both POST `https://www.strava.com/oauth/token`. Refresh happens
  lazily before any API call when `expires_at < now + 300`; the rotated
  refresh token is always re-saved.
- `fetch_activities(after)` — pages `GET /api/v3/athlete/activities`
  (`per_page=200`) until an empty page.
- `activity_to_row(a)` mapping:
  - sport_type Run/TrailRun/VirtualRun → activity 'run';
    Ride/VirtualRide/MountainBikeRide/GravelRide/EBikeRide → 'bike';
    anything else → skipped (returns None).
  - distance m → miles (2 dp); moving_time s → minutes (1 dp);
    run pace = moving_time / miles as "MM:SS/mi"; date = start_date_local
    date part; notes = activity name; kind from workout_type
    (run 2→long, run 1/3→intervals, ride 11/12→intervals, else NULL).
- `sync(conn, fetch=None)` — watermark = newest strava-sourced
  `session_date` minus 2 days (overlap window; the unique index absorbs the
  re-fetch); no watermark → full backfill. Inserts via
  `db.insert_strava_cardio` (INSERT OR IGNORE on external_id). Returns
  `{"new": n, "scanned": m}`. `fetch` injectable for tests.

## Server endpoints (all thin wrappers)

- `GET /api/strava/status` → `{configured, connected, strava_count,
  last_synced}` (no secrets).
- `POST /api/strava/config` `{client_id, client_secret}` → stores app creds.
- `GET /api/strava/authorize` → 302 to Strava; `redirect_uri` built from the
  request Host header (`https://<host>/api/strava/callback`; http for
  localhost).
- `GET /api/strava/callback?code=` → exchanges code, saves tokens,
  302 → `/#log`.
- `POST /api/strava/sync` → runs sync; errors surface as 502 JSON.

## UI (Log view)

Next to "+ Log workout": a Strava button rendered from `/api/strava/status`
state — "Connect Strava" (not configured → small modal collects client
ID/secret once, POSTs config, then navigates to `api/strava/authorize`;
configured-but-not-connected skips the modal) or "Sync Strava" (POSTs sync,
toasts "Strava sync: N new", refreshes the log list). Synced entries appear
as normal cardio sessions and are deletable like any other.

## Edge cases / errors

- Hand-logged run + synced same run → two rows; the UI habit is to use Sync
  for Strava-tracked sessions; duplicates are deletable. No auto-merge (YAGNI).
- Refresh-token failure (revoked app) → status returns connected:false with
  `reason`; button reverts to "Connect Strava".
- Rate limits (~200 req/15 min) are unreachable with manual sync
  (backfill of years ≈ a few pages).

## Testing

- `dashboard/test_strava.py` (plain asserts, no network): mapping table
  incl. skip cases and unit conversions; sync dedup on double-run; watermark
  computation; token refresh via injected fake HTTP; config/token store
  round-trip with COACH_STRAVA_TOKENS pointing at tmp.
- `test_db.py` gains: v1→v2 migration on an existing v1 file;
  insert_strava_cardio dedup.
- Endpoint smoke on a scratch server with COACH_DB + COACH_STRAVA_TOKENS in
  tmp (per the test-isolation rule). Real OAuth verified live once the user
  creates the Strava app.

## User setup (after deploy)

1. https://www.strava.com/settings/api → create app: category anything,
   Authorization Callback Domain = `bear.kunigami.cloud`.
2. Log view → Connect Strava → paste Client ID + Client Secret → authorize on
   Strava's page.
3. Click Sync Strava — first run backfills everything.
