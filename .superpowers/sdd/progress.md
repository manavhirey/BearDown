# SDD Progress — ramon-auth-hardening (plan: docs/superpowers/plans/2026-07-13-ramon-auth-hardening.md)

No git in this repo: "commits" are snapshot diffs under the session scratchpad.

- Task 1: complete (deny_reason + unit tests; 26/26 suite; review clean/Approved).
  Minor findings for final review triage: (a) test file imports json/threading/urllib/ThreadingHTTPServer before Task 2 uses them — self-resolved in Task 2; (b) deny_reason lacks `-> str | None` return annotation vs Interfaces block; (c) single blank line before WEEK_KEY_RE (PEP8 wants two).
- Task 2: complete (_forbidden wired into all 3 handlers, verified live; 14 auth tests, 35/35 suite; review Approved; keep-alive risk checked and ruled out).
  Minor findings for final review triage: (d) "manav DELETE unaffected" test only asserts status != 403, not success; (e) start_test_server never calls httpd.server_close().
- Task 3: complete (snippet has ramon hash + header_up; hash bcrypt-verified against plaintext; validate OK; suite 35/35; review Approved). Plaintext password lives in scratchpad task-3-report.md only.
  Minor finding: (f) snippet uses 4-space indent, caddy fmt prefers tabs (pre-existing style).
- Task 4: complete. First rollout attempt failed (multi-line `!` command didn't modify /etc/caddy/Caddyfile; reload succeeded on old config → ramon 401). Fixed by pre-building validated Caddyfile.new in scratchpad; owner cp'd + reloaded. Full live curl matrix passed (401/200/403s/spoof/local).
- Final whole-change review (fable): READY, zero Critical/Important. Path-canonicalization bypass structurally absent (policy and router share the same un-decoded path). Minors b-f triaged: all leave. Note: /api/strava/callback + /api/strava/sync are ramon-reachable by approved policy (flagged as known consequence).
- FEATURE COMPLETE AND DEPLOYED 2026-07-13. Ramon's password delivered to owner in chat; also in task-3-report.md (scratchpad, session-lifetime).
- POST-DEPLOY: original password suffered repeated O→0 transcription errors reaching Ramon's VM (.env never got the correct bytes). Rotated 2026-07-13 to an unambiguous-alphabet password (no O/0/l/1/I; scratchpad ramon-password-v2.txt); snippet + live Caddyfile updated; verified new=200/old=401/policy intact.
