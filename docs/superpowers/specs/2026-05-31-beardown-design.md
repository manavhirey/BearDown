# BearDown — Design Spec

**Date:** 2026-05-31
**Status:** Approved, ready for implementation planning

## 1. Summary

BearDown is a native iOS app that turns a personal coaching agent (Anthropic Claude) into a structured, persistent training program. The user chats with the agent; the agent emits workouts via tool calls; the app renders them in a week calendar and a full multi-week plan view; the user marks each workout completed or failed; the agent sees that history on every subsequent turn and adapts.

## 2. Goals and non-goals

**Goals (v1):**
- Chat-driven generation of multi-week training plans (4–8 week mesocycles).
- Week-calendar tab and full-plan tab, both rendering strength + cardio + mobility workouts.
- Tap a workout → mark completed or failed, with an optional note.
- Adaptive coaching: agent receives recent completion history on every turn.
- Per-workout local notifications.
- iCloud sync across the user's Apple devices.

**Non-goals (v1):**
- Multi-user / accounts / social features.
- Per-exercise actuals logging (weight × reps performed). Status only.
- HealthKit integration.
- Apple Watch app.
- In-app purchases, paywalls.
- User-editable system prompt. (The prompt is hardcoded; the user is the developer.)
- Image / video attachments in chat.
- Multiple simultaneous active plans.

## 3. Platform and tech choices

| Decision | Value | Rationale |
|---|---|---|
| Min iOS | 17.0 | SwiftData requires 17; CloudKit sync is supported. |
| UI | SwiftUI | Native, fast to build, plays well with `@Query`. |
| Persistence | SwiftData with `cloudKitDatabase: .automatic` | Modern, codegen-free; private CloudKit sync. |
| Secrets | Keychain (`kSecAttrAccessibleAfterFirstUnlock`) | API key must never enter iCloud. |
| LLM | Anthropic Claude — `claude-sonnet-4-6` (hardcoded) | Balanced cost/quality for planning. |
| LLM transport | Direct `URLSession.bytes(for:)` SSE call | No SDK dependency; ~150-line client. |
| Notifications | `UNUserNotificationCenter` (local only) | No push entitlement, no server. |
| Architecture | SwiftUI views + per-feature `ObservableObject` view models + repositories | Repositories are the only layer that touches `ModelContext`. |

## 4. Architecture

### 4.1 Module layout

```
BearDown/
├── App/
│   ├── BearDownApp.swift           // @main, ModelContainer setup, root TabView
│   └── AppEnvironment.swift        // dependency container (services + repos)
├── Models/                         // SwiftData @Model types
│   ├── TrainingPlan.swift
│   ├── Workout.swift
│   ├── WorkoutBlock.swift
│   ├── Exercise.swift
│   ├── CardioDetail.swift
│   ├── ChatMessage.swift
│   └── Enums.swift                 // WorkoutStatus, BlockKind, ChatRole
├── Persistence/
│   ├── ModelContainer+Beardown.swift
│   ├── PlanRepository.swift
│   ├── WorkoutRepository.swift
│   └── ChatRepository.swift
├── Coach/
│   ├── AnthropicClient.swift       // SSE Messages API client
│   ├── CoachService.swift          // turn orchestration, tool loop
│   ├── CoachPrompt.swift           // hardcoded system prompt + Context builder
│   ├── CoachTools.swift            // tool schemas + dispatch
│   └── CoachError.swift
├── Notifications/
│   └── NotificationScheduler.swift
├── Keychain/
│   └── KeychainStore.swift
├── Views/
│   ├── Onboarding/OnboardingView.swift
│   ├── Week/WeekView.swift
│   ├── Plan/PlanView.swift
│   ├── Coach/CoachView.swift
│   ├── Settings/SettingsView.swift
│   └── Shared/WorkoutDetailSheet.swift
└── ViewModels/
    ├── OnboardingViewModel.swift
    ├── WeekViewModel.swift
    ├── PlanViewModel.swift
    ├── CoachViewModel.swift
    └── SettingsViewModel.swift
```

### 4.2 Data flow — "ask coach for a plan" turn

1. User types in `CoachView`; `CoachViewModel.send()` appends to local draft, calls `CoachService.send()`.
2. `CoachService` assembles the request: hardcoded system prompt + generated Context block + full persisted chat history + tool definitions.
3. SSE stream comes back. Text deltas update the in-flight assistant `ChatMessage.text`; tool-use blocks accumulate.
4. On `stop_reason == tool_use`: persist the assistant message (with `toolCallsJSON`), execute each tool sequentially against repositories, append `tool_result` blocks, send a follow-up request. Loop.
5. On `stop_reason == end_turn`: persist final assistant message, stop.
6. `WeekView` and `PlanView` are observing `@Query` results and update automatically when SwiftData changes.

