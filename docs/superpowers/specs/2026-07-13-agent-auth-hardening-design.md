# Executive-Agent Auth Hardening — Design

**Date:** 2026-07-13
**Status:** Approved (re-scoped 2026-07-13: caller is the executive agent, not coach-bear)

## Problem

The owner's **executive agent, Ramon,** runs on a separate VM and needs to reach the
CoachBear dashboard — and through it the coach-bear agent, which runs on this
host, spawned by the dashboard server (`POST /api/generate` starts a plan run,
`POST /api/chat` converses about a week). Remote access goes through the Caddy
proxy at `https://bear.kunigami.cloud`, which currently has a single basicauth
user (`manav`). Giving the executive agent those credentials means its
credential is irrevocable without changing the owner's password, and the agent
would have full access — including destructive endpoints — from a machine whose
environment holds the password.

Coach-bear's own Claude authentication is unaffected: it runs locally under the
owner's login, as today.

## Goals

- The executive agent gets its own credential (`ramon`), revocable
  independently of the owner's.
- The credential is scoped: full `/api/*` access **except** destructive
  operations — explicitly including `POST /api/generate` and `POST /api/chat`,
  which are how it reaches coach-bear; no access to the dashboard UI or other
  paths.
- Owner access and localhost access are completely unchanged.
- The authorization rules are unit-testable without sudo or a live proxy.

## Non-goals (out of scope)

- Rate limiting.
- Cost controls on `POST /api/generate` and `POST /api/chat` — the executive
  agent MAY trigger billable claude runs; owner explicitly accepted this
  (2026-07-13).
- Any change to localhost trust (processes on the host keep full access).
- TLS, DNS, or new subdomains.
- Claude authentication for either agent (executive agent manages its own on
  its VM; coach-bear uses this host's existing login).

## Design (approach B: Caddy identity + app-level policy)

### 1. Caddy (`deploy/Caddyfile.bear.snippet`, mirrored to `/etc/caddy/Caddyfile`)

```
bear.kunigami.cloud {
    basicauth {
        manav <existing hash>
        ramon <new bcrypt hash>
    }
    reverse_proxy localhost:8737 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
```

- Caddy authenticates both users and forwards the authenticated username in
  `X-Auth-User`, overwriting any client-supplied value.
- Revocation: delete the `ramon` line, `sudo systemctl reload caddy`.
- Validated against Caddy 2.6.2 (directive is `basicauth`, one word).

### 2. Authorization policy (`dashboard/server.py`)

A single policy function called at the top of `do_GET`, `do_POST`, and
`do_DELETE`, before any routing:

| Caller (`X-Auth-User`) | Access |
|---|---|
| absent (localhost/direct) | full — unchanged |
| `manav` | full — unchanged |
| `ramon` | `/api/*` only, minus the destructive set |
| any other value | treated like `ramon` (least privilege for unknown users) |

Destructive set (denied for `ramon`):
- Any request with method `DELETE`.
- `POST /api/plans/<week>/replace`.

The set is defined as one data structure adjacent to the route handlers so
future endpoints are a one-line classification.

Denied requests get `403` with a JSON body naming the blocked rule (e.g.
`{"error": "ramon credential may not call DELETE endpoints"}`) so the executive
agent receives actionable feedback.

Header spoofing note: a local process sending `X-Auth-User: ramon` only
*reduces* its own privileges; absence of the header means full access, which
localhost already has. Remote requests can only reach the server through
Caddy, which overwrites the header. No new attack surface.

### 3. Credential generation & handling

- Password: 32 random characters via `secrets` locally; shown to the owner
  once.
- Hash: `caddy hash-password`; only the hash is stored (Caddyfile + snippet).
- On the executive agent's VM: `COACH_API_URL=https://bear.kunigami.cloud` and
  `COACH_API_AUTH="ramon:<password>"` in its environment (shell profile or
  service unit — never in prompts or repo files).
- The `dashboard/api` wrapper already sends `COACH_API_AUTH` as a Basic
  Authorization header; the VM needs a copy of that standalone script (or the
  executive agent may call the API with any HTTP client using the same
  credentials).

### 4. Testing

New `dashboard/test_server_auth.py` in the existing test style (scratch
`COACH_DB`, never prod — see project rule):

- `X-Auth-User: ramon` + `GET /api/plans` → 200.
- `X-Auth-User: ramon` + `POST /api/workouts/cardio` (valid body) → 201.
- `X-Auth-User: ramon` + `POST /api/generate` → allowed (job starts or
  claude-unavailable error — anything but 403).
- `X-Auth-User: ramon` + `DELETE /api/workouts/cardio/<id>` → 403.
- `X-Auth-User: ramon` + `POST /api/plans/<wk>/replace` → 403.
- `X-Auth-User: ramon` + `GET /` (UI) → 403.
- `X-Auth-User: unknown-user` + `DELETE ...` → 403 (least privilege).
- No header + `DELETE /api/workouts/cardio/<id>` → unchanged behavior (not
  403 from the policy layer).
- `X-Auth-User: manav` + `DELETE ...` → unchanged behavior.

Post-deployment live checks (curl through the proxy): ramon creds GET 200,
ramon creds DELETE 403, no creds 401, owner creds unchanged.

### 5. Rollout (owner-performed sudo steps, last)

1. `sudo cp` updated Caddyfile block (or edit in place) → matches snippet.
2. `sudo systemctl reload caddy`.
3. `sudo systemctl restart coachbear-dashboard` (picks up server.py policy).
4. Put `COACH_API_URL` / `COACH_API_AUTH` in the executive agent's VM
   environment, plus a copy of `dashboard/api` if it will use the wrapper.

## Risks

- Caddyfile drift between snippet and `/etc/caddy/Caddyfile` (seen once
  already with a missed daemon-reload): mitigated by diffing after copy and
  the live curl matrix.
- If the dashboard is ever exposed without Caddy in front, the absent-header
  rule means full access; acceptable because the server binds to 127.0.0.1
  only.
