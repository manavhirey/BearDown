"""Plain-assert tests for the X-Auth-User authorization policy.

Run: python3 dashboard/test_server_auth.py
"""

import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

# Isolate ALL state before importing server: scratch DB (project rule —
# never touch data/coachbear.db) and mock mode (no real claude calls).
TMP = Path(tempfile.mkdtemp(prefix="coachbear-auth-test-"))
os.environ["COACH_DB"] = str(TMP / "test.db")
os.environ["COACH_MOCK"] = "1"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import server  # noqa: E402

server.PLANS_DIR = TMP / "plans"  # never write into the real plans/

PASS = 0


def ok(label):
    global PASS
    PASS += 1
    print(f"  ok {PASS} - {label}")


def test_deny_reason():
    # Full-access callers: absent header (localhost) and the owner.
    assert server.deny_reason("", "DELETE", "/api/workouts/cardio/1") is None
    assert server.deny_reason("manav", "DELETE", "/api/workouts/cardio/1") is None
    assert server.deny_reason("manav", "GET", "/") is None
    ok("full-access users bypass the policy entirely")

    # Ramon: non-destructive /api/* is allowed, incl. generate/chat.
    assert server.deny_reason("ramon", "GET", "/api/plans") is None
    assert server.deny_reason("ramon", "GET", "/api/status") is None
    assert server.deny_reason("ramon", "POST", "/api/generate") is None
    assert server.deny_reason("ramon", "POST", "/api/chat") is None
    assert server.deny_reason("ramon", "POST", "/api/workouts/cardio") is None
    ok("ramon may use non-destructive /api/ endpoints incl. generate/chat")

    # Ramon: destructive set is denied.
    assert server.deny_reason("ramon", "DELETE", "/api/workouts/cardio/1")
    assert server.deny_reason("ramon", "DELETE", "/api/workouts/lift/abc")
    assert server.deny_reason("ramon", "POST", "/api/plans/2026-W29/replace")
    ok("ramon is blocked from destructive endpoints")

    # Ramon: everything outside /api/ is denied.
    assert server.deny_reason("ramon", "GET", "/")
    assert server.deny_reason("ramon", "GET", "/static/app.js")
    ok("ramon is blocked outside /api/")

    # Unknown users get least privilege (same scope as ramon).
    assert server.deny_reason("stranger", "DELETE", "/api/workouts/cardio/1")
    assert server.deny_reason("stranger", "GET", "/") is not None
    assert server.deny_reason("stranger", "GET", "/api/status") is None
    ok("unknown users get least privilege")


def start_test_server():
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


def request(port, method, path, user=None, body=None):
    headers = {"Content-Type": "application/json"}
    if user is not None:
        headers["X-Auth-User"] = user
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=data, method=method, headers=headers
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        return exc.code, json.loads(raw) if raw else None


def test_http_policy():
    httpd, port = start_test_server()
    try:
        status, _ = request(port, "GET", "/api/status", user="ramon")
        assert status == 200
        ok("ramon GET /api/status -> 200")

        cardio = {"date": "2026-07-12", "activity": "run",
                  "distance_mi": 2.0, "duration_min": 25}
        status, resp = request(port, "POST", "/api/workouts/cardio",
                               user="ramon", body=cardio)
        assert status == 201, resp
        entry_id = resp["entry"]["id"]
        ok("ramon POST /api/workouts/cardio -> 201")

        status, resp = request(port, "DELETE",
                               f"/api/workouts/cardio/{entry_id}", user="ramon")
        assert status == 403 and "may not" in resp["error"], resp
        ok("ramon DELETE -> 403 with actionable error")

        status, resp = request(port, "POST", "/api/plans/2026-W29/replace",
                               user="ramon", body={"markdown": "x"})
        assert status == 403, resp
        ok("ramon plan replace -> 403")

        status, resp = request(port, "GET", "/", user="ramon")
        assert status == 403, resp
        ok("ramon UI -> 403")

        status, resp = request(port, "DELETE",
                               f"/api/workouts/cardio/{entry_id}", user="stranger")
        assert status == 403, resp
        ok("unknown user DELETE -> 403")

        # Mock mode + patched PLANS_DIR: starts a fake job, no real claude run,
        # nothing written outside TMP. Anything but 403 proves policy allows it.
        status, resp = request(port, "POST", "/api/generate",
                               user="ramon", body={"week": "2020-W01"})
        assert status != 403, resp
        ok("ramon POST /api/generate is not blocked by the policy")

        status, resp = request(port, "DELETE",
                               f"/api/workouts/cardio/{entry_id}", user="manav")
        assert status != 403, resp
        ok("manav DELETE unaffected")

        status, resp = request(port, "DELETE", "/api/workouts/cardio/999999")
        assert status != 403, resp
        ok("no-header (localhost) DELETE unaffected")
    finally:
        httpd.shutdown()


if __name__ == "__main__":
    test_deny_reason()
    test_http_policy()
    print(f"{PASS} tests passed")
