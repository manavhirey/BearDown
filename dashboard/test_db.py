"""Plain-assert tests for dashboard/db.py.  Run: python3 dashboard/test_db.py"""

import json
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import db  # noqa: E402

PASS = 0


def ok(label):
    global PASS
    PASS += 1
    print(f"  ok {PASS} - {label}")


def expect_value_error(fn, label):
    try:
        fn()
    except ValueError:
        ok(label)
    else:
        raise AssertionError(f"expected ValueError: {label}")


LIFT_PAYLOAD = {
    "date": "2026-07-06",
    "workout_name": "Push #1",
    "start": "2026-07-06 18:00",
    "end": "2026-07-06 19:05",
    "exercises": [
        {"name": "Bench Press", "category": "Chest",
         "sets": [{"weight_lb": 70, "reps": 8}, {"weight_lb": 70, "reps": 8, "notes": "last set RPE 10"}]},
        {"name": "Lateral Raise", "category": "Shoulders",
         "sets": [{"weight_lb": 12.5, "reps": 12}, {"weight_lb": 12.5, "reps": 11}]},
    ],
}

CARDIO_PAYLOAD = {
    "date": "2026-07-07",
    "activity": "run",
    "kind": "easy",
    "distance_mi": 2.5,
    "duration_min": 33,
    "notes": "felt good",
}


def test_schema(conn):
    names = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"lifting_sets", "cardio_sessions", "weekly_plans"} <= names, names
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 2
    cols = {r[1] for r in conn.execute("PRAGMA table_info(cardio_sessions)")}
    assert "external_id" in cols, cols
    ok("schema: three tables, user_version=2, external_id present")


