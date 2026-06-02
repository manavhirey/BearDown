import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class CoachToolsTests: XCTestCase {
    private var env: AppEnvironment!
    private var tools: CoachTools!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        env = AppEnvironment(modelContainer: container,
                             keychain: KeychainStore(service: "com.beardown.tests.tools.\(UUID().uuidString)"),
                             anthropic: FakeAnthropicClient())
        _ = try env.plans.createPlan(title: "Block 1",
                                     startDate: .now,
                                     endDate: .now.addingTimeInterval(28 * 86400))
        tools = CoachTools(plans: env.plans, workouts: env.workouts)
    }

    func test_definitions_listAllThreeTools() {
        let names = tools.definitions.map(\.name).sorted()
        XCTAssertEqual(names, ["delete_workout", "get_recent_history", "upsert_workout"])
    }

    func test_dispatch_upsertWorkout_persists() throws {
        let input: [String: Any] = [
            "date": "2026-06-01",
            "title": "Push",
            "summary": "Bench + OHP",
            "blocks": [[
                "kind": "strength",
                "order": 0,
                "title": "Push",
                "notes": "",
                "exercises": [["order": 0, "name": "Bench", "sets": 5, "reps": "5", "load": "60kg"]]
            ]]
        ]
        let result = try tools.dispatch(name: "upsert_workout", input: input)
        XCTAssertFalse(result.isError)
        let day = Calendar.current.startOfDay(for: dateFromIso("2026-06-01"))
        let next = day.addingTimeInterval(86400)
        let stored = try env.workouts.workoutsBetween(start: day, end: next)
        XCTAssertEqual(stored.first?.title, "Push")
    }

    func test_dispatch_deleteWorkout_removes() throws {
        _ = try env.workouts.upsert(.init(date: dateFromIso("2026-06-01"),
                                          title: "x", summary: "", blocks: []))
        let result = try tools.dispatch(name: "delete_workout",
                                        input: ["date": "2026-06-01"])
        XCTAssertFalse(result.isError)
        let day = Calendar.current.startOfDay(for: dateFromIso("2026-06-01"))
        let next = day.addingTimeInterval(86400)
        XCTAssertEqual(try env.workouts.workoutsBetween(start: day, end: next).count, 0)
    }

    func test_dispatch_getRecentHistory_returnsJson() throws {
        let w = try env.workouts.upsert(.init(date: .now, title: "X", summary: "", blocks: []))
        try env.workouts.markStatus(workoutId: w.id, status: .completed, note: "good")
        let result = try tools.dispatch(name: "get_recent_history", input: ["days": 7])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("\"title\":\"X\""))
        XCTAssertTrue(result.content.contains("\"status\":\"completed\""))
    }

    func test_dispatch_invalidToolName_returnsErrorResult() {
        let r = (try? tools.dispatch(name: "nope", input: [:])) ?? .init(content: "?", isError: true)
        XCTAssertTrue(r.isError)
    }

    func test_dispatch_invalidUpsertInput_returnsErrorResult() {
        let r = (try? tools.dispatch(name: "upsert_workout", input: ["date": "not-a-date"]))
            ?? .init(content: "?", isError: true)
        XCTAssertTrue(r.isError)
    }

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

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }
}

/// Test-only stub so AppEnvironment doesn't try to hit the network.
struct FakeAnthropicClient: AnthropicClientProtocol {
    func validate(apiKey: String) async throws {}
    func stream(apiKey: String, request: AnthropicRequest) -> AsyncThrowingStream<AnthropicEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
