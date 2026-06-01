import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class ChatRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var repo: ChatRepository!

    override func setUpWithError() throws {
        container = try .beardownInMemory()
        repo = ChatRepository(context: container.mainContext)
    }

    func test_currentConversation_isStableUntilArchived() {
        let a = repo.currentConversationId()
        let b = repo.currentConversationId()
        XCTAssertEqual(a, b)
    }

    func test_archive_startsANewConversationId() {
        let a = repo.currentConversationId()
        repo.archiveCurrentConversation()
        let b = repo.currentConversationId()
        XCTAssertNotEqual(a, b)
    }

    func test_append_storesMessageInCurrentConversation() throws {
        let cid = repo.currentConversationId()
        try repo.append(role: .user, text: "hi", toolCallsJSON: nil, toolResultsJSON: nil)
        let msgs = try repo.messages(in: cid)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].text, "hi")
        XCTAssertEqual(msgs[0].role, .user)
    }

    func test_messagesInConversation_areOrderedByCreatedAt() throws {
        let cid = repo.currentConversationId()
        try repo.append(role: .user, text: "1", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .assistant, text: "2", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .user, text: "3", toolCallsJSON: nil, toolResultsJSON: nil)
        let msgs = try repo.messages(in: cid)
        XCTAssertEqual(msgs.map(\.text), ["1", "2", "3"])
    }
}
