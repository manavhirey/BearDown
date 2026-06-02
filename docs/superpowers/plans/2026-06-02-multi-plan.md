# Multi-Plan Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend BearDown from one implicit "Current Block" plan to multiple named training plans the user can list, switch between, and delete. The Coach implicitly creates new plans when the user asks for one; the user opts in via a "Switch to plan" chip in chat or "Make active" on the plan detail.

**Architecture:** Bottom-up. The data model already supports multi-plan (`isActive`, `archivedAt`). Work flows: TrainingPlan.goal → PlanRepository methods → WorkoutRepository routing + active-plan-scoped history → CoachTools schema/result string → CoachPrompt addendum → chip parsing + switch chip rendering → PlanDetailView (renamed from PlanView) + action bar → new PlansListView/PlansListViewModel → RootView rewires Plans tab → UI tests + docs.

**Tech Stack:** Swift 5, SwiftUI, SwiftData (with CloudKit), Anthropic API, XCTest, XCUITest. iOS 17+. Xcode 16 file-system synchronized groups (drop a `.swift` file in and it auto-joins the target).

**Source-of-truth spec:** `docs/superpowers/specs/2026-06-02-multi-plan-design.md` (commit `1e26cce`). When in doubt, defer to the spec.

**Working tree at plan-write time:** branch `feat/initial-implementation` at commit `1e75a4a` (the editorial-athletic UI redesign baseline). All 74 unit tests + 4 UI tests pass on this baseline.

**Conventions across all tasks:**
- All paths in commands are from the repo root `/Users/MAC/Documents/Code/BearDown`.
- Build/test from the repo root using absolute paths — **do not `cd BearDown`**. The CLAUDE.md project notes explain why.
- Simulator destination: `'platform=iOS Simulator,name=iPhone 17 Pro'` (not iPhone 15 Pro).
- After every task, run the full unit test suite: `xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BearDownTests -quiet`. The plan steps below show the single new test per task — that is the local check; the full suite confirms no regression.
- Use `@Transient` (not `@Attribute(.transient)`) for SwiftData non-persisted properties.
- View models construct cheap; `refresh()` happens in `.onAppear`. Never call `refresh()` from a VM's init.
- Don't override `objectWillChange` — see CLAUDE.md gotcha #1.
- When adding tests that exercise `WorkoutRepository`, always seed via `PlanRepository.createPlan(...)` first unless the test is specifically about the auto-create fallback.
- Use `ModelContainer.beardownInMemory()` — already sets `cloudKitDatabase: .none`.

---

## Task 1: Add `goal: String` to `TrainingPlan`

Additive field with default `""` so no SwiftData/CloudKit migration is needed.

**Files:**
- Modify: `BearDown/BearDown/Models/TrainingPlan.swift`
- Test: `BearDown/BearDownTests/ModelsTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `BearDown/BearDownTests/ModelsTests.swift` (inside the existing test class — keep `@MainActor` if the class is already annotated; if not, this single test stands alone):

```swift
func test_trainingPlan_goalDefaultsToEmptyString() throws {
    let plan = TrainingPlan(title: "Block 1", startDate: .now, endDate: .now)
    XCTAssertEqual(plan.goal, "")
}

func test_trainingPlan_goalIsAssignable() throws {
    let plan = TrainingPlan(title: "Race Prep", startDate: .now, endDate: .now)
    plan.goal = "3.5mi race goal"
    XCTAssertEqual(plan.goal, "3.5mi race goal")
}
```

- [ ] **Step 2: Run the test, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ModelsTests -quiet
```

Expected: compile error or test failure (`goal` property missing).

- [ ] **Step 3: Add the field**

In `BearDown/BearDown/Models/TrainingPlan.swift`, add `goal` directly after `title`:

```swift
@Model
public final class TrainingPlan {
    @Attribute(.unique) public var id: UUID = UUID()
    public var title: String = ""
    public var goal: String = ""
    public var startDate: Date = Date()
    public var endDate: Date = Date()
    public var isActive: Bool = false
    public var archivedAt: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \Workout.plan)
    public var workouts: [Workout] = []

    public init(
        id: UUID = UUID(),
        title: String,
        goal: String = "",
        startDate: Date,
        endDate: Date,
        isActive: Bool = true
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = isActive
    }
}
```

The default value on the stored property + default param on the init both matter: SwiftData uses the property default for existing rows, and the init keeps every existing call site (including `PlanRepository.createPlan`) compiling unchanged.

- [ ] **Step 4: Run the test, expect pass**

Same command as Step 2. Expected: PASS. Also run the full unit suite to confirm nothing else broke:

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Models/TrainingPlan.swift BearDown/BearDownTests/ModelsTests.swift
git commit -m "feat(model): add TrainingPlan.goal field

Additive String with default '' so existing rows pick up the default —
no SwiftData/CloudKit migration required. Init takes an optional goal
parameter (default '') so existing call sites compile unchanged.
"
```

---

## Task 2: `PlanRepository.allPlans()` — active first, then `createdAt` desc

**Files:**
- Modify: `BearDown/BearDown/Persistence/PlanRepository.swift`
- Test: `BearDown/BearDownTests/PlanRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `BearDown/BearDownTests/PlanRepositoryTests.swift`:

```swift
func test_allPlans_ordersActiveFirstThenCreatedAtDesc() throws {
    let older = try repo.createPlan(title: "Older",
                                    startDate: .now.addingTimeInterval(-10 * 86400),
                                    endDate: .now.addingTimeInterval(-3 * 86400))
    // Force a measurable createdAt difference. SwiftData stores Date with
    // sub-millisecond precision but tests run fast; nudge older back.
    older.createdAt = .now.addingTimeInterval(-3600)
    older.isActive = false
    older.archivedAt = .now.addingTimeInterval(-1800)

    let newerArchived = try repo.createPlan(title: "Newer Archived",
                                            startDate: .now.addingTimeInterval(-5 * 86400),
                                            endDate: .now)
    // createPlan marks it active and archives `older`. Flip newerArchived inactive.
    newerArchived.isActive = false
    newerArchived.archivedAt = .now

    let active = try repo.createPlan(title: "Active Block",
                                     startDate: .now,
                                     endDate: .now.addingTimeInterval(7 * 86400))

    let listed = try repo.allPlans()
    XCTAssertEqual(listed.map(\.title), ["Active Block", "Newer Archived", "Older"])
    XCTAssertEqual(listed.first?.id, active.id)
}
```

- [ ] **Step 2: Run the test, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/PlanRepositoryTests/test_allPlans_ordersActiveFirstThenCreatedAtDesc -quiet
```

Expected: compile failure (`allPlans` doesn't exist).

- [ ] **Step 3: Implement `allPlans()`**

Add to `BearDown/BearDown/Persistence/PlanRepository.swift`:

```swift
public func allPlans() throws -> [TrainingPlan] {
    let descriptor = FetchDescriptor<TrainingPlan>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    let rows = try context.fetch(descriptor)
    // Active first, then createdAt desc among the rest.
    return rows.sorted { lhs, rhs in
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        return lhs.createdAt > rhs.createdAt
    }
}
```

- [ ] **Step 4: Run the test, expect pass**

Same as Step 2. Expected: PASS. Then run the full PlanRepositoryTests suite to make sure existing tests still pass:

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/PlanRepositoryTests -quiet
```

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Persistence/PlanRepository.swift BearDown/BearDownTests/PlanRepositoryTests.swift
git commit -m "feat(plans): add PlanRepository.allPlans() with active-first ordering"
```

---

## Task 3: `PlanRepository.plan(id:)` and `activate(planId:)`

These are tightly paired: `activate` is a no-op if the plan is already active and otherwise archives the prior active plan. `plan(id:)` exists for `PlanDetailView` to refresh its data.

**Files:**
- Modify: `BearDown/BearDown/Persistence/PlanRepository.swift`
- Test: `BearDown/BearDownTests/PlanRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `PlanRepositoryTests.swift`:

```swift
func test_planById_returnsMatchingPlan() throws {
    let plan = try repo.createPlan(title: "A", startDate: .now, endDate: .now.addingTimeInterval(86400))
    let fetched = try repo.plan(id: plan.id)
    XCTAssertEqual(fetched?.id, plan.id)
}

func test_planById_returnsNilWhenAbsent() throws {
    let missing = try repo.plan(id: UUID())
    XCTAssertNil(missing)
}

func test_activate_archivesPriorActiveAndSetsTarget() throws {
    let first = try repo.createPlan(title: "First",
                                    startDate: .now,
                                    endDate: .now.addingTimeInterval(86400))
    let second = try repo.createPlan(title: "Second",
                                     startDate: .now,
                                     endDate: .now.addingTimeInterval(86400))
    // createPlan auto-archives first. Now activate first again.
    try repo.activate(planId: first.id)
    XCTAssertEqual(try repo.activePlan()?.id, first.id)

    let all = try repo.allPlans()
    let secondReloaded = try XCTUnwrap(all.first { $0.id == second.id })
    XCTAssertFalse(secondReloaded.isActive)
    XCTAssertNotNil(secondReloaded.archivedAt)
}

func test_activate_isIdempotentOnAlreadyActive() throws {
    let plan = try repo.createPlan(title: "A",
                                   startDate: .now,
                                   endDate: .now.addingTimeInterval(86400))
    let originalUpdated = plan.updatedAt
    try repo.activate(planId: plan.id)
    XCTAssertEqual(try repo.activePlan()?.id, plan.id)
    // Idempotent — no archival of self, no updatedAt churn.
    XCTAssertEqual(plan.updatedAt, originalUpdated)
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/PlanRepositoryTests -quiet
```

Expected: compile failure (`plan(id:)`, `activate(planId:)` missing).

- [ ] **Step 3: Implement both**

Add to `PlanRepository.swift`:

