"""Plain-assert tests for dashboard/strava.py — no network.
Run: COACH_STRAVA_TOKENS=/tmp/... python3 dashboard/test_strava.py
(sets its own env before importing when run directly)"""

import json
import os
import stat
import sys
import tempfile
import time
from pathlib import Path

_tmp = tempfile.TemporaryDirectory()
os.environ["COACH_STRAVA_TOKENS"] = str(Path(_tmp.name) / "tokens.json")

sys.path.insert(0, str(Path(__file__).resolve().parent))
import db      # noqa: E402
import strava  # noqa: E402

PASS = 0


def ok(label):
    global PASS
    PASS += 1
    print(f"  ok {PASS} - {label}")


def test_token_store():
    strava.set_app_config(" 12345 ", "s3cret")
    t = strava.load_tokens()
    assert t == {"client_id": "12345", "client_secret": "s3cret"}, t
    mode = stat.S_IMODE(os.stat(strava.TOKENS_PATH).st_mode)
    assert mode == 0o600, oct(mode)
    st = strava.status()
    assert st["configured"] is True and st["connected"] is False, st
    url = strava.authorize_url("https://x.example/cb")
    assert "client_id=12345" in url and "activity%3Aread_all" in url, url
    ok("token store, chmod 600, status, authorize url")


def test_exchange_and_refresh():
    calls = []

    def fake_http(url, data=None, headers=None):
        calls.append((url, data))
        if data and data.get("grant_type") == "authorization_code":
            return {"access_token": "AT1", "refresh_token": "RT1",
                    "expires_at": int(time.time()) - 10,  # already expired
                    "athlete": {"username": "manav"}}
        if data and data.get("grant_type") == "refresh_token":
            assert data["refresh_token"] == "RT1"
            return {"access_token": "AT2", "refresh_token": "RT2",
                    "expires_at": int(time.time()) + 21600}
        raise AssertionError(f"unexpected call {url} {data}")

    strava.exchange_code("thecode", http=fake_http)
    t = strava.load_tokens()
    assert t["refresh_token"] == "RT1" and t["athlete"]["username"] == "manav", t
    tok = strava._access_token(http=fake_http)     # expired -> refresh
    assert tok == "AT2"
    assert strava.load_tokens()["refresh_token"] == "RT2"  # rotation saved
    tok2 = strava._access_token(http=fake_http)    # fresh -> no extra call
    assert tok2 == "AT2" and len(calls) == 2, calls
    ok("code exchange, lazy refresh, rotated token persisted")


ACTS = [
    {"id": 1, "sport_type": "Run", "workout_type": 2, "distance": 9980.0,
     "moving_time": 3720, "start_date_local": "2026-07-05T07:30:00Z",
     "name": "Sunday long run"},
    {"id": 2, "sport_type": "GravelRide", "distance": 32000.0, "moving_time": 4500,
     "kilojoules": 850.4, "start_date_local": "2026-07-04T08:00:00Z", "name": "Gravel"},
    {"id": 3, "sport_type": "Walk", "distance": 2000.0, "moving_time": 1500,
     "start_date_local": "2026-07-03T18:00:00Z", "name": "Dog walk"},
    {"id": 4, "sport_type": "Run", "workout_type": 3, "distance": 4830.0,
     "moving_time": 1650, "start_date_local": "2026-07-02T06:45:00Z", "name": "Track"},
]


def test_mapping():
    r = strava.activity_to_row(ACTS[0])
    assert r["activity"] == "run" and r["kind"] == "long", r
    assert r["distance_mi"] == 6.2 and r["duration_min"] == 62.0, r
    assert r["avg_pace"] == "10:00/mi" and r["date"] == "2026-07-05", r
    assert r["external_id"] == 1 and r["notes"] == "Sunday long run", r
    b = strava.activity_to_row(ACTS[1])
    assert b["activity"] == "bike" and b["kind"] is None and b["kcal"] == 850, b
    assert b["avg_pace"] is None, b
    assert strava.activity_to_row(ACTS[2]) is None       # walk skipped
    i = strava.activity_to_row(ACTS[3])
    assert i["kind"] == "intervals", i
    ok("mapping: units, pace, kinds, kcal from kilojoules, walk skipped")


def test_sync_and_dedup():
    conn = db.connect(Path(_tmp.name) / "sync.db")
    fetched_after = []

    def fake_fetch(after):
        fetched_after.append(after)
        return iter(ACTS)

    res = strava.sync(conn, fetch=fake_fetch)
    assert res == {"new": 3, "scanned": 4}, res            # walk skipped
    assert fetched_after == [None], fetched_after          # full backfill
    res2 = strava.sync(conn, fetch=fake_fetch)
    assert res2["new"] == 0, res2                          # all dupes ignored
    assert fetched_after[1] is not None, "second sync should use watermark"
    import datetime
    wm = datetime.datetime.fromtimestamp(fetched_after[1]).strftime("%Y-%m-%d")
    assert wm == "2026-07-03", wm                          # newest 07-05 minus 2d
    n = conn.execute("SELECT COUNT(*) FROM cardio_sessions WHERE source='strava'").fetchone()[0]
    assert n == 3, n
    conn.close()
    ok("sync: backfill, dedup on re-sync, 2-day watermark")


def main():
    test_token_store()
    test_exchange_and_refresh()
    test_mapping()
    test_sync_and_dedup()
    print(f"all {PASS} checks passed")


if __name__ == "__main__":
    main()
