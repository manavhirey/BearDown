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

    // MARK: - conversations()

    func test_conversations_returnsEmptyWhenNoMessages() throws {
        let summaries = try repo.conversations()
        XCTAssertEqual(summaries, [])
    }

    func test_conversations_groupsByConversationId_sortedByLastMessageDesc() throws {
        // Conversation A: oldest
        let a = repo.currentConversationId()
        try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .assistant, text: "A2", toolCallsJSON: nil, toolResultsJSON: nil)
        // Archive -> new id minted on next currentConversationId()
        repo.archiveCurrentConversation()
        let b = repo.currentConversationId()
        try repo.append(role: .user, text: "B1", toolCallsJSON: nil, toolResultsJSON: nil)

        let summaries = try repo.conversations()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].id, b, "most-recent conversation should be first")
        XCTAssertEqual(summaries[1].id, a)
    }

    func test_conversations_filtersOutEmptyConversations() throws {
        // Conversation X: only a protocol row (role=.user, text="")
        let x = repo.currentConversationId()
        try repo.append(role: .user, text: "", toolCallsJSON: nil, toolResultsJSON: nil)
        repo.archiveCurrentConversation()
        // Conversation Y: a real user message
        _ = repo.currentConversationId()
        try repo.append(role: .user, text: "hello", toolCallsJSON: nil, toolResultsJSON: nil)

        let summaries = try repo.conversations()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertNotEqual(summaries[0].id, x, "empty conversation should be filtered out")
    }

    func test_conversations_titleIsFirstNonEmptyUserMessage() throws {
        _ = repo.currentConversationId()
        try repo.append(role: .user, text: "", toolCallsJSON: nil, toolResultsJSON: nil)         // skipped
        try repo.append(role: .user, text: "first real", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .assistant, text: "reply", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .user, text: "second real", toolCallsJSON: nil, toolResultsJSON: nil)

        let summaries = try repo.conversations()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].title, "first real")
    }

    func test_conversations_titleFallsBackToNewConversationWhenNoUserText() throws {
        _ = repo.currentConversationId()
        try repo.append(role: .assistant, text: "hi there", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .assistant, text: "still here", toolCallsJSON: nil, toolResultsJSON: nil)

        let summaries = try repo.conversations()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].title, "New conversation")
    }

    func test_conversations_messageCountExcludesProtocolRows() throws {
        _ = repo.currentConversationId()
        try repo.append(role: .user, text: "q1", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .assistant, text: "a1", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .user, text: "", toolCallsJSON: nil, toolResultsJSON: nil) // protocol row
        try repo.append(role: .assistant, text: "a2", toolCallsJSON: nil, toolResultsJSON: nil)

        let summaries = try repo.conversations()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].messageCount, 3, "excludes the empty-text user (protocol) row")
    }

    func test_conversations_isCurrentFlagsTheCurrentConversation() throws {
        let a = repo.currentConversationId()
        try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
        repo.archiveCurrentConversation()
        let b = repo.currentConversationId()
        try repo.append(role: .user, text: "B1", toolCallsJSON: nil, toolResultsJSON: nil)

        let summaries = try repo.conversations()
        let summaryA = summaries.first(where: { $0.id == a })!
        let summaryB = summaries.first(where: { $0.id == b })!
        XCTAssertTrue(summaryB.isCurrent)
        XCTAssertFalse(summaryA.isCurrent)
    }

    // MARK: - switchConversation(to:)

    func test_switchConversation_changesCurrentConversationId() throws {
        let a = repo.currentConversationId()
        try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
        repo.archiveCurrentConversation()
        let b = repo.currentConversationId()
        try repo.append(role: .user, text: "B1", toolCallsJSON: nil, toolResultsJSON: nil)
        XCTAssertEqual(repo.currentConversationId(), b)

        repo.switchConversation(to: a)
        XCTAssertEqual(repo.currentConversationId(), a)
    }

    func test_switchConversation_unknownId_isNoOp() throws {
        let a = repo.currentConversationId()
        try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
        let bogus = UUID()
        repo.switchConversation(to: bogus)
        // Per spec: the call just sets cachedConversationId. messages(in:) returns []
        // for the unknown id; user recovers via the history list.
        XCTAssertEqual(repo.currentConversationId(), bogus)
        XCTAssertEqual(try repo.messages(in: bogus), [])
        // Pre-existing messages for `a` still resolvable explicitly:
        XCTAssertEqual(try repo.messages(in: a).count, 1)
    }

    // MARK: - deleteConversation(id:)

    func test_deleteConversation_removesAllItsMessages() throws {
        let a = repo.currentConversationId()
        try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .assistant, text: "A2", toolCallsJSON: nil, toolResultsJSON: nil)

        try repo.deleteConversation(id: a)
        XCTAssertEqual(try repo.messages(in: a), [])
    }

    func test_deleteConversation_otherConversationsUntouched() throws {
        let a = repo.currentConversationId()
        try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
        repo.archiveCurrentConversation()
        let b = repo.currentConversationId()
        try repo.append(role: .user, text: "B1", toolCallsJSON: nil, toolResultsJSON: nil)
        try repo.append(role: .assistant, text: "B2", toolCallsJSON: nil, toolResultsJSON: nil)

        try repo.deleteConversation(id: a)
        XCTAssertEqual(try repo.messages(in: a), [])
        XCTAssertEqual(try repo.messages(in: b).count, 2)
    }

    func test_deleteConversation_currentMintsAFreshOne() throws {
        let a = repo.currentConversationId()
        try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
        XCTAssertEqual(repo.currentConversationId(), a)

        try repo.deleteConversation(id: a)

        let fresh = repo.currentConversationId()
        XCTAssertNotEqual(fresh, a, "deleting the current conversation should mint a new id")
        XCTAssertEqual(try repo.messages(in: fresh), [],
                       "freshly minted current conversation has no messages")
    }

    func test_deleteConversation_unknownId_isNoOp() throws {
        let a = repo.currentConversationId()
        try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)

        let bogus = UUID()
        XCTAssertNoThrow(try repo.deleteConversation(id: bogus))
        XCTAssertEqual(try repo.messages(in: a).count, 1, "untouched")
        XCTAssertEqual(repo.currentConversationId(), a, "current id unchanged")
    }
}