```swift
public func plan(id: UUID) throws -> TrainingPlan? {
    var descriptor = FetchDescriptor<TrainingPlan>(
        predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
}

public func activate(planId: UUID) throws {
    guard let target = try plan(id: planId) else { return }
    if target.isActive { return }  // idempotent — no churn

    if let current = try activePlan(), current.id != target.id {
        current.isActive = false
        current.archivedAt = .now
        current.updatedAt = .now
    }
    target.isActive = true
    target.archivedAt = nil
    target.updatedAt = .now
    try context.save()
}
```

- [ ] **Step 4: Run the tests, expect pass**

Same as Step 2. Expected: all four new tests PASS, all existing tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Persistence/PlanRepository.swift BearDown/BearDownTests/PlanRepositoryTests.swift
git commit -m "feat(plans): add PlanRepository.plan(id:) and activate(planId:)

activate is idempotent on the already-active target and archives the
prior active plan otherwise. plan(id:) is the lookup needed by
PlanDetailView for refresh."
```

---

## Task 4: `PlanRepository.delete(planId:)` with cancel hook

Deleting a plan cascades to its workouts (existing `@Relationship(deleteRule: .cascade)`). Notifications for those workouts must be cancelled — the repository needs an injected `onCancel` hook, mirroring `WorkoutRepository`.

**Files:**
- Modify: `BearDown/BearDown/Persistence/PlanRepository.swift`
- Modify: `BearDown/BearDown/App/AppEnvironment.swift`
- Test: `BearDown/BearDownTests/PlanRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `PlanRepositoryTests.swift`. Update the existing `setUpWithError` if needed so the repo can be re-constructed with a hook — or use a second helper. The cleanest path is to add a second property + tearDown reset, and a local helper that builds a hook-instrumented repo for the new tests:

```swift
func test_delete_cascadesWorkoutsAndFiresCancelHookPerWorkout() throws {
    var cancelled: [UUID] = []
    let hook: @Sendable (UUID) -> Void = { id in cancelled.append(id) }
    let repoWithHook = PlanRepository(context: container.mainContext, onCancel: hook)

    let plan = try repoWithHook.createPlan(title: "P",
                                           startDate: .now,
                                           endDate: .now.addingTimeInterval(7 * 86400))
    let workouts = WorkoutRepository(context: container.mainContext, plans: repoWithHook)
    let w1 = try workouts.upsert(.init(date: .now, title: "A", summary: "", blocks: []))
    let w2 = try workouts.upsert(.init(date: .now.addingTimeInterval(86400),
                                       title: "B", summary: "", blocks: []))

    try repoWithHook.delete(planId: plan.id)

    // Plan gone, workouts gone (cascade), hook fired once per workout id.
    XCTAssertNil(try repoWithHook.plan(id: plan.id))
    let remaining = try container.mainContext.fetch(FetchDescriptor<Workout>())
    XCTAssertTrue(remaining.isEmpty)
    XCTAssertEqual(Set(cancelled), Set([w1.id, w2.id]))
}

func test_delete_activePlan_leavesNoActivePlan() throws {
    let active = try repo.createPlan(title: "Active",
                                     startDate: .now,
                                     endDate: .now.addingTimeInterval(86400))
    try repo.delete(planId: active.id)
    XCTAssertNil(try repo.activePlan())
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/PlanRepositoryTests -quiet
```

Expected: compile failure (`delete(planId:)` missing, `onCancel:` init param missing).

- [ ] **Step 3: Add the hook + implement `delete`**

Replace the init in `PlanRepository.swift` to accept an `onCancel` hook (defaulting to nil so existing call sites work):

```swift
@MainActor
public final class PlanRepository {
    private let context: ModelContext
    private let onCancel: CancelHook?

    public init(context: ModelContext, onCancel: CancelHook? = nil) {
        self.context = context
        self.onCancel = onCancel
    }
    // ... existing methods unchanged ...
}
```

`CancelHook` is already declared in `WorkoutRepository.swift` (`public typealias CancelHook = @Sendable (UUID) -> Void`) — it's in the same module, so no import needed.

Add the `delete` method:

```swift
public func delete(planId: UUID) throws {
    guard let target = try plan(id: planId) else { return }
    let workoutIds = target.workouts.map(\.id)
    context.delete(target)
    try context.save()
    if let onCancel { for id in workoutIds { onCancel(id) } }
}
```

Wire the cancel hook from `AppEnvironment.production()`. In `AppEnvironment.swift`, change the existing line `self.plans = PlanRepository(context: ctx)` to use the same scheduler cancel that `WorkoutRepository` uses. The scheduler is created a few lines below `self.plans`, so reorder: hoist the scheduler creation above `self.plans`, then pass the closure:

```swift
let ctx = modelContainer.mainContext

let center = SystemUserNotificationCenter()
let scheduler = NotificationScheduler(center: center)
self.notificationScheduler = scheduler

self.plans = PlanRepository(context: ctx, onCancel: { id in
    Task { await scheduler.cancelByIdentifier("workout-\(id.uuidString)") }
})

let prefsEnabled: @Sendable () -> Bool = {
    UserDefaults.standard.bool(forKey: "notifications.enabled")
}

self.workouts = WorkoutRepository(
    context: ctx,
    plans: plans,
    onChange: { workout, enabled in
        Task { try? await scheduler.scheduleOrUpdate(workout: workout, enabled: enabled) }
    },
    onCancel: { id in
        Task { await scheduler.cancelByIdentifier("workout-\(id.uuidString)") }
    },
    notificationsEnabled: prefsEnabled
)
```

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Persistence/PlanRepository.swift BearDown/BearDown/App/AppEnvironment.swift BearDown/BearDownTests/PlanRepositoryTests.swift
git commit -m "feat(plans): add PlanRepository.delete(planId:) with cancel hook

Cascade removes the plan's workouts via the existing @Relationship
delete rule. Cancels scheduled notifications for each removed workout
via the new onCancel hook on PlanRepository, wired from AppEnvironment
to the same NotificationScheduler used by WorkoutRepository.

Deleting the active plan leaves the user with no active plan — no
auto-promotion, per spec."
```

---

## Task 5: `PlanRepository.findOrCreatePlan(title:goal:anchorDate:)`

Used by the agent's `upsert_workout` routing in Task 6. Case-insensitive title match. Newly created plans are **inactive** so the user explicitly switches.

**Files:**
- Modify: `BearDown/BearDown/Persistence/PlanRepository.swift`
- Test: `BearDown/BearDownTests/PlanRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `PlanRepositoryTests.swift`:

```swift
func test_findOrCreatePlan_caseInsensitiveTitleMatch() throws {
    let original = try repo.findOrCreatePlan(title: "Race Prep", goal: "g", anchorDate: .now)
    let again = try repo.findOrCreatePlan(title: "race prep", goal: "x", anchorDate: .now)
    XCTAssertEqual(again.id, original.id)
}

func test_findOrCreatePlan_createsInactiveByDefault() throws {
    let plan = try repo.findOrCreatePlan(title: "Race Prep",
                                         goal: "3.5mi race goal",
                                         anchorDate: .now)
    XCTAssertFalse(plan.isActive)
    XCTAssertEqual(plan.goal, "3.5mi race goal")
    XCTAssertEqual(plan.startDate, Calendar.current.startOfDay(for: .now))
    XCTAssertEqual(plan.endDate, plan.startDate)
}

func test_findOrCreatePlan_doesNotOverwriteGoalOnSecondCall() throws {
    let first = try repo.findOrCreatePlan(title: "Race Prep",
                                          goal: "original goal",
                                          anchorDate: .now)
    let again = try repo.findOrCreatePlan(title: "Race Prep",
                                          goal: "new goal",
                                          anchorDate: .now)
    XCTAssertEqual(again.id, first.id)
    XCTAssertEqual(again.goal, "original goal")
}
```

- [ ] **Step 2: Run the tests, expect failure**

Same command pattern as before. Expected: compile failure.

- [ ] **Step 3: Implement `findOrCreatePlan`**

Add to `PlanRepository.swift`:

```swift
public func findOrCreatePlan(title: String, goal: String, anchorDate: Date) throws -> TrainingPlan {
    let normalized = title.lowercased()
    let rows = try context.fetch(FetchDescriptor<TrainingPlan>())
    if let existing = rows.first(where: { $0.title.lowercased() == normalized }) {
        return existing
    }
    let day = Calendar.current.startOfDay(for: anchorDate)
    let plan = TrainingPlan(title: title, goal: goal,
                            startDate: day, endDate: day,
                            isActive: false)
    context.insert(plan)
    try context.save()
    return plan
}
```

Note: matching is done in-memory after fetching all plans because `String.lowercased()` isn't supported inside SwiftData `#Predicate` macros. Plan counts are small (single-digit typical), so this is fine.

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/PlanRepositoryTests -quiet
```

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Persistence/PlanRepository.swift BearDown/BearDownTests/PlanRepositoryTests.swift
git commit -m "feat(plans): add PlanRepository.findOrCreatePlan

Case-insensitive title match. Newly created plans are inactive — the
user explicitly activates via the Switch chip or the plan detail
Make Active button. Goal is set only on creation; subsequent calls
with the same title leave the original goal untouched."
```

---

## Task 6: Route `upsert_workout` writes through `planTitle`

Extend `WorkoutInput` with two optional fields. `WorkoutRepository.upsert` routes:
1. `input.planTitle` present → `findOrCreatePlan(...)`, extend that plan's `endDate` if the workout date is later.
2. Else, existing active plan → attach + extend (existing behavior).
3. Else → auto-create "Current Block" as active (existing behavior).

