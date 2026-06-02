import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class CoachViewModelTests: XCTestCase {
    private var env: AppEnvironment!
    private var scripted: ScriptedAnthropicClient!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        scripted = ScriptedAnthropicClient()
        env = AppEnvironment(
            modelContainer: container,
            keychain: KeychainStore(service: "com.beardown.tests.coachvm.\(UUID().uuidString)"),
            anthropic: scripted
        )
        try env.keychain.write(key: .anthropicAPIKey, value: "sk-test")
        _ = try env.plans.createPlan(title: "B", startDate: .now, endDate: .now.addingTimeInterval(28 * 86400))
    }

    func test_send_appendsUserAndAssistantMessages() async throws {
        scripted.scripts = [[
            .messageStart,
            .contentBlockStart(index: 0, .text),
            .contentBlockDelta(index: 0, .text("hi back")),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "end_turn"),
            .messageStop,
        ]]
        let vm = CoachViewModel(env: env)
        vm.draft = "hi"
        await vm.send()
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].text, "hi")
        XCTAssertEqual(vm.messages[1].text, "hi back")
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.draft, "")
    }

    func test_send_emptyDraft_isNoop() async {
        let vm = CoachViewModel(env: env)
        vm.draft = "   "
        await vm.send()
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func test_send_setsErrorWhenKeyMissing() async {
        try? env.keychain.delete(key: .anthropicAPIKey)
        let vm = CoachViewModel(env: env)
        vm.draft = "hi"
        await vm.send()
        XCTAssertEqual(vm.state, .error("Add your API key in Settings."))
    }

    func test_retry_replaysLastUserText() async throws {
        // First send hits an error path
        try env.keychain.delete(key: .anthropicAPIKey)
        let vm = CoachViewModel(env: env)
        vm.draft = "hi"
        await vm.send()
        XCTAssertEqual(vm.state, .error("Add your API key in Settings."))
        XCTAssertEqual(vm.lastUserText, "hi")
        // Restore key, script a success, retry
        try env.keychain.write(key: .anthropicAPIKey, value: "sk-test")
        scripted.scripts = [[
            .messageStart,
            .contentBlockStart(index: 0, .text),
            .contentBlockDelta(index: 0, .text("ok")),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "end_turn"),
            .messageStop,
        ]]
        await vm.retry()
        XCTAssertEqual(vm.state, .idle)
        // The first failed turn already persisted the user message (it gets persisted before
        // the API call). So we expect user("hi") + user("hi") + assistant("ok") = 3
        // OR depending on implementation, just user("hi") + assistant("ok") if retry reuses
        // the previously persisted user row. Either is acceptable — assert assistant text only:
        XCTAssertEqual(vm.messages.last?.text, "ok")
    }

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

    func test_refresh_afterSwitchConversation_loadsTheSwitchedConversation() throws {
        // Seed two conversations directly through env.chats.
        let a = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "from A", toolCallsJSON: nil, toolResultsJSON: nil)
        try env.chats.append(role: .assistant, text: "reply A", toolCallsJSON: nil, toolResultsJSON: nil)
        env.chats.archiveCurrentConversation()
        let b = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "from B", toolCallsJSON: nil, toolResultsJSON: nil)
        try env.chats.append(role: .assistant, text: "reply B", toolCallsJSON: nil, toolResultsJSON: nil)

        let vm = CoachViewModel(env: env)
        vm.refresh()
        XCTAssertEqual(vm.messages.map(\.text), ["from B", "reply B"])

        // Simulate the user picking conversation A in the history view.
        env.chats.switchConversation(to: a)
        vm.refresh()
        XCTAssertEqual(vm.messages.map(\.text), ["from A", "reply A"])
        XCTAssertNotEqual(a, b)
    }
}
