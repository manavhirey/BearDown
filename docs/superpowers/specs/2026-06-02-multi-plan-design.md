# Multi-Plan Support — Design Spec

**Date:** 2026-06-02
**Status:** Approved for implementation planning
**Related:** [`2026-05-31-beardown-design.md`](./2026-05-31-beardown-design.md) (v1 single-plan design)

## Summary

Extend BearDown from one implicit "Current Block" plan to multiple named training plans. The Coach implicitly creates new plans when the user asks for one (race prep, new mesocycle, return from break). The Plans tab becomes a list of plan cards with progress bars; tapping a card pushes into the existing weeks/workouts detail layout. The user opts in to making a new plan active via a "Switch to plan" chip in the Coach chat or a "Make active" button on the plan detail screen. Any plan can be deleted (with confirmation).

## Goals

- Multiple persisted `TrainingPlan` rows visible to the user
- Plans tab: list of cards, each with title, goal, date range, completion progress bar, active marker
- Plan detail: existing PlanView weeks/workouts layout, scoped to one plan
- Coach can create a new (inactive) plan implicitly via an extended `upsert_workout` tool
- User-initiated switching: Coach chat chip after creation, plus a "Make active" button in plan detail
- Delete plans from plan detail screen with destructive confirmation
- Coach context (`get_recent_history`) scoped to the active plan only — archived plans don't leak into agent's view

## Non-goals

- No new agent tool — only an additive change to `upsert_workout`
- No plan editing UI (rename, reschedule, edit goal). Plans are immutable once created; the agent can write a new plan if the user wants changes
- No archived/active sorting toggle; ordering is fixed (active first, then `createdAt` desc)
- No plan templates, sharing, or export
- No undo for delete — confirmation alert is the safeguard
- No background activation — switching is always user-initiated

## Architecture

The data model already supports multiple plans (`TrainingPlan.isActive: Bool`, `archivedAt: Date?`). The work is in the repository layer (add list/activate/delete operations, route writes by plan title), the agent tool schema (two optional fields), and the UI (list + detail navigation, switch chip).

```
PlansListView                    Coach chat
  ├─ PlansListViewModel            └─ ChatBubble
  │   └─ env.plans.allPlans()          └─ ToolChip(planId: ...)
  └─ NavigationStack                       on tap →
      └─ PlanDetailView                    env.plans.activate(planId:)
          ├─ PlanDetailViewModel(plan)     nav.selectedTab = 1
          └─ safeAreaInset action bar      nav.pendingPlanDetail = id
              ├─ MAKE ACTIVE
              └─ DELETE
```

## Data layer

### `TrainingPlan` model — one additive field

```swift
public var goal: String = ""   // default → no migration needed
```

All other fields (`id`, `title`, `startDate`, `endDate`, `isActive`, `archivedAt`, `createdAt`, `updatedAt`, `workouts`) are unchanged.

### `PlanRepository` — new methods

```swift
public func allPlans() throws -> [TrainingPlan]
public func plan(id: UUID) throws -> TrainingPlan?
public func activate(planId: UUID) throws
public func delete(planId: UUID) throws
public func findOrCreatePlan(title: String, goal: String, anchorDate: Date) throws -> TrainingPlan
```

- `allPlans()` — sort active first, then `createdAt` desc
- `activate(planId:)` — archives the current active plan (if any) and marks the target active. Idempotent if target is already active.
- `delete(planId:)` — fetches workout IDs first, deletes the plan (cascade removes workouts via existing `@Relationship(deleteRule: .cascade)`), fires `onCancel` for each workout id so scheduled notifications are removed. Deleting the active plan is allowed; no auto-promotion of another plan to active.
- `findOrCreatePlan(title:goal:anchorDate:)` — case-insensitive title match. If no match, creates an **inactive** plan with `startDate = endDate = anchorDate`. If match found, returns existing plan (does not overwrite `goal`).
- `createPlan(title:startDate:endDate:)` — unchanged. Still used by the auto-create path in `WorkoutRepository.upsert` when no active plan exists, and by future explicit creation flows if added.

### `WorkoutRepository.WorkoutInput` — one additive field

```swift
public var planTitle: String?   // nil → route to active plan (existing behavior)
public var planGoal: String?    // optional, only used on plan creation
```

`WorkoutRepository.upsert` routing:
1. If `input.planTitle` is provided → `findOrCreatePlan(title:, goal: input.planGoal ?? "", anchorDate: input.date)`, attach workout to that plan. Extend that plan's `endDate` if `input.date > plan.endDate`.
2. Else if there's an active plan → attach to it (existing behavior; extends `endDate` as today).
3. Else → call `createPlan` to auto-create "Current Block" as active (existing behavior).

