"""SQLite storage for CoachBear.

Three tables:
  lifting_sets     one row per logged set
  cardio_sessions  one row per run/ride
  weekly_plans     write-through mirror of plans/<week>.md (+ sidecar meta)

CLI:
  python3 dashboard/db.py [--db PATH] import <export.csv>   one-time history import
  python3 dashboard/db.py [--db PATH] import-plans          mirror plans/ into weekly_plans
  python3 dashboard/db.py [--db PATH] query "SELECT ..."    read-only; JSON lines to stdout
"""

import csv
import json
import os
import sqlite3
import sys
import time
from datetime import date, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# COACH_DB lets test servers point at a throwaway database. Anything that
# exercises the API destructively MUST set it — the default is production.
DB_PATH = Path(os.environ.get("COACH_DB", ROOT / "data" / "coachbear.db"))

SCHEMA = """
CREATE TABLE lifting_sets (
    id            INTEGER PRIMARY KEY,
    session_date  TEXT NOT NULL,
    session_start TEXT,
    session_end   TEXT,
    workout_name  TEXT,
    exercise      TEXT NOT NULL,
    category      TEXT,
    set_number    INTEGER,
    weight_lb     REAL,
    reps          INTEGER,
    notes         TEXT,
    source        TEXT NOT NULL DEFAULT 'dashboard'
);
CREATE INDEX idx_lift_date ON lifting_sets(session_date);
CREATE INDEX idx_lift_exercise ON lifting_sets(exercise);

CREATE TABLE cardio_sessions (
    id           INTEGER PRIMARY KEY,
    session_date TEXT NOT NULL,
    activity     TEXT NOT NULL CHECK (activity IN ('run','bike')),
    kind         TEXT,
    distance_mi  REAL,
    duration_min REAL,
    avg_pace     TEXT,
    kcal         INTEGER,
    notes        TEXT,
    external_id  TEXT,
    source       TEXT NOT NULL DEFAULT 'dashboard'
);
CREATE INDEX idx_cardio_date ON cardio_sessions(session_date);
CREATE UNIQUE INDEX idx_cardio_ext ON cardio_sessions(external_id)
    WHERE external_id IS NOT NULL;

CREATE TABLE weekly_plans (
    week_key     TEXT PRIMARY KEY,
    generated_at TEXT,
    markdown     TEXT NOT NULL,
    done_json    TEXT,
    cost_usd     REAL
);
"""


def connect(db_path: Path = DB_PATH) -> sqlite3.Connection:
    db_path = Path(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    _ensure_schema(conn)
    return conn


def _ensure_schema(conn) -> None:
    """Create/upgrade the schema; safe under concurrent connections (retries
    when another connection wins the migration race)."""
    for _ in range(40):
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        if version == 2:
            return
        try:
            if version == 0:
                conn.executescript(SCHEMA)
            elif version == 1:
                cols = {r[1] for r in conn.execute("PRAGMA table_info(cardio_sessions)")}
                if "external_id" not in cols:
                    conn.execute("ALTER TABLE cardio_sessions ADD COLUMN external_id TEXT")
                conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_cardio_ext"
                             " ON cardio_sessions(external_id) WHERE external_id IS NOT NULL")
            else:
                raise RuntimeError(f"unknown schema version {version}")
            conn.execute("PRAGMA user_version = 2")
            conn.commit()
            return
        except sqlite3.OperationalError:
            conn.rollback()          # another connection is mid-migration
            time.sleep(0.05)
    raise RuntimeError("schema migration did not converge")


# ---------------------------------------------------------------- validation

def _valid_date(s) -> str:
    try:
        return datetime.strptime(str(s).strip(), "%Y-%m-%d").strftime("%Y-%m-%d")
    except (ValueError, TypeError):
        raise ValueError(f"invalid date {s!r}: expected YYYY-MM-DD")


def _num(v, name, minimum=0):
    if v in (None, ""):
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        raise ValueError(f"invalid {name}: {v!r}")
    if f < minimum:
        raise ValueError(f"{name} must be >= {minimum}")
    return f


# ---------------------------------------------------------------- inserts / deletes

