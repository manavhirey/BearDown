"""Strava sync for CoachBear — OAuth tokens, activity fetch, cardio mapping.

Token store: data/strava_tokens.json (override with COACH_STRAVA_TOKENS).
Holds the app's client_id/client_secret plus the athlete's rotating tokens.
The client secret never leaves the server.

All HTTP is stdlib urllib; every network call goes through _http_json so
tests can stub it.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import db

ROOT = Path(__file__).resolve().parent.parent
TOKENS_PATH = Path(os.environ.get("COACH_STRAVA_TOKENS", ROOT / "data" / "strava_tokens.json"))

AUTH_URL = "https://www.strava.com/oauth/authorize"
TOKEN_URL = "https://www.strava.com/oauth/token"
API = "https://www.strava.com/api/v3"

RUN_TYPES = {"Run", "TrailRun", "VirtualRun"}
BIKE_TYPES = {"Ride", "VirtualRide", "MountainBikeRide", "GravelRide", "EBikeRide",
              "Handcycle", "Velomobile"}
# Strava workout_type: runs 1=race 2=long run 3=workout; rides 11=race 12=workout
KIND_BY_WORKOUT_TYPE = {1: "intervals", 2: "long", 3: "intervals", 11: "intervals", 12: "intervals"}


class StravaError(RuntimeError):
    pass


# ---------------------------------------------------------------- token store

def load_tokens() -> dict:
    try:
        return json.loads(TOKENS_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_tokens(tokens: dict) -> None:
    TOKENS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = TOKENS_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(tokens, indent=2))
    tmp.replace(TOKENS_PATH)
    os.chmod(TOKENS_PATH, 0o600)


def set_app_config(client_id: str, client_secret: str) -> None:
    client_id, client_secret = client_id.strip(), client_secret.strip()
    if not client_id or not client_secret:
        raise StravaError("client_id and client_secret are both required")
    tokens = load_tokens()
    tokens.update(client_id=client_id, client_secret=client_secret)
    save_tokens(tokens)


def status(conn=None) -> dict:
    t = load_tokens()
    out = {
        "configured": bool(t.get("client_id") and t.get("client_secret")),
        "connected": bool(t.get("refresh_token")),
        "athlete": (t.get("athlete") or {}).get("username") or (t.get("athlete") or {}).get("firstname"),
    }
    if conn is not None:
        row = conn.execute(
            "SELECT COUNT(*) AS n, MAX(session_date) AS latest FROM cardio_sessions"
            " WHERE source='strava'").fetchone()
        out["strava_count"] = row["n"]
        out["last_synced"] = row["latest"]
    return out


# ---------------------------------------------------------------- oauth

def authorize_url(redirect_uri: str) -> str:
    t = load_tokens()
    if not t.get("client_id"):
        raise StravaError("Strava app not configured yet")
    return AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": t["client_id"],
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "approval_prompt": "auto",
        "scope": "activity:read_all",
    })


def _http_json(url: str, data: dict | None = None, headers: dict | None = None):
    """POST form data if `data` given, else GET. Returns parsed JSON."""
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        raise StravaError(f"Strava API {e.code}: {detail}")
    except urllib.error.URLError as e:
        raise StravaError(f"Strava unreachable: {e.reason}")


def exchange_code(code: str, http=_http_json) -> dict:
    t = load_tokens()
    res = http(TOKEN_URL, data={
        "client_id": t.get("client_id"), "client_secret": t.get("client_secret"),
        "code": code, "grant_type": "authorization_code"})
    t.update(access_token=res["access_token"], refresh_token=res["refresh_token"],
             expires_at=res["expires_at"], athlete=res.get("athlete") or {})
    save_tokens(t)
    return t


def _access_token(http=_http_json) -> str:
    t = load_tokens()
    if not t.get("refresh_token"):
        raise StravaError("Strava not connected — authorize first")
    if (t.get("expires_at") or 0) < time.time() + 300:
        res = http(TOKEN_URL, data={
            "client_id": t.get("client_id"), "client_secret": t.get("client_secret"),
            "grant_type": "refresh_token", "refresh_token": t["refresh_token"]})
        t.update(access_token=res["access_token"], refresh_token=res["refresh_token"],
                 expires_at=res["expires_at"])
        save_tokens(t)
    return t["access_token"]


# ---------------------------------------------------------------- activities

def fetch_activities(after: int | None = None, http=_http_json):
    """Yield SummaryActivity dicts, paging until an empty page."""
    token = _access_token(http=http)
    page = 1
    while True:
        params = {"per_page": 200, "page": page}
        if after:
            params["after"] = int(after)
        batch = http(f"{API}/athlete/activities?" + urllib.parse.urlencode(params),
                     headers={"Authorization": f"Bearer {token}"})
        if not batch:
            return
        yield from batch
        if len(batch) < 200:
            return
        page += 1


def _fmt_pace(min_per_mi: float) -> str:
    m = int(min_per_mi)
    s = round((min_per_mi - m) * 60)
    if s == 60:
        m, s = m + 1, 0
    return f"{m}:{s:02d}/mi"


def activity_to_row(a: dict) -> dict | None:
    sport = a.get("sport_type") or a.get("type") or ""
    if sport in RUN_TYPES:
        activity = "run"
    elif sport in BIKE_TYPES:
        activity = "bike"
    else:
        return None
    meters = a.get("distance") or 0
    miles = round(meters / 1609.344, 2) if meters else None
    secs = a.get("moving_time") or a.get("elapsed_time") or 0
    minutes = round(secs / 60, 1) if secs else None
    if miles is None and minutes is None:
        return None
    pace = None
    if activity == "run" and miles and minutes:
        pace = _fmt_pace(minutes / miles)
    start = (a.get("start_date_local") or a.get("start_date") or "")[:10]
    if not start:
        return None
    return {
        "date": start,
        "activity": activity,
        "kind": KIND_BY_WORKOUT_TYPE.get(a.get("workout_type")),
        "distance_mi": miles,
        "duration_min": minutes,
        "avg_pace": pace,
        "kcal": round(a["kilojoules"]) if a.get("kilojoules") else None,
        "notes": (a.get("name") or "").strip() or None,
        "external_id": a["id"],
    }


def sync(conn, fetch=None) -> dict:
    """Import new Strava runs/rides. First run backfills everything."""
    if fetch is None:
        fetch = fetch_activities
    row = conn.execute("SELECT MAX(session_date) AS latest FROM cardio_sessions"
                       " WHERE source='strava'").fetchone()
    after = None
    if row["latest"]:
        # overlap 2 days; the unique external_id index absorbs re-fetched ones
        from datetime import datetime, timedelta
        dt = datetime.strptime(row["latest"], "%Y-%m-%d") - timedelta(days=2)
        after = int(dt.timestamp())
    new = scanned = 0
    for a in fetch(after):
        scanned += 1
        mapped = activity_to_row(a)
        if mapped and db.insert_strava_cardio(conn, mapped):
            new += 1
    return {"new": new, "scanned": scanned}


if __name__ == "__main__":
    # minimal CLI: `python3 dashboard/strava.py sync` (uses real API)
    if sys.argv[1:2] == ["sync"]:
        conn = db.connect()
        print(json.dumps(sync(conn)))
        conn.close()
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