### `WorkoutRepository.recentHistory(days:)` — scope change

Currently fetches all workouts regardless of plan. New behavior: filter to the active plan's workouts only. If no active plan, returns empty. This prevents archived-plan workouts from leaking into the Coach's `get_recent_history` tool result.

## Agent tool changes

### `upsert_workout` schema — two new optional fields

```json
{
  "type": "object",
  "required": ["date", "title", "summary", "blocks"],
  "properties": {
    "date": { "type": "string", "description": "YYYY-MM-DD" },
    "title": { "type": "string" },
    "summary": { "type": "string" },
    "blocks": { ... },
    "plan_title": { "type": "string", "description": "Optional. Attach this workout to a named training plan. If the plan doesn't exist, it's created in an inactive state — the user will activate it via the Switch to plan chip. Reuse the same plan_title across every workout you write for one block." },
    "plan_goal":  { "type": "string", "description": "Optional. One-line goal for the plan (e.g. 'Race prep — 3.5mi June 24'). Only applied when creating the plan; ignored on subsequent writes to the same plan_title." }
  }
}
```

### `CoachTools.handleUpsert` — pass-through

Parses `plan_title` and `plan_goal`, sets them on the `WorkoutInput`, and includes the resolved plan id in the tool result string so the chip renderer can pick it up:

```
Scheduled "Easy run" for 2026-06-08 in new plan "Race Prep — June 24" (plan_id=<uuid>).
```

For writes to the existing active plan (no `plan_title`), the result string stays the same as today (no `plan_id=` marker).

### `CoachPrompt.toolAddendum` — guidance

Add a paragraph explaining when to use `plan_title`:

> When the user asks you to start a new training block (race prep, new mesocycle, returning from a break), set `plan_title` and `plan_goal` on every workout you write for that block. The first workout you write with a new title creates the plan as inactive — the user will activate it themselves via a switch button. Don't change `plan_title` mid-block; treat it as the block's identity. For follow-up adjustments inside the current active block, leave `plan_title` unset.

## Plans tab UI

### `PlansListView` — tab root

Editorial vertical stack of `PlanCard` views, each `NavigationLink` to `PlanDetailView`.

```
ACTIVE  ────────────────────────────────
Race Prep — June 24                     ← BDStyle.displayMedium serif
JUN 1 · 2026  →  JUN 24 · 2026          ← BDEyebrow mono caps
3.5mi race goal pacing block            ← BDStyle.bodySerif (if plan.goal != "")
─────────────────                        ← BDHairline
████████░░░░░░░░░░  07 / 24             ← Capsule progress + mono digits
```

- Active marker: a small `BDStatusPill(label: "Active", systemImage: "circle.fill", color: .green)` aligned top-trailing on the active plan's card. Archived plans render without the pill.
- Card spacing: `BDStyle.sectionSpacing` (32pt) between cards, soft hairline above each except the first.
- Tap target: whole card.

**ViewModel:** `PlansListViewModel` exposes `plans: [PlanSummary]`. `PlanSummary` is a value type computed from `TrainingPlan`: `id`, `title`, `goal`, `startDate`, `endDate`, `isActive`, `completed: Int`, `total: Int`. Computed in `refresh()` from `env.plans.allPlans()`, walking each plan's `workouts` to count completion.

**Empty state:** Reuse the existing "Build your block." editorial state with the `ASK COACH` CTA that sets `nav.selectedTab = 2`.

### `PlanDetailView` — single plan

Reuses the recently-redesigned `PlanView` weeks-list, but with a plan-specific hero:

```
JUN 1  →  JUN 24 · 2026                 ← BDEyebrow
Race Prep — June 24                     ← BDStyle.displayTitle
3.5mi race goal pacing block            ← BDStyle.bodySerif (if goal set)
─────────────────                        ← BDHairline
                              ACTIVE     ← BDStatusPill (if active)

[then: existing BDSectionHeader per-week + workout rows]
```

**Existing PlanView code is the starting point** for the weeks/workouts portion. We rename `PlanViewModel` → `PlanDetailViewModel(plan: TrainingPlan)`. Init takes the plan directly, computes weeks from `plan.workouts` (no repository call needed — already loaded via the navigation parameter).

### Bottom action bar (`safeAreaInset`)

Mirrors `WorkoutDetailSheet`'s pattern.

- **Active plan:** `[DELETE]` only — full-width, `.buttonStyle(.bordered)`, `.tint(.red)`, mono caps "DELETE" label.
- **Inactive plan:** `[DELETE] [MAKE ACTIVE]` split — `DELETE` bordered red, `MAKE ACTIVE` `.buttonStyle(.borderedProminent).tint(.primary)`.