def insert_lift_session(conn, payload: dict) -> dict:
    day = _valid_date(payload.get("date"))
    exercises = payload.get("exercises") or []
    if not exercises:
        raise ValueError("at least one exercise required")
    workout_name = (payload.get("workout_name") or "").strip() or "Workout"
    start = (payload.get("start") or "").strip()
    end = (payload.get("end") or "").strip()
    rows = []
    for ex in exercises:
        name = (ex.get("name") or "").strip()
        if not name:
            raise ValueError("exercise name required")
        sets = ex.get("sets") or []
        if not sets:
            raise ValueError(f"exercise {name!r} has no sets")
        for i, st in enumerate(sets, start=1):
            reps = st.get("reps")
            try:
                reps = int(reps)
            except (TypeError, ValueError):
                raise ValueError(f"invalid reps {reps!r} on {name}")
            if reps < 1:
                raise ValueError(f"reps must be >= 1 on {name}")
            weight = _num(st.get("weight_lb"), "weight_lb")
            rows.append((day, start or None, end or None, workout_name, name,
                         (ex.get("category") or "").strip() or None, i, weight, reps,
                         (st.get("notes") or "").strip() or None, "dashboard"))
    with conn:
        conn.executemany(
            "INSERT INTO lifting_sets (session_date, session_start, session_end, workout_name,"
            " exercise, category, set_number, weight_lb, reps, notes, source)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)
    return {"key": f"{day}|{workout_name}|{start}", "date": day,
            "workout_name": workout_name, "rows": len(rows)}


def insert_cardio(conn, payload: dict) -> dict:
    day = _valid_date(payload.get("date"))
    activity = (payload.get("activity") or "").strip().lower()
    if activity not in ("run", "bike"):
        raise ValueError("activity must be 'run' or 'bike'")
    distance = _num(payload.get("distance_mi"), "distance_mi")
    duration = _num(payload.get("duration_min"), "duration_min")
    if distance is None and duration is None:
        raise ValueError("at least one of distance_mi / duration_min required")
    kcal = payload.get("kcal")
    kcal = int(kcal) if kcal not in (None, "") else None
    with conn:
        cur = conn.execute(
            "INSERT INTO cardio_sessions (session_date, activity, kind, distance_mi,"
            " duration_min, avg_pace, kcal, notes, source) VALUES (?,?,?,?,?,?,?,?,?)",
            (day, activity, (payload.get("kind") or "").strip() or None, distance, duration,
             (payload.get("avg_pace") or "").strip() or None, kcal,
             (payload.get("notes") or "").strip() or None, "dashboard"))
        rid = cur.lastrowid
    return dict(conn.execute("SELECT * FROM cardio_sessions WHERE id=?", (rid,)).fetchone())


def insert_strava_cardio(conn, row: dict) -> bool:
    """Insert a Strava-sourced cardio row; False if external_id already exists."""
    with conn:
        cur = conn.execute(
            "INSERT OR IGNORE INTO cardio_sessions (session_date, activity, kind,"
            " distance_mi, duration_min, avg_pace, kcal, notes, external_id, source)"
            " VALUES (?,?,?,?,?,?,?,?,?,'strava')",
            (row["date"], row["activity"], row.get("kind"), row.get("distance_mi"),
             row.get("duration_min"), row.get("avg_pace"), row.get("kcal"),
             row.get("notes"), str(row["external_id"])))
    return cur.rowcount > 0


def delete_lift_session(conn, key: str) -> int:
    try:
        day, workout_name, start = key.split("|", 2)
    except ValueError:
        raise ValueError(f"bad session key {key!r}")
    q = "DELETE FROM lifting_sets WHERE session_date=? AND workout_name=? AND "
    args = [day, workout_name]
    if start:
        q += "session_start=?"
        args.append(start)
    else:
        q += "(session_start IS NULL OR session_start='')"
    with conn:
        return conn.execute(q, args).rowcount


def delete_cardio(conn, cardio_id: int) -> int:
    with conn:
        return conn.execute("DELETE FROM cardio_sessions WHERE id=?", (int(cardio_id),)).rowcount


# ---------------------------------------------------------------- log view

def _dur_min(start, end):
    try:
        a = datetime.strptime(start, "%Y-%m-%d %H:%M")
        b = datetime.strptime(end, "%Y-%m-%d %H:%M")
        return round((b - a).total_seconds() / 60)
    except (ValueError, TypeError):
        return None


def fetch_log_view(conn, limit: int = 40) -> dict:
    sessions = []

    groups: dict = {}
    order = []
    for r in conn.execute(
            "SELECT * FROM lifting_sets ORDER BY session_date, session_start, id"):
        gkey = (r["session_date"], r["workout_name"] or "", r["session_start"] or "")
        if gkey not in groups:
            groups[gkey] = {"start": r["session_start"] or r["session_date"],
                            "date": r["session_date"],
                            "name": r["workout_name"] or "Workout",
                            "key": f"{r['session_date']}|{r['workout_name'] or ''}|{r['session_start'] or ''}",
                            "duration_min": _dur_min(r["session_start"], r["session_end"]),
                            "exercises": {}, "ex_order": []}
            order.append(gkey)
        g = groups[gkey]
        if r["exercise"] not in g["exercises"]:
            g["exercises"][r["exercise"]] = {"name": r["exercise"], "category": r["category"] or "",
                                             "sets": [], "cardio": []}
            g["ex_order"].append(r["exercise"])
        g["exercises"][r["exercise"]]["sets"].append(
            {"weight": r["weight_lb"], "reps": r["reps"], "notes": r["notes"] or ""})
    for gkey in order:
        g = groups[gkey]
        sessions.append({"start": g["start"], "date": g["date"], "name": g["name"],
                         "key": g["key"], "cardio_id": None,
                         "duration_min": g["duration_min"],
                         "exercises": [g["exercises"][e] for e in g["ex_order"]]})

    for r in conn.execute("SELECT * FROM cardio_sessions ORDER BY session_date, id"):
        label = ("Run" if r["activity"] == "run" else "Bike") + (f" — {r['kind']}" if r["kind"] else "")
        sessions.append({
            "start": r["session_date"], "date": r["session_date"], "name": label,
            "key": None, "cardio_id": r["id"],
            "duration_min": round(r["duration_min"]) if r["duration_min"] else None,
            "exercises": [{"name": label, "category": "Cardio", "sets": [],
                           "cardio": [{"distance": r["distance_mi"],
                                       "duration_s": r["duration_min"] * 60 if r["duration_min"] else None,
                                       "kcal": r["kcal"], "pace": r["avg_pace"],
                                       "notes": r["notes"]}]}]})

    sessions.sort(key=lambda s: (s["date"], s["start"]), reverse=True)

    latest = sessions[0]["date"] if sessions else None
    stats = {"total_sessions": len(sessions), "data_through": latest,
             "sessions_last_30d": 0, "sets_last_30d": 0, "top_exercises_30d": []}
    if latest:
        window = (datetime.strptime(latest, "%Y-%m-%d") - timedelta(days=30)).strftime("%Y-%m-%d")
        recent = [s for s in sessions if s["date"] >= window]
        counts: dict = {}
        for s in recent:
            for e in s["exercises"]:
                if e["sets"]:
                    counts[e["name"]] = counts.get(e["name"], 0) + len(e["sets"])
        stats.update(
            sessions_last_30d=len(recent),
            sets_last_30d=sum(len(e["sets"]) for s in recent for e in s["exercises"]),
            top_exercises_30d=sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:5])
    for s in sessions:
        s.pop("date", None)
    return {"available": True, "source": "coachbear.db", "stats": stats,
            "sessions": sessions[:limit]}