def test_concurrent_init(tmp):
    """Two threads opening a fresh DB at once must both get a valid schema
    (regression: 'table lifting_sets already exists' race)."""
    import threading
    p = tmp / "race.db"
    barrier = threading.Barrier(2)
    failures = []

    def worker():
        try:
            barrier.wait()
            conn = db.connect(p)
            assert conn.execute("PRAGMA user_version").fetchone()[0] == 2
            conn.close()
        except Exception as e:  # noqa: BLE001 — collect for the assert below
            failures.append(repr(e))

    threads = [threading.Thread(target=worker) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert not failures, failures
    ok("concurrent fresh-DB init: no schema race")


def test_v1_migration(tmp):
    """A v1-era database gets external_id added without losing rows."""
    import sqlite3 as sq
    p = tmp / "v1.db"
    v1_schema = db.SCHEMA.replace("    external_id  TEXT,\n", "").replace(
        "CREATE UNIQUE INDEX idx_cardio_ext ON cardio_sessions(external_id)\n"
        "    WHERE external_id IS NOT NULL;\n", "")  # v1: no external_id, no index
    assert "external_id" not in v1_schema
    old = sq.connect(p)
    old.executescript(v1_schema)
    old.execute("INSERT INTO cardio_sessions (session_date, activity, distance_mi)"
                " VALUES ('2026-01-01','run',3.0)")
    old.execute("PRAGMA user_version = 1")
    old.commit()
    old.close()
    conn = db.connect(p)
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 2
    rows = conn.execute("SELECT distance_mi, external_id FROM cardio_sessions").fetchall()
    assert len(rows) == 1 and rows[0][0] == 3.0 and rows[0][1] is None, rows
    conn.close()
    ok("v1 -> v2 migration preserves rows, adds external_id")


def test_strava_insert(conn):
    row = {"date": "2026-07-01", "activity": "run", "kind": "long", "distance_mi": 6.2,
           "duration_min": 62.0, "avg_pace": "10:00/mi", "notes": "Sunday long",
           "external_id": "987654"}
    assert db.insert_strava_cardio(conn, row) is True
    assert db.insert_strava_cardio(conn, row) is False  # dup external_id ignored
    got = [tuple(r) for r in conn.execute(
        "SELECT source, external_id FROM cardio_sessions WHERE external_id='987654'")]
    assert got == [("strava", "987654")], got
    ok("insert_strava_cardio: inserts once, dedups on external_id")


def test_lift_roundtrip(conn):
    res = db.insert_lift_session(conn, LIFT_PAYLOAD)
    assert res["rows"] == 4, res
    assert res["key"] == "2026-07-06|Push #1|2026-07-06 18:00", res
    rows = conn.execute(
        "SELECT exercise, set_number, weight_lb, reps FROM lifting_sets ORDER BY id").fetchall()
    assert [tuple(r) for r in rows] == [
        ("Bench Press", 1, 70.0, 8), ("Bench Press", 2, 70.0, 8),
        ("Lateral Raise", 1, 12.5, 12), ("Lateral Raise", 2, 12.5, 11)], rows
    ok("lift insert: 4 rows, per-exercise set numbers")


def test_cardio_roundtrip(conn):
    entry = db.insert_cardio(conn, CARDIO_PAYLOAD)
    assert entry["id"] and entry["activity"] == "run" and entry["distance_mi"] == 2.5, entry
    ok("cardio insert round-trip")


def test_validation(conn):
    expect_value_error(lambda: db.insert_lift_session(conn, {**LIFT_PAYLOAD, "date": "garbage"}),
                       "lift: bad date rejected")
    expect_value_error(lambda: db.insert_lift_session(conn, {**LIFT_PAYLOAD, "exercises": []}),
                       "lift: empty exercises rejected")
    bad_sets = {**LIFT_PAYLOAD, "exercises": [{"name": "X", "sets": [{"weight_lb": 10, "reps": 0}]}]}
    expect_value_error(lambda: db.insert_lift_session(conn, bad_sets), "lift: reps=0 rejected")
    expect_value_error(lambda: db.insert_cardio(conn, {**CARDIO_PAYLOAD, "activity": "swim"}),
                       "cardio: bad activity rejected")
    expect_value_error(lambda: db.insert_cardio(
        conn, {"date": "2026-07-07", "activity": "run"}), "cardio: needs distance or duration")


def test_delete(conn):
    assert db.delete_lift_session(conn, "2026-07-06|Push #1|2026-07-06 18:00") == 4
    assert conn.execute("SELECT COUNT(*) FROM lifting_sets").fetchone()[0] == 0
    cid = conn.execute("SELECT id FROM cardio_sessions").fetchone()[0]
    assert db.delete_cardio(conn, cid) == 1
    assert db.delete_cardio(conn, cid) == 0
    ok("delete lift session by key, cardio by id")


def test_log_view(conn):
    db.insert_lift_session(conn, LIFT_PAYLOAD)
    db.insert_cardio(conn, CARDIO_PAYLOAD)
    view = db.fetch_log_view(conn)
    assert view["available"] is True and view["source"] == "coachbear.db"
    assert view["stats"]["total_sessions"] == 2, view["stats"]
    assert view["stats"]["data_through"] == "2026-07-07"
    first, second = view["sessions"][0], view["sessions"][1]
    assert first["cardio_id"] and first["name"].startswith("Run"), first  # newest first
    assert first["exercises"][0]["cardio"][0]["distance"] == 2.5
    assert second["key"] == "2026-07-06|Push #1|2026-07-06 18:00"
    assert second["duration_min"] == 65, second
    assert len(second["exercises"]) == 2 and len(second["exercises"][0]["sets"]) == 2
    ok("fetch_log_view: shape, ordering, stats")


CSV_FIXTURE = """Workout Start,Workout End,Exercise,Weight,Reps,Notes,Kcal,Distance,Duration,Category,Name,Bodyweight
2026-06-08 14:11,2026-06-08 15:08,"Lat Pull-down ",85,8,"",,,,Back,"Pull ",
2026-06-08 14:11,2026-06-08 15:08,"Lat Pull-down ",90,8,"",,,,Back,"Pull ",
2026-06-08 14:11,2026-06-08 15:08,"Seated Row",100,10,"",,,,Back,"Pull ",
2026-06-10 09:00,2026-06-10 09:40,"Bench Press",70,8,"",,,,Chest,"Push",
2026-06-11 08:00,2026-06-11 08:45,"Outdoor run",,,"",320,3.1,2700,Cardio,"Run",
2026-06-12 08:00,2026-06-12 08:45,"Cycling",,,"",250,,2400,Cardio,"Bike ride",
"""


def test_csv_import(conn, tmp):
    src = tmp / "export_test.csv"
    src.write_text(CSV_FIXTURE)
    res = db.import_csv(conn, src)
    assert res == {"lift_rows": 4, "cardio_rows": 2}, res
    sessions = conn.execute(
        "SELECT DISTINCT session_date, workout_name FROM lifting_sets WHERE source='csv-import'").fetchall()
    assert len(sessions) == 2, sessions
    setnums = [r[0] for r in conn.execute(
        "SELECT set_number FROM lifting_sets WHERE exercise='Lat Pull-down' ORDER BY id")]
    assert setnums == [1, 2], setnums
    acts = {r[0]: r[1] for r in conn.execute(
        "SELECT activity, duration_min FROM cardio_sessions WHERE source='csv-import'")}
    assert acts == {"run": 45.0, "bike": 40.0}, acts
    try:
        db.import_csv(conn, src)
    except RuntimeError:
        ok("csv import: counts, grouping, activity guess, re-import refused")
    else:
        raise AssertionError("second import should raise")


def test_plans(conn, tmp):
    meta = {"generated_at": "2026-07-06T10:00:00", "done": {"Monday": True}, "cost_usd": 0.5}
    db.upsert_plan(conn, "2026-W28", "Monday [Push]\n...", meta)
    db.upsert_plan(conn, "2026-W28", "Monday [Push]\nv2", {**meta, "done": {}})
    rows = conn.execute("SELECT week_key, markdown, done_json FROM weekly_plans").fetchall()
    assert len(rows) == 1 and rows[0][1].endswith("v2") and json.loads(rows[0][2]) == {}, rows
    pdir = tmp / "plans"
    pdir.mkdir()
    (pdir / "2026-W27.md").write_text("Monday [Rest]")
    (pdir / "2026-W27.json").write_text(json.dumps(meta))
    assert db.import_plans(conn, pdir) == 1
    assert conn.execute("SELECT COUNT(*) FROM weekly_plans").fetchone()[0] == 2
    ok("weekly_plans upsert + import_plans")


def test_query_cli(tmp):
    dbfile = tmp / "cli.db"
    conn = db.connect(dbfile)
    db.insert_cardio(conn, CARDIO_PAYLOAD)
    conn.close()
    here = Path(__file__).resolve().parent
    r = subprocess.run(
        [sys.executable, str(here / "db.py"), "--db", str(dbfile), "query",
         "SELECT COUNT(*) AS n FROM cardio_sessions"],
        capture_output=True, text=True)
    assert r.returncode == 0 and json.loads(r.stdout.strip()) == {"n": 1}, r.stdout + r.stderr
    r2 = subprocess.run(
        [sys.executable, str(here / "db.py"), "--db", str(dbfile), "query",
         "DELETE FROM cardio_sessions"],
        capture_output=True, text=True)
    assert r2.returncode != 0, "write query must fail in read-only mode"
    ok("query CLI: json output, read-only enforced")


def test_digest(conn2):
    """conn2 is a fresh db.  Prev week Mon 2026-06-29 .. Sun 2026-07-05."""
    planned = [
        {"day": "Monday", "kind": "lift", "type": "Push — Lift"},
        {"day": "Tuesday", "kind": "run", "type": "Run — Intervals"},
        {"day": "Wednesday", "kind": "lift", "type": "Pull — Lift"},
        {"day": "Saturday", "kind": "rest", "type": "Rest"},
    ]
    db.insert_lift_session(conn2, {**LIFT_PAYLOAD, "date": "2026-06-29", "start": "2026-06-29 18:00"})
    db.insert_cardio(conn2, {**CARDIO_PAYLOAD, "date": "2026-07-01"})  # run on planned PULL day
    d = db.build_digest(conn2, date(2026, 6, 29), planned, {"Tuesday": True})
    assert "Monday (2026-06-29) — planned Push — Lift: completed" in d, d
    assert "Tuesday (2026-06-30) — planned Run — Intervals: missed" in d, d
    assert "Wednesday (2026-07-01) — planned Pull — Lift: done differently" in d, d
    assert "marked done manually" in d, d
    assert "Saturday (2026-07-04) — rest day" in d, d
    assert "## Recent lifting" in d and "Bench Press" in d and "70lb x 8" in d, d
    assert "## Cardio volume" in d and "runs 1 (2.5 mi)" in d, d
    assert len(d) <= 2500
    d2 = db.build_digest(conn2, date(2026, 6, 29), None, None)
    assert "no stored plan" in d2, d2
    ok("digest: adherence statuses, lifting, cardio volume, no-plan fallback")


def main():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        conn = db.connect(tmp / "test.db")
        test_schema(conn)
        test_lift_roundtrip(conn)
        test_cardio_roundtrip(conn)
        test_validation(conn)
        test_delete(conn)
        test_log_view(conn)
        test_csv_import(conn, tmp)
        test_plans(conn, tmp)
        test_strava_insert(conn)
        conn.close()
        test_v1_migration(tmp)
        test_concurrent_init(tmp)
        test_query_cli(tmp)
        conn2 = db.connect(tmp / "digest.db")
        test_digest(conn2)
        conn2.close()
    print(f"all {PASS} checks passed")


if __name__ == "__main__":
    main()
