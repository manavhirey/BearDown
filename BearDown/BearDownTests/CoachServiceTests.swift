import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class CoachServiceTests: XCTestCase {
    private var env: AppEnvironment!
    private var scripted: ScriptedAnthropicClient!
    private var service: CoachService!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        scripted = ScriptedAnthropicClient()
        env = AppEnvironment(
            modelContainer: container,
            keychain: KeychainStore(service: "com.beardown.tests.coach.\(UUID().uuidString)"),
            anthropic: scripted
        )
        try env.keychain.write(key: .anthropicAPIKey, value: "sk-test")
        _ = try env.plans.createPlan(title: "B1",
                                     startDate: .now,
                                     endDate: .now.addingTimeInterval(28 * 86400))
        let tools = CoachTools(plans: env.plans, workouts: env.workouts)
        service = CoachService(client: scripted,
                               keychain: env.keychain,
                               chats: env.chats,
                               tools: tools,
                               workouts: env.workouts,
                               plans: env.plans)
    }

    func test_textOnlyResponse_persistsAssistantMessage() async throws {
        scripted.scripts = [[
            .messageStart,
            .contentBlockStart(index: 0, .text),
            .contentBlockDelta(index: 0, .text("Hello")),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "end_turn"),
            .messageStop,
        ]]
        try await service.send(userText: "hi")
        let msgs = try env.chats.messages(in: env.chats.currentConversationId())
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertEqual(msgs[0].text, "hi")
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[1].text, "Hello")
    }

    func test_toolUseResponse_dispatchesAndLoops() async throws {
        scripted.scripts = [
            // Turn 1: assistant wants to call upsert_workout
            [
                .messageStart,
                .contentBlockStart(index: 0, .toolUse(id: "toolu_1", name: "upsert_workout")),
                .contentBlockDelta(index: 0, .inputJson(#"{"date":"2026-06-01","title":"Push","summary":"","blocks":[]}"#)),
                .contentBlockStop(index: 0),
                .messageDelta(stopReason: "tool_use"),
                .messageStop,
            ],
            // Turn 2: assistant acknowledges + ends turn
            [
                .messageStart,
                .contentBlockStart(index: 0, .text),
                .contentBlockDelta(index: 0, .text("Scheduled.")),
                .contentBlockStop(index: 0),
                .messageDelta(stopReason: "end_turn"),
                .messageStop,
            ]
        ]
        try await service.send(userText: "make a plan")

        // Tool was executed → workout exists.
        let cal = Calendar.current
        let day = cal.startOfDay(for: dateFromIso("2026-06-01"))
        XCTAssertEqual(try env.workouts.workoutsBetween(start: day, end: day.addingTimeInterval(86400)).count, 1)

        // Chat log contains user → assistant(tool) → user(tool_result) → assistant(text)
        let msgs = try env.chats.messages(in: env.chats.currentConversationId())
        XCTAssertEqual(msgs.count, 4)
        XCTAssertNotNil(msgs[1].toolCallsJSON)
        XCTAssertNotNil(msgs[2].toolResultsJSON)
        XCTAssertEqual(msgs[3].text, "Scheduled.")
    }

    func test_runawayLoop_isCapped() async throws {
        // Endlessly request tool calls — service should stop after 10 iterations.
        let toolTurn: [AnthropicEvent] = [
            .messageStart,
            .contentBlockStart(index: 0, .toolUse(id: "t", name: "get_recent_history")),
            .contentBlockDelta(index: 0, .inputJson(#"{"days":1}"#)),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "tool_use"),
            .messageStop,
        ]
        scripted.scripts = Array(repeating: toolTurn, count: 20)
        do {
            try await service.send(userText: "loop")
            XCTFail("Expected error")
        } catch CoachError.toolLoopLimitExceeded {
            // expected
        }
    }

    func test_missingApiKey_throws() async throws {
        try env.keychain.delete(key: .anthropicAPIKey)
        do {
            try await service.send(userText: "hi")
            XCTFail("Expected error")
        } catch CoachError.missingAPIKey {
            // expected
        }
    }

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }
}

/// Yields a pre-recorded sequence of events for each successive `stream(...)` call.
final class ScriptedAnthropicClient: AnthropicClientProtocol, @unchecked Sendable {
    var scripts: [[AnthropicEvent]] = []
    private var callIndex = 0

    func validate(apiKey: String) async throws {}

    func stream(apiKey: String, request: AnthropicRequest) -> AsyncThrowingStream<AnthropicEvent, Error> {
        let events = callIndex < scripts.count ? scripts[callIndex] : []
        callIndex += 1
        return AsyncThrowingStream { cont in
            Task {
                for e in events { cont.yield(e) }
                cont.finish()
            }
        }
    }
}
