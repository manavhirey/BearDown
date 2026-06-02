# Approval Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate block-scale Coach writes behind an in-chat approval card — the Coach proposes a multi-workout plan or revision via two new tools, the user taps Add / Update / Dismiss, and the proposal is then (and only then) materialized into SwiftData. In-block one-off adjustments (`upsert_workout` / `delete_workout`) keep their existing immediate-write behavior.

**Architecture:** Bottom-up. A versioned JSON envelope (`bd.proposal/v1`) is the new wire format for proposal tool results, stored inline in `ChatMessage.toolResultsJSON`. Codec + value types come first, then the two new agent tools (`propose_plan`, `propose_plan_update`) that emit the envelope without touching SwiftData, then the prompt addendum + context-block id extension that teaches the Coach when to use them. A new `ProposalApplyService` materializes an envelope into real plan/workout rows via existing repositories. `CoachViewModel` parses envelopes into a new tagged `CoachChip` enum and exposes `applyProposal` / `dismissProposal`, both of which mutate the persisted envelope's `status` field in place via a new `ChatRepository.replaceToolResults`. `ChatBubble` switches on the chip enum to render either an existing workout/plan-switch chip or a new `ProposalChipView` (pending / applied / dismissed states with `ViewThatFits` button layout). Historical messages without envelopes get retroactive grouping in `computeChips` — consecutive `upsert_workout` calls in one message render as a virtual applied-state proposal chip. Finally a UI test exercises propose → apply → navigate end-to-end.

**Tech Stack:** Swift 5, SwiftUI, SwiftData (CloudKit), Anthropic API, XCTest, XCUITest. iOS 17+. Xcode 16 file-system synchronized groups (drop a `.swift` file under the right tree and it auto-joins the target).

**Source-of-truth spec:** `docs/superpowers/specs/2026-06-02-approval-gate-design.md` (commit `a405ca1`). When in doubt, defer to the spec.

**Working tree at plan-write time:** branch `feat/initial-implementation` at commit `5642176`. All existing unit + UI tests pass on this baseline.