**Files:**
- Modify: `BearDown/BearDown/Persistence/WorkoutRepository.swift`
- Test: `BearDown/BearDownTests/WorkoutRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `BearDown/BearDownTests/WorkoutRepositoryTests.swift` (existing test class is `@MainActor`; reuse setup that already creates `env` with `plans` + `workouts`):

```swift
func test_upsert_withPlanTitle_routesToNamedPlanAndLeavesActiveAlone() throws {
    let active = try env.plans.createPlan(title: "Current Block",
                                          startDate: .now,
                                          endDate: .now.addingTimeInterval(7 * 86400))

    let input = WorkoutInput(
        date: .now.addingTimeInterval(14 * 86400),
        title: "Race long run",
        summary: "12mi",
        blocks: [],
        planTitle: "Race Prep",
        planGoal: "3.5mi race June 24"
    )
    let workout = try env.workouts.upsert(input)

    XCTAssertNotEqual(workout.plan?.id, active.id)
    XCTAssertEqual(workout.plan?.title, "Race Prep")
    XCTAssertEqual(workout.plan?.goal, "3.5mi race June 24")
    XCTAssertFalse(workout.plan!.isActive)

    // Active plan untouched.
    XCTAssertEqual(try env.plans.activePlan()?.id, active.id)
}

func test_upsert_withPlanTitle_extendsThatPlansEndDate() throws {
    _ = try env.plans.createPlan(title: "Current Block",
                                 startDate: .now,
                                 endDate: .now.addingTimeInterval(86400))
    let firstDate = Calendar.current.startOfDay(for: .now)
    let lateDate = firstDate.addingTimeInterval(20 * 86400)

    _ = try env.workouts.upsert(.init(date: firstDate, title: "W1", summary: "",
                                      blocks: [], planTitle: "Race Prep", planGoal: ""))
    _ = try env.workouts.upsert(.init(date: lateDate, title: "W2", summary: "",
                                      blocks: [], planTitle: "Race Prep", planGoal: ""))

    let racePrep = try env.plans.allPlans().first { $0.title == "Race Prep" }
    XCTAssertEqual(racePrep?.endDate, lateDate)
}