# ---------------------------------------------------------------- imports

def import_csv(conn, csv_path: Path) -> dict:
    if conn.execute("SELECT 1 FROM lifting_sets WHERE source='csv-import' LIMIT 1").fetchone() \
            or conn.execute("SELECT 1 FROM cardio_sessions WHERE source='csv-import' LIMIT 1").fetchone():
        raise RuntimeError("csv already imported")
    lift_rows = []
    cardio_rows = []
    setnum: dict = {}
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            start = (row.get("Workout Start") or "").strip()
            end = (row.get("Workout End") or "").strip()
            day = start[:10] if start else None
            if not day:
                continue
            name = (row.get("Name") or "").strip() or "Workout"
            ex = (row.get("Exercise") or "").strip() or "Unknown"
            weight = (row.get("Weight") or "").strip()
            reps = (row.get("Reps") or "").strip()
            dist = (row.get("Distance") or "").strip()
            dur = (row.get("Duration") or "").strip()
            kcal = (row.get("Kcal") or "").strip()
            if reps or weight:
                k = (start, name, ex)
                setnum[k] = setnum.get(k, 0) + 1
                try:
                    reps_i = int(float(reps)) if reps else None
                except ValueError:
                    reps_i = None
                try:
                    weight_f = float(weight) if weight else None
                except ValueError:
                    weight_f = None
                lift_rows.append((day, start, end or None, name, ex,
                                  (row.get("Category") or "").strip() or None, setnum[k],
                                  weight_f, reps_i, (row.get("Notes") or "").strip() or None,
                                  "csv-import"))
            elif dist or dur or kcal:
                text = f"{ex} {name}".lower()
                activity = "bike" if any(w in text for w in ("bike", "cycl", "spin", "ride")) else "run"
                try:
                    dur_min = round(float(dur) / 60, 1) if dur else None
                except ValueError:
                    dur_min = None
                cardio_rows.append((day, activity, None,
                                    float(dist) if dist else None, dur_min, None,
                                    int(float(kcal)) if kcal else None,
                                    (row.get("Notes") or "").strip() or None, "csv-import"))
    with conn:
        conn.executemany(
            "INSERT INTO lifting_sets (session_date, session_start, session_end, workout_name,"
            " exercise, category, set_number, weight_lb, reps, notes, source)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?)", lift_rows)
        conn.executemany(
            "INSERT INTO cardio_sessions (session_date, activity, kind, distance_mi,"
            " duration_min, avg_pace, kcal, notes, source) VALUES (?,?,?,?,?,?,?,?,?)",
            cardio_rows)
    return {"lift_rows": len(lift_rows), "cardio_rows": len(cardio_rows)}