**Delete flow:** `.alert("Delete \"\(plan.title)\"?", role: .destructive)`. The message text adapts:
- Active plan: "This is your active plan. Today will be empty until you activate or create another plan. All workouts and any scheduled notifications will be removed."
- Inactive plan: "All workouts in this plan will be removed."

On confirm: `try env.plans.delete(planId: plan.id)`, then pop the NavigationStack back to PlansListView.

**Make active flow:** `try env.plans.activate(planId: plan.id)`, refresh, optionally bounce a haptic. No navigation change — stay on the detail screen, the ACTIVE pill flips on.

### Navigation

`NavigationStack` in `PlansListView` with a typed path:

```swift
enum PlansRoute: Hashable {
    case detail(planId: UUID)
}
```

`AppNavigation` gains:

```swift
@Published public var pendingPlanDetail: UUID?
```

`PlansListView` watches `pendingPlanDetail` via `.onChange`. When set, it appends `.detail(planId:)` to its `NavigationPath` and clears the property. Used by the Coach chip tap so the user lands on the new plan's detail after switching.

## Coach chat — Switch to plan chip

### Detection

`ChatBubble.ToolChip` struct gains one optional field:

```swift
public let planId: UUID?
```

`CoachViewModel.computeChips(from:)` scans both:

1. `toolCallsJSON` (existing) — emits per-workout chips for `upsert_workout` / `delete_workout` calls
2. `toolResultsJSON` (new) — parses tool result strings for the `plan_id=<uuid>` marker. When found, extracts the plan title from the same string and emits **one chip per unique `planId`** for the assistant message (dedup across the turn so 20 workouts → 1 switch chip).

### Visual

A distinct chip variant (filled background, not soft fill) so it reads as a primary action:

```
┌────────────────────────────────────────┐
│  →  SWITCH TO: RACE PREP — JUNE 24    │   ← filled .primary tint, white text
└────────────────────────────────────────┘
```

- Symbol: `arrow.right.circle.fill`
- Background: `.primary` (high contrast)
- Text: `BDStyle.monoSmall` (slightly larger than the existing workout chips), uppercase, `BDStyle.trackingWide`
- Sorted above per-workout chips in the chip strip

### Tap action

In CoachView's `onChipTap` closure:

```swift
onChipTap: { chip in
    if let planId = chip.planId {
        try? env.plans.activate(planId: planId)
        nav.selectedTab = 1
        nav.pendingPlanDetail = planId
    } else if let d = chip.workoutDate {
        nav.focusedDate = d
        nav.selectedTab = 0
    }
}
```

Activating an already-active plan is a no-op (idempotent). Re-tapping an old chip from earlier in the conversation will re-activate (no-op) and re-navigate to the plan detail — useful for "take me back to that plan we discussed."

## Edge cases

