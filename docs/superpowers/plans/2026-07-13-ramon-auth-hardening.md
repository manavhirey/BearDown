# Ramon Auth Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the remote executive agent (Ramon) its own revocable, scoped basicauth credential for the CoachBear dashboard: full `/api/*` access (including `/api/generate` and `/api/chat`) minus destructive operations; no UI access.

**Architecture:** Caddy authenticates a second basicauth user `ramon` and forwards the authenticated username to the dashboard in an `X-Auth-User` header (overwriting any client-supplied value). `dashboard/server.py` enforces a policy at the top of every request: absent header or `manav` = full access; `ramon` (and any unknown user) = `/api/*` minus a destructive-route list.

**Tech Stack:** Python 3.12 stdlib only (`http.server`, `urllib`, `re`), Caddy 2.6.2, plain-assert test scripts.

**Spec:** `docs/superpowers/specs/2026-07-13-agent-auth-hardening-design.md`

## Global Constraints

- This project is **not a git repository** — there are no commit steps. Instead, each task ends by running the full test suite: `python3 dashboard/test_db.py && python3 dashboard/test_strava.py && python3 dashboard/test_server_auth.py` (last one exists from Task 1 on). All must print their final ok counts with exit code 0.
- Tests must NEVER touch `data/coachbear.db` or the real `plans/` directory. The new test file sets `COACH_DB` to a temp path **before importing** `server`, and reassigns `server.PLANS_DIR` to a temp dir. (Project rule: a test once wiped the prod DB.)
- Caddy is 2.6.2: the directive is `basicauth` (one word), and CLI flags are single-dash (`-plaintext`).
- Test style: plain-assert scripts with an `ok(label)` counter, run via `python3 dashboard/<file>.py` (see `dashboard/test_db.py`). No pytest.
- The basicauth username is exactly `ramon`; the identity header is exactly `X-Auth-User`.
- `POST /api/generate` and `POST /api/chat` must remain ALLOWED for `ramon` (owner decision 2026-07-13). `POST /api/strava/config` is also allowed (owner declined to restrict it).
- Sudo steps (Caddy/systemd) are performed by the owner only, in Task 4.

---

### Task 1: Authorization policy function with unit tests

**Files:**
- Modify: `dashboard/server.py` (insert at line 55, immediately after the `ALLOWED_TOOLS` block and before `WEEK_KEY_RE`)
- Create: `dashboard/test_server_auth.py`

**Interfaces:**
- Produces: `server.deny_reason(user: str, method: str, path: str) -> str | None` — returns a human-readable denial reason, or `None` if the request is allowed. Also module constants `server.FULL_ACCESS_USERS: set[str]` and `server.DESTRUCTIVE_ROUTES: tuple`. Task 2 calls `deny_reason` from the request handler.

- [ ] **Step 1: Write the failing unit tests**

Create `dashboard/test_server_auth.py`:

```python
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


if __name__ == "__main__":
    test_deny_reason()
    print(f"{PASS} tests passed")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 dashboard/test_server_auth.py`
Expected: `AttributeError: module 'server' has no attribute 'deny_reason'`

- [ ] **Step 3: Implement the policy function**

In `dashboard/server.py`, insert after the `ALLOWED_TOOLS` block (after line 55, before `WEEK_KEY_RE = ...`):

```python
# ---------------------------------------------------------------- auth policy
# Caddy forwards the authenticated basicauth username in X-Auth-User and
# overwrites any client-supplied value; an absent header means direct
# localhost access (fully trusted). Scoped users get /api/* minus the
# destructive routes below. Spec:
# docs/superpowers/specs/2026-07-13-agent-auth-hardening-design.md
FULL_ACCESS_USERS = {"", "manav"}
DESTRUCTIVE_ROUTES = (
    ("DELETE", re.compile(r".*"), "DELETE endpoints"),
    ("POST", re.compile(r"/api/plans/[^/]+/replace"), "plan replacement"),
)


def deny_reason(user: str, method: str, path: str):
    """Why this proxy user may not make this request; None if allowed."""
    if user in FULL_ACCESS_USERS:
        return None
    if not path.startswith("/api/"):
        return f"{user!r} credential may only access /api/ endpoints"
    for rule_method, rule_re, label in DESTRUCTIVE_ROUTES:
        if method == rule_method and rule_re.fullmatch(path):
            return f"{user!r} credential may not call {label}"
    return None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 dashboard/test_server_auth.py`