def upsert_plan(conn, week_key: str, markdown: str, meta: dict) -> None:
    meta = meta or {}
    with conn:
        conn.execute(
            "INSERT OR REPLACE INTO weekly_plans (week_key, generated_at, markdown, done_json, cost_usd)"
            " VALUES (?,?,?,?,?)",
            (week_key, meta.get("generated_at"), markdown,
             json.dumps(meta.get("done") or {}), meta.get("cost_usd")))


def import_plans(conn, plans_dir: Path) -> int:
    n = 0
    for mpath in sorted(Path(plans_dir).glob("*.md")):
        jpath = mpath.with_suffix(".json")
        meta = {}
        if jpath.exists():
            try:
                meta = json.loads(jpath.read_text())
            except (json.JSONDecodeError, OSError):
                meta = {}
        upsert_plan(conn, mpath.stem, mpath.read_text(), meta)
        n += 1
    return n


# ---------------------------------------------------------------- digest

DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MAX_DIGEST = 2500


def _sessions_by_date(conn, first: str, last: str) -> dict:
    """date -> list of {'type': 'lift'|'run'|'bike', 'label': str}"""
    out: dict = {}
    for r in conn.execute(
            "SELECT DISTINCT session_date, workout_name FROM lifting_sets"
            " WHERE session_date BETWEEN ? AND ?", (first, last)):
        out.setdefault(r["session_date"], []).append(
            {"type": "lift", "label": f"lift ({r['workout_name'] or 'Workout'})"})
    for r in conn.execute(
            "SELECT session_date, activity, kind, distance_mi, duration_min FROM cardio_sessions"
            " WHERE session_date BETWEEN ? AND ?", (first, last)):
        bits = [r["activity"]]
        if r["kind"]:
            bits.append(r["kind"])
        if r["distance_mi"]:
            bits.append(f"{r['distance_mi']:g} mi")
        elif r["duration_min"]:
            bits.append(f"{r['duration_min']:g} min")
        out.setdefault(r["session_date"], []).append(
            {"type": r["activity"], "label": " ".join(bits)})
    return out


