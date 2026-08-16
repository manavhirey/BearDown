# Archive

## Week of 2026-07-01
Started CoachBear lifting tracker project. Designed dashboard spec, parsed 3+ years of historical lifting data (2023–June 2026) to seed initial impl.

## Week of 2026-07-07
Shipped CoachBear MVP (bear.kunigami.cloud, Caddy reverse proxy, Strava OAuth, SQLite logging) with dashboard (Python server, JS SPA, 21 tests) despite pre-ship review finding 42 defects. Post-launch work fixed nav proxy, deployment PATH issues, and enabled subagent API with auth. Expanded workout logging with 3-year historical import, UI redesign (Arquivo font, 5-color palette), and Strava sync (25 activities: 21 runs 47.5mi, 4 bikes 15.1mi). Deployed revised dashboard (61 tests) with production auth and W28 training plan (7/6-7/12).

## Week of 2026-07-14
Continued CoachBear prod deploy (bear.kunigami.cloud, Caddy basicauth). Seeded logging DB with 3-yr historical data (lifting_sets, cardio_sessions, weekly_plans). Impl dashboard UI redesign (Archivo, 5-color palette, week-strip nav). Integrated Strava sync (21 runs 47.5mi, 4 bikes 15.1mi). Fixed infra (systemd PATH, nav proxy). Deployed remote agent auth but hit 401 verification issues.

## Week of 2026-07-21
Refined CoachBear dashboard deploy (Caddy basicauth). Expanded logging DB with 3-yr CSV import (lifting_sets, cardio_sessions, weekly_plans). Enhanced UI (5-color palette). Completed Strava sync backfill (21 runs, 4 rides).