func test_upsert_withoutPlanTitle_stillRoutesToActivePlan() throws {
    let active = try env.plans.createPlan(title: "Current Block",
                                          startDate: .now,
                                          endDate: .now.addingTimeInterval(86400))
    let workout = try env.workouts.upsert(.init(date: .now, title: "W", summary: "", blocks: []))
    XCTAssertEqual(workout.plan?.id, active.id)
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/WorkoutRepositoryTests -quiet
```

Expected: compile failure (init parameters missing).

- [ ] **Step 3: Extend `WorkoutInput` and the routing in `upsert`**

In `BearDown/BearDown/Persistence/WorkoutRepository.swift`, extend `WorkoutInput`:

```swift
public struct WorkoutInput: Sendable, Equatable {
    public var date: Date
    public var title: String
    public var summary: String
    public var blocks: [BlockInput]
    public var planTitle: String?
    public var planGoal: String?

    public init(date: Date, title: String, summary: String, blocks: [BlockInput],
                planTitle: String? = nil, planGoal: String? = nil) {
        self.date = date
        self.title = title
        self.summary = summary
        self.blocks = blocks
        self.planTitle = planTitle
        self.planGoal = planGoal
    }
}
```

Replace the plan-resolution block at the top of `upsert(_:)` with:

```swift
@discardableResult
public func upsert(_ input: WorkoutInput) throws -> Workout {
    let plan: TrainingPlan
    if let title = input.planTitle, !title.isEmpty {
        plan = try plans.findOrCreatePlan(title: title,
                                          goal: input.planGoal ?? "",
                                          anchorDate: input.date)
        let day = Calendar.current.startOfDay(for: input.date)
        if day > plan.endDate {
            plan.endDate = day
            plan.updatedAt = .now
        }
    } else if let existing = try plans.activePlan() {
        plan = existing
        try plans.extendActivePlan(throughDate: input.date)
    } else {
        plan = try plans.createPlan(title: "Current Block",
                                    startDate: input.date,
                                    endDate: input.date)
    }

    // ...existing day-window fetch + insert + blocks loop continues unchanged...
```

Leave the rest of `upsert(_:)` (the day-window fetch, block/exercise/cardio inserts, save, `onChange`) exactly as it was.

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Persistence/WorkoutRepository.swift BearDown/BearDownTests/WorkoutRepositoryTests.swift
git commit -m "feat(plans): route upsert_workout by optional planTitle/planGoal

Workouts with planTitle attach to a (find-or-create) named plan,
created inactive — does not disturb the current active plan.
extendActivePlan-equivalent logic runs on the named plan so the
endDate grows to cover the latest scheduled workout."
```

---

## Task 7: Scope `recentHistory(days:)` to the active plan

The Coach must not see archived plans' workouts via `get_recent_history`.

**Files:**
- Modify: `BearDown/BearDown/Persistence/WorkoutRepository.swift`
- Test: `BearDown/BearDownTests/WorkoutRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `WorkoutRepositoryTests.swift`:

```swift
func test_recentHistory_returnsOnlyActivePlanWorkouts() throws {
    _ = try env.plans.createPlan(title: "Active",
                                 startDate: .now,
                                 endDate: .now.addingTimeInterval(7 * 86400))
    _ = try env.workouts.upsert(.init(date: .now, title: "Active workout",
                                      summary: "", blocks: []))
    // Archived plan with its own workout
    _ = try env.workouts.upsert(.init(date: .now.addingTimeInterval(-86400),
                                      title: "Archived workout", summary: "",
                                      blocks: [], planTitle: "Archived"))
    let entries = try env.workouts.recentHistory(days: 14)
    XCTAssertEqual(entries.map(\.title), ["Active workout"])
}

func test_recentHistory_returnsEmptyWhenNoActivePlan() throws {
    // Create an inactive plan + workout, never activate.
    _ = try env.workouts.upsert(.init(date: .now, title: "Archived",
                                      summary: "", blocks: [],
                                      planTitle: "Race Prep"))
    XCTAssertNil(try env.plans.activePlan())
    let entries = try env.workouts.recentHistory(days: 14)
    XCTAssertEqual(entries.count, 0)
}
```

- [ ] **Step 2: Run the tests, expect failure**

Same command pattern. Expected: existing logic returns archived-plan workouts too.

- [ ] **Step 3: Filter by active plan**

Replace `recentHistory(days:)` in `WorkoutRepository.swift`:

```swift
public func recentHistory(days: Int) throws -> [HistoryEntry] {
    guard let active = try plans.activePlan() else { return [] }
    let activeId = active.id
    let cal = Calendar.current
    let today = cal.startOfDay(for: .now)
    let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
    let end = today.addingTimeInterval(86400)
    let ws = try context.fetch(FetchDescriptor<Workout>(
        predicate: #Predicate { w in
            w.date >= start && w.date < end && w.plan?.id == activeId
        },
        sortBy: [SortDescriptor(\.date, order: .reverse)]
    ))
    return ws.map { w in
        let summary = w.blocks
            .sorted(by: { $0.order < $1.order })
            .map { "\($0.kind.rawValue):\($0.title)" }
            .joined(separator: ", ")
        return HistoryEntry(date: w.date, title: w.title, status: w.status,
                            note: w.completionNote, blocksSummary: summary)
    }
}
```

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Persistence/WorkoutRepository.swift BearDown/BearDownTests/WorkoutRepositoryTests.swift
git commit -m "feat(coach): scope recentHistory to the active plan

Stops archived plans' workouts from leaking into the Coach's
get_recent_history tool result. Returns empty when there's no
active plan."
```

---

## Task 8: Extend `upsert_workout` tool schema + result string

Two optional schema fields. `handleUpsert` reads them, builds the `WorkoutInput`, and — when `plan_title` was provided — emits a result string with a parseable `plan_id=<uuid>` marker so the chip layer can detect it.

**Files:**
- Modify: `BearDown/BearDown/Coach/CoachTools.swift`
- Test: `BearDown/BearDownTests/CoachToolsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `BearDown/BearDownTests/CoachToolsTests.swift`:

```swift
func test_handleUpsert_withPlanTitle_includesPlanIdInResultString() throws {
    let input: [String: Any] = [
        "date": "2026-06-08",
        "title": "Easy run",
        "summary": "30 min",
        "blocks": [],
        "plan_title": "Race Prep — June 24",
        "plan_goal":  "3.5mi race goal pacing block",
    ]
    let result = try tools.dispatch(name: "upsert_workout", input: input)
    XCTAssertFalse(result.isError)
    XCTAssertTrue(result.content.contains("plan_id="),
                  "result must carry plan_id marker, got: \(result.content)")
    XCTAssertTrue(result.content.contains("Race Prep — June 24"),
                  "result must carry plan title, got: \(result.content)")
}

func test_handleUpsert_withoutPlanTitle_resultStringHasNoPlanIdMarker() throws {
    let input: [String: Any] = [
        "date": "2026-06-08",
        "title": "Easy run",
        "summary": "30 min",
        "blocks": [],
    ]
    let result = try tools.dispatch(name: "upsert_workout", input: input)
    XCTAssertFalse(result.isError)
    XCTAssertFalse(result.content.contains("plan_id="),
                   "active-plan write must not carry plan_id marker")
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachToolsTests -quiet
```

Expected: failure — `plan_id=` not in result.

- [ ] **Step 3: Extend schema + dispatcher**

In `CoachTools.swift`, append two properties to the `upsert_workout` tool definition's `properties` dictionary:

```swift
"plan_title": [
    "type": "string",
    "description": "Optional. Attach this workout to a named training plan. If the plan doesn't exist, it's created in an inactive state — the user will activate it via the Switch to plan chip. Reuse the same plan_title across every workout you write for one block."
],
"plan_goal": [
    "type": "string",
    "description": "Optional. One-line goal for the plan (e.g. 'Race prep — 3.5mi June 24'). Only applied when creating the plan; ignored on subsequent writes to the same plan_title."
],
```

In `handleUpsert(_:)`, read the new fields and pass them through. Change the construction of `WorkoutInput` and the result string. Replace the trailing portion of `handleUpsert` (from `let workoutInput = ...` through the `return` lines) with:

```swift
let planTitle = (input["plan_title"] as? String).flatMap {
    $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
}
let planGoal = (input["plan_goal"] as? String).flatMap {
    $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
}

let workoutInput = WorkoutInput(
    date: date, title: title, summary: summary, blocks: parsedBlocks,
    planTitle: planTitle, planGoal: planGoal
)
do {
    let w = try workouts.upsert(workoutInput)
    if let planTitle, let plan = w.plan {
        return ToolResult(
            content: "Scheduled \"\(title)\" for \(dateStr) in plan \"\(planTitle)\" (plan_id=\(plan.id.uuidString)).",
            isError: false
        )
    }
    return ToolResult(
        content: "Scheduled \(title) for \(dateStr) (workout \(w.id.uuidString.prefix(8))).",
        isError: false
    )
} catch RepositoryError.noActivePlan {
    return ToolResult(content: "No active training plan. Ask the user to confirm the block goal/length first.",
                      isError: true)
} catch {
    return ToolResult(content: "Persistence error: \(error.localizedDescription)", isError: true)
}
```

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/CoachTools.swift BearDown/BearDownTests/CoachToolsTests.swift
git commit -m "feat(coach): plan_title/plan_goal on upsert_workout

Adds two optional schema fields. Writes to a named plan emit a
result string carrying plan_id=<uuid> so the chip layer can detect
the new plan and render a Switch to plan chip. Writes to the active
plan keep the existing result format (no plan_id marker)."
```

---

## Task 9: Add `plan_title` guidance to `CoachPrompt.toolAddendum`

Pure prompt change — no behavior unit test, but verify the assembled prompt contains the new paragraph.

**Files:**
- Modify: `BearDown/BearDown/Coach/CoachPrompt.swift`
- Test: `BearDown/BearDownTests/CoachPromptTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `CoachPromptTests.swift`:

```swift
func test_toolAddendum_mentionsPlanTitle() {
    XCTAssertTrue(CoachPrompt.toolAddendum.contains("plan_title"),
                  "tool addendum must instruct the model when to use plan_title")
    XCTAssertTrue(CoachPrompt.toolAddendum.contains("new training block"),
                  "tool addendum must frame plan_title as a new-block signal")
}
```

- [ ] **Step 2: Run the test, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachPromptTests -quiet
```

- [ ] **Step 3: Extend the addendum**

Replace `CoachPrompt.toolAddendum` in `CoachPrompt.swift` with:

```swift
public static let toolAddendum: String = """

# App integration (the user will only see what you emit via tools)

Every scheduled day in a training block MUST be emitted via the `upsert_workout` tool. Do not describe a plan in prose without calling the tool — the user will not see it.

Each day's workout is structured as one or more blocks tagged `strength`, `cardio`, or `mobility`.

To remove an existing day, call `delete_workout` rather than emitting a "rest day" workout. Rest days are simply days with no workout.

Call `get_recent_history` when you need more than the always-on 14-day history window already provided in the context block below (for example, reviewing a prior block).

When the user asks you to start a new training block (race prep, new mesocycle, returning from a break), set `plan_title` and `plan_goal` on every workout you write for that block. The first workout you write with a new title creates the plan as inactive — the user will activate it themselves via a Switch to plan button. Don't change `plan_title` mid-block; treat it as the block's identity. For follow-up adjustments inside the current active block, leave `plan_title` unset.

Speak conversationally between tool calls — narrate intent and ask the user for input when ambiguous. The user can see your text replies in chat.
"""
```

- [ ] **Step 4: Run the test, expect pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/CoachPrompt.swift BearDown/BearDownTests/CoachPromptTests.swift
git commit -m "feat(coach): teach prompt when to use plan_title/plan_goal"
```

---

## Task 10: Add `planId` to `ChatBubble.ToolChip` + render switch variant

The chip data type gains an optional `planId`. The render path branches: when `planId != nil`, render the filled "SWITCH TO" variant; otherwise render the existing per-workout chip.

**Files:**
- Modify: `BearDown/BearDown/Views/Coach/ChatBubble.swift`

Note: this is a pure UI change — no unit test. Verified by build + smoke test in Task 19's UI test.

- [ ] **Step 1: Extend `ToolChip`**

In `BearDown/BearDown/Views/Coach/ChatBubble.swift`, replace the `ToolChip` struct:

```swift
public struct ToolChip: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let isError: Bool
    public let workoutDate: Date?
    public let planId: UUID?

    public init(id: String, label: String, isError: Bool,
                workoutDate: Date?, planId: UUID? = nil) {
        self.id = id
        self.label = label
        self.isError = isError
        self.workoutDate = workoutDate
        self.planId = planId
    }
}
```

The default value on `planId` keeps every existing construction site (CoachViewModel currently builds chips with positional + named args) compiling.

- [ ] **Step 2: Branch the chip renderer**

Replace `editorialChip(_:)` in `ChatBubble.swift`:

```swift
@ViewBuilder
private func editorialChip(_ chip: ToolChip) -> some View {
    if chip.planId != nil {
        switchPlanChip(chip)
    } else {
        workoutChip(chip)
    }
}

private func workoutChip(_ chip: ToolChip) -> some View {
    let tint: Color = chip.isError ? .red : .primary
    return HStack(spacing: 6) {
        Image(systemName: chip.isError ? "exclamationmark.triangle.fill" : "calendar")
            .font(.caption2.weight(.bold))
        Text(chip.label.uppercased())
            .font(BDStyle.monoTiny)
            .tracking(BDStyle.trackingTight)
            .lineLimit(1)
    }
    .padding(.horizontal, 10).padding(.vertical, 5)
    .foregroundStyle(tint.opacity(chip.isError ? 1.0 : 0.75))
    .background(
        (chip.isError ? Color.red.opacity(0.10) : BDStyle.chipBackground),
        in: Capsule()
    )
    .overlay(
        Capsule().stroke(
            chip.isError ? Color.red.opacity(0.3) : Color.primary.opacity(0.12),
            lineWidth: 1
        )
    )
}

private func switchPlanChip(_ chip: ToolChip) -> some View {
    HStack(spacing: 8) {
        Image(systemName: "arrow.right.circle.fill")
            .font(.callout.weight(.bold))
        Text(chip.label.uppercased())
            .font(BDStyle.monoSmall)
            .tracking(BDStyle.trackingWide)
            .lineLimit(1)
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .foregroundStyle(Color(.systemBackground))
    .background(Color.primary, in: Capsule())
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: build succeeds with no warnings about unused parameters etc.

- [ ] **Step 4: Run the unit suite**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all PASS (no test changes, but confirm we didn't break existing chip handling).

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Views/Coach/ChatBubble.swift
git commit -m "feat(coach): switch-plan chip variant in ChatBubble"
```

---

## Task 11: Extend `CoachViewModel.computeChips` to emit switch-plan chips

Parse `toolResultsJSON` for `plan_id=<uuid>` markers; for each unique plan id seen in a single message, emit one switch chip alongside the existing per-workout chips. Order: switch chips on top, then workout chips.

**Files:**
- Modify: `BearDown/BearDown/ViewModels/CoachViewModel.swift`
- Test: `BearDown/BearDownTests/CoachViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `BearDown/BearDownTests/CoachViewModelTests.swift`:

```swift
func test_computeChips_extractsPlanIdFromToolResults() throws {
    let planId = UUID()
    let toolCalls: [[String: Any]] = [[
        "id": "toolu_1",
        "name": "upsert_workout",
        "input": ["date": "2026-06-08", "title": "Easy run", "summary": "30 min", "blocks": []],
    ]]
    let toolResults: [[String: Any]] = [[
        "tool_use_id": "toolu_1",
        "content": "Scheduled \"Easy run\" for 2026-06-08 in plan \"Race Prep — June 24\" (plan_id=\(planId.uuidString)).",
    ]]
    let callsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)!
    let resultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)!

    let m = ChatMessage(role: .assistant, text: "Built your block.", conversationId: UUID())
    m.toolCallsJSON = callsJSON
    m.toolResultsJSON = resultsJSON

    let chips = CoachViewModel.computeChipsForTest(from: m)

    // Switch chip is first, then the per-workout chip.
    XCTAssertEqual(chips.count, 2)
    XCTAssertEqual(chips[0].planId, planId)
    XCTAssertTrue(chips[0].label.contains("Race Prep — June 24"),
                  "switch chip label must include plan title")
    XCTAssertNil(chips[1].planId)  // per-workout chip
}

func test_computeChips_dedupsMultipleWorkoutsToOneSwitchChipPerPlan() throws {
    let planId = UUID()
    let toolCalls: [[String: Any]] = (1...3).map { i in [
        "id": "toolu_\(i)",
        "name": "upsert_workout",
        "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": []],
    ] }
    let toolResults: [[String: Any]] = (1...3).map { i in [
        "tool_use_id": "toolu_\(i)",
        "content": "Scheduled \"W\(i)\" for 2026-06-0\(i) in plan \"Race Prep\" (plan_id=\(planId.uuidString)).",
    ] }
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)
    m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)

    let chips = CoachViewModel.computeChipsForTest(from: m)
    let switchChips = chips.filter { $0.planId != nil }
    XCTAssertEqual(switchChips.count, 1, "3 workouts -> 1 dedup'd switch chip")
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests -quiet
```

Expected: compile failure (no `computeChipsForTest` and current `computeChips` doesn't parse plan_id).

- [ ] **Step 3: Implement**

In `BearDown/BearDown/ViewModels/CoachViewModel.swift`:

1. Expose a non-private static façade for tests (keeps `computeChips` private to the type but accessible from tests via `@testable import`):

```swift
// Test seam — same body as the real computeChips, mirrors its signature.
internal static func computeChipsForTest(from m: ChatMessage) -> [ChatBubble.ToolChip] {
    computeChips(from: m)
}
```

2. Replace `computeChips(from:)` with the extended implementation that emits switch chips first, then per-workout chips:

```swift
private static func computeChips(from m: ChatMessage) -> [ChatBubble.ToolChip] {
    var switchChips: [ChatBubble.ToolChip] = []
    var workoutChips: [ChatBubble.ToolChip] = []
    var seenPlanIds = Set<UUID>()

    // Tool result → plan-switch chips, dedup'd per plan id.
    if let raw = m.toolResultsJSON,
       let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
        for dict in arr {
            guard let content = dict["content"] as? String,
                  let parsed = parsePlanSwitchMarker(in: content),
                  seenPlanIds.insert(parsed.id).inserted else { continue }
            switchChips.append(.init(
                id: "switch-\(parsed.id.uuidString)",
                label: "Switch to: \(parsed.title)",
                isError: false,
                workoutDate: nil,
                planId: parsed.id
            ))
        }
    }

    // Tool calls → per-workout chips (existing behavior).
    if let raw = m.toolCallsJSON,
       let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
        for dict in arr {
            let id = (dict["id"] as? String) ?? UUID().uuidString
            let name = (dict["name"] as? String) ?? "?"
            let input = (dict["input"] as? [String: Any]) ?? [:]
            switch name {
            case "upsert_workout":
                let date = input["date"] as? String ?? "?"
                let title = input["title"] as? String ?? "Workout"
                workoutChips.append(.init(
                    id: id,
                    label: "Scheduled \(title) — \(date)",
                    isError: false,
                    workoutDate: parseIso(date)
                ))
            case "delete_workout":
                let date = input["date"] as? String ?? "?"
                workoutChips.append(.init(
                    id: id,
                    label: "Deleted workout on \(date)",
                    isError: false,
                    workoutDate: parseIso(date)
                ))
            case "get_recent_history":
                workoutChips.append(.init(
                    id: id, label: "Reviewed recent history",
                    isError: false, workoutDate: nil
                ))
            default:
                workoutChips.append(.init(
                    id: id, label: "Called \(name)",
                    isError: false, workoutDate: nil
                ))
            }
        }
    }

    return switchChips + workoutChips
}

/// Parses `... in plan "<title>" (plan_id=<uuid>).` out of a tool result string.
/// Returns nil if the marker is absent (the common case — writes to the active plan).
private static func parsePlanSwitchMarker(in content: String) -> (id: UUID, title: String)? {
    guard let idRange = content.range(of: "plan_id=") else { return nil }
    let after = content[idRange.upperBound...]
    let uuidStr = after.prefix(36)
    guard uuidStr.count == 36, let id = UUID(uuidString: String(uuidStr)) else { return nil }

    // Title sits between the first `in plan "` and the next `"`.
    guard let titleStart = content.range(of: "in plan \"") else {
        return (id, "plan")
    }
    let titleTail = content[titleStart.upperBound...]
    guard let titleEnd = titleTail.range(of: "\"") else {
        return (id, "plan")
    }
    let title = String(titleTail[..<titleEnd.lowerBound])
    return (id, title)
}
```

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/ViewModels/CoachViewModel.swift BearDown/BearDownTests/CoachViewModelTests.swift
git commit -m "feat(coach): switch-plan chips dedup'd per plan id

CoachViewModel.computeChips now parses plan_id=<uuid> out of tool
result strings, dedups across the assistant turn, and emits one
'Switch to: <title>' chip per unique plan id ahead of the per-workout
chips."
```

---

## Task 12: Wire `CoachView.onChipTap` to activate + jump

When the tapped chip carries a `planId`, activate that plan and navigate to its detail. Otherwise (existing behavior), focus the workout date on Today.

**Files:**
- Modify: `BearDown/BearDown/Views/Coach/CoachView.swift`
- Modify: `BearDown/BearDown/App/AppNavigation.swift`

- [ ] **Step 1: Add `pendingPlanDetail` to `AppNavigation`**

Replace `BearDown/BearDown/App/AppNavigation.swift`:

```swift
import Combine
import SwiftUI

@MainActor
public final class AppNavigation: ObservableObject {

    /// 0 = Today, 1 = Plan, 2 = Coach, 3 = Settings
    @Published public var selectedTab: Int = 0

    /// When set non-nil, TodayView jumps to this date and clears it.
    @Published public var focusedDate: Date?

    /// When set non-nil, PlansListView pushes the detail for this plan id and clears it.
    @Published public var pendingPlanDetail: UUID?

    public init() {}
}
```

- [ ] **Step 2: Branch the `onChipTap` closure in `CoachView`**

In `BearDown/BearDown/Views/Coach/CoachView.swift`, replace the closure passed to `ChatBubble` with:

```swift
ChatBubble(role: m.role,
           text: m.text,
           toolChips: vm.chips(for: m),
           onChipTap: { chip in
               if let planId = chip.planId {
                   try? env.plans.activate(planId: planId)
                   nav.selectedTab = 1
                   nav.pendingPlanDetail = planId
               } else if let d = chip.workoutDate {
                   nav.focusedDate = d
                   nav.selectedTab = 0
               }
           })
    .id(m.id)
```

`env` is reachable as an `@EnvironmentObject` — `CoachView` already has `@EnvironmentObject private var nav: AppNavigation`; add a sibling declaration if not already present:

```swift
@EnvironmentObject private var env: AppEnvironment
@EnvironmentObject private var nav: AppNavigation
```

- [ ] **Step 3: Build**

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: build succeeds.

- [ ] **Step 4: Run tests to confirm nothing regressed**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Views/Coach/CoachView.swift BearDown/BearDown/App/AppNavigation.swift
git commit -m "feat(coach): switch-chip tap activates plan + jumps to Plans tab

AppNavigation.pendingPlanDetail is the cross-tab signal so the
PlansListView (Task 14) can auto-push the plan detail when the user
taps a Switch to plan chip in chat."
```

---

## Task 13: Rename `PlanViewModel` → `PlanDetailViewModel(plan:)`

The detail VM no longer queries the active plan — it takes a `TrainingPlan` directly. Weeks are computed from `plan.workouts`; no repo call needed (the relation is loaded eagerly by SwiftData via the navigation parameter). `hasPlan` goes away — a detail view always has a plan.

The existing `PlanViewModelTests.swift` is updated alongside.

**Files:**
- Delete: `BearDown/BearDown/ViewModels/PlanViewModel.swift`
- Create: `BearDown/BearDown/ViewModels/PlanDetailViewModel.swift`
- Delete: `BearDown/BearDownTests/PlanViewModelTests.swift`
- Create: `BearDown/BearDownTests/PlanDetailViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `BearDown/BearDownTests/PlanDetailViewModelTests.swift`:

```swift
import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class PlanDetailViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var plans: PlanRepository!
    private var workouts: WorkoutRepository!

    override func setUpWithError() throws {
        container = try .beardownInMemory()
        plans = PlanRepository(context: container.mainContext)
        workouts = WorkoutRepository(context: container.mainContext, plans: plans)
    }

    func test_refresh_groupsWorkoutsIntoWeeksSortedAscending() throws {
        let plan = try plans.createPlan(title: "Block",
                                        startDate: .now,
                                        endDate: .now.addingTimeInterval(14 * 86400))
        _ = try workouts.upsert(.init(date: .now, title: "Mon", summary: "", blocks: []))
        _ = try workouts.upsert(.init(date: .now.addingTimeInterval(7 * 86400),
                                       title: "NextMon", summary: "", blocks: []))

        let vm = PlanDetailViewModel(plan: plan)
        vm.refresh()

        XCTAssertEqual(vm.weeks.count, 2)
        XCTAssertEqual(vm.weeks[0].workouts.first?.title, "Mon")
        XCTAssertEqual(vm.weeks[1].workouts.first?.title, "NextMon")
    }

    func test_isActive_reflectsPlanState() throws {
        let plan = try plans.createPlan(title: "Block",
                                        startDate: .now,
                                        endDate: .now)
        let vm = PlanDetailViewModel(plan: plan)
        vm.refresh()
        XCTAssertTrue(vm.isActive)
    }
}
```

- [ ] **Step 2: Delete old files**

```bash
rm BearDown/BearDown/ViewModels/PlanViewModel.swift
rm BearDown/BearDownTests/PlanViewModelTests.swift
```

The Xcode synchronized group will pick up the deletion automatically.

- [ ] **Step 3: Create `PlanDetailViewModel`**

Create `BearDown/BearDown/ViewModels/PlanDetailViewModel.swift`:

```swift
import Combine
import Foundation

@MainActor
public final class PlanDetailViewModel: ObservableObject {

    public struct WeekSection: Identifiable {
        public let id: Date          // weekStart
        public let label: String
        public let progress: String
        public let workouts: [Workout]
    }

    @Published public private(set) var weeks: [WeekSection] = []
    @Published public private(set) var title: String = ""
    @Published public private(set) var goal: String = ""
    @Published public private(set) var startDate: Date = .now
    @Published public private(set) var endDate: Date = .now
    @Published public private(set) var isActive: Bool = false

    private static let weekRangeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    public let planId: UUID
    private let plan: TrainingPlan

    public init(plan: TrainingPlan) {
        self.plan = plan
        self.planId = plan.id
        // Cheap init — owning view triggers refresh() in .onAppear.
    }

    public func refresh() {
        title = plan.title
        goal = plan.goal
        startDate = plan.startDate
        endDate = plan.endDate
        isActive = plan.isActive

        let cal = Calendar.current
        let ws = plan.workouts.sorted { $0.date < $1.date }
        let grouped = Dictionary(grouping: ws) { cal.dateInterval(of: .weekOfYear, for: $0.date)!.start }
        let f = Self.weekRangeFormatter
        weeks = grouped.keys.sorted().enumerated().map { (idx, weekStart) in
            let items = grouped[weekStart]!.sorted { $0.date < $1.date }
            let done = items.filter { $0.status == .completed }.count
            let total = items.count
            let end = cal.date(byAdding: .day, value: 6, to: weekStart)!
            let label = "Week \(idx + 1) · \(f.string(from: weekStart)) – \(f.string(from: end))"
            return WeekSection(id: weekStart, label: label,
                               progress: "\(done)/\(total) complete",
                               workouts: items)
        }
    }
}
```

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/PlanDetailViewModelTests -quiet
```

Expected: PASS. **Build will still fail at the project level** because `PlanView.swift` still references the deleted `PlanViewModel`. The next task replaces PlanView. Do not attempt to ship at this point — finish Task 14 before committing the unified rename.

Skip the unit-suite check at this step; it will fail until Task 14 lands.

- [ ] **Step 5: Don't commit yet**

This task and Task 14 are a single git commit. Move directly to Task 14.

---

## Task 14: Replace `PlanView` with `PlanDetailView(plan:)` + action bar

Rewrite of the current `PlanView`:
- Takes a `TrainingPlan` parameter instead of an `AppEnvironment` (the parent's NavigationLink provides the plan).
- Hero replaces the static "Training Block" label with the plan's title + date range + (optional) `goal`.
- `safeAreaInset(edge: .bottom)` adds an action bar: DELETE (always), and MAKE ACTIVE (when inactive only).
- Confirmation alerts route through `@State`.
- After Make Active, the view stays put; after Delete, it dismisses via the parent NavigationStack.

**Files:**
- Delete: `BearDown/BearDown/Views/Plan/PlanView.swift`
- Create: `BearDown/BearDown/Views/Plan/PlanDetailView.swift`

- [ ] **Step 1: Delete `PlanView.swift`**

```bash
rm BearDown/BearDown/Views/Plan/PlanView.swift
```

- [ ] **Step 2: Create `PlanDetailView.swift`**

Create `BearDown/BearDown/Views/Plan/PlanDetailView.swift`:

```swift
import SwiftUI

public struct PlanDetailView: View {
    @StateObject private var vm: PlanDetailViewModel
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Workout?
    @State private var showDeleteConfirm = false
    @State private var actionError: String?

    public init(plan: TrainingPlan) {
        _vm = StateObject(wrappedValue: PlanDetailViewModel(plan: plan))
    }

    public var body: some View {
        planScroll
            .background(Color(.systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .sheet(item: $selected) { w in
                WorkoutDetailSheet(vm: WorkoutDetailViewModel(env: env, workout: w))
            }
            .alert("Delete \"\(vm.title)\"?",
                   isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { performDelete() }
            } message: {
                Text(vm.isActive
                     ? "This is your active plan. Today will be empty until you activate or create another plan. All workouts and any scheduled notifications will be removed."
                     : "All workouts in this plan will be removed.")
            }
            .alert("Action failed",
                   isPresented: Binding(get: { actionError != nil },
                                        set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
            .onAppear { vm.refresh() }
    }

    private var planScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BDStyle.sectionSpacing) {
                hero
                ForEach(vm.weeks) { section in weekSection(section) }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .refreshable { vm.refresh() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            BDEyebrow(eyebrow)
            Text(vm.title)
                .font(BDStyle.displayTitle)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if !vm.goal.isEmpty {
                Text(vm.goal)
                    .font(BDStyle.bodySerif)
                    .foregroundStyle(BDStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BDHairline().padding(.top, 4)
            if vm.isActive {
                HStack {
                    Spacer()
                    BDStatusPill(label: "Active",
                                 systemImage: "circle.fill",
                                 color: .green)
                }
            }
        }
    }

    private var eyebrow: String {
        let f = Self.eyebrowFormatter
        return "\(f.string(from: vm.startDate)) – \(f.string(from: vm.endDate))".uppercased()
    }

    private func weekSection(_ section: PlanDetailViewModel.WeekSection) -> some View {
        let done = section.workouts.filter { $0.status == .completed }.count
        let total = section.workouts.count
        let progress = String(format: "%02d / %02d", done, total)
        let weekIndex = (vm.weeks.firstIndex(where: { $0.id == section.id }) ?? 0) + 1
        let weekTitle = String(format: "Week %02d", weekIndex)

        return VStack(alignment: .leading, spacing: 14) {
            BDSectionHeader(title: weekTitle, trailing: AnyView(progressLabel(progress)))
            BDLabel(dateRangeLabel(for: section.id))
            VStack(spacing: 0) {
                ForEach(Array(section.workouts.enumerated()), id: \.element.id) { idx, w in
                    Button { selected = w } label: { workoutRow(w) }
                        .buttonStyle(.plain)
                    if idx < section.workouts.count - 1 {
                        BDHairline().padding(.leading, 56)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func progressLabel(_ text: String) -> some View {
        Text(text)
            .font(BDStyle.monoSmall)
            .tracking(BDStyle.trackingWide)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func workoutRow(_ w: Workout) -> some View {
        let kinds: [BlockKind] = orderedKinds(for: w)
        return HStack(alignment: .top, spacing: 14) {
            dateGutter(w.date)
            VStack(alignment: .leading, spacing: 8) {
                Text(w.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if !kinds.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(kinds, id: \.self) { kind in
                            BDKindChip(emoji: emoji(for: kind), label: label(for: kind))
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            statusIcon(w.status).padding(.top, 2)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func dateGutter(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.weekday(.abbreviated))
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingWide)
                .foregroundStyle(.secondary)
            Text(date, format: .dateTime.day())
                .font(.system(.title3, design: .serif).weight(.bold))
                .monospacedDigit()
        }
        .frame(width: 42, alignment: .leading)
    }

    @ViewBuilder
    private func statusIcon(_ status: WorkoutStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.body.weight(.regular))
                .foregroundStyle(.secondary.opacity(0.6))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            BDHairline()
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("DELETE")
                        .font(BDStyle.monoSmall)
                        .tracking(BDStyle.trackingWide)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
                .accessibilityIdentifier("plan.delete")

                if !vm.isActive {
                    Button {
                        performActivate()
                    } label: {
                        Text("MAKE ACTIVE")
                            .font(BDStyle.monoSmall)
                            .tracking(BDStyle.trackingWide)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .controlSize(.large)
                    .accessibilityIdentifier("plan.makeActive")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }

    private func performActivate() {
        do {
            try env.plans.activate(planId: vm.planId)
            vm.refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func performDelete() {
        do {
            try env.plans.delete(planId: vm.planId)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: – Helpers

    private static let eyebrowFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d · yyyy"; return f
    }()

    private static let weekRangeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private func dateRangeLabel(for weekStart: Date) -> String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let f = Self.weekRangeFormatter
        return "\(f.string(from: weekStart)) – \(f.string(from: end))"
    }

    private func orderedKinds(for w: Workout) -> [BlockKind] {
        var seen = Set<BlockKind>()
        var out: [BlockKind] = []
        for k in w.blocks.sorted(by: { $0.order < $1.order }).map(\.kind) where seen.insert(k).inserted {
            out.append(k)
        }
        return out
    }

    private func emoji(for kind: BlockKind) -> String {
        switch kind {
        case .strength: return "💪"
        case .cardio:   return "🏃"
        case .mobility: return "🧘"
        }
    }

    private func label(for kind: BlockKind) -> String {
        switch kind {
        case .strength: return "Strength"
        case .cardio:   return "Cardio"
        case .mobility: return "Mobility"
        }
    }
}
```

- [ ] **Step 3: Build**

`RootView` still references `PlanView` — expect a build error. We fix that in Task 15. To verify just the new file compiles in isolation, you can run the unit-test suite, which doesn't link `RootView` aggressively but will still hit the compile error. Instead, run a build:

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | tail -30
```

Expected: error in `RootView.swift` about `PlanView` missing. **That's fine** — Task 15 fixes it.

- [ ] **Step 4: Continue to Task 15**

This task and Task 13 + Task 15 share a single commit. Do not commit yet.

- [ ] **Step 5: (Deferred) Commit after Task 15.**

---

## Task 15: New `PlansListViewModel` + `PlansListView`, wire into `RootView`

The new tab root. List of `PlanCard`s. Tap → `PlanDetailView`. Listens to `nav.pendingPlanDetail` to auto-push the detail after a switch-chip tap.

**Files:**
- Create: `BearDown/BearDown/ViewModels/PlansListViewModel.swift`
- Create: `BearDown/BearDown/Views/Plan/PlansListView.swift`
- Create: `BearDown/BearDownTests/PlansListViewModelTests.swift`
- Modify: `BearDown/BearDown/Views/Shared/RootView.swift`

- [ ] **Step 1: Write the failing test**

Create `BearDown/BearDownTests/PlansListViewModelTests.swift`:

```swift
import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class PlansListViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        container = try .beardownInMemory()
        env = AppEnvironment(modelContainer: container,
                             keychain: KeychainStore(service: "com.beardown.tests.plans.\(UUID().uuidString)"),
                             anthropic: FakeAnthropicClient())
    }

    func test_refresh_buildsSummariesActiveFirstWithCompletionCounts() throws {
        let active = try env.plans.createPlan(title: "Active",
                                              startDate: .now,
                                              endDate: .now.addingTimeInterval(7 * 86400))
        _ = try env.workouts.upsert(.init(date: .now, title: "A1", summary: "", blocks: []))
        let archivedW = try env.workouts.upsert(.init(date: .now.addingTimeInterval(-86400),
                                                     title: "AR1", summary: "",
                                                     blocks: [], planTitle: "Archived"))
        try env.workouts.markStatus(workoutId: archivedW.id, status: .completed, note: nil)

        let vm = PlansListViewModel(env: env)
        vm.refresh()

        XCTAssertEqual(vm.plans.count, 2)
        XCTAssertEqual(vm.plans[0].id, active.id)
        XCTAssertTrue(vm.plans[0].isActive)
        XCTAssertEqual(vm.plans[0].completed, 0)
        XCTAssertEqual(vm.plans[0].total, 1)

        XCTAssertFalse(vm.plans[1].isActive)
        XCTAssertEqual(vm.plans[1].title, "Archived")
        XCTAssertEqual(vm.plans[1].completed, 1)
        XCTAssertEqual(vm.plans[1].total, 1)
    }
}
```

- [ ] **Step 2: Run the test, expect failure**

Expected: compile failure (`PlansListViewModel` missing).

- [ ] **Step 3: Implement VM + View + rewire RootView**

Create `BearDown/BearDown/ViewModels/PlansListViewModel.swift`:

```swift
import Combine
import Foundation

@MainActor
public final class PlansListViewModel: ObservableObject {

    public struct PlanSummary: Identifiable, Equatable {
        public let id: UUID
        public let title: String
        public let goal: String
        public let startDate: Date
        public let endDate: Date
        public let isActive: Bool
        public let completed: Int
        public let total: Int
    }

    @Published public private(set) var plans: [PlanSummary] = []

    private let env: AppEnvironment
    public init(env: AppEnvironment) {
        self.env = env
        // Cheap init — owning view triggers refresh() in .onAppear.
    }

    public func refresh() {
        let rows = (try? env.plans.allPlans()) ?? []
        plans = rows.map { p in
            let total = p.workouts.count
            let done = p.workouts.filter { $0.status == .completed }.count
            return PlanSummary(id: p.id, title: p.title, goal: p.goal,
                               startDate: p.startDate, endDate: p.endDate,
                               isActive: p.isActive, completed: done, total: total)
        }
    }

    public func plan(id: UUID) -> TrainingPlan? {
        try? env.plans.plan(id: id)
    }
}
```

Create `BearDown/BearDown/Views/Plan/PlansListView.swift`:

```swift
import SwiftUI

public enum PlansRoute: Hashable {
    case detail(planId: UUID)
}

public struct PlansListView: View {
    @StateObject private var vm: PlansListViewModel
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var nav: AppNavigation
    @State private var path = NavigationPath()

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: PlansListViewModel(env: env))
    }

    public var body: some View {
        NavigationStack(path: $path) {
            Group {
                if vm.plans.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PlansRoute.self) { route in
                switch route {
                case .detail(let id):
                    if let plan = vm.plan(id: id) {
                        PlanDetailView(plan: plan)
                            .onDisappear { vm.refresh() }
                    } else {
                        Text("Plan not found")
                            .font(BDStyle.bodySerif)
                    }
                }
            }
            .onAppear { vm.refresh() }
            .onChange(of: nav.pendingPlanDetail) { _, newValue in
                if let id = newValue {
                    path.append(PlansRoute.detail(planId: id))
                    nav.pendingPlanDetail = nil
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BDStyle.sectionSpacing) {
                pageHeader
                ForEach(Array(vm.plans.enumerated()), id: \.element.id) { idx, p in
                    if idx > 0 { BDHairline() }
                    NavigationLink(value: PlansRoute.detail(planId: p.id)) {
                        PlanCard(plan: p)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("plan.card.\(p.title)")
                }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .refreshable { vm.refresh() }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PLANS")
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingHero)
                .foregroundStyle(.secondary)
            Text("Training blocks")
                .font(BDStyle.displayTitle)
                .foregroundStyle(.primary)
            BDHairline().padding(.top, 8)
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            BDEyebrow("No plans yet")
            Text("Build your block.")
                .font(BDStyle.displayTitle)
                .fixedSize(horizontal: false, vertical: true)
            BDHairline()
            Text("Ask the Coach to draft a four-week training block tailored to your goals, schedule, and recovery.")
                .font(BDStyle.bodySerif)
                .foregroundStyle(BDStyle.mutedText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                nav.selectedTab = 2
            } label: {
                HStack(spacing: 8) {
                    Text("ASK COACH")
                        .font(BDStyle.monoSmall)
                        .tracking(BDStyle.trackingWide)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .controlSize(.large)
            .padding(.top, 6)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlanCard: View {
    let plan: PlansListViewModel.PlanSummary

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d · yyyy"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                BDEyebrow(rangeText)
                Spacer()
                if plan.isActive {
                    BDStatusPill(label: "Active",
                                 systemImage: "circle.fill",
                                 color: .green)
                }
            }
            Text(plan.title)
                .font(BDStyle.displayMedium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !plan.goal.isEmpty {
                Text(plan.goal)
                    .font(BDStyle.bodySerif)
                    .foregroundStyle(BDStyle.mutedText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BDHairline().padding(.top, 4)
            progressRow
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var rangeText: String {
        let f = Self.rangeFormatter
        return "\(f.string(from: plan.startDate)) → \(f.string(from: plan.endDate))".uppercased()
    }

    private var progressRow: some View {
        HStack(spacing: 12) {
            ProgressBar(fraction: plan.total == 0 ? 0 : Double(plan.completed) / Double(plan.total))
                .frame(height: 4)
            Text(String(format: "%02d / %02d", plan.completed, plan.total))
                .font(BDStyle.monoSmall)
                .tracking(BDStyle.trackingWide)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.primary)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
    }
}
```

Modify `BearDown/BearDown/Views/Shared/RootView.swift` — change the Plan tab line:

```swift
PlansListView(env: env)
    .tabItem { Label("Plan", systemImage: "list.bullet.rectangle") }
    .tag(1)
```

(Tab label stays "Plan" — the user thinks of it as the same tab; the list-vs-detail is a navigation concern.)

- [ ] **Step 4: Run the full suite**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all PASS — including the new `PlansListViewModelTests` and `PlanDetailViewModelTests`.

Also build the app target to confirm `RootView` compiles:

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: build succeeds.

- [ ] **Step 5: Commit all of Tasks 13 + 14 + 15 together**

```bash
git add -A
git status
git commit -m "feat(plans): multi-plan list + detail with action bar

Replaces the single-plan PlanView with two screens:
  PlansListView — tab root, list of cards (active first) with
    title/goal/range/progress, taps a NavigationLink into the detail.
  PlanDetailView — hero with plan-specific title/goal/range/ACTIVE pill,
    weeks scroll (extracted from PlanView), bottom action bar with
    DELETE (always) and MAKE ACTIVE (when inactive). Confirmation
    alerts route through @State; errors surface via .alert.

ViewModels:
  PlansListViewModel — exposes PlanSummary values computed from
    PlanRepository.allPlans().
  PlanDetailViewModel — takes a TrainingPlan, mirrors the weeks
    grouping the old PlanViewModel did.

RootView's Plan tab points at PlansListView. AppNavigation gains
pendingPlanDetail for auto-pushing the detail when the user taps
a Switch to plan chip in Coach.

Old PlanView + PlanViewModel deleted."
```

---

## Task 16: UI test — multi-plan switch + delete flow

End-to-end XCUITest that proves the data layer + UI wiring work together. Seeds two plans via a launch argument, walks the user through tapping into the inactive plan, making it active, popping back, deleting the now-archived original, and confirming both card and notifications are gone.

**Files:**
- Create: `BearDown/BearDownUITests/MultiPlanUITests.swift`
- Modify: `BearDown/BearDown/BearDownApp.swift` (extend the existing UI test seed switch with a `--ui-test-seed-two-plans` branch)

- [ ] **Step 1: Inspect the existing UI test seed in `BearDownApp.swift`**

Read it to see how the existing `--ui-test-seed-week` seed is wired:

```bash
grep -n "ui-test-seed" BearDown/BearDown/BearDownApp.swift
```

Use that pattern for the new flag.

- [ ] **Step 2: Add the new seed branch**

In `BearDown/BearDown/BearDownApp.swift`, alongside the existing seed handler, add a branch that runs when `ProcessInfo.processInfo.arguments.contains("--ui-test-seed-two-plans")`. It should:

1. Create plan "Current Block" as active, `startDate = today - 6d`, `endDate = today + 6d`.
2. Insert 3 workouts in it (yesterday, today, tomorrow).
3. Create an inactive plan "Race Prep — June 24" with `goal = "3.5mi race goal pacing block"`, `startDate = endDate = today + 21d`, by writing a workout with `planTitle:`.

Pattern (adapt to whatever `try? env.workouts.upsert(...)` shape already exists in the file):

```swift
if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-two-plans") {
    let today = Calendar.current.startOfDay(for: .now)
    _ = try? env.plans.createPlan(
        title: "Current Block",
        startDate: today.addingTimeInterval(-6 * 86400),
        endDate: today.addingTimeInterval(6 * 86400)
    )
    for offset in [-1, 0, 1] {
        _ = try? env.workouts.upsert(.init(
            date: today.addingTimeInterval(TimeInterval(offset) * 86400),
            title: "Active W\(offset)",
            summary: "Seed",
            blocks: []
        ))
    }
    _ = try? env.workouts.upsert(.init(
        date: today.addingTimeInterval(21 * 86400),
        title: "Race long run",
        summary: "12mi",
        blocks: [],
        planTitle: "Race Prep — June 24",
        planGoal: "3.5mi race goal pacing block"
    ))
}
```

- [ ] **Step 3: Write the UI test**

Create `BearDown/BearDownUITests/MultiPlanUITests.swift`:

```swift
import XCTest

final class MultiPlanUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func test_listShowsBothPlans_switchActive_deleteArchived() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-stub-validator",
            "--reset-keychain",
            "--ui-test-seed-two-plans",
        ]
        app.launch()

        // Onboard
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap(); key.typeText("sk-ant-uitest")
        app.buttons["Continue"].tap()

        // Plans tab
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Plan"].tap()

        // Two cards visible (active first), one with ACTIVE pill.
        let currentCard = app.otherElements["plan.card.Current Block"]
        let raceCard = app.otherElements["plan.card.Race Prep — June 24"]
        XCTAssertTrue(currentCard.waitForExistence(timeout: 10))
        XCTAssertTrue(raceCard.waitForExistence(timeout: 5))

        // Tap the inactive (race) card -> detail with MAKE ACTIVE.
        raceCard.tap()
        let makeActive = app.buttons["plan.makeActive"]
        XCTAssertTrue(makeActive.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plan.delete"].exists)

        // Make it active. MAKE ACTIVE disappears (button no longer rendered).
        makeActive.tap()
        XCTAssertFalse(makeActive.waitForExistence(timeout: 3))

        // Pop back via the nav bar back button.
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Open the (now archived) "Current Block" card and delete it.
        let currentCard2 = app.otherElements["plan.card.Current Block"]
        XCTAssertTrue(currentCard2.waitForExistence(timeout: 5))
        currentCard2.tap()
        app.buttons["plan.delete"].tap()
        // Confirm destructive alert.
        app.alerts.buttons["Delete"].tap()

        // Pops back to list with only Race Prep present.
        XCTAssertTrue(app.otherElements["plan.card.Race Prep — June 24"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["plan.card.Current Block"].exists)
    }
}
```

- [ ] **Step 4: Run the UI test**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownUITests/MultiPlanUITests -quiet
```

Expected: PASS. The UI runner sometimes fails the first attempt with "Mach error -308 - server died" — that's a known flake on this project. Re-run once; if it passes the second time, that's the canonical outcome. Document this in the failure message if you have to escalate.

If a real failure surfaces, the most likely cause is the accessibility identifier on the card. The `NavigationLink(value:) { ... }` form wraps a button — XCUI reaches the `accessibilityIdentifier` set on the label's container view. If it doesn't, you may need to move the identifier off the NavigationLink container and onto the `PlanCard` itself, or add an explicit `.accessibilityElement(children: .combine)` to the card.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDownUITests/MultiPlanUITests.swift BearDown/BearDown/BearDownApp.swift
git commit -m "test(ui): multi-plan switch + delete flow"
```

---

## Task 17: Update `CLAUDE.md` and `docs/manual-tests.md`

CLAUDE.md needs to reflect:
- The Plans tab is now a list-of-cards landing on a detail view (`PlansListView` / `PlanDetailView`, not `PlanView`).
- `WorkoutRepository.recentHistory` is scoped to the active plan.
- The agent influences plan creation via `plan_title` — gotcha #8 about no `create_plan` tool should add a follow-up note.
- The "Where to look first" table updates the row for changing the coaching/persona to also list the new addendum paragraph, and the row for adding a tab gains a mention of `PlansListView` and `pendingPlanDetail`.
- Add a new gotcha noting that `PlanDetailView` takes a `TrainingPlan` parameter (not env) so it can be reused for any plan.

`docs/manual-tests.md` needs a Multi-Plan section.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/manual-tests.md`

- [ ] **Step 1: Edit `CLAUDE.md`**

In the "What this is" paragraph, change "generates 4-week training blocks via tool calls" to "generates 4-week training blocks via tool calls, with multi-plan support: any number of named plans, one active at a time, switched via Coach chips or the Plans tab".

Update the project tree in "Project layout":

```
│   │   └── Views/{Onboarding,Today,Plan,Coach,Settings,Shared}/
```

is unchanged but the contents inside `Plan/` are `PlansListView.swift` + `PlanDetailView.swift` (no more `PlanView.swift`). You can leave the tree as-is — it's already directory-level.

Append a new gotcha after gotcha #11 ("Don't read repositories from view body"):

```markdown
### 12. `PlanDetailView` takes a `TrainingPlan`, not an `AppEnvironment`

Unlike the other top-level views (`TodayView`, `PlansListView`, `CoachView`, `SettingsView`), `PlanDetailView` constructs its VM with a plan instance:

```swift
PlanDetailView(plan: plan)
```

The parent `PlansListView` provides the plan via the `NavigationStack`'s typed path (`PlansRoute.detail(planId:)`). Don't refactor `PlanDetailView` back to an env-based init — the whole point of the rename was so it could be reused for any plan regardless of active state.
```

Update gotcha #8 ("The agent has no `create_plan` tool — repos must auto-create") with a follow-up paragraph:

```markdown
**As of 2026-06-02 (multi-plan):** the agent can influence plan creation by setting `plan_title` on `upsert_workout`. `WorkoutRepository.upsert` resolves through `PlanRepository.findOrCreatePlan`, which creates the named plan as inactive — the user activates it via the Switch to plan chip. There is still no `create_plan` tool; the auto-create path remains the fallback for writes without `plan_title`.
```

In the "Architecture pointers" list, replace the `WorkoutRepository.recentHistory` mention with:

```markdown
- **`WorkoutRepository.recentHistory(days:)` is scoped to the active plan.** Archived plans don't leak into the Coach's view. Returns empty if there is no active plan.
```

In the "Where to look first" table, replace the row for "Add a new tab or change navigation" with:

```markdown
| Add a tab, change navigation, or push a plan detail from elsewhere | `BearDown/BearDown/Views/Shared/RootView.swift`, `BearDown/BearDown/App/AppNavigation.swift` (`focusedDate`, `pendingPlanDetail`), `BearDown/BearDown/Views/Plan/PlansListView.swift` (`PlansRoute`) |
```

Add a new row above "Run UI tests reliably":

```markdown
| Add a new operation on plans (rename, archive without delete, etc.) | `BearDown/BearDown/Persistence/PlanRepository.swift`, expose to UI via `PlansListViewModel`/`PlanDetailViewModel` |
```

- [ ] **Step 2: Edit `docs/manual-tests.md`**

Append a "Multi-Plan" section at the end:

```markdown
## Multi-Plan

1. **Implicit plan creation via Coach.** Ask the Coach in plain English: *"Build me a race prep block for a 3.5mi race on June 24."* Confirm the assistant emits multiple `upsert_workout` calls and a single SWITCH TO chip appears in the chat (dedup'd across the burst of workouts). The chip background is filled black/white; the text reads `SWITCH TO: <PLAN TITLE>`.

2. **Switch chip activates and navigates.** Tap the SWITCH TO chip. Verify: (a) the Plans tab becomes selected, (b) the new plan's detail screen is pushed, (c) the ACTIVE pill is showing on the new plan.

3. **Plans list shows both plans, active first.** Pop back to the Plans tab root. The list shows the new active plan on top and the formerly-active plan below it (without the ACTIVE pill). Each card shows date range, optional goal, and a `NN / NN` completion ratio.

4. **Make active from detail.** Tap the archived plan. Confirm MAKE ACTIVE + DELETE buttons are in the bottom bar. Tap MAKE ACTIVE. The ACTIVE pill flips on; MAKE ACTIVE disappears. The other plan, when revisited, no longer shows the pill.

5. **Delete with confirmation.** From any plan, tap DELETE. A destructive alert appears. The message text mentions "your active plan" when applicable, otherwise "All workouts in this plan will be removed." Confirm DELETE — the detail pops back to the list and the card is gone.

6. **Notifications cancelled on delete.** Before deleting a plan with scheduled workouts, open iOS Settings → Notifications → BearDown → Show Previews to inspect pending notifications (this is best done via Xcode debugging or `xcrun simctl get_app_container booted Hirey.BearDown data` if you want to script it). After delete, confirm pending notifications for the removed workouts are no longer scheduled.

7. **Empty state after deleting all plans.** Delete the only remaining plan. The Plans tab shows "Build your block." with an ASK COACH CTA. Today shows the rest-day empty state. Type a Coach message asking for a new plan and confirm the auto-create path puts you back at one plan called "Current Block" (no `plan_title` set).
```

- [ ] **Step 3: Build (no test changes)**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all PASS — the doc-only edits don't affect tests.

- [ ] **Step 4: Manual review of the docs**

Re-read CLAUDE.md from top to bottom once. Specifically, confirm gotcha numbering is intact (1 through 12), and the "Where to look first" table doesn't have a stale "Add a tab" row.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/manual-tests.md
git commit -m "docs: multi-plan additions to CLAUDE.md + manual tests"
```

---

## Wrap-up

After all 17 tasks land:

```bash
# Confirm the full suite is green.
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet

# Confirm the UI suite passes (may need a re-run for the known Mach -308 flake).
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownUITests -quiet

# Smoke-test by installing on the booted simulator and walking through
# the manual-tests Multi-Plan section end to end (see docs/manual-tests.md).
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
xcrun simctl install booted /tmp/beardown-dd/Build/Products/Debug-iphonesimulator/BearDown.app
xcrun simctl launch booted Hirey.BearDown
```

If anything below the unit-test level is off (visual styling, scroll behavior, alert wording), capture a screenshot and iterate without changing the unit tests — the suite is the canonical contract.

The final commit chain (in order):

1. `feat(model): add TrainingPlan.goal field`
2. `feat(plans): add PlanRepository.allPlans() with active-first ordering`
3. `feat(plans): add PlanRepository.plan(id:) and activate(planId:)`
4. `feat(plans): add PlanRepository.delete(planId:) with cancel hook`
5. `feat(plans): add PlanRepository.findOrCreatePlan`
6. `feat(plans): route upsert_workout by optional planTitle/planGoal`
7. `feat(coach): scope recentHistory to the active plan`
8. `feat(coach): plan_title/plan_goal on upsert_workout`
9. `feat(coach): teach prompt when to use plan_title/plan_goal`
10. `feat(coach): switch-plan chip variant in ChatBubble`
11. `feat(coach): switch-plan chips dedup'd per plan id`
12. `feat(coach): switch-chip tap activates plan + jumps to Plans tab`
13–15. `feat(plans): multi-plan list + detail with action bar` (combined commit)
16. `test(ui): multi-plan switch + delete flow`
17. `docs: multi-plan additions to CLAUDE.md + manual tests`
