# CLAUDE.md — BearDown

Notes for future Claude sessions on this iOS app. Skim before making changes.

## What this is

Native iOS 17+ SwiftUI app. A hardcoded coaching agent (Anthropic Claude Sonnet 4.6, with the user's verbatim "Hybrid Athlete Coach" prompt) generates 4-week training blocks via tool calls, with multi-plan support: any number of named plans, one active at a time, switched via Coach chips or the Plans tab. The app persists workouts to SwiftData with CloudKit sync, renders them as a single-day Today view and a list+detail Plans tab, and lets the user mark each workout completed or failed. Per-workout local notifications.

Full design rationale: `docs/superpowers/specs/2026-05-31-beardown-design.md`. Original implementation plan: `docs/superpowers/plans/2026-05-31-beardown.md`. Manual test checklist: `docs/manual-tests.md`.

## Project layout (important — non-obvious)

Xcode created a nested wrapper folder. The git repo root and the Xcode project root are NOT the same.

```
/Users/MAC/Documents/Code/BearDown/          ← git repo root, CWD
├── docs/
├── BearDown/                                 ← Xcode wrapper folder
│   ├── BearDown.xcodeproj                    ← the project file
│   ├── BearDown/                             ← app sources
│   │   ├── BearDownApp.swift                 ← @main entry (lives at the source root, NOT inside App/)
│   │   ├── App/                              ← AppEnvironment, AppNavigation
│   │   ├── Models/
│   │   ├── Persistence/
│   │   ├── Coach/
│   │   ├── Notifications/
│   │   ├── Keychain/
│   │   ├── ViewModels/
│   │   └── Views/{Onboarding,Today,Plan,Coach,Settings,Shared}/
│   ├── BearDownTests/                        ← unit tests + Fixtures/
│   └── BearDownUITests/                      ← XCUITest
```

**All source paths in commands use `BearDown/BearDown/...` from repo root.** Don't `cd` — past attempts to `cd BearDown` then run `xcodebuild` confused subsequent commands. Use absolute paths.

## Build / test commands

```bash
# Build
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet

# Run unit tests
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet

# Run a single suite
xcodebuild test ... -only-testing:BearDownTests/CoachServiceTests -quiet

# Install + launch on the booted simulator
xcrun simctl install booted /tmp/beardown-dd/Build/Products/Debug-iphonesimulator/BearDown.app
xcrun simctl launch booted Hirey.BearDown
```

**Bundle id:** `Hirey.BearDown`. **Simulator:** `iPhone 17 Pro` (Xcode 26 setup). The original plan said `iPhone 15 Pro` — that simulator doesn't exist here.

## Xcode 16 file-system synchronized groups

The project uses `PBXFileSystemSynchronizedRootGroup`. **Dropping a `.swift` file into `BearDown/BearDown/...` automatically adds it to the BearDown target.** Same for `BearDown/BearDownTests/...` and the test target. No `.pbxproj` editing needed.

Non-Swift resources (e.g. `.txt` fixtures in `BearDownTests/Fixtures/`) also auto-bundle correctly via `Bundle(for: Self.self).url(forResource:withExtension:)`.

## SourceKit live lint is noisy and stale

Expect lots of "Cannot find type X in scope" / "No such module 'XCTest'" diagnostics in the editor even when `xcodebuild` succeeds. The live indexer lags behind the real build state. **Trust `xcodebuild` exit codes, not SourceKit diagnostics.** If `xcodebuild build` returns 0, the code compiles.

## Critical gotchas hit during initial build (do not repeat)

### 1. Never override `objectWillChange` on `ObservableObject` in Swift 5 mode

Subagents kept adding this "Swift 6 concurrency workaround" to every ObservableObject:

```swift
// ❌ DO NOT DO THIS — silently breaks @Published binding propagation
public nonisolated let objectWillChange = PassthroughSubject<Void, Never>()
```

`@Published` only fires on the *synthesized* `objectWillChange`. When you override it with your own subject, the conformer must call `.send()` manually on every property change — which we weren't doing. **Symptom:** TextField bindings appear to work but the view never re-evaluates (e.g. the Coach composer's send button stayed greyed out forever because `vm.draft` changes didn't propagate).

Project is `SWIFT_VERSION = 5.0` (no strict concurrency). The workaround was solving a problem that didn't exist. Removed in commit `d315846`.

If you ever hit a *real* Swift 6 concurrency warning on `objectWillChange`, the fix is to enable strict concurrency on a per-file basis or upgrade the project, NOT to override the publisher.

### 2. `@Transient` not `@Attribute(.transient)`

`@Attribute(.transient)` doesn't exist. Use `@Transient` (peer macro) for SwiftData properties that should not sync via CloudKit or persist:

```swift
@Transient public var notificationId: String?
```

### 3. In-memory test containers need `cloudKitDatabase: .none`

The app has the CloudKit entitlement. SwiftData runs CloudKit schema validation even on in-memory stores unless you explicitly opt out:

```swift
let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
```

`ModelContainer.beardownInMemory()` already does this. **Always use the factory** in tests rather than constructing your own `ModelConfiguration`.

### 4. Never fall back to in-memory for the production container

`AppEnvironment.production()` can fail (no iCloud, missing entitlement). The fallback chain is:

```
try beardownProduction()       // CloudKit-synced
  ↳ try beardownLocalOnly()    // on-disk, no sync  ← preserves user data
    ↳ fatalError
```

**Do not fall back to `beardownInMemory()`** — that would silently throw away the user's training plans on every relaunch.

### 5. `StateObject` autoclosure can't take throwing expressions

This won't compile:
```swift
// ❌
_env = StateObject(wrappedValue: try AppEnvironment.production())
```

Assign to a local first:
```swift
let environment: AppEnvironment
do { environment = try AppEnvironment.production() } catch { ... }
_env = StateObject(wrappedValue: environment)
```

### 6. JSON `.prettyPrinted` adds spaces around colons

`JSONSerialization.WritingOptions.prettyPrinted` renders `"title" : "X"` (spaces). Plain assertions like `result.contains("\"title\":\"X\"")` fail. Use `.sortedKeys` alone for compact, deterministic JSON.

### 7. xcrun simctl: keep the simulator booted between commands

`xcrun simctl install booted ...` requires a booted simulator. If a prior `xcrun simctl terminate booted ...` or simulator restart killed it, re-boot before install:

```bash
xcrun simctl boot 'iPhone 17 Pro'
xcrun simctl install booted /path/to/BearDown.app
xcrun simctl launch booted Hirey.BearDown
```

Pasting strings into the simulator clipboard (e.g. to inject an API key during testing):
```bash
printf 'sk-ant-...' | xcrun simctl pbcopy booted
```
Then long-press the SecureField → Paste.

## Git workflow

- **Active branch:** `feat/initial-implementation` (v0.1, pushed to `origin`, not yet merged to `main`).
- **Remote:** `git@github.com:manavhirey/BearDown.git` (SSH, authenticated via `gh` CLI).
- **Push:** `git push` — branch is tracking `origin/feat/initial-implementation`.
- **Open a PR:** `gh pr create --base main --head feat/initial-implementation --fill`.
- **Merge to main locally** (skip PR review): `git checkout main && git merge --no-ff feat/initial-implementation && git push`.

### 8. The agent has no `create_plan` tool — repos must auto-create

The coach exposes three tools: `upsert_workout`, `delete_workout`, `get_recent_history`. There is intentionally no `create_plan` tool. `WorkoutRepository.upsert` auto-creates a "Current Block" plan if none exists, so the agent's first `upsert_workout` call doesn't bounce off `RepositoryError.noActivePlan`. If you add a tool that mutates the plan in any way, mirror this pattern — don't expose plan creation as a separate agent step. Caught during fresh-install smoke test (commit `fbe8cf0`).

**As of 2026-06-02 (multi-plan):** the agent can influence plan creation by setting `plan_title` on `upsert_workout`. `WorkoutRepository.upsert` resolves through `PlanRepository.findOrCreatePlan`, which creates the named plan as inactive — the user activates it via the Switch to plan chip. There is still no `create_plan` tool; the auto-create path remains the fallback for writes without `plan_title`.

### 9. View models that pass `Sendable` callbacks to async work need optimistic UI

`CoachViewModel.send` calls into the async `CoachService.send` which doesn't return until the entire stream completes. `vm.messages` is only refreshed after that returns. Without an optimistic append in `send`, the user types a message, taps send, and sees nothing change until the agent finishes responding several seconds later. **Always optimistically append the user message before kicking off the async call.** Pattern in `CoachViewModel.send` (commit `111b220`).

### 10. Construct child VMs inside the `@StateObject` autoclosure, not in body

This is wrong (creates the VM on every body re-eval, even though `@StateObject` only keeps the first instance):

```swift
// ❌ in RootView.body
SettingsView(vm: SettingsViewModel(env: env))   // VM constructor runs every render
```

This is right (autoclosure means SwiftUI only evaluates it once):

```swift
// ✅ in SettingsView
public init(env: AppEnvironment) {
    _vm = StateObject(wrappedValue: SettingsViewModel(env: env))
}
// in RootView.body
SettingsView(env: env)
```

All child views in this project (`TodayView`, `PlanView`, `CoachView`, `SettingsView`) take `env: AppEnvironment` and create their VM via `@StateObject(wrappedValue:)`. Don't break this pattern by reverting to the `vm:` parameter form. Fixed in commit `715994d`.

### 11. Don't read repositories from view `body`

If a view's `body` needs to differentiate states (e.g. "no plan yet" vs "loading from iCloud"), expose the distinction as `@Published` state on the ViewModel and let `refresh()` compute it. Doing `(try? env.plans.activePlan()) == nil` directly in `body` runs a SwiftData fetch on every render. Pattern: `PlanViewModel.hasPlan` flag set in `refresh()`. Fixed in commit `57b467a`.

### 12. `PlanDetailView` takes a `TrainingPlan`, not an `AppEnvironment`

Unlike the other top-level views (`TodayView`, `PlansListView`, `CoachView`, `SettingsView`), `PlanDetailView` constructs its VM with a plan instance:

```swift
PlanDetailView(plan: plan)
```

The parent `PlansListView` provides the plan via the `NavigationStack`'s typed path (`PlansRoute.detail(planId:)`). Don't refactor `PlanDetailView` back to an env-based init — the whole point of the rename was so it could be reused for any plan regardless of active state.

## Architecture pointers

- **Repositories are the only layer touching `ModelContext`.** Views and view models go through `PlanRepository`, `WorkoutRepository`, `ChatRepository`. Don't add `@Query` in views; query through repos.
- **Conversations are virtual groupings of `ChatMessage`.** There is no `Conversation` SwiftData model. `ChatRepository.conversations()` fetches all `ChatMessage` rows sorted by `createdAt` and groups in-memory by `conversationId` (SwiftData `#Predicate` does not support `GROUP BY`). Empty conversations (only Anthropic protocol rows: `role == .user && text.isEmpty`) are filtered out. The list is reactive — no schema change, no migration; new conversations appear on first launch of the updated app.
- **`CoachService` is the agent turn loop.** Streams events from `AnthropicClient`, accumulates text + tool calls, dispatches tools, persists chat messages with raw tool JSON for replay. Capped at 10 tool iterations per user turn.
- **`CoachPrompt` is layered:** verbatim coaching persona (Appendix A of the design spec) + app-owned tool addendum + per-turn context block (today's date, active plan snapshot, 14-day history). The persona must never be paraphrased or normalized — it's the user's domain.
- **`NotificationScheduler` is an actor.** Repository methods stay sync and fire fire-and-forget `Task { await scheduler.... }` to schedule/cancel. Brief race window between save and schedule; acceptable for v1.
- **`WorkoutRepository.recentHistory(days:)` is scoped to the active plan.** Archived plans don't leak into the Coach's view. Returns empty if there is no active plan.
- **`AppNavigation`** is the cross-tab navigation observable (selected tab + `focusedDate` for chip-tap navigation from Coach to Today).
- **ViewModels load data via `.onAppear`, not from `init()`.** Each `*ViewModel.init` is intentionally cheap — no repo calls, no `refresh()`. The owning view triggers the first load via `.onAppear { vm.refresh() }` (also runs on tab-switch returns). Don't reintroduce `refresh()` calls into VM inits — they'd double-fetch on every first appearance. Established in commit `947a16b`.
- **`CoachViewModel.chips(for:)` is the entry point for tool-call chip rendering.** Chips are pre-computed during `refresh()` and cached in `chipCache: [UUID: [ChatBubble.ToolChip]]`. The view does O(1) lookup. If you add a new agent tool, update `CoachViewModel.computeChips(from:)` (not the view) to format its chip.

## What worked well during initial build

- **TDD discipline.** Every layer (parser, repos, scheduler, service, tools) was written test-first and stayed test-green throughout. Made the refactors near the end of the build (notification hooks, scheduler wiring) safe.
- **Xcode 16 synchronized groups.** Massive time-saver vs. hand-editing `.pbxproj` for every new file. Subagents could drop files anywhere under the source/test trees and Xcode picked them up.
- **Fake/scripted Anthropic clients in tests.** `ScriptedAnthropicClient` (yields pre-recorded `AnthropicEvent` sequences) let us test the full tool loop without network. Recorded SSE fixtures (`stream-text-only.txt`, `stream-with-tool-use.txt`) test the parser deterministically.
- **Recording deviations in subagent reports.** When a subagent had to deviate from the plan (e.g. `cloudKitDatabase: .none`, JSON `.prettyPrinted` issue), they reported it back. We patched the plan in-place so subsequent tasks didn't rediscover.
- **`swiftui-pro` + `swift-testing-expert` skills as a post-build code review pass.** Ran both against the v1 codebase after smoke testing. Surfaced 7 important fixes (DateFormatter allocations, body-side DB calls, silent save errors, double-`refresh` in VM inits, JSON parsing per render, two test correctness issues) that unit tests didn't catch. **Run these skills after major implementation work** before shipping — they catch the class of issues TDD misses (perf, error UX, view-data-flow).

## What didn't work / things to watch

- **Subagents pattern-matched a non-issue.** They saw "Swift 6 concurrency" warnings on one file and applied a "fix" everywhere — including places where Swift 6 wasn't even enabled. The fix was harmful. **Verify a workaround is needed before generalizing it.** Check `SWIFT_VERSION` in the .pbxproj before reaching for concurrency workarounds.
- **Unit tests don't catch view-data-flow bugs.** The `objectWillChange` override bug, the missing optimistic UI for user messages, and the per-render DB fetch in `PlanView.body` all passed every unit test but were broken in the running app. **Smoke test in the simulator after every major feature**, not just at the end. `swiftui-pro` review is a partial substitute, but real-app testing catches what static analysis can't.
- **UI test runner is flaky.** "Mach error -308 - server died" on the first attempt is common. Retrying usually works. If it persists, restart the simulator or run via Xcode UI rather than `xcodebuild test`.
- **SourceKit diagnostics drowned out signal.** The skill loop kept surfacing stale "Cannot find type" errors after every edit, even when builds were clean. Future sessions: skim diagnostics for *new* concerns (real errors), but trust `xcodebuild` as ground truth.
- **The "Mark…" menu accessibility-label assertion in XCUITest was fragile.** UI tests that match on SF Symbol image labels are unreliable — prefer asserting on text changes ("Mark…" → "✓ Completed") via the toolbar menu label.

## Where to look first

All paths below are from the repo root. The `BearDown/BearDown/...` prefix reflects Xcode's nested wrapper folder.

| You want to... | Read this |
|---|---|
| Add a new tool the coach can call | `BearDown/BearDown/Coach/CoachTools.swift` (`definitions` + `dispatch`) and `BearDown/BearDown/Coach/CoachPrompt.swift` (`toolAddendum`) |
| Change what data persists | `BearDown/BearDown/Models/*.swift` + `BearDown/BearDown/Persistence/*.swift` |
| Adjust the coaching persona | `BearDown/BearDown/Coach/CoachPrompt.swift` `coachingPersona` constant (verbatim from spec Appendix A) |
| Adjust streaming/turn-loop behavior | `BearDown/BearDown/Coach/CoachService.swift` |
| Change notification scheduling | `BearDown/BearDown/Notifications/NotificationScheduler.swift` + repository hooks in `BearDown/BearDown/Persistence/WorkoutRepository.swift` |
| Add a tab, change navigation, or push a plan detail from elsewhere | `BearDown/BearDown/Views/Shared/RootView.swift`, `BearDown/BearDown/App/AppNavigation.swift` (`focusedDate`, `pendingPlanDetail`), `BearDown/BearDown/Views/Plan/PlansListView.swift` (`PlansRoute`) |
| Add a new operation on plans (rename, archive without delete, etc.) | `BearDown/BearDown/Persistence/PlanRepository.swift`, expose to UI via `PlansListViewModel`/`PlanDetailViewModel` |
| Add or change chat-history navigation | `BearDown/BearDown/Views/Coach/CoachView.swift` (HISTORY toolbar + `CoachRoute`) + `BearDown/BearDown/Views/Coach/ChatHistoryView.swift` + `BearDown/BearDown/Persistence/ChatRepository.swift` (`conversations()`, `switchConversation(to:)`, `deleteConversation(id:)`) |
| Run UI tests reliably | Open the project in Xcode and use ⌘U; `xcodebuild test -only-testing:BearDownUITests` is flaky |

## Style preferences

- Match existing patterns. Repos use `@MainActor`. View models are `@MainActor ObservableObject` with plain synthesized `objectWillChange`. SwiftData models follow the `statusRaw: String` + computed enum accessor pattern (CloudKit-friendly).
- Don't add comments explaining what the code does — well-named identifiers already do that. Add a one-line comment only when the *why* is non-obvious (a workaround, a hidden constraint, an iCloud quirk).
- Keep files focused. The existing tree splits by responsibility: one repo per aggregate, one view per screen, one VM per feature. Don't merge unrelated concerns.
- **Use `Text(date, format: .dateTime...)` not `DateFormatter`** for date display in views. Zero allocation, locale-aware. Only fall back to a `static let DateFormatter` when you need a custom format that `FormatStyle` can't express cleanly.
- **Save errors must be visible to the user.** If a user-initiated action throws (mark-complete, replace-key, etc.), surface it via `.alert`. Silent `catch {}` blocks are a no-no — see `WorkoutDetailSheet.save()` for the canonical pattern (`@State var saveError: String?` + alert binding).

## Future tightening (deferred, not blocking)

These came out of the post-build review and are tracked for a future polish pass:

- Replace `AppNavigation.selectedTab: Int` with a typed `Tab` enum (eliminates magic numbers in `TodayView`, `PlansListView`, `CoachView`, `RootView`).
- Add VoiceOver text labels to icon-only buttons (notably the Coach send button at `CoachView.swift:66`).
- Extract `FakeAnthropicClient`, `ScriptedAnthropicClient`, and `dateFromIso` into `BearDownTests/TestSupport.swift` — currently scattered across three test files.
- Optionally migrate `EnumsTests.swift` to Swift Testing as a parameterized test (`@Test(arguments:)`). Per the `swift-testing-expert` review: do this opportunistically, not as a sweep. Keep SwiftData-heavy suites on XCTest.
- Delete the Xcode-generated `BearDownTests/BearDownTests.swift` `example()` stub.
