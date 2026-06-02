# Approval Gate — Design Spec

**Date:** 2026-06-02
**Status:** Approved for implementation planning
**Related:**
- [`2026-05-31-beardown-design.md`](./2026-05-31-beardown-design.md) — v1 single-plan architecture
- [`2026-06-02-multi-plan-design.md`](./2026-06-02-multi-plan-design.md) — multi-plan support (the foundation this builds on)

## Summary

Today, the Coach silently writes workouts the moment it decides to. The user finds out by switching to Today or Plans. For full new training blocks (4 weeks at a time) this is jarring: 28 workouts land on the calendar before the user has agreed to anything. For in-block adjustments (move Tuesday's run to Wednesday) the immediate-write behavior is fine — those are small, expected, and reversible by another chat turn.

This spec introduces an **approval gate** for the heavyweight case. The Coach gets two new tools — `propose_plan` and `propose_plan_update` — that emit a structured proposal payload instead of writing to SwiftData. The proposal renders in the Coach chat as a prominent chip with explicit CTAs (Add as inactive / Add & switch / Dismiss for new plans; Update plan / Dismiss for updates). Tapping a CTA replays the proposal payload through `WorkoutRepository.upsert` and, for new plans, optionally activates them via `PlanRepository.activate`. The proposal's status (`pending` → `applied` | `dismissed`) is persisted inside the chat message's existing `toolResultsJSON` blob — no new SwiftData model.

Existing `upsert_workout` and `delete_workout` remain as immediate-write paths for follow-up adjustments inside the active block. The `toolAddendum` in `CoachPrompt` is rewritten to teach the agent which tool to call when, and how to interpret prior proposal statuses on subsequent turns (so it doesn't re-propose what's already pending, applied, or dismissed).

Old assistant messages — from before this feature shipped — get a one-way visual upgrade: consecutive `upsert_workout` calls in a single turn are grouped at render time into a virtual proposal payload with `status=applied`, so chat history reads consistently with the new chip language.

## Goals

- Block-scale changes (new plan, multi-workout plan revisions) require explicit user approval before any DB write
- In-block tweaks (a single `upsert_workout` / `delete_workout` against the active plan) stay immediate-write — no regression for the existing UX
- Proposal state survives relaunches and iCloud sync without introducing a new SwiftData model
- Coach sees the status of past proposals in its tool-result history and doesn't re-propose pending ones
- Old chat history reads cleanly in the new chip language — applied-in-the-past actions show as "Applied"
- All-or-nothing per proposal: no per-workout checkboxes; if the proposal is wrong, the user types in chat and the Coach issues a new one
- Single-tap apply (no confirmation sheet); irreversibility is acceptable because correction-via-chat is fast

## Non-goals

- No editing of a pending proposal in the UI. The Coach revises by issuing a new proposal.
- No undo for Apply or Dismiss. Re-running the Coach is the undo.
- No per-workout selection inside a proposal. Whole proposal or nothing.
- No background or auto-apply. Every apply is an explicit tap.
- No new SwiftData entity for proposals. The chat message is the source of truth.
- No retroactive data migration. Old chats stay in their existing storage shape; the upgrade is render-time only.
- No partial overlap reconciliation for old chats. We don't try to figure out whether an old `upsert_workout` was "really" a new-plan write vs an in-block edit beyond the simple `plan_title` heuristic.
- No proposal lifecycle expiration. A pending proposal from three weeks ago stays pending forever (the Coach is expected to acknowledge it via the addendum guidance and offer to redo).

## Architecture

```
Coach agent turn
  │
  ├─ propose_plan ─────────────────► ToolResult JSON envelope
  ├─ propose_plan_update ─────────► ToolResult JSON envelope
  ├─ upsert_workout (immediate) ──► WorkoutRepository.upsert + plain-text result
  └─ delete_workout (immediate) ──► WorkoutRepository.delete + plain-text result
                                           │
                                           ▼
                              ChatMessage.toolResultsJSON
                                           │
                                           ▼
                         CoachViewModel.computeChips ──► ToolChip / ProposalChip variants
                                           │
                                           ▼
                                    ChatBubble (renders)
                                           │
                              user taps Add / Update / Dismiss
                                           │
                                           ▼
                          ProposalApplyService.apply(proposal, mode:)
                            ├─ WorkoutRepository.upsert(...) per workout
                            ├─ PlanRepository.activate(planId:)  [if mode == &switch]
                            └─ rewrite toolResultsJSON: status pending → applied|dismissed
```

Pending proposals live in the chat message's existing `toolResultsJSON` blob. When the user taps a CTA, the ViewModel rewrites that blob in place (mutating the persisted `ChatMessage`) and refreshes. The Coach's next turn sees the updated status in its tool-result history.

## Data layer

### No new SwiftData model

This is the most important architectural decision. A `PendingProposal` table would have been the conventional choice, but it adds CloudKit schema work, a migration story, lifecycle management (when does a proposal age out?), and dual-source-of-truth bugs (the proposal is in the table *and* referenced from a chat message — which wins?).

By keeping the proposal payload inline in `ChatMessage.toolResultsJSON`, we get:

- **iCloud sync for free.** Chat messages already sync.
- **No migration.** No new field on any model.
- **Single source of truth.** The chat message *is* the proposal.
- **Replay-friendly.** The agent already replays tool results on every turn — status changes are visible to it without any extra wiring.
- **Lifecycle is the conversation's lifecycle.** A new chat (`archiveCurrentConversation`) hides historical proposals; deleted chat history deletes proposals. Acceptable behavior.

The cost is that `toolResultsJSON` is parsed more aggressively than it is today. We define a small, versioned envelope to keep that parsing robust.

### Tool-result envelope format

Today's `CoachTools.handleUpsert` writes plain text into the tool result string, with a `plan_id=<uuid>` marker the parser picks out. That format is fine for the immediate-write tools because their result is read-only metadata for chip rendering. But proposals need structured fields (workouts, status, mode, plan identification) that we must round-trip when the user taps a CTA.

**Decision: JSON envelope for proposal results; keep plain-text for immediate-write results.**

Two formats coexist inside `toolResultsJSON`:

1. **Immediate-write results (`upsert_workout`, `delete_workout`, `get_recent_history`).** Unchanged — plain text strings with the `plan_id=` marker when present. `CoachViewModel.computeChips` continues to parse these as today.

2. **Proposal results (`propose_plan`, `propose_plan_update`).** A single JSON object encoded as a string. The chip renderer detects "this looks like a proposal envelope" by trying to parse the content as JSON and checking for the `bd.proposal/v1` discriminator. Falls back to immediate-write parsing if it doesn't match.

#### Envelope schema

```json
{
  "schema": "bd.proposal/v1",
  "mode": "add" | "update",
  "status": "pending" | "applied" | "dismissed",
  "plan_title": "Race Prep — June 24",
  "plan_goal": "3.5mi race goal pacing block",
  "plan_id": "<uuid-string>",
  "applied_plan_id": "<uuid-string>",
  "applied_at": "2026-06-02T14:33:00Z",
  "applied_mode": "inactive" | "switch" | "update",
  "workouts": [
    {
      "date": "2026-06-03",
      "title": "Upper Push",
      "summary": "Compound-led, RPE 7 cap.",
      "blocks": [ ... same shape as upsert_workout's `blocks` ... ]
    }
  ]
}
```

Field rules:

- `schema` is the discriminator. Bumping to `bd.proposal/v2` would let us evolve safely later.
- `mode` is set by the tool: `propose_plan` → `"add"`; `propose_plan_update` → `"update"`.
- `status` starts as `"pending"`. The ViewModel rewrites this field when the user taps a CTA.
- `plan_title` is required for `add` mode. For `update` mode it's a display hint (we copy in the target plan's title at proposal time so the chip can render without a DB lookup, but the source of truth for which plan to update is `plan_id`).
- `plan_goal` is optional. Only used on plan creation; ignored on updates.
- `plan_id` is required for `update` mode (identifies the target plan). For `add` mode, it's absent until/unless the user applies the proposal — then `applied_plan_id` is filled in (see below).
- `applied_plan_id` is filled at apply time so the chip can still link to the resulting plan after the proposal is no longer pending. For `add` mode this is the newly-created plan's id; for `update` mode it equals `plan_id`. Absent when `status != "applied"`.
- `applied_at` is the ISO-8601 timestamp of when the user tapped Apply. Absent when `status != "applied"`.
- `applied_mode` only present when `status == "applied"`. Values: `"inactive"` (Add as inactive), `"switch"` (Add & switch), `"update"` (update path).
- `workouts` array has the same shape as the input to today's `upsert_workout` tool. The tool definition reuses the same JSON-Schema sub-tree (factored into `CoachTools.workoutSchema`).