def build_digest(conn, prev_monday: date, planned_days, done_marks) -> str:
    lines = []
    first = prev_monday.strftime("%Y-%m-%d")
    last = (prev_monday + timedelta(days=6)).strftime("%Y-%m-%d")
    logged = _sessions_by_date(conn, first, last)

    lines.append(f"## Adherence — week of {first}")
    if not planned_days:
        lines.append("(no stored plan for last week — treat logged sessions below as the baseline)")
        for d in sorted(logged):
            for s in logged[d]:
                lines.append(f"{d}: {s['label']}")
    else:
        planned_by_day = {p["day"]: p for p in planned_days}
        matched_dates = set()
        for i, day_name in enumerate(DAY_NAMES):
            d = (prev_monday + timedelta(days=i)).strftime("%Y-%m-%d")
            p = planned_by_day.get(day_name)
            if not p:
                continue
            kind = p.get("kind", "other")
            head = f"{day_name} ({d}) — "
            if kind == "rest":
                lines.append(head + "rest day")
                continue
            head += f"planned {p.get('type', kind)}: "
            day_logs = logged.get(d, [])
            hit = [s for s in day_logs if s["type"] == kind]
            if hit:
                matched_dates.add(d)
                lines.append(head + "completed" + (f" ({hit[0]['label']})" if kind != "lift" else ""))
            elif day_logs:
                matched_dates.add(d)
                lines.append(head + f"done differently (logged {', '.join(s['label'] for s in day_logs)})")
            else:
                suffix = " — but marked done manually" if (done_marks or {}).get(day_name) else ""
                lines.append(head + "missed" + suffix)
        extras = [(d, s) for d in sorted(logged) if d not in matched_dates for s in logged[d]]
        for d, s in extras:
            lines.append(f"Extra (unplanned) {d}: {s['label']}")

    lines.append("")
    lines.append("## Recent lifting (28 days)")
    ref = prev_monday + timedelta(days=6)
    since = (ref - timedelta(days=28)).strftime("%Y-%m-%d")
    ex_rows = conn.execute(
        """SELECT exercise, MAX(session_date) AS last_date,
                  COUNT(DISTINCT session_date) AS sessions
           FROM lifting_sets WHERE session_date >= ?
           GROUP BY exercise ORDER BY last_date DESC LIMIT 20""", (since,)).fetchall()
    if not ex_rows:
        lines.append("(no lifting logged in the last 28 days)")
    for r in ex_rows:
        top = conn.execute(
            """SELECT weight_lb, reps FROM lifting_sets
               WHERE exercise=? AND session_date=? ORDER BY weight_lb DESC, reps DESC LIMIT 1""",
            (r["exercise"], r["last_date"])).fetchone()
        w = f"{top['weight_lb']:g}lb" if top["weight_lb"] is not None else "bodyweight"
        lines.append(f"{r['exercise']}: last {r['last_date']}, top set {w} x {top['reps']},"
                     f" {r['sessions']} sessions")

    lines.append("")
    lines.append("## Cardio volume by week (4 weeks)")
    since4 = (prev_monday - timedelta(days=21)).strftime("%Y-%m-%d")
    weeks: dict = {}
    for r in conn.execute(
            "SELECT session_date, activity, distance_mi, duration_min FROM cardio_sessions"
            " WHERE session_date BETWEEN ? AND ?", (since4, last)):
        d = datetime.strptime(r["session_date"], "%Y-%m-%d").date()
        iso = d.isocalendar()
        wk = f"{iso[0]}-W{iso[1]:02d}"
        w = weeks.setdefault(wk, {"runs": 0, "run_mi": 0.0, "bike_min": 0.0})
        if r["activity"] == "run":
            w["runs"] += 1
            w["run_mi"] += r["distance_mi"] or 0
        else:
            w["bike_min"] += r["duration_min"] or 0
    if not weeks:
        lines.append("(no cardio logged in the last 4 weeks)")
    for wk in sorted(weeks):
        w = weeks[wk]
        lines.append(f"{wk}: runs {w['runs']} ({w['run_mi']:g} mi), bike {w['bike_min']:g} min")

    text = "\n".join(lines)
    if len(text) > MAX_DIGEST:
        text = text[:MAX_DIGEST].rsplit("\n", 1)[0] + "\n…(truncated)"
    return text


# ---------------------------------------------------------------- CLI

def _cli(argv) -> int:
    args = list(argv)
    db_path = DB_PATH
    if args[:1] == ["--db"] or (args and args[0] == "--db"):
        db_path = Path(args[1])
        args = args[2:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = args[0], args[1:]
    if cmd == "import":
        if not rest:
            print("usage: db.py import <export.csv>", file=sys.stderr)
            return 2
        res = import_csv(connect(db_path), Path(rest[0]))
        print(json.dumps(res))
        return 0
    if cmd == "import-plans":
        n = import_plans(connect(db_path), ROOT / "plans")
        print(json.dumps({"plans": n}))
        return 0
    if cmd == "query":
        if not rest:
            print("usage: db.py query \"SELECT ...\"", file=sys.stderr)
            return 2
        conn = sqlite3.connect(f"file:{Path(db_path)}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        try:
            for row in conn.execute(rest[0]):
                print(json.dumps(dict(row), default=str))
        except sqlite3.Error as e:
            print(f"query error: {e}", file=sys.stderr)
            return 1
        finally:
            conn.close()
        return 0
    print(f"unknown command {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
