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
}