## 5. Data model

All entities have `id: UUID`, `createdAt: Date`, `updatedAt: Date`. Relationships use `@Relationship` with explicit inverses and deletion rules.

```
TrainingPlan
├─ id, title: String, startDate: Date, endDate: Date
├─ isActive: Bool                       // exactly one true at any time
├─ archivedAt: Date?
└─ workouts: [Workout]                  // .cascade

Workout                                 // one per scheduled day
├─ id, date: Date                       // normalized to startOfDay
├─ title: String, summary: String
├─ status: WorkoutStatus                // .pending | .completed | .failed
├─ completionNote: String?
├─ completedAt: Date?
├─ notificationId: String?              // UNNotificationRequest identifier; @Attribute(.transient) — device-local, not synced
├─ plan: TrainingPlan                   // inverse, .nullify
└─ blocks: [WorkoutBlock]               // .cascade, ordered by `order`

WorkoutBlock
├─ id, order: Int
├─ kind: BlockKind                      // .strength | .cardio | .mobility
├─ title: String, notes: String
├─ workout: Workout                     // inverse, .nullify
├─ exercises: [Exercise]                // .cascade, ordered (strength only)
└─ cardio: CardioDetail?                // .cascade (cardio only)

Exercise
├─ id, order: Int, name: String
├─ sets: Int
├─ reps: String                         // "8–10", "AMRAP", "5"
├─ load: String?                        // "80kg", "bodyweight", "RPE 7"
├─ restSeconds: Int?
└─ block: WorkoutBlock                  // inverse, .nullify

CardioDetail
├─ id, modality: String                 // "run", "bike", "row", "swim"
├─ durationMinutes: Int?
├─ distanceMeters: Double?
├─ targetDescription: String?           // "zone 2", "5×400m @ 1:30"
└─ block: WorkoutBlock                  // inverse, .nullify

ChatMessage
├─ id, role: ChatRole                   // .user | .assistant
├─ text: String
├─ toolCallsJSON: String?               // raw tool_use blocks
├─ toolResultsJSON: String?             // raw tool_result blocks (on user-role messages following a tool turn)
├─ conversationId: UUID                 // groups messages into threads
└─ createdAt: Date
```

**Enums:**
- `WorkoutStatus`: `pending`, `completed`, `failed`
- `BlockKind`: `strength`, `cardio`, `mobility`
- `ChatRole`: `user`, `assistant`

**CloudKit constraints honored:** every relationship has an inverse; every non-optional value type has a default; no `@Attribute(.unique)` on user-mutable fields. Uniqueness of "one workout per date per active plan" is enforced by the repository layer.

**Transient fields (never synced):** `Workout.notificationId` is marked `@Attribute(.transient)` because notification identifiers are issued by the device's local `UNUserNotificationCenter` and are meaningless on any other device. Each device's `NotificationScheduler` reconciles its own set of pending requests from the synced `Workout` rows.

## 6. Agent integration

### 6.1 Hardcoded system prompt

The system prompt lives in `Coach/CoachPrompt.swift` as a `static let base: String`. The user (developer) supplies the prompt text before first build. The prompt must instruct the agent to:

1. Use `upsert_workout` for every scheduled day — never just describe a plan in prose.
2. Structure each day as one or more blocks tagged `strength`, `cardio`, or `mobility`.
3. Generate 4–8 weeks of training per plan, starting from "today" (provided in the Context block).
4. Use `delete_workout` to remove a day rather than rewriting it as a rest day.
5. Use `get_recent_history` when it needs more than the always-on 14-day window.
6. Speak conversationally between tool calls — narrate intent, ask the user for input when ambiguous.

The exact wording is the user's choice and may be tuned freely; the contract above is what the rest of the app assumes.

### 6.2 Context block (always injected)

Before each request, `CoachService` appends a Context section to the system prompt:

```
<context>
Today: 2026-05-31 (Sunday)
Active plan: "Spring strength block" — Week 3 of 6, started 2026-05-17, ends 2026-06-28.
Recent history (last 14 days):
  2026-05-30 | Pull day            | completed | "shoulders felt great"
  2026-05-29 | Easy run 30min      | completed
  2026-05-28 | Push day            | failed    | "bench felt heavy, stopped at set 3"
  ...
</context>
```

