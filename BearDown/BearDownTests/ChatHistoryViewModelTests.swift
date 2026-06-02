import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class ChatHistoryViewModelTests: XCTestCase {
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        env = AppEnvironment(
            modelContainer: container,
            keychain: KeychainStore(service: "com.beardown.tests.chathistoryvm.\(UUID().uuidString)"),
            anthropic: ScriptedAnthropicClient()
        )
    }

    func test_refresh_populatesConversationsFromRepo() throws {
        // Two conversations, both with a real user message.
        let a = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "first", toolCallsJSON: nil, toolResultsJSON: nil)
        env.chats.archiveCurrentConversation()
        let b = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "second", toolCallsJSON: nil, toolResultsJSON: nil)

        let vm = ChatHistoryViewModel(env: env)
        XCTAssertTrue(vm.conversations.isEmpty, "cheap init does not load")
        vm.refresh()
        XCTAssertEqual(vm.conversations.count, 2)
        XCTAssertEqual(vm.conversations[0].id, b, "most-recent first")
        XCTAssertEqual(vm.conversations[1].id, a)
    }

    func test_delete_callsRepoAndRefreshes() throws {
        let a = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "doomed", toolCallsJSON: nil, toolResultsJSON: nil)
        env.chats.archiveCurrentConversation()
        _ = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "kept", toolCallsJSON: nil, toolResultsJSON: nil)

        let vm = ChatHistoryViewModel(env: env)
        vm.refresh()
        XCTAssertEqual(vm.conversations.count, 2)

        vm.delete(id: a)
        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertFalse(vm.conversations.contains(where: { $0.id == a }))
    }

    func test_switchTo_changesRepoCurrentId_withoutRefreshingThisVM() throws {
        let a = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "A", toolCallsJSON: nil, toolResultsJSON: nil)
        env.chats.archiveCurrentConversation()
        let b = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "B", toolCallsJSON: nil, toolResultsJSON: nil)

        let vm = ChatHistoryViewModel(env: env)
        vm.refresh()
        // Sanity: B is the current conversation before the switch.
        XCTAssertTrue(vm.conversations.first(where: { $0.id == b })!.isCurrent)
        XCTAssertFalse(vm.conversations.first(where: { $0.id == a })!.isCurrent)

        vm.switchTo(id: a)

        // Repo state has changed:
        XCTAssertEqual(env.chats.currentConversationId(), a)
        // But vm.conversations is intentionally stale — the caller dismisses, CoachView
        // re-reads via its own onAppear → CoachViewModel.refresh().
        XCTAssertTrue(vm.conversations.first(where: { $0.id == b })!.isCurrent,
                      "vm should NOT have auto-refreshed isCurrent flags")
    }
}