- **Plan with zero workouts** — progress shows `00 / 00`, empty bar
- **Last plan deleted** — PlansListView shows the editorial "Build your block." empty state; Today shows the rest-day empty state; first agent upsert auto-creates "Current Block" as active (existing behavior unchanged)
- **Activate a plan with past `endDate`** — fine; `isActive` is the source of truth, not the date window
- **Agent writes workouts to a `plan_title` that was previously deleted** — `findOrCreatePlan` recreates a fresh inactive plan with that title (idempotent from the agent's perspective)
- **Concurrent edits** (Coach writes to plan X while user views plan X) — PlanDetailView refreshes on `.onAppear`; live SwiftData notifications may also surface changes. Same race window as today.
- **CloudKit conflicts** on `isActive` (two devices activate different plans simultaneously) — last writer wins per SwiftData/CloudKit default. Acceptable for this feature.

## Migration

- **Data:** none. The new `TrainingPlan.goal` field defaults to `""`; existing rows pick up the default. `allPlans()` on existing data returns one row (the current active plan) → Plans tab shows one card → unchanged user experience until they create a second plan.
- **CloudKit schema:** additive optional field with default. No schema rev required.
- **App version:** no migration code in `BearDownApp` or `ModelContainer+Beardown`.

## Testing

### Unit tests (XCTest, in-memory `ModelContainer.beardownInMemory()`)

**PlanRepository (`PlanRepositoryTests`):**
- `test_allPlans_ordersActiveFirst_thenCreatedAtDesc`
- `test_activate_archivesPriorActive_andSetsTarget`
- `test_activate_isIdempotentOnAlreadyActive`
- `test_delete_cascadesWorkouts_andFiresCancelHookPerWorkout`
- `test_delete_activePlan_leavesNoActivePlan`
- `test_findOrCreatePlan_caseInsensitiveTitleMatch`
- `test_findOrCreatePlan_createsInactiveByDefault`
- `test_findOrCreatePlan_doesNotOverwriteGoalOnSecondCall`

**WorkoutRepository (`WorkoutRepositoryTests` — extend existing):**
- `test_upsert_withPlanTitle_routesToNamedPlan_doesNotDisturbActive`
- `test_upsert_withPlanTitle_extendsThatPlansEndDate`
- `test_upsert_withoutPlanTitle_routesToActivePlan` (existing behavior preserved)
- `test_recentHistory_returnsOnlyActivePlanWorkouts`
- `test_recentHistory_returnsEmptyWhenNoActivePlan`

**CoachTools (`CoachToolsTests` — extend existing):**
- `test_handleUpsert_withPlanTitle_includesPlanIdInResultString`
- `test_handleUpsert_withoutPlanTitle_resultStringHasNoPlanIdMarker`

**CoachViewModel (`CoachViewModelTests` — extend existing):**
- `test_computeChips_extractsPlanIdFromToolResults`
- `test_computeChips_dedupsMultipleWorkoutsToOneSwitchChipPerPlan`

### UI test (XCUITest, `MultiPlanUITests`)

Seed: two plans (one active, one inactive) plus a few workouts in each.

1. Onboard, navigate to Plans tab
2. Assert two plan cards are visible, in active-first order
3. Tap the inactive card → assert PlanDetailView appears with MAKE ACTIVE + DELETE buttons
4. Tap MAKE ACTIVE → assert ACTIVE pill appears, MAKE ACTIVE button disappears
5. Pop back, assert the (formerly active) plan now shows without the ACTIVE pill
6. Tap into the (formerly active) plan → tap DELETE → confirm in alert → assert pop-back and card is gone

### Manual test addendum

Update `docs/manual-tests.md` with a Multi-Plan section:
- Coach: ask for a race prep block → assert Coach chat shows SWITCH TO chip → tap it → land on plan detail with ACTIVE pill
- Plans tab: tap an archived plan → see its workouts and dates → tap MAKE ACTIVE → today's view updates to that plan's workouts
- Delete: from any plan, hit DELETE → confirm → plan removed, notifications cancelled (verify via system Settings → Notifications → BearDown)

## Files affected

**New:**
- `BearDown/BearDown/ViewModels/PlansListViewModel.swift`
- `BearDown/BearDown/Views/Plan/PlansListView.swift`
- `BearDown/BearDown/Views/Plan/PlanDetailView.swift` (extracted from current PlanView)
- `BearDown/BearDownTests/PlansListViewModelTests.swift`
- `BearDown/BearDownUITests/MultiPlanUITests.swift`

**Modified:**
- `BearDown/BearDown/Models/TrainingPlan.swift` — add `goal: String`
- `BearDown/BearDown/Persistence/PlanRepository.swift` — add `allPlans`, `plan(id:)`, `activate`, `delete`, `findOrCreatePlan`
- `BearDown/BearDown/Persistence/WorkoutRepository.swift` — `WorkoutInput.planTitle/planGoal`, routing in `upsert`, scope `recentHistory` to active plan
- `BearDown/BearDown/Coach/CoachTools.swift` — extend `upsert_workout` schema + dispatcher, include `plan_id=` in result
- `BearDown/BearDown/Coach/CoachPrompt.swift` — add `plan_title` guidance to `toolAddendum`
- `BearDown/BearDown/Views/Coach/ChatBubble.swift` — add `planId` to `ToolChip`, render switch variant
- `BearDown/BearDown/Views/Coach/CoachView.swift` — branch `onChipTap` on `planId`
- `BearDown/BearDown/ViewModels/CoachViewModel.swift` — extend `computeChips` to parse `plan_id=` from tool results, dedup per plan
- `BearDown/BearDown/App/AppNavigation.swift` — add `pendingPlanDetail: UUID?`
- `BearDown/BearDown/Views/Shared/RootView.swift` — Plans tab points at `PlansListView` (renamed from `PlanView`)
- `BearDown/BearDown/ViewModels/PlanViewModel.swift` → renamed `PlanDetailViewModel`, takes a `TrainingPlan` parameter
- `BearDown/BearDownTests/PlanRepositoryTests.swift`, `WorkoutRepositoryTests.swift`, `CoachToolsTests.swift`, `CoachViewModelTests.swift` — extend per the unit test list
- `docs/manual-tests.md` — add multi-plan section
- `CLAUDE.md` — update single-plan assumptions and the gotcha #8 note now that the agent influences plan creation through `plan_title`

**Deleted:**
- None (PlanView becomes PlanDetailView via rename + extraction)