The envelope is encoded with `JSONSerialization.WritingOptions.sortedKeys` (no `.prettyPrinted` — gotcha #6 in CLAUDE.md) so equality checks are stable.

### Tool result wrapper — keeping CoachService backward compatible

`CoachService.encodeToolResults` already wraps each tool result in an Anthropic API tool_result block:

```json
[{ "type": "tool_result", "tool_use_id": "...", "content": "<string>", "is_error": false }]
```

For proposals, the `"content"` string *is* the JSON envelope (a JSON-string-of-JSON — exactly one level of nesting, since the outer array's content field is a string per Anthropic's API). The Coach reads it back as plain text on its next turn; that text happens to be parseable as JSON. No changes to `CoachService` other than what `CoachTools.dispatch` returns.

## Agent tools

### `propose_plan` — new tool

```json
{
  "name": "propose_plan",
  "description": "Propose a brand-new training plan for the user to approve. Use this whenever you're sketching out a multi-workout block (race prep, new mesocycle, returning from a break). The proposal is NOT written to the user's calendar until they tap a button. Do not use this for single-workout adjustments inside an existing active block — use upsert_workout for that.",
  "input_schema": {
    "type": "object",
    "required": ["plan_title", "plan_goal", "workouts"],
    "properties": {
      "plan_title": {
        "type": "string",
        "description": "Name of the proposed plan. Treat as the block's identity. Example: 'Race Prep — June 24', 'Hybrid Build — Q3 2026'."
      },
      "plan_goal": {
        "type": "string",
        "description": "One-line goal. Example: '3.5mi race goal pacing block'. Shown on the plan card."
      },
      "workouts": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["date", "title", "summary", "blocks"],
          "properties": {
            "date":    { "type": "string", "description": "YYYY-MM-DD" },
            "title":   { "type": "string" },
            "summary": { "type": "string" },
            "blocks":  { "$ref": "#/definitions/blocks" }
          }
        },
        "minItems": 1
      }
    }
  }
}
```

The `blocks` sub-schema is identical to today's `upsert_workout.blocks` schema. In Swift, both tools build their definition by composing a shared `workoutItemSchema` literal (a `[String: Any]` constant in `CoachTools`).

### `propose_plan_update` — new tool

```json
{
  "name": "propose_plan_update",
  "description": "Propose a revision to an existing plan (any plan you can see in the context block — usually the active plan). The user approves the whole set of changes with one tap. Use this when you want to overhaul a week or more of an existing block; for moving a single workout, use upsert_workout instead. Workouts in the proposal overwrite existing workouts on matching dates; workouts on new dates are added; nothing is deleted unless the user later asks via chat.",
  "input_schema": {
    "type": "object",
    "required": ["plan_id", "workouts"],
    "properties": {
      "plan_id": {
        "type": "string",
        "description": "UUID of the plan being updated. You learn this from prior tool-result envelopes (their applied_plan_id or plan_id field) and from the active plan reference in the <context> block."
      },
      "workouts": {
        "type": "array",
        "items": { "$ref": "#/properties/workouts/items in propose_plan" },
        "minItems": 1
      }
    }
  }
}
```

For `propose_plan_update`, the Coach learns the target plan's id from two sources:

1. **The `<context>` block** — extended in this feature to include the active plan's id, not just its title/dates. Example: `Active plan: "Race Prep — June 24" (id=4DC1…F812) — Week 2 of 4, ...`.
2. **Prior tool-result envelopes** — applied proposals carry `applied_plan_id`. The Coach can reference that id when proposing further updates to the plan it just created.

If the agent passes a `plan_id` that doesn't resolve (typo, deleted plan), the tool result is an error envelope — see "Tool dispatcher behavior" below.

### `upsert_workout` and `delete_workout` — unchanged shape, narrower guidance

Schema is unchanged. The `toolAddendum` is rewritten to make clear these are for in-block adjustments only:

```
Use `upsert_workout` and `delete_workout` to make small adjustments to the user's CURRENTLY ACTIVE plan — moving a single day, swapping a movement, deleting a workout. These take effect immediately on the user's calendar.

For anything block-scale (a new plan, replacing multiple weeks at once), call `propose_plan` or `propose_plan_update` instead. The proposal renders as a card the user taps to approve. Do not write a new plan workout-by-workout via `upsert_workout`.
```

The existing `plan_title` / `plan_goal` parameters on `upsert_workout` (added in the multi-plan spec) stay, but the addendum discourages their use for new plans — they exist now mainly to support agent-driven additions to a *named existing* plan that the user has already approved. We considered removing them outright but kept them to avoid breaking the multi-plan path before approval-gate is live (they're a no-op in the common case).

### `CoachPrompt.toolAddendum` — full rewrite

Replace the existing `toolAddendum` with:

```
# App integration (the user will only see what you emit via tools)

You have four tools that affect the user's calendar. Pick the right one.

`propose_plan` — Use for ANY brand-new training block (race prep, new mesocycle, return from a break, any plan you're sketching from scratch). Emits a proposal card the user must tap to approve. The plan is NOT on the user's calendar until they tap Add as inactive, Add & switch, or Dismiss.

`propose_plan_update` — Use to revise an existing plan with multiple workout changes at once (rewriting a week, replacing the last half of a block). Workouts on matching dates overwrite the existing entries; new dates are added. The user approves the whole revision with one tap (Update plan), or dismisses it.

`upsert_workout` — Use ONLY for small in-block adjustments to the currently active plan (move Tuesday's run to Wednesday, swap a movement, add a single workout). Takes effect immediately on the user's calendar; do not use this to build a new plan workout-by-workout.

`delete_workout` — Use ONLY to remove a single day from the currently active plan. Immediate-effect; no proposal step. To delete many workouts, ask the user in chat or issue a `propose_plan_update` that re-writes the affected days as a coherent revision.

`get_recent_history` — Read-only. Use when you need more than the 14-day window already pasted into the context.

# Reading prior proposal statuses

Each tool call you made in the past appears in your tool-result history. Proposal results are JSON envelopes that include a `status` field:

- `status: "pending"` — the user has not yet acted. Do not re-propose the same plan. Acknowledge if they ask: "still waiting on you to tap Add as inactive or Add & switch on that block." If they want a different plan, issue a fresh proposal; the old one stays on screen until they dismiss it.
- `status: "applied"` — the user accepted. Reference the plan by its `applied_plan_id` when proposing updates via `propose_plan_update`.
- `status: "dismissed"` — the user rejected. Don't re-propose the identical plan. Ask what they want changed, then issue a new (different) proposal.

# Voice between calls

Speak conversationally between tool calls — narrate intent and ask the user for input when ambiguous. The user can see your text replies in chat.
```

### Tool dispatcher behavior

```swift
// CoachTools.swift (new methods)

private func handlePropose(_ input: [String: Any]) throws -> ToolResult {
    guard let planTitle = (input["plan_title"] as? String)?.trimmed, !planTitle.isEmpty else {
        return ToolResult(content: "`plan_title` is required.", isError: true)
    }
    let planGoal = (input["plan_goal"] as? String) ?? ""
    let rawWorkouts = (input["workouts"] as? [[String: Any]]) ?? []
    guard !rawWorkouts.isEmpty else {
        return ToolResult(content: "Proposal must include at least one workout.", isError: true)
    }
    // Validate workouts using the same parser as handleUpsert; bail on first failure.
    // (The parser is factored out — see "Workout parsing extraction" below.)
    let parsed: [[String: Any]]
    do { parsed = try ProposalCodec.normalizeWorkouts(rawWorkouts) }
    catch let e as ProposalCodec.Error {
        return ToolResult(content: e.message, isError: true)
    }

    let envelope: [String: Any] = [
        "schema": "bd.proposal/v1",
        "mode": "add",
        "status": "pending",
        "plan_title": planTitle,
        "plan_goal": planGoal,
        "workouts": parsed,
    ]
    let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    return ToolResult(content: String(data: data, encoding: .utf8) ?? "{}", isError: false)
}

private func handleProposeUpdate(_ input: [String: Any]) throws -> ToolResult {
    guard let planIdStr = input["plan_id"] as? String,
          let planId = UUID(uuidString: planIdStr) else {
        return ToolResult(content: "Invalid or missing `plan_id`.", isError: true)
    }
    guard let plan = try plans.plan(id: planId) else {
        return ToolResult(content: "No plan found with id \(planIdStr). It may have been deleted; ask the user.", isError: true)
    }
    let rawWorkouts = (input["workouts"] as? [[String: Any]]) ?? []
    guard !rawWorkouts.isEmpty else {
        return ToolResult(content: "Proposal must include at least one workout.", isError: true)
    }
    let parsed: [[String: Any]]
    do { parsed = try ProposalCodec.normalizeWorkouts(rawWorkouts) }
    catch let e as ProposalCodec.Error {
        return ToolResult(content: e.message, isError: true)
    }
    let envelope: [String: Any] = [
        "schema": "bd.proposal/v1",
        "mode": "update",
        "status": "pending",
        "plan_id": plan.id.uuidString,
        "plan_title": plan.title,    // copied in for offline-render
        "plan_goal": plan.goal,
        "workouts": parsed,
    ]
    let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    return ToolResult(content: String(data: data, encoding: .utf8) ?? "{}", isError: false)
}
```

The dispatcher's contract: a proposal tool either returns a `pending` envelope (success) or an error result with a plain-text reason (so the Coach can recover on its next turn). The tool never writes to SwiftData.

#### Workout parsing extraction

The block/exercise/cardio validator inside `handleUpsert` is moved to a free function `ProposalCodec.normalizeWorkouts(_:)` that:

1. Accepts the raw `workouts` array from `propose_plan` / `propose_plan_update` (each item: `date`, `title`, `summary`, `blocks`).
2. Validates each item with the same rules as `handleUpsert` (date parseable, title non-empty, every block has a valid `kind`, every exercise has name/sets/reps, cardio has a modality).
3. Returns a normalized `[[String: Any]]` ready to serialize into the envelope.

`handleUpsert` is refactored to share the per-workout validation via a single-item variant (`ProposalCodec.normalizeWorkoutItem(_:)`). This is the only structural refactor to existing code outside the new tools.

### `CoachService` — context block extension

The `<context>` block already lists the active plan's title and dates. Extend it to include the active plan's UUID so the Coach can pass it as `plan_id` to `propose_plan_update`:

```
Active plan: "Race Prep — June 24" (id=4DC1F70E-7B16-4F8E-A41C-71BC2A3DF812) — Week 2 of 4, started 2026-05-26, ends 2026-06-22.
```

`CoachPrompt.context(today:plan:history:)` is updated to render the id when a plan is present. `TrainingPlanSnapshot` gains a `let planId: UUID` field; `CoachService.buildRequest` populates it from `plan.id`.

## View model

### `CoachViewModel.computeChips` — extended

The existing `computeChips(from:)` static method gets a new code path: parse the JSON proposal envelope out of each tool-result entry and emit one **proposal chip** per envelope. The function's signature stays the same; the return type changes to a tagged enum so the view can render either kind:

```swift
public enum CoachChip: Identifiable, Equatable {
    case workout(ChatBubble.ToolChip)        // existing tool-call chip
    case planSwitch(ChatBubble.ToolChip)     // existing plan-switch chip
    case proposal(ProposalChip)              // NEW

    public var id: String { ... }
}

public struct ProposalChip: Identifiable, Equatable {
    public let id: String                // stable per chat message + tool_use_id
    public let messageId: UUID           // for status writeback
    public let toolUseId: String         // index into the tool result array
    public let envelope: ProposalEnvelope
}

public struct ProposalEnvelope: Equatable {
    public let mode: Mode                // .add | .update
    public let status: Status            // .pending | .applied | .dismissed
    public let planTitle: String
    public let planGoal: String
    public let planId: UUID?             // .update sets this; .add sets nil until applied
    public let appliedPlanId: UUID?      // set when status == .applied
    public let appliedAt: Date?
    public let appliedMode: AppliedMode? // .inactive | .switch | .update
    public let workouts: [ProposalWorkout]

    public enum Mode: String { case add, update }
    public enum Status: String { case pending, applied, dismissed }
    public enum AppliedMode: String { case inactive, `switch`, update }
}
```

`ProposalWorkout` mirrors `WorkoutInput` (date, title, summary, blocks…); it's the on-the-wire shape.

`CoachViewModel.computeChips(from:)`:

1. Walks `toolResultsJSON` array.
2. For each entry, tries `ProposalCodec.decode(contentString:)` — succeeds only when the content is a JSON object with `schema == "bd.proposal/v1"`.
3. On success → emit a `.proposal` chip.
4. On failure → fall back to the existing plan-switch / immediate-write parsing (`parsePlanSwitchMarker`).

The view model then `flatMap`s the call-side chips (`toolCallsJSON`) the same as today and merges them with the proposal/switch chips. Sort order:

```
[proposal chips] → [planSwitch chips] → [workout chips]
```

so the most prominent action surface is at the top.

### Status transitions — writeback

When the user taps Add as inactive / Add & switch / Update plan / Dismiss, the view model calls:

```swift
func applyProposal(_ chip: ProposalChip, mode: ProposalApplyMode) async
func dismissProposal(_ chip: ProposalChip)
```

Both methods locate the source `ChatMessage` by `chip.messageId`, decode the existing `toolResultsJSON` array, find the entry whose `tool_use_id` matches `chip.toolUseId`, mutate that entry's content envelope (`status`, `applied_*` fields), re-encode the array, and persist via `ChatRepository.replaceToolResults(messageId:newJSON:)` (new repo method). Then `refresh()`.

Why mutate in place instead of appending a new message? Two reasons:

1. The Coach should see the *current* state of past proposals — not "proposed, then applied" as two separate tool calls. The Anthropic API takes the most recent tool_use_id's tool_result; rewriting the existing tool_result is the simplest way to surface the new status without confusing the model.
2. The chip should disappear/transition in place. Appending an audit message would litter the chat with "applied" / "dismissed" rows.

### `ChatRepository.replaceToolResults` — new method

```swift
public func replaceToolResults(messageId: UUID, newJSON: String) throws {
    let rows = try context.fetch(FetchDescriptor<ChatMessage>(
        predicate: #Predicate { $0.id == messageId }
    ))
    guard let m = rows.first else { throw RepositoryError.workoutNotFound /* reuse */ }
    m.toolResultsJSON = newJSON
    try context.save()
}
```

Idempotent; no-op if `newJSON` equals the existing `toolResultsJSON`. We deliberately don't add a separate `RepositoryError.chatMessageNotFound` case — `workoutNotFound` is the existing "row missing" error and re-using it keeps the error surface small. (Note: this is a minor naming smell. Acceptable for v1; can be renamed later when the repository error enum grows.)

### Apply pipeline — `ProposalApplyService`

A new `@MainActor` class that owns the apply logic. Lives in `BearDown/BearDown/Coach/ProposalApplyService.swift` (next to `CoachTools` and `CoachService` because it's the inverse operation — a tool result going back to mutations).

```swift
@MainActor
public final class ProposalApplyService {
    private let plans: PlanRepository
    private let workouts: WorkoutRepository

    public init(plans: PlanRepository, workouts: WorkoutRepository) { ... }

    public enum ApplyMode { case addInactive, addAndSwitch, update }

    public struct ApplyResult {
        public let planId: UUID         // the resulting / updated plan's id
        public let appliedMode: ProposalEnvelope.AppliedMode
    }

    public func apply(_ envelope: ProposalEnvelope, mode: ApplyMode) throws -> ApplyResult
}
```

Behavior:

- `addInactive` (envelope.mode == .add): for each workout, call `WorkoutRepository.upsert` with `planTitle = envelope.planTitle`, `planGoal = envelope.planGoal`. The existing multi-plan routing in `upsert` (re-use `findOrCreatePlan`) creates the plan inactive on the first workout and reuses it for the rest. Returns the new plan's id (read off the first inserted workout's `plan`).
- `addAndSwitch` (envelope.mode == .add): same as `addInactive`, then call `PlanRepository.activate(planId: result.planId)`. Atomicity: not strictly transactional across SwiftData saves, but each `upsert` is itself save-on-success; if the activate step fails (rare — CloudKit hiccup) the plan still exists inactive and the user can activate from the Plans tab. Acceptable.
- `update` (envelope.mode == .update): the envelope carries `plan_id` as identity-of-truth. For each workout, call `WorkoutRepository.upsert` with `planTitle = envelope.planTitle`, `planGoal = envelope.planGoal`. `WorkoutRepository.upsert`'s routing then goes through `findOrCreatePlan(title:goal:anchorDate:)` which does a case-insensitive title match. This works correctly today because plans are immutable (no rename UI per the multi-plan spec). When plan rename ships, `WorkoutRepository.upsert` will need an alternative routing path that takes `planId: UUID?` and short-circuits the title lookup; flagged as a follow-up. `propose_plan_update` semantics are replace-on-date / add-on-new-date, identical to `upsert_workout`'s existing behavior. **Nothing is deleted** even if the user's existing plan has workouts on dates not in the proposal — the proposal is additive/replacement, never destructive.

Caller (the view model) is responsible for the SwiftData saves happening on the main actor — every method on `WorkoutRepository.upsert` and `PlanRepository.activate` is already `@MainActor`.

### `CoachViewModel.applyProposal` — full flow

```swift
public func applyProposal(_ chip: ProposalChip, mode: ProposalApplyMode) async {
    do {
        let result = try env.proposals.apply(chip.envelope, mode: mode)
        try mutateEnvelope(messageId: chip.messageId, toolUseId: chip.toolUseId) { env in
            env.status = .applied
            env.appliedPlanId = result.planId
            env.appliedAt = .now
            env.appliedMode = result.appliedMode
        }
        if mode == .addAndSwitch {
            // The CoachView's chip-tap handler also navigates — see "View" below.
            nav.selectedTab = 1
            nav.pendingPlanDetail = result.planId
        }
        refresh()
    } catch {
        state = .error("Couldn't apply this plan: \(error.localizedDescription)")
    }
}
```

`mutateEnvelope` is an internal helper that decodes `toolResultsJSON`, mutates the matching entry's parsed envelope, re-encodes, and calls `env.chats.replaceToolResults(...)`.

### `CoachViewModel.dismissProposal`

```swift
public func dismissProposal(_ chip: ProposalChip) {
    do {
        try mutateEnvelope(messageId: chip.messageId, toolUseId: chip.toolUseId) { env in
            env.status = .dismissed
        }
        refresh()
    } catch {
        state = .error("Couldn't dismiss: \(error.localizedDescription)")
    }
}
```

No await — purely a metadata write. Synchronous.

### Caching considerations

Today, `chipCache: [UUID: [ChatBubble.ToolChip]]` is recomputed in `refresh()`. With the proposal flow, status transitions invalidate the cache for one specific message. `refresh()` already rebuilds the whole cache from scratch on every call, so a status flip naturally regenerates the affected chip. No targeted invalidation needed.

The `chips(for:)` accessor's return type changes from `[ChatBubble.ToolChip]` to `[CoachChip]` (the new enum). All call sites are inside `CoachView` and `ChatBubble`.

## View

### `ChatBubble` — extended chip rendering

`ChatBubble.ToolChip` stays. A new `ChatBubble.ProposalChipView` is introduced — a separate SwiftUI view because the proposal chip is significantly more complex than a one-line capsule (it has a header, sub-label, two CTAs, a status state, and three layout modes).

The `chipStrip` switches on the chip enum:

```swift
private var chipStrip: some View {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(chips) { chip in
            switch chip {
            case .proposal(let p):
                ProposalChipView(chip: p,
                                 onApply: onApplyProposal,
                                 onDismiss: onDismissProposal)
            case .planSwitch(let c):
                Button { onChipTap(c) } label: { switchPlanChip(c) }
                    .buttonStyle(.plain)
            case .workout(let c):
                Button { onChipTap(c) } label: { workoutChip(c) }
                    .buttonStyle(.plain)
            }
        }
    }
}
```

`ChatBubble`'s init gains two new closures: `onApplyProposal: (ProposalChip, ProposalApplyMode) -> Void` and `onDismissProposal: (ProposalChip) -> Void`.

### Proposal chip — visual design

A **tall pill-style chip** (per the user's choice, design Q3 = B). Not a full-width card. Internally laid out as a two-row capsule:

**ADD-mode, pending (three buttons total):**

```
┌──────────────────────────────────────────────────────────────┐
│  +  PROPOSED PLAN: RACE PREP — JUNE 24                       │   ← top row, mono small, bold
│     12 WORKOUTS · JUN 3 → JUN 24                             │   ← sub-label, mono tiny, muted
│  ┌────────────────┐ ┌──────────────┐  ┌────────────┐         │   ← CTAs row
│  │ ADD AS INACTIVE│ │  ADD & SWITCH│  │  DISMISS   │         │
│  └────────────────┘ └──────────────┘  └────────────┘         │
└──────────────────────────────────────────────────────────────┘
```

- Background: `BDStyle.chipBackground` (the soft fill used for the rest of the chip strip), `Capsule()`-rounded but with a fixed 16pt corner radius so the two-row content sits comfortably. Stroke: `Color.primary.opacity(0.18)`, 1pt — slightly more prominent than the workout chip stroke so the proposal reads as a primary action.
- Top-row symbol: `plus.circle.fill` (for `add` mode) or `arrow.triangle.2.circlepath` (for `update` mode).
- Title: `BDStyle.monoSmall`, `BDStyle.trackingWide`, uppercase. Truncates with tail ellipsis at one line.
- Sub-label: `BDStyle.monoTiny`, `BDStyle.trackingTight`, `.secondary` foreground. Format: `<N> WORKOUTS · <FIRST_DATE> → <LAST_DATE>` (months in `MMM`, day in `d`).
- CTAs: three buttons in a horizontal `HStack(spacing: 8)`. On narrow widths (iPhone SE class), the row falls back to a vertical stack via `ViewThatFits`.

**ADD-mode CTAs:**

| Button | Style | Tint | Label |
|---|---|---|---|
| ADD AS INACTIVE | `.bordered` | `.primary` | "ADD AS INACTIVE" |
| ADD & SWITCH | `.borderedProminent` | `.primary` | "ADD & SWITCH" |
| DISMISS | `.borderless` | `.secondary` | "DISMISS" |

`ADD & SWITCH` is the visual primary (filled) because the most common path the agent recommends is "this is your new plan." `ADD AS INACTIVE` is the secondary (outlined). `DISMISS` is the tertiary (text only) so the row reads CTAs-first, exit-last.

**UPDATE-mode, pending (two buttons total):**

```
┌──────────────────────────────────────────────────────────────┐
│  ⟳  PROPOSED UPDATE TO: RACE PREP — JUNE 24                  │
│     5 WORKOUTS REPLACE · JUN 10 → JUN 14                     │
│  ┌──────────────┐  ┌────────────┐                            │
│  │ UPDATE PLAN  │  │  DISMISS   │                            │
│  └──────────────┘  └────────────┘                            │
└──────────────────────────────────────────────────────────────┘
```

| Button | Style | Tint | Label |
|---|---|---|---|
| UPDATE PLAN | `.borderedProminent` | `.primary` | "UPDATE PLAN" |
| DISMISS | `.borderless` | `.secondary` | "DISMISS" |

Sub-label format: `<N> WORKOUTS REPLACE · <FIRST_DATE> → <LAST_DATE>`. Strictly speaking the proposal may add days (not just replace), but "replace" is the dominant operation and the simpler word for the chip. Edge case (proposal contains only net-new dates, no overlap with existing) is rare and "replace" still reads coherently.

**APPLIED state (after user tapped Add as inactive / Add & switch / Update):**

```
┌──────────────────────────────────────────────────────────────┐
│  ✓  APPLIED: RACE PREP — JUNE 24                             │   ← muted .secondary
│     12 WORKOUTS · JUN 3 → JUN 24 · ADDED AS INACTIVE         │   ← appliedMode appended
└──────────────────────────────────────────────────────────────┘
```

- Background: same `BDStyle.chipBackground` but at 60% opacity.
- Stroke: dashed, 1pt, `.secondary.opacity(0.4)`.
- Symbol: `checkmark.seal.fill` in `.secondary`.
- Whole chip becomes tappable (`Button` wrapping). Tap routes to the resulting plan: `nav.selectedTab = 1; nav.pendingPlanDetail = envelope.appliedPlanId`. For `add & switch`, this is the same plan that's currently active. For `add as inactive`, tap takes the user to the inactive plan's detail. For `update`, tap takes the user to the updated plan.
- No CTAs.

**DISMISSED state:**

```
┌──────────────────────────────────────────────────────────────┐
│  ⊘  DISMISSED: RACE PREP — JUNE 24                           │   ← struck through
│     12 WORKOUTS · JUN 3 → JUN 24                             │   ← struck through
└──────────────────────────────────────────────────────────────┘
```

- Background: `Color.clear`.
- Stroke: dashed, 1pt, `.secondary.opacity(0.3)`.
- Symbol: `nosign` in `.secondary.opacity(0.6)`.
- Title and sub-label rendered with `.strikethrough()` and `.secondary` foreground.
- Not tappable.

### Three-button row layout — the tight case

The ADD-mode chip has three buttons. On a 320pt-wide chip strip, three buttons of moderate text width (`ADD AS INACTIVE` is the widest) won't fit on one row. The chip uses `ViewThatFits`:

```swift
ViewThatFits {
    // First preference: single-row
    HStack(spacing: 8) {
        addInactiveButton
        addAndSwitchButton
        dismissButton
        Spacer(minLength: 0)
    }
    // Fallback: stacked rows
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
            addInactiveButton
            addAndSwitchButton
        }
        dismissButton
    }
}
```

This gives the chip a maximum height of two CTA rows in worst-case narrow widths, but a typical iPhone 17 Pro chat strip is wide enough that the single-row layout always wins. We don't constrain the chip's vertical size — it grows to whatever the content requires.

### Header + sub-label compute

The sub-label `<N> WORKOUTS · <FIRST_DATE> → <LAST_DATE>` is computed once in `CoachViewModel.computeChips` and stored on `ProposalChip` so the view stays a pure renderer. We pre-format the dates using `Text(date, format: .dateTime.month(.abbreviated).day())` at render time (per CLAUDE.md style guidance — no `DateFormatter` allocation in views) — actually wait, the chip is in a static-list context and `Text(date, format:)` lazy-formats per render. That's fine performance-wise. The pre-computation in the VM is *only* the number of workouts and the first/last dates as `Date` values; the actual textification stays in the view.

### `CoachView` — wiring

Two new closures on the `ChatBubble`:

```swift
ChatBubble(
    role: m.role,
    text: m.text,
    toolChips: vm.chips(for: m),
    onChipTap: { chip in /* existing handler */ },
    onApplyProposal: { chip, mode in
        Task { await vm.applyProposal(chip, mode: mode) }
    },
    onDismissProposal: { chip in
        vm.dismissProposal(chip)
    }
)
```

For `mode == .addAndSwitch`, navigation to the new plan happens inside `applyProposal` (the VM, with access to `nav`). The chip's tap handler doesn't navigate on apply — only on dismiss-then-applied-state-tap.

### Empty-text proposal turns

When the Coach issues a proposal, it often emits an explanatory paragraph alongside the tool call ("Here's the 4-week race-prep block based on your March mileage. Tap Add & switch when you're ready."). The chip renders below the text. If the Coach issues a tool call with no accompanying text (e.g. it immediately writes after asking a clarifying question and getting a one-word answer), the chat bubble shows only the chip. `ChatBubble` already handles `text.isEmpty` gracefully.

## Application path — full sequence diagram

```
[user] taps ADD & SWITCH on a proposal chip
   ↓
ChatBubble fires onApplyProposal(chip, .addAndSwitch)
   ↓
CoachView.applyProposal({ chip, mode: .addAndSwitch })
   ↓
CoachViewModel.applyProposal(chip, mode: .addAndSwitch) async
   ↓
   ├─ env.proposals.apply(chip.envelope, mode: .addAndSwitch)
   │     ├─ for workout in envelope.workouts:
   │     │     env.workouts.upsert(WorkoutInput(
   │     │         date:, title:, summary:, blocks:,
   │     │         planTitle: envelope.planTitle,
   │     │         planGoal:  envelope.planGoal))
   │     │   (each upsert auto-creates the plan via findOrCreatePlan on the first call,
   │     │    then reuses it for the rest)
   │     └─ env.plans.activate(planId: <new plan id>)
   │     → returns ApplyResult(planId:, appliedMode: .switch)
   │
   ├─ mutateEnvelope: status = .applied, appliedPlanId = ..., appliedMode = .switch, appliedAt = .now
   │   env.chats.replaceToolResults(messageId:, newJSON:)
   │
   ├─ nav.selectedTab = 1
   │   nav.pendingPlanDetail = result.planId
   │
   └─ refresh() → chipCache rebuilt → applied state appears in chat strip
```

Side note on the workout count: the activate step is `O(1)`; the per-workout `upsert` is `O(blocks·exercises)` per workout. A 4-week plan with ~16 workouts is fast (each `upsert` runs `context.save()`, so worst case we do ~16 saves — still sub-second). If this becomes a performance issue we can refactor `ProposalApplyService.apply` to batch the saves; deferred.

### Side effects (notifications, etc.)

`WorkoutRepository.upsert` already calls `onChange?(w, notificationsEnabled())` which routes to `NotificationScheduler.schedule(...)`. Applying a proposal therefore schedules per-workout notifications as a side effect — matching the immediate-write behavior. Good.

When the user dismisses a proposal, nothing schedules: the proposal never wrote workouts, so there's nothing to cancel.

## Retroactive rendering — old chats in the new chip language

Per the user's choice (Q9 = B), assistant messages that pre-date this feature need to *look like* the new proposal chips, with `status=applied`, even though their actual writes happened immediately at the time.

### Detection

For each assistant message:

1. Decode `toolCallsJSON`.
2. Filter for `upsert_workout` calls only (delete and history calls keep their existing rendering).
3. If there's exactly one `upsert_workout` call → keep the existing single-workout chip. (One workout is an in-block adjustment; no virtual proposal.)
4. If there are 2+ `upsert_workout` calls in the same message:
   - Group by `plan_title` from each call's input.
   - For each unique `plan_title` (including the empty/absent group → "Updated plan"):
     - If the group has only one entry, render as a normal workout chip.
     - If the group has 2+ entries:
       - If `plan_title` is present and matches an existing plan (case-insensitive title match via `findOrCreatePlan`-style lookup, but read-only — see below): emit a virtual `.proposal` chip with `mode = .add`, `status = .applied`, `appliedPlanId = <found plan id>`, `appliedMode = .switch` (we don't know whether it was switched or kept inactive; we pick `.switch` as the more user-visible label).
       - If `plan_title` is present and *no* plan with that title currently exists (was deleted in the meantime): emit a virtual `.proposal` chip with `mode = .add`, `status = .applied`, `appliedPlanId = nil`, `appliedMode = .switch`, and use the title from the tool call input. The chip is non-tappable (the plan is gone) — same visual treatment as applied state but no `Button` wrapping.
       - If `plan_title` is absent: emit a virtual `.proposal` chip with `mode = .update`, `status = .applied`, `planTitle = "Updated plan"`, `appliedPlanId = nil` (we can't reliably reconstruct which plan was active at the time), `appliedMode = .update`. Non-tappable.

### Lookup-by-title at render time

The retroactive grouping needs to resolve `plan_title` → current plan id (when applicable) without rewriting any data. `PlanRepository` gains:

```swift
public func plan(title: String) throws -> TrainingPlan?
```

Case-insensitive title match, same normalization as `findOrCreatePlan`. Read-only. Called from `CoachViewModel.computeChips` once per unique title per refresh.

Caching: with chat histories of ~100 messages, this lookup happens a handful of times per refresh. The view model's `refresh()` already does N message-shaped work; a few extra plan fetches is negligible (`<2ms` for typical sizes). Not optimized for v1.

### Documented limitations

These are called out in the spec because they're visible in the rendered chips:

- **Status doesn't reflect later state changes.** A plan that was created and later deleted still shows "APPLIED" — not "APPLIED & REMOVED." We don't try to inspect plan-history.
- **"Updated plan" is the catch-all label for messages without `plan_title`.** We can't reconstruct which plan was active when the message was sent.
- **Applied chips for deleted plans are non-tappable.** The chip says "Applied: Some Block" but tapping does nothing because there's no plan to navigate to.
- **The visual transition is one-way.** Retroactive chips can't be dismissed; they always show as Applied. (Real proposals can transition pending → applied or pending → dismissed; retroactive virtual proposals start at applied and stay there.)
- **The chip groups by `plan_title`, not by Anthropic tool turn.** If a single chat message contains `upsert_workout` calls for two different `plan_title`s (rare but possible), each title becomes its own virtual proposal. That's a feature, not a bug.

### Why not migrate the data?

Two reasons:

1. **CloudKit risk.** Rewriting `toolResultsJSON` on every device on first launch after the update would cause a sync storm. With JSON envelope retrofits applied locally on every device, conflicts on the same chat row would race.
2. **Information loss.** We don't know the original applied_mode for old messages. Render-time inference is honest about this; storing a guessed value as ground truth is worse.

### Why include this in v1 instead of deferring it?

Without retroactive rendering, the chat feels inconsistent: the Coach's old "Scheduled X" chips look different from the new proposal chips. The user explicitly chose option B for Q9. Implementing render-only changes — no schema, no migration — keeps the cost low.

## Edge cases

### Coach issues a proposal then the user starts a new chat without tapping

- The chip stays in the archived conversation in `pending` state. The Coach's context for the *new* chat doesn't include old conversations' messages (the active conversation is the latest one). So on the new chat's first turn, the agent doesn't see the old pending proposal — fine.
- If the user navigates back to the old chat (future feature — chat history) and taps Apply months later, the proposal still works as expected: the workouts get written with today's dates? No — with the *proposal's* dates. If those dates are in the past, the user gets a calendar full of historical workouts. Acceptable for v1; we document this in `docs/manual-tests.md`. Future polish: warn when applying a proposal whose first date is `< today`.

### User taps Add & switch but the proposal's `plan_title` collides with an existing plan

- `ProposalApplyService.apply` calls `WorkoutRepository.upsert(planTitle:)` per workout. Routing goes through `PlanRepository.findOrCreatePlan(title:goal:anchorDate:)` which does case-insensitive title match. **The existing plan with that title is reused** — its workouts are extended/overwritten by the proposal's workouts.
- This is the right behavior in the common case (the Coach references a plan it already named). It's potentially surprising if the user has two unrelated plans with similar names. Acceptable risk; the user-facing fix is to dismiss and ask the Coach to use a different title.
- The activate step in `.addAndSwitch` mode activates the *resolved* (possibly pre-existing) plan. So tapping Add & switch on a proposal whose title matches an inactive plan ends up making that plan active and patching in the proposal's workouts. That's coherent.

### User taps Update plan but the target plan was deleted between proposal and apply

- `ProposalApplyService.apply` for `.update` mode: the first workout's `upsert` call routes via `findOrCreatePlan(title: envelope.planTitle, ...)`. Since the plan is gone, `findOrCreatePlan` creates a fresh inactive plan with the title from the envelope. The workouts attach to this new plan.
- The chip ends up showing `applied_plan_id = <new plan id>`, status=applied, mode=update. Slightly misleading (the "update" became an "add"), but the user's data is preserved and they can find it in Plans tab. Acceptable.
- Alternative: detect the missing plan and surface an error. Rejected for v1 — error UX is more complex than "the update silently created a new plan." We document this in the manual test addendum.

### User is offline / iCloud not synced

- All apply operations are local-first SwiftData writes. They succeed immediately and sync to CloudKit when reachable. Same behavior as today's immediate-write tools. No special handling.
- If two devices apply the same proposal simultaneously (offline → both come online), the CloudKit conflict resolution is last-writer-wins per field. The chip's `status` ends up `applied` on both devices (idempotent), and workouts may end up duplicated *iff* both devices ran their own `upsert` cycle. This is a low-likelihood corner case; acceptable for v1.

### Coach issues two proposals in the same turn

- Each tool call is a separate entry in the message's tool-result array. `computeChips` emits one `.proposal` chip per envelope. Independent state — applying one doesn't affect the other.
- The chip strip vertically stacks all proposals. The Coach is discouraged in the addendum from doing this; if it happens anyway, the UX is "two cards, two sets of buttons."

### Coach issues a proposal then tries to write the same workouts via `upsert_workout` on the next turn

- The addendum tells the agent not to do this, but if it happens, the immediate-writes succeed and create the workouts on the *active* plan (or auto-create "Current Block" if no active plan). The pending proposal stays pending. The user sees both: a card asking them to approve, and the workouts already on their calendar in a different (or auto-created) plan.
- This is a Coach-behavior bug, surfaced visibly. The user's manual fix is to dismiss the proposal. We document the addendum text carefully to minimize this.

### Empty workouts array in a proposal

- Caught at dispatch time — `handlePropose` and `handleProposeUpdate` return an error result. The Coach sees the error and (per the addendum) tries again with workouts.

### Workouts in a proposal validate at propose time, fail at apply time

- We validate envelope shape at propose time (block kinds, exercise fields, date parseability). The actual `WorkoutRepository.upsert` call at apply time could in principle throw, but the same validations passed earlier so the only realistic failure is the underlying SwiftData save (out of disk, CloudKit error). Apply surfaces that as `vm.state = .error("…")`. The chip stays pending — user can tap Apply again after fixing.

### A proposal in the chat where `plan_id` (update mode) doesn't resolve

- Caught at dispatch time in `handleProposeUpdate` (returns error). The Coach sees the error and the user sees a normal error tool-result entry (no chip) in the chat — same shape as any other tool error today.

### A `propose_plan_update` proposal where the resulting plan would have a past `endDate`

- The plan's `endDate` is `max(existing endDate, max(proposal workout dates))` — `WorkoutRepository.upsert` already extends `endDate` if a workout's date is later. We don't shorten `endDate`. Acceptable.

### A pending proposal exists when the user starts a new chat

- New conversation has a new `conversationId`. The pending proposal lives in the old conversation. The Coach's tool-result history for the new conversation is empty (per `ChatRepository.messages(in:)` scope-by-conversation). The agent doesn't see the pending proposal — fine for the new chat. If the user navigates back (future chat-history feature), the proposal is still actionable.

### CloudKit syncs an applied state from another device while the user is staring at the chip

- The user sees the chip flip from pending to applied on the next `refresh()`. `refresh()` is called on `.onAppear` and after every send; we don't auto-refresh on CloudKit updates. So the staleness window is "until the user taps something." Acceptable.

## Migration

- **Data:** none. No new model, no field changes on `ChatMessage`. The new envelope format coexists with the existing plain-text format in the same `toolResultsJSON` blob.
- **CloudKit schema:** no change.
- **App version:** no migration code.
- **Coach memory:** the addendum rewrite means the agent will start preferring the new tools on its next turn. Old immediate-write `upsert_workout` calls in conversation history are still rendered (with the retroactive grouping above), and the agent can still read them — they just don't influence its tool choice.

## Testing

### Unit tests (XCTest, in-memory `ModelContainer.beardownInMemory()`)

**`ProposalCodec` (new — `ProposalCodecTests.swift`):**

- `test_encode_pendingAddEnvelope_isStableJSON` — encode a known proposal, assert byte-for-byte equality with the expected JSON (sortedKeys).
- `test_decode_validEnvelope_roundtrips` — encode then decode, assert equality.
- `test_decode_rejectsMissingSchemaField`
- `test_decode_rejectsUnknownSchemaVersion` (e.g. `bd.proposal/v2`)
- `test_decode_rejectsMissingWorkouts`
- `test_normalizeWorkouts_validatesEachItem` — passes the same gauntlet as today's `handleUpsert` parser (invalid block kind, missing exercise fields, missing cardio modality, unparseable date) and returns the same kinds of error messages.

**`CoachTools` (extend `CoachToolsTests.swift`):**

- `test_propose_emitsValidEnvelope_withModeAdd_statusPending`
- `test_propose_rejectsEmptyWorkouts`
- `test_propose_rejectsMissingPlanTitle`
- `test_propose_passesThroughBlocksAndCardioFields` — assert nested shape preserved
- `test_proposeUpdate_resolvesPlanId_andCopiesTitleGoal`
- `test_proposeUpdate_rejectsUnknownPlanId_withErrorResult`
- `test_proposeUpdate_rejectsMissingPlanId`
- `test_upsert_unchanged_resultIncludesPlanIdMarker_whenPlanTitleProvided` — regression
- `test_upsert_unchanged_noPlanIdMarker_whenWritingToActivePlan` — regression

**`ProposalApplyService` (new — `ProposalApplyServiceTests.swift`):**

- `test_applyAddInactive_createsPlan_inactiveByDefault`
- `test_applyAddInactive_doesNotChangeActivePlan`
- `test_applyAddInactive_writesAllWorkouts_toTheNewPlan`
- `test_applyAddAndSwitch_createsPlan_andActivatesIt`
- `test_applyAddAndSwitch_archivesPriorActivePlan` — assert the previous plan's `isActive == false`, `archivedAt != nil`
- `test_applyAddAndSwitch_extendsPlanEndDate_toLastWorkoutDate`
- `test_applyUpdate_replacesExistingWorkouts_onMatchingDates` — set up the active plan with workouts on 2026-06-10 and 2026-06-11, apply an update with new workouts on those dates, assert the new ones replaced the old.
- `test_applyUpdate_addsNewDates_withoutDeletingOthers` — assert workouts on dates not mentioned in the update are preserved.
- `test_applyUpdate_doesNotChangeActivePlan` — applying an update to an inactive plan doesn't activate it.
- `test_applyUpdate_failsGracefully_whenTargetPlanDeleted` — pre-delete the plan referenced by `envelope.planId`, apply, assert the workouts ended up on a freshly-created plan with the envelope's `plan_title`.

**`CoachViewModel.computeChips` (extend `CoachViewModelTests.swift`):**

- `test_computeChips_emitsProposalChip_forAddEnvelope`
- `test_computeChips_emitsProposalChip_forUpdateEnvelope`
- `test_computeChips_proposalChip_carriesMessageIdAndToolUseId` — for status writeback
- `test_computeChips_appliedEnvelope_rendersAppliedState` — assert chip enum case `.proposal` with envelope.status == .applied
- `test_computeChips_dismissedEnvelope_rendersDismissedState`
- `test_computeChips_proposalChip_isSortedAbovePlanSwitchAndWorkoutChips`
- `test_computeChips_fallsBackToPlainText_whenEnvelopeMalformed` — corrupted JSON in tool result string → falls back to existing plain-text parser, no proposal chip emitted.

**Retroactive rendering tests (extend `CoachViewModelTests.swift`):**

- `test_computeChips_retroGroupsConsecutiveUpserts_withSamePlanTitle_intoAppliedProposal`
- `test_computeChips_retroSingleUpsert_doesNotEmitProposal` — single in-message upsert stays a workout chip
- `test_computeChips_retroMissingPlanTitle_emitsUpdatedPlanProposal`
- `test_computeChips_retroPlanTitleResolves_toCurrentPlanId`
- `test_computeChips_retroPlanTitleDoesNotResolve_emitsNonTappableAppliedChip`
- `test_computeChips_retroMixedPlanTitles_emitsOneProposalPerTitle`
- `test_computeChips_retroDoesNotEmitForNonUpsertTools` — `delete_workout`, `get_recent_history` calls don't get grouped

**`CoachViewModel.applyProposal` (new section in `CoachViewModelTests.swift`):**

- `test_applyProposal_addInactive_writesWorkouts_andMutatesEnvelopeStatus`
- `test_applyProposal_addAndSwitch_writesWorkouts_activatesPlan_andSetsNav` — assert `nav.selectedTab == 1`, `nav.pendingPlanDetail == <new plan id>`
- `test_applyProposal_update_replacesWorkouts_andMutatesEnvelopeStatus`
- `test_applyProposal_envelopeMutation_persistsAcrossRefresh` — apply, call refresh, decode the message's `toolResultsJSON`, assert `status == "applied"`
- `test_applyProposal_failure_leavesStatusPending` — inject a workouts repository that throws on the second `upsert`, assert the chip stays pending and `vm.state == .error(...)`. (Note: partial writes will have happened — see "Edge cases" / atomicity. Test asserts the user-visible state, not full transactional rollback.)
- `test_dismissProposal_mutatesEnvelopeStatus_withoutWritingWorkouts`

**`ChatRepository.replaceToolResults`:**

- `test_replaceToolResults_updatesTheTargetMessage`
- `test_replaceToolResults_throwsWhenMessageNotFound`
- `test_replaceToolResults_isIdempotent`

### UI test (XCUITest, `ApprovalGateUITests.swift`)

Seed: API key + an active "Hybrid Build" plan with two workouts on past dates.

1. Onboard, navigate to Coach tab.
2. Send "give me a 1-week race prep block for June 10-16". Wait for streaming to finish.
3. Assert a proposal chip is visible with text containing "PROPOSED PLAN".
4. Assert three buttons visible: "ADD AS INACTIVE", "ADD & SWITCH", "DISMISS".
5. Tap "ADD AS INACTIVE".
6. Assert chip transitions to applied state ("APPLIED: …"). The "ADD AS INACTIVE" button is gone.
7. Switch to Plans tab. Assert two plan cards: original "Hybrid Build" (active), new plan (inactive).
8. Switch back to Coach. Tap the applied chip. Assert navigation lands on the new plan's PlanDetailView.

Second flow:

1. Send "actually, rewrite the last 3 days more aggressive".
2. Wait for the propose_plan_update chip. Assert "UPDATE PLAN" and "DISMISS" buttons visible.
3. Tap "DISMISS". Assert chip transitions to dismissed (struck-through text).
4. Tap "UPDATE PLAN" — fail safety: it should be gone after dismiss. Assert button no longer hit-testable.

Smoke for retroactive rendering:

1. Inject a synthetic chat message (via a test-only seam, not the real Coach) with two `upsert_workout` tool calls sharing `plan_title = "Old Block"`.
2. Open Coach. Assert one applied-style proposal chip rendered, titled "Old Block", with "12 WORKOUTS" sub-label, no buttons.

### Manual test addendum

Update `docs/manual-tests.md` with an Approval Gate section:

- Coach: ask for a new 4-week block → assert proposal chip appears, not Today/Plans changes.
- Tap Dismiss → assert chip greys out, plan does NOT appear in Plans tab.
- Ask again, this time tap Add as inactive → assert plan appears in Plans tab as inactive, original active plan unchanged.
- Tap Add & switch → assert original plan archived, new plan active, Today shows new plan's workouts.
- Ask for a multi-day revision to the active plan → assert update chip → tap Update plan → assert active plan's workouts on those dates are replaced.
- Re-open the app after each step to verify CloudKit/SwiftData persistence.
- Scroll back in chat to pre-feature messages — assert old `upsert_workout` rows now render as applied-style chips.

## Files affected

**New:**

- `BearDown/BearDown/Coach/ProposalApplyService.swift`
- `BearDown/BearDown/Coach/ProposalCodec.swift` — encode/decode envelope, normalize workouts
- `BearDown/BearDown/Coach/ProposalEnvelope.swift` — value types (`ProposalEnvelope`, `ProposalWorkout`, `ProposalBlock`, `ProposalExercise`, `ProposalCardio`, enums)
- `BearDown/BearDown/Views/Coach/ProposalChipView.swift`
- `BearDown/BearDownTests/ProposalCodecTests.swift`
- `BearDown/BearDownTests/ProposalApplyServiceTests.swift`
- `BearDown/BearDownUITests/ApprovalGateUITests.swift`

**Modified:**

- `BearDown/BearDown/Coach/CoachTools.swift` — add `propose_plan` + `propose_plan_update` definitions and dispatchers; refactor workout-parsing into `ProposalCodec.normalizeWorkoutItem`
- `BearDown/BearDown/Coach/CoachPrompt.swift` — rewrite `toolAddendum`; extend `context(...)` to render plan id; `TrainingPlanSnapshot.planId`
- `BearDown/BearDown/Coach/CoachService.swift` — populate `TrainingPlanSnapshot.planId` from the active plan
- `BearDown/BearDown/Persistence/PlanRepository.swift` — add `plan(title:)`
- `BearDown/BearDown/Persistence/ChatRepository.swift` — add `replaceToolResults(messageId:newJSON:)`
- `BearDown/BearDown/Views/Coach/ChatBubble.swift` — chip rendering switches on `CoachChip` enum; new `ProposalChipView` integration; init takes `onApplyProposal` + `onDismissProposal` closures
- `BearDown/BearDown/Views/Coach/CoachView.swift` — pass apply/dismiss closures into `ChatBubble`
- `BearDown/BearDown/ViewModels/CoachViewModel.swift` — `computeChips` returns `[CoachChip]`; new `applyProposal` / `dismissProposal` methods; retroactive grouping logic
- `BearDown/BearDown/App/AppEnvironment.swift` — wire `ProposalApplyService` into the env (`env.proposals`)
- `BearDown/BearDownTests/CoachToolsTests.swift` — extend per unit test list
- `BearDown/BearDownTests/CoachViewModelTests.swift` — extend per unit test list
- `docs/manual-tests.md` — add Approval Gate section
- `CLAUDE.md` — note the new dual write/proposal tool split + retroactive rendering rule; document the JSON-envelope-in-toolResultsJSON pattern

**Deleted:**

- None.

## Open questions / assumptions

These are explicit so they're easy to revisit later. Where the user has already chosen, the choice is noted.

- **(Assumption)** The `<context>` block's added `id=<uuid>` field is unambiguous enough for the model to use as `plan_id` in `propose_plan_update`. If during smoke-testing the model hallucinates ids, we'll fall back to making `propose_plan_update` accept `plan_title` and resolve server-side. Not adding both up-front to keep the tool schema lean.
- **(Assumption)** `ProposalApplyService.apply` is non-transactional across workouts. If the 8th of 12 `upsert` calls fails, the first 7 are written. The chip stays pending (status writeback only happens on success). The user can re-tap Apply to retry — the first 7 will be no-ops (replace-on-date) and the failing one will fail again. Acceptable for v1.
- **(Assumption)** Retroactive rendering's "Updated plan" label for `plan_title`-less old upserts is fine UX. If users find it confusing, the fallback is to suppress the proposal-style chip and keep the old per-workout chips for those messages. Cheap to revert.
- **(Assumption)** Three-button row on iPhone SE-class widths uses `ViewThatFits` to wrap onto two rows. We don't shorten button text on narrow widths. If two-row chips look too tall, the polish move is to shorten labels ("INACTIVE" / "ACTIVE" / "DISMISS"). Deferred until we see real devices.
- **(Q3 — user chose B)** Pill chip, not a card. The two-row layout (header + sub-label + CTAs) lives inside one capsule. Confirmed.
- **(Q5 — user chose B)** Dismiss is a distinct button. No long-press affordance, no swipe-to-dismiss. Confirmed.
- **(Q8 — user chose C)** Two buttons for Add (Inactive + & Switch). Documented above.
- **(Q9 — user chose B)** Retroactive rendering with the limitations documented in "Retroactive rendering → Documented limitations." Confirmed.
- **Future polish** (not in v1):
  - Confirmation sheet for `Add & switch` that summarizes the change before commit. (User chose A: no confirmation.)
  - Per-workout edit before apply. (User chose A: all-or-nothing.)
  - Undo for Dismiss. (User chose A: no undo.)
  - Auto-dismiss old pending proposals after N days. (Not chosen; deferred.)
  - Warn when applying a proposal whose dates are entirely in the past.
  - Audit-log style "applied at HH:MM" timestamp visible on the chip on hover/tap.