Expected: `5 tests passed`, exit 0

- [ ] **Step 5: Run the full suite**

Run: `python3 dashboard/test_db.py && python3 dashboard/test_strava.py && python3 dashboard/test_server_auth.py`
Expected: all three print their pass counts, exit 0

---

### Task 2: Enforce the policy in the request handler, with HTTP integration tests

**Files:**
- Modify: `dashboard/server.py` — `Handler._error` vicinity (~line 492) and the first lines of `do_GET` (~line 527), `do_POST` (~line 603), `do_DELETE` (~line 723)
- Modify: `dashboard/test_server_auth.py` (append integration tests)

**Interfaces:**
- Consumes: `deny_reason(user, method, path)` from Task 1.
- Produces: HTTP behavior — any request whose `X-Auth-User` fails the policy gets `403` with body `{"error": "<reason>"}` before any routing runs. No new Python API.

- [ ] **Step 1: Append the failing integration tests**

Append to `dashboard/test_server_auth.py` (above the `if __name__ == "__main__":` block), and extend that block as shown:

```python
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
```

(Replace the existing `if __name__ == "__main__":` block with the version above.)

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `python3 dashboard/test_server_auth.py`
Expected: unit tests pass, then an AssertionError in `test_http_policy` at "ramon DELETE -> 403" (the handler doesn't enforce anything yet, so the DELETE succeeds).

- [ ] **Step 3: Wire the policy into the handler**

In `dashboard/server.py`, add a helper to `Handler` directly after `_error` (~line 493):

```python
    def _forbidden(self, path):
        """Enforce the proxy-user policy; True if the request was rejected."""
        reason = deny_reason(self.headers.get("X-Auth-User", ""), self.command, path)
        if reason:
            self._json({"error": reason}, 403)
            return True
        return False
```

Then in each of `do_GET`, `do_POST`, and `do_DELETE`, insert the check between the `path = urlparse(self.path).path` line and the `try:` line. All three become:

```python
        path = urlparse(self.path).path
        if self._forbidden(path):
            return
        try:
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 dashboard/test_server_auth.py`
Expected: `14 tests passed`, exit 0

- [ ] **Step 5: Run the full suite**

Run: `python3 dashboard/test_db.py && python3 dashboard/test_strava.py && python3 dashboard/test_server_auth.py`
Expected: all three pass, exit 0

---

### Task 3: Generate Ramon's credential and update the Caddyfile snippet

**Files:**
- Modify: `deploy/Caddyfile.bear.snippet`

**Interfaces:**
- Consumes: nothing from earlier tasks (Caddy-side only).
- Produces: the final snippet with both users and the `X-Auth-User` header forwarding; the plaintext password (shown once, for the owner to place on Ramon's VM).

- [ ] **Step 1: Generate the password (do not store it anywhere in the repo)**

Run: `python3 -c "import secrets; print(secrets.token_urlsafe(24))"`
Expected: a ~32-char URL-safe random string. Keep it for Steps 2 and the handoff; it appears in the final report to the owner ONLY.

- [ ] **Step 2: Hash it with Caddy**

Run: `caddy hash-password -plaintext '<password from step 1>'`
Expected: a `$2a$14$...` bcrypt hash. (If the single-dash flag is rejected, run `caddy hash-password` and enter the password at the prompt.)

- [ ] **Step 3: Update the snippet**

Rewrite `deploy/Caddyfile.bear.snippet` to (keep the existing `manav` hash exactly as it is; substitute the real hash from Step 2 for `<RAMON_HASH>`):

```
# Append this block to /etc/caddy/Caddyfile, then: sudo systemctl reload caddy
# Validated against Caddy 2.6.2 (directive is `basicauth`, one word).
# Users: `manav` (owner, full access) and `ramon` (executive agent on remote
# VM — scoped by dashboard/server.py to non-destructive /api/* via the
# X-Auth-User header forwarded below). Revoke ramon: delete its line, reload.
# manav hash generated 2026-07-08; ramon hash 2026-07-13.

bear.kunigami.cloud {
    basicauth {
        manav $2a$14$H1dFZaZavZef6gkWr/dsHeZgm7/KtXTG903XTy7oIDi44QiG4Q/8G
        ramon <RAMON_HASH>
    }
    reverse_proxy localhost:8737 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
```

- [ ] **Step 4: Validate the snippet syntax**

Run: `cd /tmp && printf '%s\n' "$(cat /home/manav/CoachBear/deploy/Caddyfile.bear.snippet)" > /tmp/caddy-validate-test && caddy validate --adapter caddyfile --config /tmp/caddy-validate-test; rm /tmp/caddy-validate-test`
Expected: `Valid configuration` (Caddy may warn about missing TLS context outside the real config; an adapt/parse success is what matters. If validate insists on resolving TLS, `caddy adapt --adapter caddyfile --config ...` succeeding is sufficient.)

- [ ] **Step 5: Run the full suite (unchanged, regression check)**

Run: `python3 dashboard/test_db.py && python3 dashboard/test_strava.py && python3 dashboard/test_server_auth.py`
Expected: all pass, exit 0

---

### Task 4: Rollout and live verification (owner performs sudo steps)

**Files:**
- None (live `/etc/caddy/Caddyfile` and systemd, owner-performed)

**Interfaces:**
- Consumes: the snippet from Task 3 and the running policy from Task 2.
- Produces: the deployed system; a verified curl matrix.

- [ ] **Step 1: Owner updates the live Caddyfile**

Ask the owner to run (via `!` in the prompt):

```
! sudo python3 - <<'EOF'
import re, pathlib
live = pathlib.Path("/etc/caddy/Caddyfile")
snippet = pathlib.Path("/home/manav/CoachBear/deploy/Caddyfile.bear.snippet").read_text()
block = snippet[snippet.index("bear.kunigami.cloud {"):]
text = live.read_text()
new = re.sub(r"bear\.kunigami\.cloud \{.*?\n\}\n", block, text, count=1, flags=re.S)
assert new != text, "bear block not found/replaced"
live.write_text(new)
print("bear block replaced")
EOF
```

Expected: `bear block replaced`

- [ ] **Step 2: Owner reloads Caddy and restarts the dashboard**

```
! sudo systemctl reload caddy && sudo systemctl restart coachbear-dashboard
```

Expected: no output, exit 0.

- [ ] **Step 3: Verify the live curl matrix**

Run (with `<PW>` = Ramon's plaintext password from Task 3):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://bear.kunigami.cloud/api/status                      # expect 401
curl -s -o /dev/null -w '%{http_code}\n' -u "ramon:<PW>" https://bear.kunigami.cloud/api/status      # expect 200
curl -s -o /dev/null -w '%{http_code}\n' -u "ramon:<PW>" https://bear.kunigami.cloud/                 # expect 403
curl -s -w '\n%{http_code}\n' -u "ramon:<PW>" -X DELETE https://bear.kunigami.cloud/api/workouts/cardio/999999  # expect JSON error + 403
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Auth-User;' -u "ramon:<PW>" https://bear.kunigami.cloud/api/status  # expect 200 (spoof attempt still resolves to ramon)
```

Also verify locally that direct access is unchanged: `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8737/api/status` → 200.

(Owner's own login is checked by simply loading the dashboard in the browser as usual.)

- [ ] **Step 4: Hand off Ramon's environment**

Report to the owner, exactly once, the values to place on Ramon's VM (environment, not prompts):

```
COACH_API_URL=https://bear.kunigami.cloud
COACH_API_AUTH="ramon:<PW>"
```

plus a copy of `dashboard/api` (standalone script) if Ramon uses the wrapper, and the allow rule `Bash(./dashboard/api:*)` in that project's `.claude/settings.local.json`.

---

## Self-Review Notes

- Spec coverage: Caddy changes → Task 3; policy table & destructive set → Task 1; handler wiring & 403 body → Task 2; credential handling → Task 3/4; test list → Tasks 1–2 (all nine spec test cases present); rollout + live checks → Task 4. Strava-config intentionally unrestricted (owner decision).
- The `X-Auth-User: unknown` least-privilege rule is covered in both unit ("stranger") and HTTP tests.
- Type consistency: `deny_reason(user, method, path) -> str | None` used identically in Tasks 1 and 2; `_forbidden(path)` reads method from `self.command`.
