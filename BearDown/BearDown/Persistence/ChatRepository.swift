import Foundation
import SwiftData

@MainActor
public final class ChatRepository {
    private let context: ModelContext
    private var cachedConversationId: UUID?

    public init(context: ModelContext) {
        self.context = context
    }

    public func currentConversationId() -> UUID {
        if let id = cachedConversationId { return id }
        // Pick the conversation id of the most recent message, else mint a new one.
        var d = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        d.fetchLimit = 1
        if let latest = try? context.fetch(d).first {
            cachedConversationId = latest.conversationId
        } else {
            cachedConversationId = UUID()
        }
        return cachedConversationId!
    }

    public func archiveCurrentConversation() {
        cachedConversationId = UUID()
    }

    public func append(role: ChatRole, text: String,
                       toolCallsJSON: String?, toolResultsJSON: String?) throws {
        let cid = currentConversationId()
        let m = ChatMessage(role: role, text: text, conversationId: cid)
        m.toolCallsJSON = toolCallsJSON
        m.toolResultsJSON = toolResultsJSON
        context.insert(m)
        try context.save()
    }

    public func messages(in conversationId: UUID) throws -> [ChatMessage] {
        try context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.createdAt)]
        ))
    }
}