**Conventions across all tasks:**
- All paths in commands are from the repo root `/Users/MAC/Documents/Code/BearDown`.
- Build/test from the repo root using **absolute paths**. **Do not `cd BearDown`** — see CLAUDE.md project notes.
- Simulator destination: `'platform=iOS Simulator,name=iPhone 17 Pro'` (not iPhone 15 Pro).
- After every task, run the full unit suite: `xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BearDownTests -quiet`. The plan steps below show the new test for that task — the full suite confirms no regression.
- All JSON serialization uses `JSONSerialization.WritingOptions.sortedKeys` only — never `.prettyPrinted`. `.prettyPrinted` adds spaces around colons and breaks `contains(...)` checks (CLAUDE.md gotcha #6).
- Use `ModelContainer.beardownInMemory()` for tests (already sets `cloudKitDatabase: .none`).
- View models construct cheap; `refresh()` happens in `.onAppear`. Never call `refresh()` from a VM's init.
- Don't override `objectWillChange` — see CLAUDE.md gotcha #1.
- Trust `xcodebuild` exit codes over SourceKit live lints — the editor is stale.
- For tests that exercise `WorkoutRepository.upsert` via the active-plan path, always seed via `PlanRepository.createPlan(...)` first unless the test specifically exercises the auto-create fallback.

The canonical envelope wire shape — referenced across multiple tasks — is:

```json
{
  "schema": "bd.proposal/v1",
  "mode": "add",
  "status": "pending",
  "plan_title": "Race Prep — June 24",
  "plan_goal": "3.5mi race goal pacing block",
  "workouts": [
    { "date": "2026-06-03", "title": "Upper Push", "summary": "Compound-led, RPE 7 cap.",
      "blocks": [ /* same shape as upsert_workout.blocks */ ] }
  ]
}
```

For `mode: "update"`, `plan_id` (UUID string) is required and `plan_goal` is optional. When `status` flips to `"applied"`, three extra fields are written: `applied_plan_id`, `applied_at` (ISO-8601), `applied_mode` (`"inactive"` | `"switch"` | `"update"`).

---

## Task 1: `ProposalEnvelope` value types

Pure-Swift value types that mirror the JSON envelope's shape. No SwiftData, no codec yet — those follow in Tasks 2–3.

**Files:**
- Create: `BearDown/BearDown/Coach/ProposalEnvelope.swift`
- Test: `BearDown/BearDownTests/ProposalEnvelopeTests.swift` (new file)

- [ ] **Step 1: Write the failing test**

Create `BearDown/BearDownTests/ProposalEnvelopeTests.swift`:

```swift
import XCTest
@testable import BearDown

final class ProposalEnvelopeTests: XCTestCase {
    func test_addModeEnvelope_buildsWithExpectedFields() {
        let env = ProposalEnvelope(
            mode: .add,
            status: .pending,
            planTitle: "Race Prep — June 24",
            planGoal: "3.5mi race goal",
            planId: nil,
            appliedPlanId: nil,
            appliedAt: nil,
            appliedMode: nil,
            workouts: [
                .init(date: dateFromIso("2026-06-03"),
                      title: "Upper Push", summary: "Compound-led",
                      blocks: [])
            ]
        )
        XCTAssertEqual(env.mode, .add)
        XCTAssertEqual(env.status, .pending)
        XCTAssertEqual(env.planTitle, "Race Prep — June 24")
        XCTAssertEqual(env.workouts.count, 1)
        XCTAssertEqual(env.workouts.first?.title, "Upper Push")
    }

    func test_updateModeEnvelope_carriesPlanId() {
        let pid = UUID()
        let env = ProposalEnvelope(
            mode: .update, status: .pending,
            planTitle: "Race Prep", planGoal: "",
            planId: pid, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: .now, title: "x", summary: "", blocks: [])]
        )
        XCTAssertEqual(env.mode, .update)
        XCTAssertEqual(env.planId, pid)
    }

    func test_modeAndStatus_rawValues() {
        XCTAssertEqual(ProposalEnvelope.Mode.add.rawValue, "add")
        XCTAssertEqual(ProposalEnvelope.Mode.update.rawValue, "update")
        XCTAssertEqual(ProposalEnvelope.Status.pending.rawValue, "pending")
        XCTAssertEqual(ProposalEnvelope.Status.applied.rawValue, "applied")
        XCTAssertEqual(ProposalEnvelope.Status.dismissed.rawValue, "dismissed")
        XCTAssertEqual(ProposalEnvelope.AppliedMode.inactive.rawValue, "inactive")
        XCTAssertEqual(ProposalEnvelope.AppliedMode.switchPlan.rawValue, "switch")
        XCTAssertEqual(ProposalEnvelope.AppliedMode.update.rawValue, "update")
    }

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }
}
```

- [ ] **Step 2: Run the test, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ProposalEnvelopeTests -quiet
```

Expected: compile error — `ProposalEnvelope` undefined.

- [ ] **Step 3: Create the value types**

Create `BearDown/BearDown/Coach/ProposalEnvelope.swift`:

```swift
import Foundation

/// Wire-shape mirror of the `bd.proposal/v1` JSON envelope persisted inside
/// `ChatMessage.toolResultsJSON`. See spec §"Envelope schema".
public struct ProposalEnvelope: Equatable {
    public var mode: Mode
    public var status: Status
    public var planTitle: String
    public var planGoal: String
    public var planId: UUID?          // .update mode: target plan id
    public var appliedPlanId: UUID?   // set when status == .applied
    public var appliedAt: Date?
    public var appliedMode: AppliedMode?
    public var workouts: [ProposalWorkout]

    public enum Mode: String, Equatable { case add, update }
    public enum Status: String, Equatable { case pending, applied, dismissed }
    public enum AppliedMode: String, Equatable {
        case inactive
        case switchPlan = "switch"   // `switch` is a reserved word; map manually
        case update
    }

    public init(mode: Mode, status: Status,
                planTitle: String, planGoal: String,
                planId: UUID?, appliedPlanId: UUID?,
                appliedAt: Date?, appliedMode: AppliedMode?,
                workouts: [ProposalWorkout]) {
        self.mode = mode
        self.status = status
        self.planTitle = planTitle
        self.planGoal = planGoal
        self.planId = planId
        self.appliedPlanId = appliedPlanId
        self.appliedAt = appliedAt
        self.appliedMode = appliedMode
        self.workouts = workouts
    }
}

public struct ProposalWorkout: Equatable {
    public var date: Date
    public var title: String
    public var summary: String
    public var blocks: [ProposalBlock]

    public init(date: Date, title: String, summary: String, blocks: [ProposalBlock]) {
        self.date = date; self.title = title; self.summary = summary; self.blocks = blocks
    }
}

public struct ProposalBlock: Equatable {
    public var order: Int
    public var kind: BlockKind
    public var title: String
    public var notes: String
    public var exercises: [ProposalExercise]
    public var cardio: ProposalCardio?

    public init(order: Int, kind: BlockKind, title: String, notes: String,
                exercises: [ProposalExercise] = [], cardio: ProposalCardio? = nil) {
        self.order = order; self.kind = kind; self.title = title; self.notes = notes
        self.exercises = exercises; self.cardio = cardio
    }
}

public struct ProposalExercise: Equatable {
    public var order: Int
    public var name: String
    public var sets: Int
    public var reps: String
    public var load: String?
    public var restSeconds: Int?

    public init(order: Int, name: String, sets: Int, reps: String,
                load: String? = nil, restSeconds: Int? = nil) {
        self.order = order; self.name = name; self.sets = sets; self.reps = reps
        self.load = load; self.restSeconds = restSeconds
    }
}

public struct ProposalCardio: Equatable {
    public var modality: String
    public var durationMinutes: Int?
    public var distanceMeters: Double?
    public var targetDescription: String?

    public init(modality: String, durationMinutes: Int? = nil,
                distanceMeters: Double? = nil, targetDescription: String? = nil) {
        self.modality = modality
        self.durationMinutes = durationMinutes
        self.distanceMeters = distanceMeters
        self.targetDescription = targetDescription
    }
}
```

Xcode 16 file-system synchronized groups auto-add this `.swift` file to the BearDown target.

- [ ] **Step 4: Run the test, expect pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/ProposalEnvelope.swift \
        BearDown/BearDownTests/ProposalEnvelopeTests.swift
git commit -m "feat(coach): add ProposalEnvelope value types"
```

---

## Task 2: `ProposalCodec` — encode/decode the envelope as JSON

Centralizes serialization of `ProposalEnvelope` to and from the JSON-string-of-JSON content used inside `toolResultsJSON`. Discriminator: `schema == "bd.proposal/v1"`. Decode is strict — unknown schema or missing required fields → `nil`.

**Files:**
- Create: `BearDown/BearDown/Coach/ProposalCodec.swift`
- Test: `BearDown/BearDownTests/ProposalCodecTests.swift` (new file)

- [ ] **Step 1: Write the failing test**

Create `BearDown/BearDownTests/ProposalCodecTests.swift`:

```swift
import XCTest
@testable import BearDown

final class ProposalCodecTests: XCTestCase {
    func test_encode_pendingAddEnvelope_isStableSortedKeysJSON() throws {
        let env = ProposalEnvelope(
            mode: .add, status: .pending,
            planTitle: "Race Prep", planGoal: "Goal text",
            planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [
                .init(date: dateFromIso("2026-06-03"),
                      title: "Push", summary: "Compound-led",
                      blocks: [
                        .init(order: 0, kind: .strength,
                              title: "Push", notes: "",
                              exercises: [.init(order: 0, name: "Bench",
                                                sets: 5, reps: "5", load: "60kg")])
                      ])
            ]
        )
        let json = try ProposalCodec.encode(env)
        // Discriminator + mode + status must be present.
        XCTAssertTrue(json.contains("\"schema\":\"bd.proposal/v1\""), json)
        XCTAssertTrue(json.contains("\"mode\":\"add\""), json)
        XCTAssertTrue(json.contains("\"status\":\"pending\""), json)
        XCTAssertTrue(json.contains("\"plan_title\":\"Race Prep\""), json)
        XCTAssertFalse(json.contains(": "), "sortedKeys output must not contain spaces after colons; got: \(json)")
    }

    func test_decode_roundtripsAValidEnvelope() throws {
        let env = ProposalEnvelope(
            mode: .update, status: .pending,
            planTitle: "Block X", planGoal: "",
            planId: UUID(uuidString: "4DC1F70E-7B16-4F8E-A41C-71BC2A3DF812"),
            appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: dateFromIso("2026-06-10"),
                             title: "Run", summary: "Easy",
                             blocks: [.init(order: 0, kind: .cardio,
                                            title: "Run", notes: "",
                                            cardio: .init(modality: "Run",
                                                          durationMinutes: 30))])]
        )
        let json = try ProposalCodec.encode(env)
        let decoded = ProposalCodec.decode(contentString: json)
        XCTAssertEqual(decoded, env)
    }

    func test_decode_appliedEnvelope_carriesAppliedFields() throws {
        let pid = UUID()
        let env = ProposalEnvelope(
            mode: .add, status: .applied,
            planTitle: "Block", planGoal: "",
            planId: nil, appliedPlanId: pid,
            appliedAt: Date(timeIntervalSince1970: 1_780_000_000),
            appliedMode: .switchPlan,
            workouts: [.init(date: .now, title: "x", summary: "", blocks: [])]
        )
        let json = try ProposalCodec.encode(env)
        XCTAssertTrue(json.contains("\"applied_mode\":\"switch\""), json)
        XCTAssertTrue(json.contains("\"applied_plan_id\":\"\(pid.uuidString)\""), json)
        let decoded = ProposalCodec.decode(contentString: json)
        XCTAssertEqual(decoded?.status, .applied)
        XCTAssertEqual(decoded?.appliedPlanId, pid)
        XCTAssertEqual(decoded?.appliedMode, .switchPlan)
    }

    func test_decode_rejectsMissingSchemaDiscriminator() {
        let raw = #"{"mode":"add","status":"pending","plan_title":"x","workouts":[]}"#
        XCTAssertNil(ProposalCodec.decode(contentString: raw))
    }

    func test_decode_rejectsUnknownSchemaVersion() {
        let raw = #"{"schema":"bd.proposal/v2","mode":"add","status":"pending","plan_title":"x","workouts":[]}"#
        XCTAssertNil(ProposalCodec.decode(contentString: raw))
    }

    func test_decode_rejectsPlainTextResultStrings() {
        // Immediate-write `upsert_workout` result strings must not be decoded as proposals.
        let raw = #"Scheduled "Easy run" for 2026-06-08 in plan "Race Prep" (plan_id=4DC1F70E-7B16-4F8E-A41C-71BC2A3DF812)."#
        XCTAssertNil(ProposalCodec.decode(contentString: raw))
    }

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }
}
```

- [ ] **Step 2: Run the test, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ProposalCodecTests -quiet
```

Expected: compile error — `ProposalCodec` undefined.

- [ ] **Step 3: Implement the codec**

Create `BearDown/BearDown/Coach/ProposalCodec.swift`:

```swift
import Foundation

public enum ProposalCodec {

    public static let schemaVersion = "bd.proposal/v1"

    /// Encode `ProposalEnvelope` to a `bd.proposal/v1` JSON string using
    /// `.sortedKeys` only (no `.prettyPrinted` — see CLAUDE.md gotcha #6).
    public static func encode(_ env: ProposalEnvelope) throws -> String {
        var obj: [String: Any] = [
            "schema": schemaVersion,
            "mode": env.mode.rawValue,
            "status": env.status.rawValue,
            "plan_title": env.planTitle,
            "plan_goal": env.planGoal,
            "workouts": env.workouts.map(encodeWorkout),
        ]
        if let pid = env.planId { obj["plan_id"] = pid.uuidString }
        if let apid = env.appliedPlanId { obj["applied_plan_id"] = apid.uuidString }
        if let at = env.appliedAt { obj["applied_at"] = isoTimestamp(at) }
        if let am = env.appliedMode { obj["applied_mode"] = am.rawValue }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Try to decode a string-encoded tool result as a `bd.proposal/v1` envelope.
    /// Returns `nil` for anything that isn't a proposal — plain-text immediate-write
    /// results, malformed JSON, unknown schema versions, etc.
    public static func decode(contentString: String) -> ProposalEnvelope? {
        guard let data = contentString.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["schema"] as? String) == schemaVersion,
              let modeRaw = obj["mode"] as? String,
              let mode = ProposalEnvelope.Mode(rawValue: modeRaw),
              let statusRaw = obj["status"] as? String,
              let status = ProposalEnvelope.Status(rawValue: statusRaw)
        else { return nil }

        let workoutsRaw = (obj["workouts"] as? [[String: Any]]) ?? []
        let workouts = workoutsRaw.compactMap(decodeWorkout)
        let planId = (obj["plan_id"] as? String).flatMap(UUID.init(uuidString:))
        let appliedPlanId = (obj["applied_plan_id"] as? String).flatMap(UUID.init(uuidString:))
        let appliedAt = (obj["applied_at"] as? String).flatMap(parseTimestamp)
        let appliedMode = (obj["applied_mode"] as? String)
            .flatMap(ProposalEnvelope.AppliedMode.init(rawValue:))

        return ProposalEnvelope(
            mode: mode,
            status: status,
            planTitle: (obj["plan_title"] as? String) ?? "",
            planGoal: (obj["plan_goal"] as? String) ?? "",
            planId: planId,
            appliedPlanId: appliedPlanId,
            appliedAt: appliedAt,
            appliedMode: appliedMode,
            workouts: workouts
        )
    }

    // MARK: – Workouts

    private static func encodeWorkout(_ w: ProposalWorkout) -> [String: Any] {
        [
            "date": isoDate(w.date),
            "title": w.title,
            "summary": w.summary,
            "blocks": w.blocks.map(encodeBlock),
        ]
    }

    private static func decodeWorkout(_ obj: [String: Any]) -> ProposalWorkout? {
        guard let dateStr = obj["date"] as? String,
              let date = parseDate(dateStr) else { return nil }
        let blocksRaw = (obj["blocks"] as? [[String: Any]]) ?? []
        return ProposalWorkout(
            date: date,
            title: (obj["title"] as? String) ?? "",
            summary: (obj["summary"] as? String) ?? "",
            blocks: blocksRaw.compactMap(decodeBlock)
        )
    }

    private static func encodeBlock(_ b: ProposalBlock) -> [String: Any] {
        var obj: [String: Any] = [
            "order": b.order,
            "kind": b.kind.rawValue,
            "title": b.title,
            "notes": b.notes,
        ]
        if !b.exercises.isEmpty {
            obj["exercises"] = b.exercises.map { e -> [String: Any] in
                var d: [String: Any] = [
                    "order": e.order, "name": e.name,
                    "sets": e.sets, "reps": e.reps,
                ]
                if let l = e.load { d["load"] = l }
                if let r = e.restSeconds { d["rest_seconds"] = r }
                return d
            }
        }
        if let c = b.cardio {
            var d: [String: Any] = ["modality": c.modality]
            if let m = c.durationMinutes { d["duration_minutes"] = m }
            if let m = c.distanceMeters { d["distance_meters"] = m }
            if let t = c.targetDescription { d["target"] = t }
            obj["cardio"] = d
        }
        return obj
    }

    private static func decodeBlock(_ obj: [String: Any]) -> ProposalBlock? {
        guard let kindRaw = obj["kind"] as? String,
              let kind = BlockKind(rawValue: kindRaw) else { return nil }
        let exercises = ((obj["exercises"] as? [[String: Any]]) ?? []).compactMap { e -> ProposalExercise? in
            guard let name = e["name"] as? String,
                  let sets = e["sets"] as? Int,
                  let reps = e["reps"] as? String else { return nil }
            return ProposalExercise(
                order: (e["order"] as? Int) ?? 0,
                name: name, sets: sets, reps: reps,
                load: e["load"] as? String,
                restSeconds: e["rest_seconds"] as? Int
            )
        }
        var cardio: ProposalCardio? = nil
        if let c = obj["cardio"] as? [String: Any],
           let modality = c["modality"] as? String {
            cardio = ProposalCardio(
                modality: modality,
                durationMinutes: c["duration_minutes"] as? Int,
                distanceMeters: c["distance_meters"] as? Double,
                targetDescription: c["target"] as? String
            )
        }
        return ProposalBlock(
            order: (obj["order"] as? Int) ?? 0,
            kind: kind,
            title: (obj["title"] as? String) ?? "",
            notes: (obj["notes"] as? String) ?? "",
            exercises: exercises,
            cardio: cardio
        )
    }

    // MARK: – Date helpers

    private static func isoDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: d)
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    private static func isoTimestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
```

- [ ] **Step 4: Run the test, expect pass**

Same command as Step 2. Expected: PASS. Then full suite:

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/ProposalCodec.swift \
        BearDown/BearDownTests/ProposalCodecTests.swift
git commit -m "feat(coach): JSON codec for bd.proposal/v1 envelope"
```

---

## Task 3: `ProposalCodec.normalizeWorkouts` — shared validator

The block/exercise/cardio validator currently lives inline in `CoachTools.handleUpsert`. Extract a single-item variant (`normalizeWorkoutItem`) and a list variant (`normalizeWorkouts`) on `ProposalCodec` so the new `propose_plan` / `propose_plan_update` tools can validate the same way. `handleUpsert` is refactored to call the single-item variant in Task 5.

**Files:**
- Modify: `BearDown/BearDown/Coach/ProposalCodec.swift`
- Test: `BearDown/BearDownTests/ProposalCodecTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `ProposalCodecTests`:

```swift
func test_normalizeWorkouts_acceptsValidArray() throws {
    let raw: [[String: Any]] = [[
        "date": "2026-06-08", "title": "Push", "summary": "OHP",
        "blocks": [[
            "order": 0, "kind": "strength", "title": "Main", "notes": "",
            "exercises": [["order": 0, "name": "OHP", "sets": 5, "reps": "5"]]
        ]]
    ]]
    let normalized = try ProposalCodec.normalizeWorkouts(raw)
    XCTAssertEqual(normalized.count, 1)
    XCTAssertEqual((normalized[0]["title"] as? String), "Push")
    XCTAssertEqual(((normalized[0]["blocks"] as? [[String: Any]])?.first?["kind"] as? String), "strength")
}

func test_normalizeWorkouts_throwsOnInvalidBlockKind() {
    let raw: [[String: Any]] = [[
        "date": "2026-06-08", "title": "x", "summary": "",
        "blocks": [["order": 0, "kind": "yoga-thing", "title": "", "notes": ""]]
    ]]
    XCTAssertThrowsError(try ProposalCodec.normalizeWorkouts(raw)) { err in
        guard case ProposalCodec.NormalizeError.invalidBlockKind(let i) = err else {
            XCTFail("wrong error: \(err)"); return
        }
        XCTAssertEqual(i, 0)
    }
}

func test_normalizeWorkouts_throwsOnUnparseableDate() {
    let raw: [[String: Any]] = [["date": "not-a-date", "title": "x", "summary": "", "blocks": []]]
    XCTAssertThrowsError(try ProposalCodec.normalizeWorkouts(raw)) { err in
        guard case ProposalCodec.NormalizeError.invalidDate = err else {
            XCTFail("wrong error: \(err)"); return
        }
    }
}

func test_normalizeWorkouts_throwsOnMissingTitle() {
    let raw: [[String: Any]] = [["date": "2026-06-08", "title": "", "summary": "", "blocks": []]]
    XCTAssertThrowsError(try ProposalCodec.normalizeWorkouts(raw)) { err in
        guard case ProposalCodec.NormalizeError.missingTitle = err else {
            XCTFail("wrong error: \(err)"); return
        }
    }
}

func test_normalizeWorkouts_throwsOnMissingExerciseField() {
    let raw: [[String: Any]] = [[
        "date": "2026-06-08", "title": "x", "summary": "",
        "blocks": [[
            "order": 0, "kind": "strength", "title": "", "notes": "",
            "exercises": [["order": 0, "name": "Bench"]]  // missing sets/reps
        ]]
    ]]
    XCTAssertThrowsError(try ProposalCodec.normalizeWorkouts(raw))
}

func test_normalizeWorkouts_throwsOnMissingCardioModality() {
    let raw: [[String: Any]] = [[
        "date": "2026-06-08", "title": "x", "summary": "",
        "blocks": [[
            "order": 0, "kind": "cardio", "title": "", "notes": "",
            "cardio": ["duration_minutes": 20]
        ]]
    ]]
    XCTAssertThrowsError(try ProposalCodec.normalizeWorkouts(raw))
}
```

- [ ] **Step 2: Run the test, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ProposalCodecTests -quiet
```

Expected: compile error — `normalizeWorkouts` / `NormalizeError` undefined.

- [ ] **Step 3: Add the validator**

Append to `BearDown/BearDown/Coach/ProposalCodec.swift`:

```swift
extension ProposalCodec {
    /// Thrown by `normalizeWorkouts`. `.message` is a user-readable, agent-facing
    /// description suitable for echoing back as a tool error result.
    public enum NormalizeError: Error, Equatable {
        case invalidDate
        case missingTitle
        case invalidBlockKind(blockIndex: Int)
        case missingExerciseFields(blockIndex: Int, exerciseIndex: Int)
        case missingCardioModality(blockIndex: Int)

        public var message: String {
            switch self {
            case .invalidDate:
                return "Invalid or missing `date` (expected YYYY-MM-DD)."
            case .missingTitle:
                return "`title` is required."
            case .invalidBlockKind(let i):
                return "Block \(i): invalid `kind` (expected strength|cardio|mobility)."
            case .missingExerciseFields(let i, let j):
                return "Block \(i) exercise \(j): missing name/sets/reps."
            case .missingCardioModality(let i):
                return "Block \(i) cardio: missing `modality`."
            }
        }
    }

    /// Validate and normalize a workouts array (same gauntlet as
    /// `CoachTools.handleUpsert` used to apply inline). Returns a `[[String: Any]]`
    /// ready to serialize into the envelope's `workouts` field.
    public static func normalizeWorkouts(_ raw: [[String: Any]]) throws -> [[String: Any]] {
        try raw.map(normalizeWorkoutItem)
    }

    /// Validate and normalize a single workout dict.
    public static func normalizeWorkoutItem(_ raw: [String: Any]) throws -> [String: Any] {
        guard let dateStr = raw["date"] as? String,
              parseIsoDate(dateStr) != nil else {
            throw NormalizeError.invalidDate
        }
        let title = (raw["title"] as? String) ?? ""
        guard !title.isEmpty else { throw NormalizeError.missingTitle }
        let summary = (raw["summary"] as? String) ?? ""
        let rawBlocks = (raw["blocks"] as? [[String: Any]]) ?? []
        var normalizedBlocks: [[String: Any]] = []
        for (i, b) in rawBlocks.enumerated() {
            guard let kindRaw = b["kind"] as? String,
                  BlockKind(rawValue: kindRaw) != nil else {
                throw NormalizeError.invalidBlockKind(blockIndex: i)
            }
            var nb: [String: Any] = [
                "order": (b["order"] as? Int) ?? i,
                "kind": kindRaw,
                "title": (b["title"] as? String) ?? "",
                "notes": (b["notes"] as? String) ?? "",
            ]
            if let exs = b["exercises"] as? [[String: Any]] {
                var normalizedEx: [[String: Any]] = []
                for (j, e) in exs.enumerated() {
                    guard let name = e["name"] as? String, !name.isEmpty,
                          let sets = e["sets"] as? Int,
                          let reps = e["reps"] as? String else {
                        throw NormalizeError.missingExerciseFields(blockIndex: i, exerciseIndex: j)
                    }
                    var ne: [String: Any] = [
                        "order": (e["order"] as? Int) ?? j,
                        "name": name, "sets": sets, "reps": reps,
                    ]
                    if let l = e["load"] as? String { ne["load"] = l }
                    if let r = e["rest_seconds"] as? Int { ne["rest_seconds"] = r }
                    normalizedEx.append(ne)
                }
                if !normalizedEx.isEmpty { nb["exercises"] = normalizedEx }
            }
            if let c = b["cardio"] as? [String: Any] {
                guard let modality = c["modality"] as? String, !modality.isEmpty else {
                    throw NormalizeError.missingCardioModality(blockIndex: i)
                }
                var nc: [String: Any] = ["modality": modality]
                if let m = c["duration_minutes"] as? Int { nc["duration_minutes"] = m }
                if let d = c["distance_meters"] as? Double { nc["distance_meters"] = d }
                if let t = c["target"] as? String { nc["target"] = t }
                nb["cardio"] = nc
            }
            normalizedBlocks.append(nb)
        }
        return [
            "date": dateStr,
            "title": title,
            "summary": summary,
            "blocks": normalizedBlocks,
        ]
    }

    private static func parseIsoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
}
```

- [ ] **Step 4: Run the test, expect pass**

Same command as Step 2 → PASS. Run full suite to confirm nothing regressed (handleUpsert still uses its inline validator at this point — refactored in Task 5).

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/ProposalCodec.swift \
        BearDown/BearDownTests/ProposalCodecTests.swift
git commit -m "feat(coach): factor workout validation into ProposalCodec.normalizeWorkouts"
```

---
## Task 4: `propose_plan` tool — definition + dispatcher

Adds the `propose_plan` tool to `CoachTools.definitions` and routes its call to a new `handlePropose` private method. The dispatcher emits a `bd.proposal/v1` envelope with `mode=add`, `status=pending` and writes **nothing** to SwiftData.

**Files:**
- Modify: `BearDown/BearDown/Coach/CoachTools.swift`
- Test: `BearDown/BearDownTests/CoachToolsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CoachToolsTests`:

```swift
func test_propose_plan_emitsValidPendingEnvelope() throws {
    let input: [String: Any] = [
        "plan_title": "Race Prep — June 24",
        "plan_goal": "3.5mi race goal pacing block",
        "workouts": [
            ["date": "2026-06-03", "title": "Upper Push", "summary": "Compound-led",
             "blocks": [["order": 0, "kind": "strength", "title": "Push", "notes": "",
                         "exercises": [["order": 0, "name": "Bench", "sets": 5, "reps": "5"]]]]],
            ["date": "2026-06-04", "title": "Easy Run", "summary": "30 min",
             "blocks": [["order": 0, "kind": "cardio", "title": "Run", "notes": "",
                         "cardio": ["modality": "Run", "duration_minutes": 30]]]],
        ]
    ]
    let result = try tools.dispatch(name: "propose_plan", input: input)
    XCTAssertFalse(result.isError)
    let env = ProposalCodec.decode(contentString: result.content)
    XCTAssertNotNil(env)
    XCTAssertEqual(env?.mode, .add)
    XCTAssertEqual(env?.status, .pending)
    XCTAssertEqual(env?.planTitle, "Race Prep — June 24")
    XCTAssertEqual(env?.planGoal, "3.5mi race goal pacing block")
    XCTAssertEqual(env?.workouts.count, 2)
    XCTAssertEqual(env?.workouts.first?.title, "Upper Push")
}

func test_propose_plan_doesNotWriteToSwiftData() throws {
    let input: [String: Any] = [
        "plan_title": "Phantom Plan", "plan_goal": "",
        "workouts": [["date": "2026-06-03", "title": "Workout", "summary": "",
                      "blocks": []]]
    ]
    _ = try tools.dispatch(name: "propose_plan", input: input)
    let names = try env.plans.allPlans().map(\.title)
    XCTAssertFalse(names.contains("Phantom Plan"), "proposals must not create plans")
    let day = Calendar.current.startOfDay(for: dateFromIso("2026-06-03"))
    let next = day.addingTimeInterval(86400)
    let workouts = try env.workouts.workoutsBetween(start: day, end: next)
    XCTAssertEqual(workouts.count, 0, "proposals must not create workouts")
}

func test_propose_plan_rejectsEmptyWorkouts() {
    let r = (try? tools.dispatch(name: "propose_plan",
        input: ["plan_title": "x", "plan_goal": "", "workouts": []]))
        ?? .init(content: "?", isError: false)
    XCTAssertTrue(r.isError)
}

func test_propose_plan_rejectsMissingPlanTitle() {
    let r = (try? tools.dispatch(name: "propose_plan",
        input: ["plan_goal": "", "workouts": [["date": "2026-06-03", "title": "x", "summary": "", "blocks": []]]]))
        ?? .init(content: "?", isError: false)
    XCTAssertTrue(r.isError)
}

func test_definitions_includePropose_plan() {
    XCTAssertTrue(tools.definitions.map(\.name).contains("propose_plan"))
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachToolsTests -quiet
```

Expected: failures — tool not defined; dispatch returns "Unknown tool".

- [ ] **Step 3: Add `propose_plan` to `definitions` and `dispatch`**

In `BearDown/BearDown/Coach/CoachTools.swift`, inside `definitions` (after the `get_recent_history` entry, before the closing `]`), add:

```swift
.init(name: "propose_plan",
      description: "Propose a brand-new training plan for the user to approve. Use this whenever you're sketching out a multi-workout block (race prep, new mesocycle, returning from a break). The proposal is NOT written to the user's calendar until they tap a button. Do not use this for single-workout adjustments inside an existing active block — use upsert_workout for that.",
      inputSchema: [
        "type": "object",
        "required": ["plan_title", "plan_goal", "workouts"],
        "properties": [
            "plan_title": ["type": "string", "description": "Name of the proposed plan. Treat as the block's identity."],
            "plan_goal": ["type": "string", "description": "One-line goal. Shown on the plan card."],
            "workouts": [
                "type": "array",
                "minItems": 1,
                "items": [
                    "type": "object",
                    "required": ["date", "title", "summary", "blocks"],
                    "properties": [
                        "date": ["type": "string", "description": "YYYY-MM-DD"],
                        "title": ["type": "string"],
                        "summary": ["type": "string"],
                        "blocks": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "required": ["order", "kind", "title", "notes"],
                                "properties": [
                                    "order": ["type": "integer"],
                                    "kind": ["type": "string", "enum": ["strength", "cardio", "mobility"]],
                                    "title": ["type": "string"],
                                    "notes": ["type": "string"],
                                    "exercises": [
                                        "type": "array",
                                        "items": [
                                            "type": "object",
                                            "required": ["order", "name", "sets", "reps"],
                                            "properties": [
                                                "order": ["type": "integer"],
                                                "name": ["type": "string"],
                                                "sets": ["type": "integer"],
                                                "reps": ["type": "string"],
                                                "load": ["type": "string"],
                                                "rest_seconds": ["type": "integer"]
                                            ]
                                        ]
                                    ],
                                    "cardio": [
                                        "type": "object",
                                        "required": ["modality"],
                                        "properties": [
                                            "modality": ["type": "string"],
                                            "duration_minutes": ["type": "integer"],
                                            "distance_meters": ["type": "number"],
                                            "target": ["type": "string"]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
      ]),
```

In `dispatch(name:input:)`, add a case before `default`:

```swift
case "propose_plan":
    return try handlePropose(input)
```

Add the handler at the bottom of `CoachTools`:

```swift
private func handlePropose(_ input: [String: Any]) throws -> ToolResult {
    let planTitle = ((input["plan_title"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !planTitle.isEmpty else {
        return ToolResult(content: "`plan_title` is required.", isError: true)
    }
    let planGoal = (input["plan_goal"] as? String) ?? ""
    let rawWorkouts = (input["workouts"] as? [[String: Any]]) ?? []
    guard !rawWorkouts.isEmpty else {
        return ToolResult(content: "Proposal must include at least one workout.", isError: true)
    }
    let normalized: [[String: Any]]
    do { normalized = try ProposalCodec.normalizeWorkouts(rawWorkouts) }
    catch let e as ProposalCodec.NormalizeError {
        return ToolResult(content: e.message, isError: true)
    }
    let envelope: [String: Any] = [
        "schema": ProposalCodec.schemaVersion,
        "mode": "add",
        "status": "pending",
        "plan_title": planTitle,
        "plan_goal": planGoal,
        "workouts": normalized,
    ]
    let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    return ToolResult(content: String(data: data, encoding: .utf8) ?? "{}", isError: false)
}
```

- [ ] **Step 4: Run the tests, expect pass**

Same command as Step 2 → PASS. Then full unit suite to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/CoachTools.swift \
        BearDown/BearDownTests/CoachToolsTests.swift
git commit -m "feat(coach): add propose_plan tool that emits a pending envelope"
```

---

## Task 5: Refactor `handleUpsert` to share single-workout normalizer

Now that `ProposalCodec.normalizeWorkoutItem` exists, `handleUpsert` should use it instead of its inline duplicate. This is the one structural refactor of existing code; it keeps the result string format unchanged so existing tests pass.

**Files:**
- Modify: `BearDown/BearDown/Coach/CoachTools.swift`
- Test: existing `BearDown/BearDownTests/CoachToolsTests.swift` (regression-only — no new assertions)

- [ ] **Step 1: Confirm existing tests pass on the current code**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachToolsTests -quiet
```

Expected: PASS (we just added passing tests in Task 4).

- [ ] **Step 2: Rewrite `handleUpsert` to use the shared normalizer**

In `BearDown/BearDown/Coach/CoachTools.swift`, replace the entire `handleUpsert(_:)` body with:

```swift
private func handleUpsert(_ input: [String: Any]) throws -> ToolResult {
    let normalized: [String: Any]
    do { normalized = try ProposalCodec.normalizeWorkoutItem(input) }
    catch let e as ProposalCodec.NormalizeError {
        return ToolResult(content: e.message, isError: true)
    }
    guard let dateStr = normalized["date"] as? String,
          let date = parseIsoDate(dateStr) else {
        // normalizeWorkoutItem already validated date — this guard is just a re-extract.
        return ToolResult(content: "Invalid or missing `date` (expected YYYY-MM-DD).", isError: true)
    }
    let title = (normalized["title"] as? String) ?? ""
    let summary = (normalized["summary"] as? String) ?? ""
    let blockDicts = (normalized["blocks"] as? [[String: Any]]) ?? []
    let parsedBlocks: [BlockInput] = blockDicts.map { b in
        let kind = BlockKind(rawValue: b["kind"] as? String ?? "")!  // normalizer guaranteed validity
        let order = (b["order"] as? Int) ?? 0
        let bTitle = (b["title"] as? String) ?? ""
        let notes = (b["notes"] as? String) ?? ""
        let exDicts = (b["exercises"] as? [[String: Any]]) ?? []
        let exercises: [ExerciseInput] = exDicts.map { e in
            ExerciseInput(
                order: (e["order"] as? Int) ?? 0,
                name: (e["name"] as? String) ?? "",
                sets: (e["sets"] as? Int) ?? 0,
                reps: (e["reps"] as? String) ?? "",
                load: e["load"] as? String,
                restSeconds: e["rest_seconds"] as? Int
            )
        }
        var cardio: CardioInput? = nil
        if let c = b["cardio"] as? [String: Any], let modality = c["modality"] as? String {
            cardio = CardioInput(
                modality: modality,
                durationMinutes: c["duration_minutes"] as? Int,
                distanceMeters: c["distance_meters"] as? Double,
                targetDescription: c["target"] as? String
            )
        }
        return BlockInput(order: order, kind: kind, title: bTitle, notes: notes,
                          exercises: exercises, cardio: cardio)
    }
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
}
```

- [ ] **Step 3: Run all CoachTools tests, expect all pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachToolsTests -quiet
```

Expected: PASS (both pre-existing `test_dispatch_upsertWorkout_persists`, `test_handleUpsert_withPlanTitle_includesPlanIdInResultString`, and the new propose-plan tests).

- [ ] **Step 4: Run full unit suite**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: PASS — `CoachServiceTests`, `WorkoutRepositoryTests`, etc. still green because the result-string shape is unchanged.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/CoachTools.swift
git commit -m "refactor(coach): handleUpsert uses ProposalCodec.normalizeWorkoutItem"
```

---

## Task 6: `propose_plan_update` tool — definition + dispatcher

Mirrors `propose_plan` but requires `plan_id` and resolves it against `PlanRepository.plan(id:)`. Copies the target plan's title and goal into the envelope so the chip can render offline.

**Files:**
- Modify: `BearDown/BearDown/Coach/CoachTools.swift`
- Test: `BearDown/BearDownTests/CoachToolsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CoachToolsTests`:

```swift
func test_propose_plan_update_resolvesPlanId_andCopiesTitleGoal() throws {
    let target = try env.plans.createPlan(
        title: "Race Prep — June 24",
        startDate: .now, endDate: .now.addingTimeInterval(28 * 86400))
    target.goal = "3.5mi race goal pacing block"
    try env.modelContainer.mainContext.save()

    let input: [String: Any] = [
        "plan_id": target.id.uuidString,
        "workouts": [["date": "2026-06-10", "title": "Tempo run", "summary": "20 min",
                      "blocks": [["order": 0, "kind": "cardio", "title": "Run", "notes": "",
                                  "cardio": ["modality": "Run", "duration_minutes": 20]]]]],
    ]
    let result = try tools.dispatch(name: "propose_plan_update", input: input)
    XCTAssertFalse(result.isError)
    let env2 = ProposalCodec.decode(contentString: result.content)
    XCTAssertNotNil(env2)
    XCTAssertEqual(env2?.mode, .update)
    XCTAssertEqual(env2?.status, .pending)
    XCTAssertEqual(env2?.planId, target.id)
    XCTAssertEqual(env2?.planTitle, "Race Prep — June 24")
    XCTAssertEqual(env2?.planGoal, "3.5mi race goal pacing block")
}

func test_propose_plan_update_rejectsUnknownPlanId() {
    let r = (try? tools.dispatch(name: "propose_plan_update",
        input: ["plan_id": UUID().uuidString,
                "workouts": [["date": "2026-06-10", "title": "x", "summary": "", "blocks": []]]]))
        ?? .init(content: "?", isError: false)
    XCTAssertTrue(r.isError)
}

func test_propose_plan_update_rejectsMissingPlanId() {
    let r = (try? tools.dispatch(name: "propose_plan_update",
        input: ["workouts": [["date": "2026-06-10", "title": "x", "summary": "", "blocks": []]]]))
        ?? .init(content: "?", isError: false)
    XCTAssertTrue(r.isError)
}

func test_propose_plan_update_rejectsEmptyWorkouts() throws {
    let target = try env.plans.createPlan(
        title: "X", startDate: .now, endDate: .now.addingTimeInterval(86400))
    let r = (try? tools.dispatch(name: "propose_plan_update",
        input: ["plan_id": target.id.uuidString, "workouts": []]))
        ?? .init(content: "?", isError: false)
    XCTAssertTrue(r.isError)
}

func test_definitions_includePropose_plan_update() {
    XCTAssertTrue(tools.definitions.map(\.name).contains("propose_plan_update"))
}
```

- [ ] **Step 2: Run the tests, expect failure**

Same command as Task 4 Step 2 → failures, tool undefined.

- [ ] **Step 3: Add `propose_plan_update` to `definitions` and `dispatch`**

In the `definitions` array (after `propose_plan`):

```swift
.init(name: "propose_plan_update",
      description: "Propose a revision to an existing plan (any plan you can see in the context block — usually the active plan). The user approves the whole set of changes with one tap. Use this when you want to overhaul a week or more of an existing block; for moving a single workout, use upsert_workout instead. Workouts in the proposal overwrite existing workouts on matching dates; workouts on new dates are added; nothing is deleted unless the user later asks via chat.",
      inputSchema: [
        "type": "object",
        "required": ["plan_id", "workouts"],
        "properties": [
            "plan_id": ["type": "string",
                        "description": "UUID of the plan being updated. Learn this from prior tool-result envelopes' applied_plan_id or from the active plan id in the <context> block."],
            "workouts": [
                "type": "array",
                "minItems": 1,
                "items": [
                    "type": "object",
                    "required": ["date", "title", "summary", "blocks"],
                    "properties": [
                        "date": ["type": "string", "description": "YYYY-MM-DD"],
                        "title": ["type": "string"],
                        "summary": ["type": "string"],
                        "blocks": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "required": ["order", "kind", "title", "notes"],
                                "properties": [
                                    "order": ["type": "integer"],
                                    "kind": ["type": "string", "enum": ["strength", "cardio", "mobility"]],
                                    "title": ["type": "string"],
                                    "notes": ["type": "string"],
                                    "exercises": [
                                        "type": "array",
                                        "items": [
                                            "type": "object",
                                            "required": ["order", "name", "sets", "reps"],
                                            "properties": [
                                                "order": ["type": "integer"],
                                                "name": ["type": "string"],
                                                "sets": ["type": "integer"],
                                                "reps": ["type": "string"],
                                                "load": ["type": "string"],
                                                "rest_seconds": ["type": "integer"]
                                            ]
                                        ]
                                    ],
                                    "cardio": [
                                        "type": "object",
                                        "required": ["modality"],
                                        "properties": [
                                            "modality": ["type": "string"],
                                            "duration_minutes": ["type": "integer"],
                                            "distance_meters": ["type": "number"],
                                            "target": ["type": "string"]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
      ]),
```

In `dispatch`, add another case before `default`:

```swift
case "propose_plan_update":
    return try handleProposeUpdate(input)
```

Add the handler at the bottom of `CoachTools`:

```swift
private func handleProposeUpdate(_ input: [String: Any]) throws -> ToolResult {
    guard let planIdStr = input["plan_id"] as? String,
          let planId = UUID(uuidString: planIdStr) else {
        return ToolResult(content: "Invalid or missing `plan_id`.", isError: true)
    }
    guard let plan = try plans.plan(id: planId) else {
        return ToolResult(content: "No plan found with id \(planIdStr). It may have been deleted; ask the user.",
                          isError: true)
    }
    let rawWorkouts = (input["workouts"] as? [[String: Any]]) ?? []
    guard !rawWorkouts.isEmpty else {
        return ToolResult(content: "Proposal must include at least one workout.", isError: true)
    }
    let normalized: [[String: Any]]
    do { normalized = try ProposalCodec.normalizeWorkouts(rawWorkouts) }
    catch let e as ProposalCodec.NormalizeError {
        return ToolResult(content: e.message, isError: true)
    }
    let envelope: [String: Any] = [
        "schema": ProposalCodec.schemaVersion,
        "mode": "update",
        "status": "pending",
        "plan_id": plan.id.uuidString,
        "plan_title": plan.title,
        "plan_goal": plan.goal,
        "workouts": normalized,
    ]
    let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    return ToolResult(content: String(data: data, encoding: .utf8) ?? "{}", isError: false)
}
```

- [ ] **Step 4: Run the tests, expect pass**

Same command as Step 2 → PASS. Then run the full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/CoachTools.swift \
        BearDown/BearDownTests/CoachToolsTests.swift
git commit -m "feat(coach): add propose_plan_update tool"
```

---
## Task 7: Extend `<context>` block with active plan id

`CoachPrompt.context(today:plan:history:)` currently renders the active plan's title and dates. The Coach needs the plan's UUID to pass as `plan_id` to `propose_plan_update`. Add a `planId` field to `TrainingPlanSnapshot`, render it in the context line, and populate it from `CoachService.buildRequest`.

**Files:**
- Modify: `BearDown/BearDown/Coach/CoachPrompt.swift`
- Modify: `BearDown/BearDown/Coach/CoachService.swift`
- Test: `BearDown/BearDownTests/CoachPromptTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `BearDown/BearDownTests/CoachPromptTests.swift`:

```swift
func test_context_includesActivePlanId() {
    let pid = UUID(uuidString: "4DC1F70E-7B16-4F8E-A41C-71BC2A3DF812")!
    let snap = TrainingPlanSnapshot(
        title: "Race Prep — June 24",
        planId: pid,
        weekNumber: 2, totalWeeks: 4,
        startDate: Date(timeIntervalSince1970: 1_780_000_000),
        endDate: Date(timeIntervalSince1970: 1_782_500_000)
    )
    let ctx = CoachPrompt.context(today: .now, plan: snap, history: [])
    XCTAssertTrue(ctx.contains("id=\(pid.uuidString)"),
                  "context must include active plan id; got: \(ctx)")
}
```

- [ ] **Step 2: Run the test, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachPromptTests -quiet
```

Expected: compile error — `TrainingPlanSnapshot.init(title:planId:...)` doesn't exist.

- [ ] **Step 3: Extend `TrainingPlanSnapshot` and the context renderer**

In `BearDown/BearDown/Coach/CoachPrompt.swift`, replace the `TrainingPlanSnapshot` struct with:

```swift
public struct TrainingPlanSnapshot: Equatable {
    public let title: String
    public let planId: UUID
    public let weekNumber: Int
    public let totalWeeks: Int
    public let startDate: Date
    public let endDate: Date

    public init(title: String, planId: UUID, weekNumber: Int, totalWeeks: Int,
                startDate: Date, endDate: Date) {
        self.title = title
        self.planId = planId
        self.weekNumber = weekNumber
        self.totalWeeks = totalWeeks
        self.startDate = startDate
        self.endDate = endDate
    }
}
```

In the same file, update the `if let plan` branch inside `context(today:plan:history:)`:

```swift
if let plan {
    lines.append(#"Active plan: "\#(plan.title)" (id=\#(plan.planId.uuidString)) — Week \#(plan.weekNumber) of \#(plan.totalWeeks), started \#(iso(plan.startDate)), ends \#(iso(plan.endDate))."#)
}
```

In `BearDown/BearDown/Coach/CoachService.swift`, update the snapshot construction inside `buildRequest(history:)` to pass the plan id:

```swift
return TrainingPlanSnapshot(title: plan.title,
                            planId: plan.id,
                            weekNumber: weekNumber,
                            totalWeeks: totalWeeks,
                            startDate: plan.startDate,
                            endDate: plan.endDate)
```

- [ ] **Step 4: Run the test, expect pass**

Same command as Step 2 → PASS. Then run the full suite — `CoachPromptTests`, `CoachServiceTests` must still pass; the snapshot is constructed in exactly one place in the production code.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/CoachPrompt.swift \
        BearDown/BearDown/Coach/CoachService.swift \
        BearDown/BearDownTests/CoachPromptTests.swift
git commit -m "feat(coach): expose active plan id in <context> block"
```

---

## Task 8: Rewrite `CoachPrompt.toolAddendum`

Teaches the agent the four-tool split and how to read proposal statuses from prior tool results. The persona (`coachingPersona`) is verbatim and untouched.

**Files:**
- Modify: `BearDown/BearDown/Coach/CoachPrompt.swift`
- Test: `BearDown/BearDownTests/CoachPromptTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `CoachPromptTests`:

```swift
func test_toolAddendum_mentionsAllFourCalendarTools() {
    let a = CoachPrompt.toolAddendum
    XCTAssertTrue(a.contains("propose_plan"), "addendum must teach propose_plan")
    XCTAssertTrue(a.contains("propose_plan_update"), "addendum must teach propose_plan_update")
    XCTAssertTrue(a.contains("upsert_workout"), "addendum must mention upsert_workout")
    XCTAssertTrue(a.contains("delete_workout"), "addendum must mention delete_workout")
}

func test_toolAddendum_describesProposalStatusReading() {
    let a = CoachPrompt.toolAddendum
    XCTAssertTrue(a.contains("pending"), "addendum must explain pending status")
    XCTAssertTrue(a.contains("applied"), "addendum must explain applied status")
    XCTAssertTrue(a.contains("dismissed"), "addendum must explain dismissed status")
}
```

- [ ] **Step 2: Run the test, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachPromptTests -quiet
```

Expected: failures — current addendum doesn't mention `propose_plan` etc.

- [ ] **Step 3: Replace `toolAddendum`**

In `BearDown/BearDown/Coach/CoachPrompt.swift`, replace the `toolAddendum` constant with:

```swift
public static let toolAddendum: String = """

# App integration (the user will only see what you emit via tools)

You have four tools that affect the user's calendar. Pick the right one.

`propose_plan` — Use for ANY brand-new training block (race prep, new mesocycle, return from a break, any plan you're sketching from scratch). Emits a proposal card the user must tap to approve. The plan is NOT on the user's calendar until they tap Add as inactive, Add & switch, or Dismiss.

`propose_plan_update` — Use to revise an existing plan with multiple workout changes at once (rewriting a week, replacing the last half of a block). Workouts on matching dates overwrite the existing entries; new dates are added. The user approves the whole revision with one tap (Update plan), or dismisses it. The `plan_id` you pass MUST come from the active plan id in the <context> block below, or from a prior tool-result envelope's `applied_plan_id` field.

`upsert_workout` — Use ONLY for small in-block adjustments to the currently active plan (move Tuesday's run to Wednesday, swap a movement, add a single workout). Takes effect immediately on the user's calendar; do not use this to build a new plan workout-by-workout.

`delete_workout` — Use ONLY to remove a single day from the currently active plan. Immediate-effect; no proposal step. To delete many workouts, ask the user in chat or issue a `propose_plan_update` that re-writes the affected days as a coherent revision.

`get_recent_history` — Read-only. Use when you need more than the 14-day window already pasted into the context.

# Reading prior proposal statuses

Each tool call you made in the past appears in your tool-result history. Proposal results are JSON envelopes that include a `status` field:

- `status: "pending"` — the user has not yet acted. Do not re-propose the same plan. Acknowledge if asked. If they want a different plan, issue a fresh proposal; the old one stays on screen until they dismiss it.
- `status: "applied"` — the user accepted. Reference the plan by its `applied_plan_id` when proposing updates via `propose_plan_update`.
- `status: "dismissed"` — the user rejected. Don't re-propose the identical plan. Ask what they want changed, then issue a new (different) proposal.

# Voice between calls

Speak conversationally between tool calls — narrate intent and ask the user for input when ambiguous. The user can see your text replies in chat.
"""
```

- [ ] **Step 4: Run the test, expect pass**

Same command as Step 2 → PASS. Run full unit suite — any pre-existing addendum-content assertions in `CoachPromptTests` may need to be reconciled; surface and adjust if you encounter them.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/CoachPrompt.swift \
        BearDown/BearDownTests/CoachPromptTests.swift
git commit -m "feat(coach): rewrite toolAddendum for proposal-vs-immediate tool split"
```

---

## Task 9: `PlanRepository.plan(title:)` — case-insensitive lookup

The retroactive grouping logic (Task 16) needs a read-only title lookup. Same normalization as `findOrCreatePlan`. Pure SwiftData fetch — no mutation.

**Files:**
- Modify: `BearDown/BearDown/Persistence/PlanRepository.swift`
- Test: `BearDown/BearDownTests/PlanRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `PlanRepositoryTests`:

```swift
func test_planByTitle_returnsMatch_caseInsensitive() throws {
    _ = try repo.createPlan(title: "Race Prep — June 24",
                            startDate: .now, endDate: .now.addingTimeInterval(86400))
    let found = try repo.plan(title: "RACE PREP — JUNE 24")
    XCTAssertNotNil(found)
    XCTAssertEqual(found?.title, "Race Prep — June 24")
}

func test_planByTitle_returnsNil_whenNoMatch() throws {
    _ = try repo.createPlan(title: "Block A",
                            startDate: .now, endDate: .now.addingTimeInterval(86400))
    let found = try repo.plan(title: "Some Other Plan")
    XCTAssertNil(found)
}
```

- [ ] **Step 2: Run the test, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/PlanRepositoryTests -quiet
```

Expected: compile error — method missing.

- [ ] **Step 3: Add the method**

In `BearDown/BearDown/Persistence/PlanRepository.swift`, add after `plan(id:)`:

```swift
public func plan(title: String) throws -> TrainingPlan? {
    let normalized = title.lowercased()
    let rows = try context.fetch(FetchDescriptor<TrainingPlan>())
    return rows.first(where: { $0.title.lowercased() == normalized })
}
```

- [ ] **Step 4: Run the test, expect pass**

Same command as Step 2 → PASS. Run full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Persistence/PlanRepository.swift \
        BearDown/BearDownTests/PlanRepositoryTests.swift
git commit -m "feat(plans): add case-insensitive plan(title:) lookup"
```

---

## Task 10: `ChatRepository.replaceToolResults` — status writeback path

Lets the view model mutate the persisted envelope when the user taps Apply / Dismiss. The method is idempotent and reuses `RepositoryError.workoutNotFound` (single-error-case decision per spec §"ChatRepository.replaceToolResults").

**Files:**
- Modify: `BearDown/BearDown/Persistence/ChatRepository.swift`
- Test: `BearDown/BearDownTests/ChatRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `ChatRepositoryTests`:

```swift
func test_replaceToolResults_updatesTargetMessage() throws {
    let cid = repo.currentConversationId()
    try repo.append(role: .assistant, text: "x",
                    toolCallsJSON: nil, toolResultsJSON: #"[{"a":1}]"#)
    let msg = try repo.messages(in: cid).first!
    try repo.replaceToolResults(messageId: msg.id, newJSON: #"[{"b":2}]"#)
    let refetched = try repo.messages(in: cid).first!
    XCTAssertEqual(refetched.toolResultsJSON, #"[{"b":2}]"#)
}

func test_replaceToolResults_throwsWhenMessageNotFound() {
    XCTAssertThrowsError(try repo.replaceToolResults(messageId: UUID(),
                                                     newJSON: "[]"))
}

func test_replaceToolResults_isIdempotent() throws {
    let cid = repo.currentConversationId()
    let json = #"[{"a":1}]"#
    try repo.append(role: .assistant, text: "x",
                    toolCallsJSON: nil, toolResultsJSON: json)
    let msg = try repo.messages(in: cid).first!
    try repo.replaceToolResults(messageId: msg.id, newJSON: json)
    try repo.replaceToolResults(messageId: msg.id, newJSON: json)
    let refetched = try repo.messages(in: cid).first!
    XCTAssertEqual(refetched.toolResultsJSON, json)
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ChatRepositoryTests -quiet
```

Expected: compile error — method missing.

- [ ] **Step 3: Add the method**

In `BearDown/BearDown/Persistence/ChatRepository.swift`, append a method to the class:

```swift
public func replaceToolResults(messageId: UUID, newJSON: String) throws {
    let rows = try context.fetch(FetchDescriptor<ChatMessage>(
        predicate: #Predicate { $0.id == messageId }
    ))
    guard let m = rows.first else { throw RepositoryError.workoutNotFound }
    if m.toolResultsJSON == newJSON { return }   // idempotent
    m.toolResultsJSON = newJSON
    try context.save()
}
```

- [ ] **Step 4: Run the tests, expect pass**

Same command as Step 2 → PASS. Full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Persistence/ChatRepository.swift \
        BearDown/BearDownTests/ChatRepositoryTests.swift
git commit -m "feat(chat): add ChatRepository.replaceToolResults for status writeback"
```

---

## Task 11: `ProposalApplyService` — materialize envelope to SwiftData

New `@MainActor` class that owns the apply pipeline. Three modes: `.addInactive`, `.addAndSwitch`, `.update`. Each calls `WorkoutRepository.upsert` per workout with `planTitle`/`planGoal` so the repo's existing `findOrCreatePlan` routing creates (or reuses) the plan. `.addAndSwitch` additionally calls `PlanRepository.activate`.

**Files:**
- Create: `BearDown/BearDown/Coach/ProposalApplyService.swift`
- Test: `BearDown/BearDownTests/ProposalApplyServiceTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `BearDown/BearDownTests/ProposalApplyServiceTests.swift`:

```swift
import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class ProposalApplyServiceTests: XCTestCase {
    private var env: AppEnvironment!
    private var service: ProposalApplyService!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        env = AppEnvironment(modelContainer: container,
                             keychain: KeychainStore(service: "com.beardown.tests.apply.\(UUID().uuidString)"),
                             anthropic: FakeAnthropicClient())
        service = ProposalApplyService(plans: env.plans, workouts: env.workouts)
    }

    private func envelope(mode: ProposalEnvelope.Mode,
                          planTitle: String = "Race Prep — June 24",
                          planGoal: String = "Goal",
                          planId: UUID? = nil,
                          dates: [String] = ["2026-06-03", "2026-06-04"]) -> ProposalEnvelope {
        ProposalEnvelope(
            mode: mode, status: .pending,
            planTitle: planTitle, planGoal: planGoal,
            planId: planId, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: dates.map { d in
                .init(date: dateFromIso(d), title: "W \(d)", summary: "", blocks: [])
            }
        )
    }

    func test_addInactive_createsPlan_inactiveByDefault() throws {
        let result = try service.apply(envelope(mode: .add), mode: .addInactive)
        let p = try env.plans.plan(id: result.planId)
        XCTAssertNotNil(p)
        XCTAssertFalse(p!.isActive)
        XCTAssertEqual(result.appliedMode, .inactive)
    }

    func test_addInactive_doesNotChangeActivePlan() throws {
        let existing = try env.plans.createPlan(
            title: "Existing", startDate: .now,
            endDate: .now.addingTimeInterval(7 * 86400))
        _ = try service.apply(envelope(mode: .add), mode: .addInactive)
        let active = try env.plans.activePlan()
        XCTAssertEqual(active?.id, existing.id, "addInactive must not switch active plan")
    }

    func test_addInactive_writesAllWorkouts() throws {
        let result = try service.apply(envelope(mode: .add,
            dates: ["2026-06-03", "2026-06-04", "2026-06-05"]), mode: .addInactive)
        let plan = try env.plans.plan(id: result.planId)!
        XCTAssertEqual(plan.workouts.count, 3)
    }

    func test_addAndSwitch_createsAndActivatesPlan() throws {
        _ = try env.plans.createPlan(title: "Old",
            startDate: .now, endDate: .now.addingTimeInterval(86400))
        let result = try service.apply(envelope(mode: .add), mode: .addAndSwitch)
        let active = try env.plans.activePlan()
        XCTAssertEqual(active?.id, result.planId)
        XCTAssertEqual(result.appliedMode, .switchPlan)
    }

    func test_addAndSwitch_archivesPriorActivePlan() throws {
        let old = try env.plans.createPlan(title: "Old",
            startDate: .now, endDate: .now.addingTimeInterval(86400))
        _ = try service.apply(envelope(mode: .add), mode: .addAndSwitch)
        let refetched = try env.plans.plan(id: old.id)
        XCTAssertEqual(refetched?.isActive, false)
        XCTAssertNotNil(refetched?.archivedAt)
    }

    func test_update_replacesWorkoutsOnMatchingDates() throws {
        let target = try env.plans.createPlan(title: "Active Block",
            startDate: dateFromIso("2026-06-01"),
            endDate: dateFromIso("2026-06-30"))
        // Seed two workouts on dates we'll overwrite.
        _ = try env.workouts.upsert(.init(date: dateFromIso("2026-06-10"),
            title: "OLD-1", summary: "", blocks: []))
        _ = try env.workouts.upsert(.init(date: dateFromIso("2026-06-11"),
            title: "OLD-2", summary: "", blocks: []))
        let env2 = ProposalEnvelope(
            mode: .update, status: .pending,
            planTitle: "Active Block", planGoal: "",
            planId: target.id,
            appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [
                .init(date: dateFromIso("2026-06-10"), title: "NEW-1", summary: "", blocks: []),
                .init(date: dateFromIso("2026-06-11"), title: "NEW-2", summary: "", blocks: []),
            ]
        )
        _ = try service.apply(env2, mode: .update)
        let day = dateFromIso("2026-06-10")
        let after = try env.workouts.workoutsBetween(start: day, end: day.addingTimeInterval(2 * 86400))
        XCTAssertEqual(after.map(\.title).sorted(), ["NEW-1", "NEW-2"])
    }

    func test_update_addsNewDates_withoutDeletingOthers() throws {
        let target = try env.plans.createPlan(title: "Active",
            startDate: dateFromIso("2026-06-01"),
            endDate: dateFromIso("2026-06-30"))
        _ = try env.workouts.upsert(.init(date: dateFromIso("2026-06-10"),
            title: "KEEP", summary: "", blocks: []))
        let env2 = ProposalEnvelope(
            mode: .update, status: .pending,
            planTitle: "Active", planGoal: "",
            planId: target.id,
            appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: dateFromIso("2026-06-15"), title: "ADDED",
                             summary: "", blocks: [])]
        )
        _ = try service.apply(env2, mode: .update)
        let allPlanWorkouts = try env.workouts.workoutsBetween(
            start: dateFromIso("2026-06-01"),
            end: dateFromIso("2026-06-30"))
        XCTAssertTrue(allPlanWorkouts.contains(where: { $0.title == "KEEP" }))
        XCTAssertTrue(allPlanWorkouts.contains(where: { $0.title == "ADDED" }))
    }

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ProposalApplyServiceTests -quiet
```

Expected: compile error — `ProposalApplyService` undefined.

- [ ] **Step 3: Implement the service**

Create `BearDown/BearDown/Coach/ProposalApplyService.swift`:

```swift
import Foundation

@MainActor
public final class ProposalApplyService {
    public enum ApplyMode { case addInactive, addAndSwitch, update }

    public struct ApplyResult: Equatable {
        public let planId: UUID
        public let appliedMode: ProposalEnvelope.AppliedMode
    }

    public enum ApplyError: Error, Equatable {
        case missingPlanId          // update mode without envelope.planId
        case noWorkoutsWritten      // upsert never produced a plan attachment
    }

    private let plans: PlanRepository
    private let workouts: WorkoutRepository

    public init(plans: PlanRepository, workouts: WorkoutRepository) {
        self.plans = plans
        self.workouts = workouts
    }

    public func apply(_ envelope: ProposalEnvelope,
                      mode: ApplyMode) throws -> ApplyResult {
        guard !envelope.workouts.isEmpty else { throw ApplyError.noWorkoutsWritten }
        let resolvedTitle = envelope.planTitle
        let resolvedGoal = envelope.planGoal

        var firstPlanId: UUID?
        for w in envelope.workouts.sorted(by: { $0.date < $1.date }) {
            let input = WorkoutInput(
                date: w.date,
                title: w.title,
                summary: w.summary,
                blocks: w.blocks.map(toBlockInput),
                planTitle: resolvedTitle,
                planGoal: resolvedGoal
            )
            let written = try workouts.upsert(input)
            if firstPlanId == nil, let pid = written.plan?.id { firstPlanId = pid }
        }
        guard let planId = firstPlanId else { throw ApplyError.noWorkoutsWritten }

        let appliedMode: ProposalEnvelope.AppliedMode
        switch mode {
        case .addInactive:
            appliedMode = .inactive
        case .addAndSwitch:
            try plans.activate(planId: planId)
            appliedMode = .switchPlan
        case .update:
            // Update never changes activation. WorkoutRepository.upsert routes by title
            // (findOrCreatePlan), which resolves to the same row the envelope identifies.
            appliedMode = .update
        }
        return ApplyResult(planId: planId, appliedMode: appliedMode)
    }

    private func toBlockInput(_ b: ProposalBlock) -> BlockInput {
        BlockInput(
            order: b.order, kind: b.kind, title: b.title, notes: b.notes,
            exercises: b.exercises.map {
                ExerciseInput(order: $0.order, name: $0.name, sets: $0.sets, reps: $0.reps,
                              load: $0.load, restSeconds: $0.restSeconds)
            },
            cardio: b.cardio.map {
                CardioInput(modality: $0.modality,
                            durationMinutes: $0.durationMinutes,
                            distanceMeters: $0.distanceMeters,
                            targetDescription: $0.targetDescription)
            }
        )
    }
}
```

- [ ] **Step 4: Run the tests, expect pass**

Same command as Step 2 → PASS. Full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Coach/ProposalApplyService.swift \
        BearDown/BearDownTests/ProposalApplyServiceTests.swift
git commit -m "feat(coach): ProposalApplyService materializes envelopes to SwiftData"
```

---

## Task 12: Wire `ProposalApplyService` into `AppEnvironment`

Exposes the service as `env.proposals` so the view model can call it.

**Files:**
- Modify: `BearDown/BearDown/App/AppEnvironment.swift`
- Test: existing `ProposalApplyServiceTests.swift` (the env wiring is exercised indirectly by the VM tests in Task 14)

- [ ] **Step 1: Add a brief assertion**

Append to `BearDown/BearDownTests/ProposalApplyServiceTests.swift`:

```swift
func test_appEnvironment_exposesProposalsService() {
    XCTAssertNotNil(env.proposals)
}
```

- [ ] **Step 2: Run, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ProposalApplyServiceTests/test_appEnvironment_exposesProposalsService -quiet
```

Expected: compile error — `AppEnvironment.proposals` doesn't exist.

- [ ] **Step 3: Add the property to `AppEnvironment`**

In `BearDown/BearDown/App/AppEnvironment.swift`, add a `public let proposals: ProposalApplyService` declaration and assign it in `init` after `self.workouts = ...`:

```swift
public let proposals: ProposalApplyService
```

…and in `init(modelContainer:keychain:anthropic:)`, after the line `self.chats = ChatRepository(context: ctx)` add:

```swift
self.proposals = ProposalApplyService(plans: plans, workouts: workouts)
```

- [ ] **Step 4: Run the tests, expect pass**

Same command as Step 2 → PASS. Full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/App/AppEnvironment.swift \
        BearDown/BearDownTests/ProposalApplyServiceTests.swift
git commit -m "feat(env): expose ProposalApplyService as env.proposals"
```

---
## Task 13: Introduce `CoachChip` tagged enum (rename existing chip → workout case)

`CoachViewModel.chips(for:)` currently returns `[ChatBubble.ToolChip]`. To support proposal chips, the return type becomes a new tagged enum `CoachChip` with three cases: `.workout`, `.planSwitch`, `.proposal`. This task adds the enum and rewires the existing chip emission to use it. `ChatBubble` still accepts the same shape via a typealias for now (the renderer switches over the enum in Task 15).

**Files:**
- Modify: `BearDown/BearDown/ViewModels/CoachViewModel.swift`
- Modify: `BearDown/BearDown/Views/Coach/ChatBubble.swift`
- Modify: `BearDown/BearDown/Views/Coach/CoachView.swift`
- Test: `BearDown/BearDownTests/CoachViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `CoachViewModelTests`:

```swift
func test_computeChips_returnsCoachChip_workoutAndPlanSwitchCases() throws {
    let planId = UUID()
    let toolCalls: [[String: Any]] = [[
        "id": "toolu_1", "name": "upsert_workout",
        "input": ["date": "2026-06-08", "title": "Easy run", "summary": "", "blocks": []],
    ]]
    let toolResults: [[String: Any]] = [[
        "tool_use_id": "toolu_1",
        "content": "Scheduled \"Easy run\" for 2026-06-08 in plan \"Race Prep\" (plan_id=\(planId.uuidString)).",
    ]]
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)
    m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)

    let chips = CoachViewModel.computeChipsForTest(from: m)
    XCTAssertEqual(chips.count, 2)

    guard case .planSwitch = chips[0] else { return XCTFail("expected planSwitch first; got \(chips[0])") }
    guard case .workout = chips[1] else { return XCTFail("expected workout second; got \(chips[1])") }
}
```

You will also need to update existing tests (`test_computeChips_extractsPlanIdFromToolResults`, `test_computeChips_dedupsMultipleWorkoutsToOneSwitchChipPerPlan`) to read the new enum cases instead of `chip.planId`. Rewrite those tests in this same step:

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
    XCTAssertEqual(chips.count, 2)
    if case let .planSwitch(c) = chips[0] {
        XCTAssertEqual(c.planId, planId)
        XCTAssertTrue(c.label.contains("Race Prep — June 24"))
    } else { XCTFail("first chip should be planSwitch") }
    if case let .workout(c) = chips[1] {
        XCTAssertNil(c.planId)
    } else { XCTFail("second chip should be workout") }
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
    let switchChips = chips.filter { if case .planSwitch = $0 { return true }; return false }
    XCTAssertEqual(switchChips.count, 1)
}
```

- [ ] **Step 2: Run, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests -quiet
```

Expected: compile errors — `CoachChip` enum undefined, existing `ChatBubble.ToolChip`-typed call sites broken.

- [ ] **Step 3: Add `CoachChip` enum + rewire VM + view**

In `BearDown/BearDown/ViewModels/CoachViewModel.swift`, add at the top of the file (after the `import` lines, before the `CoachViewModel` class):

```swift
public enum CoachChip: Identifiable, Equatable {
    case workout(ChatBubble.ToolChip)
    case planSwitch(ChatBubble.ToolChip)
    case proposal(ProposalChip)

    public var id: String {
        switch self {
        case .workout(let c): return "w-\(c.id)"
        case .planSwitch(let c): return "s-\(c.id)"
        case .proposal(let p): return "p-\(p.id)"
        }
    }
}

/// View-ready snapshot of a proposal envelope, paired with the source message
/// info needed to write status changes back through ChatRepository.
public struct ProposalChip: Identifiable, Equatable {
    public let id: String           // stable: messageId-toolUseId
    public let messageId: UUID
    public let toolUseId: String
    public let envelope: ProposalEnvelope
    public let workoutCount: Int    // pre-computed for sub-label rendering
    public let firstDate: Date?
    public let lastDate: Date?
    /// True if this chip is a retroactive applied-state synthesis (from pre-feature
    /// chat history). Not user-actionable: no buttons, no tap-target if appliedPlanId
    /// can't be resolved. Filled by computeChips() — see Task 16.
    public let isRetroactive: Bool

    public init(id: String, messageId: UUID, toolUseId: String,
                envelope: ProposalEnvelope,
                workoutCount: Int, firstDate: Date?, lastDate: Date?,
                isRetroactive: Bool = false) {
        self.id = id; self.messageId = messageId; self.toolUseId = toolUseId
        self.envelope = envelope
        self.workoutCount = workoutCount
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.isRetroactive = isRetroactive
    }
}
```

Update the `chipCache` declaration to `[UUID: [CoachChip]]` and the `chips(for:)` return type to `[CoachChip]`. Update `computeChips(from:)` signature to return `[CoachChip]` and wrap the existing chip emissions:

```swift
private var chipCache: [UUID: [CoachChip]] = [:]

public func chips(for message: ChatMessage) -> [CoachChip] {
    chipCache[message.id] ?? []
}

internal static func computeChipsForTest(from m: ChatMessage) -> [CoachChip] {
    computeChips(from: m)
}

private static func computeChips(from m: ChatMessage) -> [CoachChip] {
    var switchChips: [CoachChip] = []
    var workoutChips: [CoachChip] = []
    var seenPlanIds = Set<UUID>()

    if let raw = m.toolResultsJSON,
       let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
        for dict in arr {
            guard let content = dict["content"] as? String,
                  let parsed = parsePlanSwitchMarker(in: content),
                  seenPlanIds.insert(parsed.id).inserted else { continue }
            let tc = ChatBubble.ToolChip(
                id: "switch-\(parsed.id.uuidString)",
                label: "Switch to: \(parsed.title)",
                isError: false,
                workoutDate: nil,
                planId: parsed.id
            )
            switchChips.append(.planSwitch(tc))
        }
    }

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
                workoutChips.append(.workout(.init(
                    id: id,
                    label: "Scheduled \(title) — \(date)",
                    isError: false,
                    workoutDate: parseIso(date)
                )))
            case "delete_workout":
                let date = input["date"] as? String ?? "?"
                workoutChips.append(.workout(.init(
                    id: id,
                    label: "Deleted workout on \(date)",
                    isError: false,
                    workoutDate: parseIso(date)
                )))
            case "get_recent_history":
                workoutChips.append(.workout(.init(
                    id: id, label: "Reviewed recent history",
                    isError: false, workoutDate: nil
                )))
            case "propose_plan", "propose_plan_update":
                // Tool-call chip is suppressed here; the proposal chip emitted from
                // the tool result (handled in Task 14) is the visible surface.
                break
            default:
                workoutChips.append(.workout(.init(
                    id: id, label: "Called \(name)",
                    isError: false, workoutDate: nil
                )))
            }
        }
    }
    return switchChips + workoutChips
}
```

In `BearDown/BearDown/Views/Coach/ChatBubble.swift`, change `toolChips: [ToolChip]` to `toolChips: [CoachChip]`, and update `chipStrip` to switch on the enum. Until Task 15 introduces `ProposalChipView`, render `.proposal` as a placeholder so this task compiles:

```swift
public let toolChips: [CoachChip]
public let onChipTap: (ChatBubble.ToolChip) -> Void

public init(role: ChatRole,
            text: String,
            toolChips: [CoachChip] = [],
            onChipTap: @escaping (ChatBubble.ToolChip) -> Void = { _ in }) {
    self.role = role
    self.text = text
    self.toolChips = toolChips
    self.onChipTap = onChipTap
}
```

In `chipStrip`, replace the existing `FlexibleChipRow` body with:

```swift
private var chipStrip: some View {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(toolChips) { chip in
            switch chip {
            case .planSwitch(let c):
                Button { onChipTap(c) } label: { switchPlanChip(c) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.label)
            case .workout(let c):
                Button { onChipTap(c) } label: { workoutChip(c) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.label)
            case .proposal:
                // Placeholder — real renderer arrives in Task 15.
                EmptyView()
            }
        }
    }
    .padding(.top, 2)
}
```

Remove the `editorialChip(_:)` helper (no longer needed — the switch dispatches directly).

In `BearDown/BearDown/Views/Coach/CoachView.swift`, the existing `onChipTap:` closure receives a `ChatBubble.ToolChip` — no signature change.

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests -quiet
```

Expected: PASS. Then full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/ViewModels/CoachViewModel.swift \
        BearDown/BearDown/Views/Coach/ChatBubble.swift \
        BearDown/BearDown/Views/Coach/CoachView.swift \
        BearDown/BearDownTests/CoachViewModelTests.swift
git commit -m "refactor(coach): introduce CoachChip enum for chip rendering"
```

---

## Task 14: Emit `.proposal` chips from `bd.proposal/v1` envelopes

Extend `computeChips` to detect a proposal envelope inside each `toolResultsJSON` entry (via `ProposalCodec.decode`) and emit a `.proposal` chip. Pair it with the originating tool-call id so the writeback path (Task 17) can find it.

**Files:**
- Modify: `BearDown/BearDown/ViewModels/CoachViewModel.swift`
- Test: `BearDown/BearDownTests/CoachViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CoachViewModelTests`:

```swift
func test_computeChips_emitsProposalChip_forAddEnvelope() throws {
    let env = ProposalEnvelope(
        mode: .add, status: .pending,
        planTitle: "Race Prep", planGoal: "",
        planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
        workouts: [.init(date: dateFromIso("2026-06-03"),
                         title: "Push", summary: "", blocks: [])]
    )
    let envJSON = try ProposalCodec.encode(env)
    let toolResults: [[String: Any]] = [["tool_use_id": "toolu_1", "content": envJSON]]
    let toolCalls: [[String: Any]] = [["id": "toolu_1", "name": "propose_plan",
                                       "input": [:]]]
    let m = ChatMessage(role: .assistant, text: "Here's the block.", conversationId: UUID())
    m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)

    let chips = CoachViewModel.computeChipsForTest(from: m)
    XCTAssertEqual(chips.count, 1)
    guard case let .proposal(p) = chips[0] else {
        return XCTFail("expected .proposal; got \(chips[0])")
    }
    XCTAssertEqual(p.envelope.mode, .add)
    XCTAssertEqual(p.envelope.status, .pending)
    XCTAssertEqual(p.envelope.planTitle, "Race Prep")
    XCTAssertEqual(p.workoutCount, 1)
    XCTAssertEqual(p.messageId, m.id)
    XCTAssertEqual(p.toolUseId, "toolu_1")
}

func test_computeChips_proposalChip_sortsAboveWorkoutChips() throws {
    // A message can in theory mix tools; the proposal chip is the most important
    // surface, so it must appear first.
    let env = ProposalEnvelope(
        mode: .add, status: .pending, planTitle: "X", planGoal: "",
        planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
        workouts: [.init(date: .now, title: "x", summary: "", blocks: [])]
    )
    let envJSON = try ProposalCodec.encode(env)
    let toolResults: [[String: Any]] = [["tool_use_id": "p1", "content": envJSON],
                                         ["tool_use_id": "u1", "content": "Scheduled X for 2026-06-08."]]
    let toolCalls: [[String: Any]] = [["id": "p1", "name": "propose_plan", "input": [:]],
                                       ["id": "u1", "name": "upsert_workout",
                                        "input": ["date": "2026-06-08", "title": "X", "summary": "", "blocks": []]]]
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)

    let chips = CoachViewModel.computeChipsForTest(from: m)
    XCTAssertEqual(chips.count, 2)
    guard case .proposal = chips[0] else { return XCTFail("proposal must sort first") }
    guard case .workout = chips[1] else { return XCTFail("workout must sort after") }
}

func test_computeChips_fallsBackToPlainText_whenEnvelopeMalformed() throws {
    // Garbled content → no proposal chip; existing plan-switch parser still runs.
    let toolResults: [[String: Any]] = [["tool_use_id": "x", "content": "not json {{{"]]
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
    let chips = CoachViewModel.computeChipsForTest(from: m)
    XCTAssertTrue(chips.allSatisfy { if case .proposal = $0 { return false }; return true })
}

func test_computeChips_appliedEnvelope_carriesAppliedStatus() throws {
    let pid = UUID()
    let env = ProposalEnvelope(
        mode: .add, status: .applied, planTitle: "X", planGoal: "",
        planId: nil, appliedPlanId: pid, appliedAt: .now, appliedMode: .switchPlan,
        workouts: [.init(date: .now, title: "x", summary: "", blocks: [])]
    )
    let envJSON = try ProposalCodec.encode(env)
    let toolResults: [[String: Any]] = [["tool_use_id": "t", "content": envJSON]]
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: [["id": "t", "name": "propose_plan", "input": [:]]], options: [.sortedKeys]), encoding: .utf8)

    let chips = CoachViewModel.computeChipsForTest(from: m)
    guard case let .proposal(p) = chips[0] else { return XCTFail("expected proposal") }
    XCTAssertEqual(p.envelope.status, .applied)
    XCTAssertEqual(p.envelope.appliedPlanId, pid)
    XCTAssertEqual(p.envelope.appliedMode, .switchPlan)
}

private func dateFromIso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: s)!
}
```

- [ ] **Step 2: Run, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests -quiet
```

Expected: failures — proposal chips not yet emitted.

- [ ] **Step 3: Emit proposal chips in `computeChips`**

In `BearDown/BearDown/ViewModels/CoachViewModel.swift`, rewrite `computeChips(from:)` to scan `toolResultsJSON` for envelopes **first** (before the plan-switch marker pass). The plan-switch pass only runs for entries where envelope decode failed (to preserve the multi-plan v1 chip behavior for plain-text immediate writes).

```swift
private static func computeChips(from m: ChatMessage) -> [CoachChip] {
    var proposalChips: [CoachChip] = []
    var switchChips: [CoachChip] = []
    var workoutChips: [CoachChip] = []
    var seenPlanIds = Set<UUID>()

    // Pass 1 — tool results. Try envelope decode; fall back to plan-switch parser.
    var resultsArr: [[String: Any]] = []
    if let raw = m.toolResultsJSON,
       let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
        resultsArr = arr
    }
    for dict in resultsArr {
        guard let content = dict["content"] as? String else { continue }
        if let env = ProposalCodec.decode(contentString: content) {
            let toolUseId = (dict["tool_use_id"] as? String) ?? ""
            let id = "\(m.id.uuidString)-\(toolUseId)"
            let dates = env.workouts.map(\.date).sorted()
            proposalChips.append(.proposal(ProposalChip(
                id: id,
                messageId: m.id,
                toolUseId: toolUseId,
                envelope: env,
                workoutCount: env.workouts.count,
                firstDate: dates.first,
                lastDate: dates.last,
                isRetroactive: false
            )))
        } else if let parsed = parsePlanSwitchMarker(in: content),
                  seenPlanIds.insert(parsed.id).inserted {
            let tc = ChatBubble.ToolChip(
                id: "switch-\(parsed.id.uuidString)",
                label: "Switch to: \(parsed.title)",
                isError: false,
                workoutDate: nil,
                planId: parsed.id
            )
            switchChips.append(.planSwitch(tc))
        }
    }

    // Pass 2 — tool calls.
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
                workoutChips.append(.workout(.init(
                    id: id, label: "Scheduled \(title) — \(date)",
                    isError: false, workoutDate: parseIso(date))))
            case "delete_workout":
                let date = input["date"] as? String ?? "?"
                workoutChips.append(.workout(.init(
                    id: id, label: "Deleted workout on \(date)",
                    isError: false, workoutDate: parseIso(date))))
            case "get_recent_history":
                workoutChips.append(.workout(.init(
                    id: id, label: "Reviewed recent history",
                    isError: false, workoutDate: nil)))
            case "propose_plan", "propose_plan_update":
                break  // surfaced via proposalChips above
            default:
                workoutChips.append(.workout(.init(
                    id: id, label: "Called \(name)",
                    isError: false, workoutDate: nil)))
            }
        }
    }

    return proposalChips + switchChips + workoutChips
}
```

- [ ] **Step 4: Run the tests, expect pass**

Same command as Step 2 → PASS. Full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/ViewModels/CoachViewModel.swift \
        BearDown/BearDownTests/CoachViewModelTests.swift
git commit -m "feat(coach): emit ProposalChips from bd.proposal/v1 envelopes"
```

---
## Task 15: `ProposalChipView` — pending / applied / dismissed rendering

Pill-style chip with `ViewThatFits` button row. ADD-mode pending has three CTAs (`ADD AS INACTIVE`, `ADD & SWITCH`, `DISMISS`); UPDATE-mode pending has two (`UPDATE PLAN`, `DISMISS`); applied/dismissed states render without buttons (applied is tappable to navigate, dismissed isn't).

**Files:**
- Create: `BearDown/BearDown/Views/Coach/ProposalChipView.swift`
- Modify: `BearDown/BearDown/Views/Coach/ChatBubble.swift`

- [ ] **Step 1: Add UI build smoke**

Append to `BearDown/BearDownTests/CoachViewModelTests.swift`:

```swift
func test_proposalChipView_buildsForAllThreeStates() {
    // Pure type-check / construction smoke — we don't render here.
    let env = ProposalEnvelope(mode: .add, status: .pending,
                               planTitle: "X", planGoal: "",
                               planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
                               workouts: [.init(date: .now, title: "x", summary: "", blocks: [])])
    let chip = ProposalChip(id: "1", messageId: UUID(), toolUseId: "t",
                            envelope: env, workoutCount: 1,
                            firstDate: .now, lastDate: .now)
    _ = ProposalChipView(chip: chip, onApply: { _, _ in }, onDismiss: { _ in })
    var applied = env; applied.status = .applied; applied.appliedMode = .switchPlan
    _ = ProposalChipView(
        chip: ProposalChip(id: "2", messageId: UUID(), toolUseId: "t",
                           envelope: applied, workoutCount: 1,
                           firstDate: .now, lastDate: .now),
        onApply: { _, _ in }, onDismiss: { _ in })
    var dismissed = env; dismissed.status = .dismissed
    _ = ProposalChipView(
        chip: ProposalChip(id: "3", messageId: UUID(), toolUseId: "t",
                           envelope: dismissed, workoutCount: 1,
                           firstDate: .now, lastDate: .now),
        onApply: { _, _ in }, onDismiss: { _ in })
}
```

- [ ] **Step 2: Run, expect compile failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests -quiet
```

Expected: compile error — `ProposalChipView` undefined.

- [ ] **Step 3: Build the view**

Create `BearDown/BearDown/Views/Coach/ProposalChipView.swift`:

```swift
import SwiftUI

public enum ProposalApplyMode: Equatable {
    case addInactive, addAndSwitch, update
}

public struct ProposalChipView: View {
    public let chip: ProposalChip
    public let onApply: (ProposalChip, ProposalApplyMode) -> Void
    public let onDismiss: (ProposalChip) -> Void
    public let onAppliedTap: (ProposalChip) -> Void

    public init(chip: ProposalChip,
                onApply: @escaping (ProposalChip, ProposalApplyMode) -> Void,
                onDismiss: @escaping (ProposalChip) -> Void,
                onAppliedTap: @escaping (ProposalChip) -> Void = { _ in }) {
        self.chip = chip
        self.onApply = onApply
        self.onDismiss = onDismiss
        self.onAppliedTap = onAppliedTap
    }

    public var body: some View {
        switch chip.envelope.status {
        case .pending:    pendingBody
        case .applied:    appliedBody
        case .dismissed:  dismissedBody
        }
    }

    // MARK: – Pending

    private var pendingBody: some View {
        container(strokeOpacity: 0.18, dashed: false) {
            header(symbol: chip.envelope.mode == .add ? "plus.circle.fill" : "arrow.triangle.2.circlepath",
                   title: chip.envelope.mode == .add
                       ? "PROPOSED PLAN: \(chip.envelope.planTitle)"
                       : "PROPOSED UPDATE TO: \(chip.envelope.planTitle)",
                   tint: .primary)
            subLabel(text: pendingSubLabel)
            ViewThatFits {
                singleRowButtons
                stackedButtons
            }
        }
    }

    private var pendingSubLabel: String {
        let countWord = chip.envelope.mode == .add ? "WORKOUTS" : "WORKOUTS REPLACE"
        let range = dateRangeText
        return "\(chip.workoutCount) \(countWord)\(range.isEmpty ? "" : " · \(range)")"
    }

    private var dateRangeText: String {
        guard let first = chip.firstDate, let last = chip.lastDate else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let a = f.string(from: first).uppercased()
        let b = f.string(from: last).uppercased()
        return first == last ? a : "\(a) → \(b)"
    }

    @ViewBuilder
    private var singleRowButtons: some View {
        if chip.envelope.mode == .add {
            HStack(spacing: 8) {
                addInactiveButton
                addAndSwitchButton
                dismissButton
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                updatePlanButton
                dismissButton
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var stackedButtons: some View {
        if chip.envelope.mode == .add {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    addInactiveButton
                    addAndSwitchButton
                }
                dismissButton
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                updatePlanButton
                dismissButton
            }
        }
    }

    private var addInactiveButton: some View {
        Button("ADD AS INACTIVE") { onApply(chip, .addInactive) }
            .buttonStyle(.bordered)
            .tint(.primary)
            .font(BDStyle.monoTiny)
            .accessibilityIdentifier("proposal.addInactive")
    }

    private var addAndSwitchButton: some View {
        Button("ADD & SWITCH") { onApply(chip, .addAndSwitch) }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .font(BDStyle.monoTiny)
            .accessibilityIdentifier("proposal.addAndSwitch")
    }

    private var updatePlanButton: some View {
        Button("UPDATE PLAN") { onApply(chip, .update) }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .font(BDStyle.monoTiny)
            .accessibilityIdentifier("proposal.update")
    }

    private var dismissButton: some View {
        Button("DISMISS") { onDismiss(chip) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(BDStyle.monoTiny)
            .accessibilityIdentifier("proposal.dismiss")
    }

    // MARK: – Applied

    private var appliedBody: some View {
        let modeLabel: String
        switch chip.envelope.appliedMode {
        case .inactive: modeLabel = "ADDED AS INACTIVE"
        case .switchPlan: modeLabel = "ADDED & SWITCHED"
        case .update: modeLabel = "UPDATED"
        case .none: modeLabel = "APPLIED"
        }
        let sub = chip.workoutCount > 0
            ? "\(chip.workoutCount) WORKOUTS\(dateRangeText.isEmpty ? "" : " · \(dateRangeText)") · \(modeLabel)"
            : modeLabel
        let inner = container(strokeOpacity: 0.4, dashed: true, background: BDStyle.chipBackground.opacity(0.6)) {
            header(symbol: "checkmark.seal.fill",
                   title: "APPLIED: \(chip.envelope.planTitle)",
                   tint: .secondary)
            subLabel(text: sub)
        }
        // Whole chip becomes tappable iff the applied plan id is known. For retroactive
        // chips this is filled in by `resolveRetroactiveAppliedPlanIds()` when a same-title
        // plan still exists; otherwise the chip stays non-interactive.
        if chip.envelope.appliedPlanId != nil {
            return AnyView(Button { onAppliedTap(chip) } label: { inner }.buttonStyle(.plain))
        }
        return AnyView(inner)
    }

    // MARK: – Dismissed

    private var dismissedBody: some View {
        container(strokeOpacity: 0.3, dashed: true, background: .clear) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "nosign")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("DISMISSED: \(chip.envelope.planTitle)".uppercased())
                    .font(BDStyle.monoSmall)
                    .tracking(BDStyle.trackingWide)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(subLabelText)
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingTight)
                .strikethrough()
                .foregroundStyle(.secondary)
        }
    }

    private var subLabelText: String {
        let range = dateRangeText
        return "\(chip.workoutCount) WORKOUTS\(range.isEmpty ? "" : " · \(range)")"
    }

    // MARK: – Shared scaffolding

    @ViewBuilder
    private func header(symbol: String, title: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.bold))
                .foregroundStyle(tint)
            Text(title.uppercased())
                .font(BDStyle.monoSmall)
                .tracking(BDStyle.trackingWide)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func subLabel(text: String) -> some View {
        Text(text.uppercased())
            .font(BDStyle.monoTiny)
            .tracking(BDStyle.trackingTight)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func container<Content: View>(strokeOpacity: Double,
                                          dashed: Bool,
                                          background: Color = BDStyle.chipBackground,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(strokeOpacity),
                              style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
        )
    }
}
```

In `BearDown/BearDown/Views/Coach/ChatBubble.swift`, replace the `.proposal: EmptyView()` placeholder from Task 13 with the real view, and extend `ChatBubble`'s init with three new closures:

```swift
public let onApplyProposal: (ProposalChip, ProposalApplyMode) -> Void
public let onDismissProposal: (ProposalChip) -> Void
public let onProposalAppliedTap: (ProposalChip) -> Void

public init(role: ChatRole,
            text: String,
            toolChips: [CoachChip] = [],
            onChipTap: @escaping (ChatBubble.ToolChip) -> Void = { _ in },
            onApplyProposal: @escaping (ProposalChip, ProposalApplyMode) -> Void = { _, _ in },
            onDismissProposal: @escaping (ProposalChip) -> Void = { _ in },
            onProposalAppliedTap: @escaping (ProposalChip) -> Void = { _ in }) {
    self.role = role
    self.text = text
    self.toolChips = toolChips
    self.onChipTap = onChipTap
    self.onApplyProposal = onApplyProposal
    self.onDismissProposal = onDismissProposal
    self.onProposalAppliedTap = onProposalAppliedTap
}
```

In `chipStrip`, replace the `.proposal:` case:

```swift
case .proposal(let p):
    ProposalChipView(chip: p,
                     onApply: onApplyProposal,
                     onDismiss: onDismissProposal,
                     onAppliedTap: onProposalAppliedTap)
```

- [ ] **Step 4: Run the build + tests**

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: build succeeds; smoke test + all unit tests PASS.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Views/Coach/ProposalChipView.swift \
        BearDown/BearDown/Views/Coach/ChatBubble.swift \
        BearDown/BearDownTests/CoachViewModelTests.swift
git commit -m "feat(ui): ProposalChipView with pending/applied/dismissed states"
```

---

## Task 16: Retroactive grouping — old `upsert_workout` calls render as applied proposals

For chat messages predating this feature, group consecutive `upsert_workout` calls in a single message into a virtual applied-state proposal chip. Single-upsert messages still render as the existing workout chip. The grouping is per-`plan_title` (each unique title in the same message becomes its own virtual proposal).

**Files:**
- Modify: `BearDown/BearDown/ViewModels/CoachViewModel.swift`
- Test: `BearDown/BearDownTests/CoachViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CoachViewModelTests`:

```swift
func test_retro_groupsMultipleUpsertsWithSamePlanTitle_intoAppliedProposal() throws {
    let calls: [[String: Any]] = (1...3).map { i in
        ["id": "t\(i)", "name": "upsert_workout",
         "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": [],
                   "plan_title": "Old Block", "plan_goal": ""]]
    }
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)

    let chips = CoachViewModel.computeChipsForTest(from: m)
    let proposals = chips.compactMap { c -> ProposalChip? in
        if case .proposal(let p) = c { return p }; return nil
    }
    XCTAssertEqual(proposals.count, 1)
    XCTAssertEqual(proposals[0].envelope.status, .applied)
    XCTAssertEqual(proposals[0].envelope.planTitle, "Old Block")
    XCTAssertEqual(proposals[0].workoutCount, 3)
    XCTAssertTrue(proposals[0].isRetroactive)
}

func test_retro_singleUpsert_doesNotEmitProposal() throws {
    let calls: [[String: Any]] = [["id": "t1", "name": "upsert_workout",
        "input": ["date": "2026-06-01", "title": "W", "summary": "", "blocks": [],
                  "plan_title": "Single Plan"]]]
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)
    let chips = CoachViewModel.computeChipsForTest(from: m)
    XCTAssertTrue(chips.allSatisfy { if case .proposal = $0 { return false }; return true })
}

func test_retro_missingPlanTitle_emitsUpdatedPlanProposal() throws {
    let calls: [[String: Any]] = (1...2).map { i in
        ["id": "t\(i)", "name": "upsert_workout",
         "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": []]]
    }
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)
    let chips = CoachViewModel.computeChipsForTest(from: m)
    let proposals = chips.compactMap { c -> ProposalChip? in
        if case .proposal(let p) = c { return p }; return nil
    }
    XCTAssertEqual(proposals.count, 1)
    XCTAssertEqual(proposals[0].envelope.mode, .update)
    XCTAssertEqual(proposals[0].envelope.planTitle, "Updated plan")
    XCTAssertEqual(proposals[0].workoutCount, 2)
    XCTAssertEqual(proposals[0].envelope.appliedPlanId, nil)
}

func test_retro_doesNotEmitForNonUpsertTools() throws {
    let calls: [[String: Any]] = [
        ["id": "t1", "name": "delete_workout", "input": ["date": "2026-06-01"]],
        ["id": "t2", "name": "delete_workout", "input": ["date": "2026-06-02"]],
        ["id": "t3", "name": "get_recent_history", "input": [:]],
    ]
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)
    let chips = CoachViewModel.computeChipsForTest(from: m)
    XCTAssertTrue(chips.allSatisfy { if case .proposal = $0 { return false }; return true })
}

func test_retro_doesNotApply_whenEnvelopeAlreadyPresent() throws {
    // If a message already has a real proposal envelope, the multi-upsert path
    // (which writes plan_id into the result string) does NOT also synthesize a
    // virtual proposal. Otherwise we'd render two proposal chips for the same
    // logical action.
    let env = ProposalEnvelope(mode: .add, status: .pending, planTitle: "Real",
        planGoal: "", planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
        workouts: [.init(date: .now, title: "x", summary: "", blocks: [])])
    let envJSON = try ProposalCodec.encode(env)
    let toolResults: [[String: Any]] = [["tool_use_id": "p", "content": envJSON]]
    let calls: [[String: Any]] = [
        ["id": "p", "name": "propose_plan", "input": [:]],
        ["id": "u1", "name": "upsert_workout",
         "input": ["date": "2026-06-01", "title": "W1", "summary": "", "blocks": [],
                   "plan_title": "Other Block"]],
        ["id": "u2", "name": "upsert_workout",
         "input": ["date": "2026-06-02", "title": "W2", "summary": "", "blocks": [],
                   "plan_title": "Other Block"]],
    ]
    let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
    m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
    m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)

    let chips = CoachViewModel.computeChipsForTest(from: m)
    let proposals = chips.compactMap { c -> ProposalChip? in
        if case .proposal(let p) = c { return p }; return nil
    }
    // One real proposal + one retroactive group for "Other Block".
    XCTAssertEqual(proposals.count, 2)
    XCTAssertEqual(proposals[0].envelope.status, .pending)
    XCTAssertEqual(proposals[1].envelope.status, .applied)
    XCTAssertTrue(proposals[1].isRetroactive)
}
```

- [ ] **Step 2: Run, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests -quiet
```

Expected: failures — no retroactive grouping yet.

- [ ] **Step 3: Add the grouping logic**

In `BearDown/BearDown/ViewModels/CoachViewModel.swift`, extend `computeChips(from:)` with a final pass that:

1. Counts `upsert_workout` calls in `toolCallsJSON`.
2. Groups them by `plan_title` (absent → "Updated plan" group).
3. For each group with `count >= 2`, emit a virtual `.proposal` chip with `status=.applied`, `isRetroactive=true`.
4. Remove the workout chips that were absorbed into a retroactive group.

The simplest factoring: do the retroactive scan in a helper, decide which `tool_use_id`s get "absorbed," and skip those in the main workout-chip emission.

Replace `computeChips(from:)` with a version that does this. The full version (copy verbatim — only place where retroactive grouping is defined):

```swift
private static func computeChips(from m: ChatMessage) -> [CoachChip] {
    // Decode tool results once.
    var resultsArr: [[String: Any]] = []
    if let raw = m.toolResultsJSON,
       let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
        resultsArr = arr
    }
    // Decode tool calls once.
    var callsArr: [[String: Any]] = []
    if let raw = m.toolCallsJSON,
       let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
        callsArr = arr
    }

    // Pass 1 — real proposals (decoded envelopes).
    var proposalChips: [CoachChip] = []
    var switchChips: [CoachChip] = []
    var seenPlanIds = Set<UUID>()

    for dict in resultsArr {
        guard let content = dict["content"] as? String else { continue }
        if let env = ProposalCodec.decode(contentString: content) {
            let toolUseId = (dict["tool_use_id"] as? String) ?? ""
            let dates = env.workouts.map(\.date).sorted()
            proposalChips.append(.proposal(ProposalChip(
                id: "\(m.id.uuidString)-\(toolUseId)",
                messageId: m.id,
                toolUseId: toolUseId,
                envelope: env,
                workoutCount: env.workouts.count,
                firstDate: dates.first,
                lastDate: dates.last,
                isRetroactive: false
            )))
        } else if let parsed = parsePlanSwitchMarker(in: content),
                  seenPlanIds.insert(parsed.id).inserted {
            switchChips.append(.planSwitch(.init(
                id: "switch-\(parsed.id.uuidString)",
                label: "Switch to: \(parsed.title)",
                isError: false,
                workoutDate: nil,
                planId: parsed.id
            )))
        }
    }

    // Pass 2 — retroactive grouping. Group upsert_workout calls in this message
    // by `plan_title`. Groups of size >= 2 collapse into a virtual applied-state
    // proposal chip. Singletons fall through to per-workout rendering.
    struct RetroGroup { var title: String?; var calls: [(id: String, input: [String: Any])] }
    var groups: [String: RetroGroup] = [:]   // key = plan_title or "" for none
    var absorbedToolUseIds = Set<String>()
    for dict in callsArr {
        guard (dict["name"] as? String) == "upsert_workout" else { continue }
        let id = (dict["id"] as? String) ?? ""
        let input = (dict["input"] as? [String: Any]) ?? [:]
        let title = (input["plan_title"] as? String).flatMap {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        let key = title ?? ""
        groups[key, default: RetroGroup(title: title, calls: [])].calls.append((id, input))
    }
    for (_, group) in groups where group.calls.count >= 2 {
        let title = group.title ?? "Updated plan"
        let mode: ProposalEnvelope.Mode = (group.title == nil) ? .update : .add
        let goal = (group.calls.first?.input["plan_goal"] as? String) ?? ""
        let dates = group.calls.compactMap { ($0.input["date"] as? String).flatMap(parseIso) }.sorted()
        let envelope = ProposalEnvelope(
            mode: mode, status: .applied,
            planTitle: title, planGoal: goal,
            planId: nil,
            appliedPlanId: nil,             // resolved by caller via PlanRepository.plan(title:) — see Task 19
            appliedAt: nil,
            appliedMode: (mode == .update ? .update : .switchPlan),
            workouts: group.calls.compactMap { call -> ProposalWorkout? in
                guard let dateStr = call.input["date"] as? String,
                      let date = parseIso(dateStr) else { return nil }
                return ProposalWorkout(
                    date: date,
                    title: (call.input["title"] as? String) ?? "",
                    summary: (call.input["summary"] as? String) ?? "",
                    blocks: []   // we don't try to reconstruct blocks; the chip only uses count + dates
                )
            }
        )
        let chipId = "retro-\(m.id.uuidString)-\(title.hashValue)"
        proposalChips.append(.proposal(ProposalChip(
            id: chipId, messageId: m.id, toolUseId: "retro",
            envelope: envelope,
            workoutCount: group.calls.count,
            firstDate: dates.first, lastDate: dates.last,
            isRetroactive: true
        )))
        for c in group.calls { absorbedToolUseIds.insert(c.id) }
    }

    // Pass 3 — workout/per-call chips. Skip anything absorbed by retroactive grouping.
    var workoutChips: [CoachChip] = []
    for dict in callsArr {
        let id = (dict["id"] as? String) ?? UUID().uuidString
        let name = (dict["name"] as? String) ?? "?"
        let input = (dict["input"] as? [String: Any]) ?? [:]
        switch name {
        case "upsert_workout":
            if absorbedToolUseIds.contains(id) { continue }
            let date = input["date"] as? String ?? "?"
            let title = input["title"] as? String ?? "Workout"
            workoutChips.append(.workout(.init(
                id: id, label: "Scheduled \(title) — \(date)",
                isError: false, workoutDate: parseIso(date))))
        case "delete_workout":
            let date = input["date"] as? String ?? "?"
            workoutChips.append(.workout(.init(
                id: id, label: "Deleted workout on \(date)",
                isError: false, workoutDate: parseIso(date))))
        case "get_recent_history":
            workoutChips.append(.workout(.init(
                id: id, label: "Reviewed recent history",
                isError: false, workoutDate: nil)))
        case "propose_plan", "propose_plan_update":
            break
        default:
            workoutChips.append(.workout(.init(
                id: id, label: "Called \(name)",
                isError: false, workoutDate: nil)))
        }
    }

    return proposalChips + switchChips + workoutChips
}
```

- [ ] **Step 4: Run the tests, expect pass**

Same command as Step 2 → PASS. Full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/ViewModels/CoachViewModel.swift \
        BearDown/BearDownTests/CoachViewModelTests.swift
git commit -m "feat(coach): retroactive proposal grouping for pre-feature messages"
```

---
## Task 17: `CoachViewModel.applyProposal` and `dismissProposal`

Wires the chip taps to `ProposalApplyService` + `ChatRepository.replaceToolResults`. After apply, the persisted envelope's `status` flips to `applied` (with `applied_*` fields filled in). Dismiss flips it to `dismissed`. For `.addAndSwitch`, the VM also drives navigation via `AppNavigation`.

**Files:**
- Modify: `BearDown/BearDown/ViewModels/CoachViewModel.swift`
- Test: `BearDown/BearDownTests/CoachViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CoachViewModelTests`:

```swift
func test_applyProposal_addInactive_writesWorkouts_andMutatesEnvelopeStatus() async throws {
    // Seed an assistant message with a pending add envelope.
    let env = ProposalEnvelope(
        mode: .add, status: .pending, planTitle: "New Plan", planGoal: "",
        planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
        workouts: [.init(date: dateFromIso("2026-07-01"),
                         title: "W1", summary: "", blocks: [])]
    )
    let envJSON = try ProposalCodec.encode(env)
    try self.env.chats.append(role: .assistant, text: "",
        toolCallsJSON: #"[{"id":"toolu_1","name":"propose_plan","input":{}}]"#,
        toolResultsJSON: #"[{"tool_use_id":"toolu_1","content":\#(jsonStringLiteral(envJSON))}]"#)
    let vm = CoachViewModel(env: self.env)
    vm.refresh()
    guard case let .proposal(p)? = vm.chips(for: vm.messages.last!).first(where: { if case .proposal = $0 { return true }; return false }) else {
        return XCTFail("expected a proposal chip")
    }
    await vm.applyProposal(p, mode: .addInactive)
    vm.refresh()
    // Status writeback: re-decode the message's tool result, must be applied.
    let after = vm.messages.last!
    let updatedEnv = decodeFirstEnvelope(after)
    XCTAssertEqual(updatedEnv?.status, .applied)
    XCTAssertEqual(updatedEnv?.appliedMode, .inactive)
    XCTAssertNotNil(updatedEnv?.appliedPlanId)
    // Workout exists.
    let day = dateFromIso("2026-07-01")
    let written = try self.env.workouts.workoutsBetween(start: day, end: day.addingTimeInterval(86400))
    XCTAssertEqual(written.first?.title, "W1")
}

func test_applyProposal_addAndSwitch_setsNav() async throws {
    let env = ProposalEnvelope(
        mode: .add, status: .pending, planTitle: "Switch Plan", planGoal: "",
        planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
        workouts: [.init(date: dateFromIso("2026-07-02"), title: "W", summary: "", blocks: [])]
    )
    let envJSON = try ProposalCodec.encode(env)
    try self.env.chats.append(role: .assistant, text: "",
        toolCallsJSON: #"[{"id":"t","name":"propose_plan","input":{}}]"#,
        toolResultsJSON: #"[{"tool_use_id":"t","content":\#(jsonStringLiteral(envJSON))}]"#)
    let nav = AppNavigation()
    let vm = CoachViewModel(env: self.env, nav: nav)
    vm.refresh()
    let chip = firstProposal(in: vm)
    await vm.applyProposal(chip, mode: .addAndSwitch)
    XCTAssertEqual(nav.selectedTab, 1)
    XCTAssertNotNil(nav.pendingPlanDetail)
}

func test_dismissProposal_mutatesEnvelopeWithoutWritingWorkouts() throws {
    let env = ProposalEnvelope(mode: .add, status: .pending, planTitle: "Phantom",
        planGoal: "", planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
        workouts: [.init(date: dateFromIso("2026-07-01"), title: "W", summary: "", blocks: [])])
    let envJSON = try ProposalCodec.encode(env)
    try self.env.chats.append(role: .assistant, text: "",
        toolCallsJSON: #"[{"id":"t","name":"propose_plan","input":{}}]"#,
        toolResultsJSON: #"[{"tool_use_id":"t","content":\#(jsonStringLiteral(envJSON))}]"#)
    let vm = CoachViewModel(env: self.env)
    vm.refresh()
    let chip = firstProposal(in: vm)
    vm.dismissProposal(chip)
    vm.refresh()
    XCTAssertEqual(decodeFirstEnvelope(vm.messages.last!)?.status, .dismissed)
    let day = dateFromIso("2026-07-01")
    let workouts = try self.env.workouts.workoutsBetween(start: day, end: day.addingTimeInterval(86400))
    XCTAssertTrue(workouts.isEmpty, "dismiss must not write workouts")
}

// Helpers for the tests above
private func firstProposal(in vm: CoachViewModel) -> ProposalChip {
    for m in vm.messages {
        for chip in vm.chips(for: m) {
            if case .proposal(let p) = chip { return p }
        }
    }
    fatalError("no proposal chip found")
}

private func decodeFirstEnvelope(_ m: ChatMessage) -> ProposalEnvelope? {
    guard let raw = m.toolResultsJSON,
          let arr = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]],
          let content = arr.first?["content"] as? String else { return nil }
    return ProposalCodec.decode(contentString: content)
}

/// Escape a JSON envelope for inclusion as a string field inside another JSON literal.
private func jsonStringLiteral(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
    return String(data: data, encoding: .utf8)!
}
```

- [ ] **Step 2: Run, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests -quiet
```

Expected: compile errors — `CoachViewModel.init(env:nav:)`, `applyProposal`, `dismissProposal` don't exist.

- [ ] **Step 3: Add the methods**

In `BearDown/BearDown/ViewModels/CoachViewModel.swift`:

a) Add an optional `nav` dependency. The default initializer keeps backwards compatibility for sites that don't pass nav (mostly tests that don't exercise navigation):

```swift
private let env: AppEnvironment
private let nav: AppNavigation?

public init(env: AppEnvironment, nav: AppNavigation? = nil) {
    self.env = env
    self.nav = nav
    self.env.coach.onTextDelta = { [weak self] delta in
        Task { @MainActor in self?.liveAssistantText += delta }
    }
}
```

b) Add `applyProposal` and `dismissProposal` methods:

```swift
public func applyProposal(_ chip: ProposalChip, mode: ProposalApplyMode) async {
    do {
        let applyMode: ProposalApplyService.ApplyMode
        switch mode {
        case .addInactive:   applyMode = .addInactive
        case .addAndSwitch:  applyMode = .addAndSwitch
        case .update:        applyMode = .update
        }
        let result = try env.proposals.apply(chip.envelope, mode: applyMode)
        try writebackEnvelope(messageId: chip.messageId, toolUseId: chip.toolUseId) { env in
            env.status = .applied
            env.appliedPlanId = result.planId
            env.appliedAt = .now
            env.appliedMode = result.appliedMode
        }
        if mode == .addAndSwitch, let nav {
            nav.selectedTab = 1
            nav.pendingPlanDetail = result.planId
        }
        refresh()
    } catch {
        state = .error("Couldn't apply this plan: \(error.localizedDescription)")
    }
}

public func dismissProposal(_ chip: ProposalChip) {
    do {
        try writebackEnvelope(messageId: chip.messageId, toolUseId: chip.toolUseId) { env in
            env.status = .dismissed
        }
        refresh()
    } catch {
        state = .error("Couldn't dismiss: \(error.localizedDescription)")
    }
}

public func navigateToAppliedProposal(_ chip: ProposalChip) {
    guard let nav, let pid = chip.envelope.appliedPlanId else { return }
    nav.selectedTab = 1
    nav.pendingPlanDetail = pid
}

/// Decode `toolResultsJSON`, locate the entry matching `toolUseId`, mutate its
/// envelope via `mutate`, re-encode, and persist via ChatRepository.
private func writebackEnvelope(messageId: UUID,
                               toolUseId: String,
                               mutate: (inout ProposalEnvelope) -> Void) throws {
    let convId = env.chats.currentConversationId()
    let msgs = try env.chats.messages(in: convId)
    guard let target = msgs.first(where: { $0.id == messageId }),
          let raw = target.toolResultsJSON,
          var arr = (try JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]]
    else { throw RepositoryError.workoutNotFound }

    for i in 0..<arr.count {
        guard (arr[i]["tool_use_id"] as? String) == toolUseId,
              let content = arr[i]["content"] as? String,
              var decoded = ProposalCodec.decode(contentString: content)
        else { continue }
        mutate(&decoded)
        arr[i]["content"] = try ProposalCodec.encode(decoded)
    }
    let newData = try JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])
    let newJSON = String(data: newData, encoding: .utf8) ?? "[]"
    try env.chats.replaceToolResults(messageId: messageId, newJSON: newJSON)
}
```

c) `CoachView.swift` already constructs the VM as `CoachViewModel(env: env)` — keep that for the default-no-nav path the tests use. In Task 18 we'll pass `nav` from the view.

- [ ] **Step 4: Run the tests, expect pass**

Same command as Step 2 → PASS. Full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/ViewModels/CoachViewModel.swift \
        BearDown/BearDownTests/CoachViewModelTests.swift
git commit -m "feat(coach): applyProposal/dismissProposal mutate persisted envelope"
```

---

## Task 18: `CoachView` wires apply/dismiss closures + passes nav into VM

The VM's apply path needs `AppNavigation` for the `.addAndSwitch` case. The view supplies it at construction time, and forwards chip-button events to the VM.

**Files:**
- Modify: `BearDown/BearDown/Views/Coach/CoachView.swift`
- Test: existing tests; no new unit assertions (the next task — UI test — exercises this end-to-end).

- [ ] **Step 1: Confirm baseline**

Build the app to confirm it still compiles:

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: clean build.

- [ ] **Step 2: Change `CoachView` init to pass nav**

In `BearDown/BearDown/Views/Coach/CoachView.swift`, change the init + the `ChatBubble` construction:

```swift
public init(env: AppEnvironment, nav: AppNavigation) {
    _vm = StateObject(wrappedValue: CoachViewModel(env: env, nav: nav))
}
```

Note: `RootView` passes `nav` already to other tabs via `.environmentObject(nav)`. Here we pass it explicitly so it's available inside the `@StateObject` autoclosure (which can't reach the environment-object yet). The owning `RootView` site changes to:

```swift
CoachView(env: env, nav: nav)
```

In `BearDown/BearDown/Views/Shared/RootView.swift`, find where `CoachView(env:)` is constructed and replace with `CoachView(env: env, nav: nav)` (the `nav: AppNavigation` is already in scope as an `@StateObject` / `@EnvironmentObject` — use whichever the file already uses).

Update the `ChatBubble` call site inside `messagesScroll`:

```swift
ChatBubble(
    role: m.role,
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
    },
    onApplyProposal: { chip, mode in
        Task { await vm.applyProposal(chip, mode: mode) }
    },
    onDismissProposal: { chip in
        vm.dismissProposal(chip)
    },
    onProposalAppliedTap: { chip in
        vm.navigateToAppliedProposal(chip)
    }
)
```

- [ ] **Step 3: Build**

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: clean.

- [ ] **Step 4: Run full unit suite**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/Views/Coach/CoachView.swift \
        BearDown/BearDown/Views/Shared/RootView.swift
git commit -m "feat(coach): CoachView passes nav to VM + forwards proposal closures"
```

---

## Task 19: Retroactive applied chip — resolve `appliedPlanId` from `PlanRepository.plan(title:)`

Until this task, retroactive proposal chips have `appliedPlanId = nil`. Now `computeChips` consults `PlanRepository.plan(title:)` to fill it in when a same-title plan still exists, so tapping the chip navigates correctly. If the plan was deleted, the chip stays non-tappable (per spec §"Retroactive rendering"). The VM-side helper needs access to the repo, so move retroactive-resolution out of the static `computeChips` into an instance helper.

**Files:**
- Modify: `BearDown/BearDown/ViewModels/CoachViewModel.swift`
- Test: `BearDown/BearDownTests/CoachViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `CoachViewModelTests`:

```swift
func test_retro_resolvesAppliedPlanId_whenPlanTitleStillExists() throws {
    let existing = try env.plans.createPlan(
        title: "Block X", startDate: .now, endDate: .now.addingTimeInterval(86400))
    let calls: [[String: Any]] = (1...2).map { i in
        ["id": "t\(i)", "name": "upsert_workout",
         "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": [],
                   "plan_title": "Block X"]]
    }
    try env.chats.append(role: .assistant, text: "",
        toolCallsJSON: String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8),
        toolResultsJSON: nil)
    let vm = CoachViewModel(env: env)
    vm.refresh()
    let chip = firstProposal(in: vm)
    XCTAssertEqual(chip.envelope.appliedPlanId, existing.id)
}

func test_retro_appliedPlanId_isNil_whenPlanTitleNoLongerExists() throws {
    let calls: [[String: Any]] = (1...2).map { i in
        ["id": "t\(i)", "name": "upsert_workout",
         "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": [],
                   "plan_title": "Deleted Block"]]
    }
    try env.chats.append(role: .assistant, text: "",
        toolCallsJSON: String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8),
        toolResultsJSON: nil)
    let vm = CoachViewModel(env: env)
    vm.refresh()
    let chip = firstProposal(in: vm)
    XCTAssertNil(chip.envelope.appliedPlanId)
}
```

- [ ] **Step 2: Run, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests -quiet
```

Expected: fails — retroactive chips currently have `appliedPlanId == nil`.

- [ ] **Step 3: Resolve `appliedPlanId` during `refresh()`**

In `BearDown/BearDown/ViewModels/CoachViewModel.swift`:

a) Add a post-process step inside `refresh()` that walks the cached chips and resolves any retroactive proposal's `appliedPlanId` by looking up its `planTitle` via `env.plans.plan(title:)`. Cache the lookups per refresh — many messages can share a title.

```swift
public func refresh() {
    let id = env.chats.currentConversationId()
    let msgs = (try? env.chats.messages(in: id)) ?? []
    let visible = msgs.filter { !($0.role == .user && $0.text.isEmpty) }
    messages = visible
    chipCache = Dictionary(uniqueKeysWithValues:
        visible.map { ($0.id, Self.computeChips(from: $0)) })
    resolveRetroactiveAppliedPlanIds()
}

private func resolveRetroactiveAppliedPlanIds() {
    var titleCache: [String: UUID?] = [:]
    for (mid, chips) in chipCache {
        chipCache[mid] = chips.map { chip -> CoachChip in
            guard case .proposal(let p) = chip,
                  p.isRetroactive,
                  p.envelope.status == .applied,
                  p.envelope.appliedPlanId == nil else { return chip }
            let title = p.envelope.planTitle
            let resolvedId: UUID?
            if let cached = titleCache[title] {
                resolvedId = cached
            } else {
                resolvedId = (try? env.plans.plan(title: title))?.id
                titleCache[title] = resolvedId
            }
            guard let resolvedId else { return chip }
            var newEnv = p.envelope
            newEnv.appliedPlanId = resolvedId
            return .proposal(ProposalChip(
                id: p.id, messageId: p.messageId, toolUseId: p.toolUseId,
                envelope: newEnv,
                workoutCount: p.workoutCount,
                firstDate: p.firstDate, lastDate: p.lastDate,
                isRetroactive: true
            ))
        }
    }
}
```

- [ ] **Step 4: Run the tests, expect pass**

Same command as Step 2 → PASS. Full unit suite.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/ViewModels/CoachViewModel.swift \
        BearDown/BearDownTests/CoachViewModelTests.swift
git commit -m "feat(coach): resolve retroactive proposal appliedPlanId via plan(title:)"
```

---
## Task 20: UI test — end-to-end propose → apply → navigate

XCUITest exercising the new approval flow. Uses a scripted `AnthropicClient` test seam injected via launch arguments — same pattern as `MultiPlanUITests` uses `--ui-test-seed-two-plans`. Adds a new launch-arg `--ui-test-seed-pending-proposal` that injects a chat message with a `bd.proposal/v1` pending envelope into the chat store at app start, so the test doesn't need a network round-trip.

**Files:**
- Modify: `BearDown/BearDown/BearDownApp.swift` — add seed handler
- Create: `BearDown/BearDownUITests/ApprovalGateUITests.swift`

- [ ] **Step 1: Write the UI test**

Create `BearDown/BearDownUITests/ApprovalGateUITests.swift`:

```swift
import XCTest

final class ApprovalGateUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func test_addAsInactive_appliesEnvelopeAndShowsPlan() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-stub-validator",
            "--reset-keychain",
            "--ui-test-seed-pending-proposal",
        ]
        app.launch()

        // Onboard
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap(); key.typeText("sk-ant-uitest")
        app.buttons["Continue"].tap()

        // Coach tab
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Coach"].tap()

        // The seeded proposal chip is visible.
        let addInactive = app.buttons["proposal.addInactive"]
        XCTAssertTrue(addInactive.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["proposal.addAndSwitch"].exists)
        XCTAssertTrue(app.buttons["proposal.dismiss"].exists)

        // Tap Add as inactive.
        addInactive.tap()

        // The pending CTAs disappear (applied state has no buttons).
        XCTAssertFalse(addInactive.waitForExistence(timeout: 3))

        // Plans tab: the new plan is present (inactive). The seeded "Current Block"
        // (from --ui-test-seed-pending-proposal's secondary setup) remains active.
        app.tabBars.buttons["Plan"].tap()
        let newCard = app.buttons["plan.card.Seeded Proposal Plan"]
        XCTAssertTrue(newCard.waitForExistence(timeout: 5))
    }

    func test_dismiss_marksProposalDismissed_andDoesNotCreatePlan() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-stub-validator",
            "--reset-keychain",
            "--ui-test-seed-pending-proposal",
        ]
        app.launch()

        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap(); key.typeText("sk-ant-uitest")
        app.buttons["Continue"].tap()

        app.tabBars.buttons["Coach"].tap()
        let dismiss = app.buttons["proposal.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertFalse(dismiss.waitForExistence(timeout: 3))

        app.tabBars.buttons["Plan"].tap()
        XCTAssertFalse(app.buttons["plan.card.Seeded Proposal Plan"].exists)
    }
}
```

- [ ] **Step 2: Add the seed launch-arg handler**

In `BearDown/BearDown/BearDownApp.swift`, after the existing `--ui-test-seed-two-plans` block, add:

```swift
if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-pending-proposal") {
    Task { @MainActor in
        // Provide a baseline active plan so the Plans tab isn't empty.
        if (try? environment.plans.activePlan()) == nil {
            _ = try? environment.plans.createPlan(
                title: "Current Block",
                startDate: .now, endDate: .now.addingTimeInterval(7 * 86400)
            )
        }
        // Build a pending add-mode envelope by hand.
        let envelopeJSON: String = {
            let obj: [String: Any] = [
                "schema": "bd.proposal/v1",
                "mode": "add",
                "status": "pending",
                "plan_title": "Seeded Proposal Plan",
                "plan_goal": "Goal text",
                "workouts": [
                    ["date": "2026-07-01", "title": "W1", "summary": "Compound-led", "blocks": []],
                    ["date": "2026-07-02", "title": "W2", "summary": "Easy run", "blocks": []],
                ],
            ]
            let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }()
        let toolUseId = "toolu_seed"
        let calls: [[String: Any]] = [["type": "tool_use", "id": toolUseId,
                                       "name": "propose_plan", "input": [:]]]
        let results: [[String: Any]] = [["type": "tool_result", "tool_use_id": toolUseId,
                                         "content": envelopeJSON, "is_error": false]]
        let callsJSON = String(data: try! JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)!
        let resultsJSON = String(data: try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), encoding: .utf8)!
        try? environment.chats.append(role: .assistant,
            text: "Here's a proposed plan.",
            toolCallsJSON: callsJSON, toolResultsJSON: resultsJSON)
    }
}
```

- [ ] **Step 3: Run the UI tests**

Open the project in Xcode and run `ApprovalGateUITests` via the test navigator (UI tests via `xcodebuild test -only-testing:BearDownUITests` are flaky — CLAUDE.md note). If you must run from the CLI:

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownUITests/ApprovalGateUITests -quiet
```

Expected: both tests PASS. If you see "Mach error -308 — server died" on the first attempt, retry once (known flake).

- [ ] **Step 4: Confirm baseline unit suite is still green**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add BearDown/BearDown/BearDownApp.swift \
        BearDown/BearDownUITests/ApprovalGateUITests.swift
git commit -m "test(ui): approval-gate flow — propose, apply, dismiss"
```

---

## Task 21: Manual-test addendum + CLAUDE.md notes

Document the new flow for human smoke testing and capture the JSON-envelope-in-`toolResultsJSON` pattern + dual-write/proposal split in CLAUDE.md so future sessions don't have to relearn it.

**Files:**
- Modify: `docs/manual-tests.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Append to `docs/manual-tests.md`**

Append a new section to `docs/manual-tests.md`:

```markdown
## Approval gate

Goal: confirm that block-scale Coach output is gated behind an explicit Apply / Dismiss tap, while in-block adjustments still write immediately.

1. Open Coach. Send "give me a 4-week race prep block targeting June 24."
2. Wait for streaming to finish. Confirm a tall pill chip appears with:
   - Top row: "PROPOSED PLAN: <title>"
   - Sub-row: "<N> WORKOUTS · <date range>"
   - Three buttons: ADD AS INACTIVE / ADD & SWITCH / DISMISS
3. Switch to Today and to Plans. Confirm no new plan or workouts exist yet.
4. Return to Coach. Tap DISMISS. Confirm the chip transitions to a struck-through dismissed state with no buttons.
5. Ask again: "alright, propose it again as a 1-week block." Wait for the new proposal.
6. Tap ADD AS INACTIVE. Confirm:
   - The chip transitions to the applied state ("APPLIED: …").
   - Plans tab shows the new plan listed as inactive, with the original active plan unchanged.
7. Open Coach again. Ask for a multi-day adjustment to the active plan ("rewrite Thu/Fri/Sat to be hypertrophy-focused"). Confirm a `propose_plan_update` chip appears with UPDATE PLAN / DISMISS only.
8. Tap UPDATE PLAN. Confirm the active plan's workouts on those dates are replaced (Today's preview reflects the new entries) and the chip shows applied state.
9. Ask for a single-workout change ("move Tuesday's run to Wednesday"). Confirm the coach uses `upsert_workout` (no proposal chip — the change is immediate). The chat shows a small scheduled-workout chip; Today reflects the change immediately.
10. Tap the applied proposal chip in chat — confirm it deep-links to the corresponding plan in the Plans tab.
11. Force-quit and relaunch the app. Confirm all applied/dismissed chip states persist (the writeback is real, not in-memory only).
12. Scroll back to chat messages from before this feature (or from a `--ui-test-seed-two-plans` baseline that uses immediate writes) — confirm groups of `upsert_workout` calls with the same plan title now render as a single Applied-style chip with the plan title and workout count.
```

- [ ] **Step 2: Append to `CLAUDE.md`**

Append a new bullet under the "Critical gotchas" section (numbered next sequentially — gotcha #12):

```markdown
### 12. Tool-result strings carry one of two formats — detect by JSON shape

Today's `toolResultsJSON` array contains entries whose `content` is either:

1. **Plain text** (immediate-write tools — `upsert_workout`, `delete_workout`, `get_recent_history`). Parsed by `parsePlanSwitchMarker(in:)` for the `plan_id=` marker.
2. **JSON envelope** with `schema: "bd.proposal/v1"` (proposal tools — `propose_plan`, `propose_plan_update`). Decoded by `ProposalCodec.decode(contentString:)`.

When extending `CoachViewModel.computeChips`, always try envelope decode first; fall back to plain-text marker parsing only if `decode(contentString:)` returns `nil`. Don't introduce a third format — bump the schema version (`bd.proposal/v2`) and extend the decoder. Documented in `docs/superpowers/specs/2026-06-02-approval-gate-design.md`.
```

Add another bullet under "Architecture pointers":

```markdown
- **Two paths into SwiftData from the agent:** immediate-write (`upsert_workout` / `delete_workout` → `WorkoutRepository.upsert` / `delete`) for in-block adjustments, and proposal-gated (`propose_plan` / `propose_plan_update` → envelope in `ChatMessage.toolResultsJSON` → user tap → `ProposalApplyService.apply(...)` → repositories). Never invent a third path; if you add a multi-workout tool, route it through `ProposalApplyService` so the user-visible chip stays consistent.
```

Add to "Where to look first" table:

```markdown
| Change the proposal envelope shape | `BearDown/BearDown/Coach/ProposalEnvelope.swift` + `BearDown/BearDown/Coach/ProposalCodec.swift` (bump `schemaVersion` if breaking) |
| Apply a proposal to SwiftData | `BearDown/BearDown/Coach/ProposalApplyService.swift` |
| Adjust proposal chip visuals | `BearDown/BearDown/Views/Coach/ProposalChipView.swift` |
```

- [ ] **Step 3: Build the app once to make sure nothing inadvertently broke**

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: clean.

- [ ] **Step 4: Run full unit suite a final time**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add docs/manual-tests.md CLAUDE.md
git commit -m "docs(approval-gate): manual tests + CLAUDE.md notes"
```

---

## Done

All 21 tasks complete. Recap of the new public surface:

- **Agent tools:** `propose_plan`, `propose_plan_update` (definitions in `CoachTools.definitions`, dispatched via `handlePropose` / `handleProposeUpdate`).
- **Wire format:** `bd.proposal/v1` JSON envelope, persisted inside existing `ChatMessage.toolResultsJSON`. Encoded with `JSONSerialization.WritingOptions.sortedKeys`. No new SwiftData model.
- **Apply pipeline:** `ProposalApplyService.apply(_:mode:)` (modes `.addInactive` / `.addAndSwitch` / `.update`).
- **View model:** `CoachViewModel.applyProposal(_:mode:)`, `dismissProposal(_:)`, `navigateToAppliedProposal(_:)`. Status writeback via `ChatRepository.replaceToolResults`.
- **View:** `ProposalChipView` rendering pending / applied / dismissed states; `ChatBubble` switches on `CoachChip` enum.
- **Retroactive rendering:** consecutive pre-feature `upsert_workout` calls in one message group into virtual applied-state proposal chips per `plan_title`. `appliedPlanId` resolved via `PlanRepository.plan(title:)`.

Spec section → task coverage:
- §Architecture / Data layer → Tasks 1, 2, 3
- §Tool-result envelope format → Task 2
- §Agent tools (`propose_plan`) → Task 4
- §Workout parsing extraction → Tasks 3, 5
- §Agent tools (`propose_plan_update`) → Task 6
- §CoachService context block extension → Task 7
- §`CoachPrompt.toolAddendum` rewrite → Task 8
- §`PlanRepository.plan(title:)` for retro lookup → Task 9
- §`ChatRepository.replaceToolResults` → Task 10
- §`ProposalApplyService` → Tasks 11, 12
- §View model: `computeChips` + `CoachChip` enum → Tasks 13, 14
- §View: `ProposalChipView` + `ViewThatFits` button row → Task 15
- §Retroactive rendering → Tasks 16, 19
- §Status transitions / writeback → Task 17
- §`CoachView` wiring → Task 18
- §Testing — UI test → Task 20
- §Testing — manual addendum + CLAUDE.md → Task 21