This guarantees the "agent sees history each turn" requirement without requiring a tool call. The `get_recent_history` tool exists for windows >14 days.

### 6.3 Tools

JSON Schema defined in `CoachTools.swift`. Three tools:

**`upsert_workout`** — creates or replaces a workout on a given date in the active plan.
```
input:
  date: string (YYYY-MM-DD)
  title: string
  summary: string                       // one-line description for the calendar card
  blocks: [
    {
      kind: "strength" | "cardio" | "mobility"
      title: string
      notes: string
      exercises?: [                     // required when kind=strength
        { name, sets, reps, load?, rest_seconds? }
      ]
      cardio?: {                        // required when kind=cardio
        modality, duration_minutes?, distance_meters?, target?
      }
    }
  ]
effect: upsert keyed on (active_plan, date). Reschedules notification.
```

**`delete_workout`** — removes a workout and its notification.
```
input: { date: string }
```

**`get_recent_history`** — returns up to 30 days of completion history.
```
input: { days: int (1..30, default 14) }
result: JSON array of { date, title, status, note?, blocks_summary }
```

### 6.4 Tool loop and guardrails

- Sequential tool execution. Each tool's error is captured and returned as `tool_result` with `is_error: true`; the agent self-corrects on the next iteration.
- Max iterations per user turn: **10**. Beyond that, the loop stops and the UI surfaces "Coach got stuck — try rephrasing."
- Max response tokens: **8192**.
- API key never logged. Request bodies are not persisted (only the assistant's emitted `ChatMessage`s are).

## 7. Screens

### 7.1 Onboarding

Shown when `KeychainStore.apiKey == nil`.
- BearDown wordmark, one-paragraph explainer, `SecureField` for the Anthropic API key, link to `console.anthropic.com`, `Continue` button.
- `Continue` validates the key by sending a 1-token `claude-sonnet-4-6` ping. On success, store in Keychain, dismiss to Coach tab with an empty conversation. On failure, inline error.

### 7.2 Week tab (default landing tab)

- Header: month / year + `<` `>` week stepper. Tapping the title jumps to current week.
- Body: seven horizontal day cards (Mon–Sun, locale-aware first day). Today highlighted with accent color. Each card shows: day name, date number, workout title, kind-badge strip (💪 / 🏃 / 🧘), status icon (empty / green check / red X).
- Tap card → `WorkoutDetailSheet`.
- Empty state: "No plan yet. Ask the Coach to build one." with a button that switches to the Coach tab.

### 7.3 Plan tab

- Vertical scroll, grouped by week.
- Section header per week: "Week 1 · May 31 – Jun 6" with a progress pill (`3/5 complete`).
- One compact row per workout day inside each section: date, title, kind-badges, status icon.
- Tap row → same `WorkoutDetailSheet`.
- Empty state mirrors Week tab.

### 7.4 Coach tab

- Standard chat list: user bubbles right, assistant bubbles left, time-grouped.
- Streaming responses render live with a caret indicator.
- Tool calls render inline as compact chips inside the assistant bubble ("📅 Scheduled workout for Jun 3 — Push day"). Tapping a chip switches to Week tab focused on that date. Tool errors render as yellow chips with the error text.
- Composer: multi-line text field + send button. Disabled while streaming.
- Toolbar: "New chat" button (archives the current `conversationId`, starts a fresh thread). Old conversations stay in SwiftData but are not surfaced in v1.

### 7.5 Settings tab

- API Key — masked field, "Replace" button → re-runs the validation ping.
- Default reminder time — `DatePicker` (time only), defaults to 7:00 AM.
- Notifications — master toggle. First enable calls `requestAuthorization`. When off, all `workout-*` notifications cancelled.
- About — version, link to Anthropic privacy policy, "Delete all data" (double-confirm; wipes SwiftData + Keychain).

### 7.6 Shared component

`WorkoutDetailSheet` (in `Views/Shared/`) renders one workout's blocks (strength tables / cardio details / mobility notes) and exposes the single primary action: a `Menu`-backed button labeled by current status. Menu items: **Mark Completed**, **Mark Failed**. Selecting one flips status, opens an inline optional-note field, shows Save and Skip. Re-tapping the button allows changing status.

## 8. Notifications

`NotificationScheduler` is an actor — the only thing in the app touching `UNUserNotificationCenter`.

**Authorization:**
- Not requested at launch.
- Requested first time the user enables the master toggle, or via a soft prompt after the first plan is generated ("Want a reminder before each workout?").
- If iOS authorization is denied while the master toggle is on, Settings shows an inline "Open iOS Settings" link.

**Scheduling rules:**
- For each `Workout` with `status == .pending` and `date >= today`, schedule one `UNCalendarNotificationTrigger` at the workout's date + the Settings default time.
- Identifier: `"workout-\(workout.id.uuidString)"`, also written to `Workout.notificationId`.
- Title: workout title. Body: workout summary.
- Past-dated workouts are never scheduled. Completed/failed workouts have their notification cancelled.

**Reconciliation (idempotent — safe to call any time):**
1. After `upsert_workout`: cancel existing notification for that workout, schedule a new one if pending + future + enabled.
2. After `delete_workout`: cancel.
3. After user marks completed/failed: cancel.
4. After Settings → reminder time changes: full re-reconcile.
5. After master toggle on: full re-reconcile. After off: cancel all `workout-*` IDs.
6. App-launch sanity pass on `applicationDidBecomeActive`: enumerate pending notifications, drop any whose `Workout` no longer exists or is no longer pending.

Notifications are device-local and do not sync via CloudKit. Each device schedules its own from its own SwiftData mirror.

## 9. Error handling and edge cases

| Surface | Behaviour |
|---|---|
| Missing / invalid API key | `CoachView` banner: "API key invalid. Update it in Settings." with deep link. |
| Network failure mid-stream | Partial assistant message discarded. Inline "Send failed — Retry" attached to the last user message. |
| Tool input validation failure | Tool returns `tool_result` with `is_error: true`. Agent self-corrects. After 10 iterations: "Coach got stuck — try rephrasing." |
| CloudKit sync conflict | Last-write-wins per record (SwiftData default). Sub-collections not merged. |
| iCloud disabled / signed out | App fully functional locally; Settings shows a one-time banner. |
| Notification authorization denied | Master toggle becomes no-op with "Open iOS Settings" inline link. |
| Fresh install on a second iCloud-signed-in device | Keychain doesn't sync. Onboarding shows; user enters API key. Plans then appear automatically as CloudKit catches up. Expected behaviour, not an error — but the empty-state copy on Week/Plan tabs must handle the brief "onboarded but plans haven't synced yet" window gracefully ("Loading your plan…"). |
| Time zone change | `Workout.date` is day-precision; calendar-based notification triggers re-anchor to local time. |
| Agent emits duplicate `upsert_workout` for the same date | Repository upsert is idempotent on `date`; last one wins. |
| Agent emits a workout outside the plan's `startDate..<endDate` | Repository extends `endDate` to cover it. |
| New plan generation while one is active | Old plan flipped to `isActive == false`, `archivedAt` set. Workouts persist in history queries. |

## 10. Testing strategy

- **Unit tests (XCTest):**
  - Repository CRUD, upsert idempotency, plan-extension behaviour.
  - `NotificationScheduler` reconciliation with a fake `UNUserNotificationCenter`.
  - `AnthropicClient` SSE parser with recorded fixture responses.
  - Tool input validators.
- **Integration tests:**
  - Full agent turn against a recorded `claude-sonnet-4-6` fixture stream including text + multiple `upsert_workout` calls. Assert resulting SwiftData state. In-memory `ModelContainer`.
- **UI tests (XCUITest):**
  - Onboarding happy path.
  - Mark-completed flow from Week view (tap card → menu → save with note).
  - Status change in detail sheet.
- **Manual checklist (in repo `docs/manual-tests.md`):**
  - Fresh-install onboarding end-to-end.
  - iCloud sync across two devices.
  - Notification fires at scheduled time.
  - API key rotation.

## 11. Open content gaps

These are content the developer must supply before / during implementation. They do not affect the architecture.

1. **System prompt text** for `CoachPrompt.base` — must meet the behavioral contract in §6.1.
2. **App icon and accent color** — visual identity not specified here.
3. **About-screen copy** and Anthropic privacy policy URL.

## 12. References

- Anthropic Messages API: https://docs.claude.com/en/api/messages
- Anthropic streaming format: https://docs.claude.com/en/api/messages-streaming
- Anthropic tool use: https://docs.claude.com/en/docs/build-with-claude/tool-use
- SwiftData + CloudKit: Apple WWDC23 "Model your schema with SwiftData"
