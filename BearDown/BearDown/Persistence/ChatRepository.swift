import Foundation
import SwiftData

/// Aggregated view of a single conversation derived from `ChatMessage` rows.
/// Declared alongside `ChatRepository` because it's strictly a repo-shaped value type
/// (same precedent as `HistoryEntry` in this codebase).
public struct ConversationSummary: Identifiable, Equatable, Sendable {
    public let id: UUID                  // the conversationId
    public let title: String             // first non-empty user message, OR "New conversation"
    public let lastMessageAt: Date
    public let messageCount: Int         // excludes role=.user/text="" protocol rows
    public let isCurrent: Bool

    public init(id: UUID,
                title: String,
                lastMessageAt: Date,
                messageCount: Int,
                isCurrent: Bool) {
        self.id = id
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.isCurrent = isCurrent
    }
}

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

    /// All conversations as summaries, sorted by `lastMessageAt` descending.
    /// Empty conversations (`messageCount == 0` after filtering protocol rows) are excluded.
    public func conversations() throws -> [ConversationSummary] {
        // SwiftData #Predicate doesn't support GROUP BY; we fetch sorted and group in-memory.
        // n is bounded (<10k over app lifetime) so the O(n) pass is fine.
        let all = try context.fetch(FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))
        let currentId = currentConversationId()

        var orderedIds: [UUID] = []
        var groups: [UUID: [ChatMessage]] = [:]
        for m in all {
            if groups[m.conversationId] == nil {
                groups[m.conversationId] = []
                orderedIds.append(m.conversationId)
            }
            groups[m.conversationId]!.append(m)
        }

        var summaries: [ConversationSummary] = []
        for cid in orderedIds {
            let msgs = groups[cid]!
            let visible = msgs.filter { !($0.role == .user && $0.text.isEmpty) }
            let count = visible.count
            if count == 0 { continue } // empty / protocol-only conversation
            let title = msgs.first(where: { $0.role == .user && !$0.text.isEmpty })?.text
                ?? "New conversation"
            let lastAt = msgs.last?.createdAt ?? Date()
            summaries.append(ConversationSummary(
                id: cid,
                title: title,
                lastMessageAt: lastAt,
                messageCount: count,
                isCurrent: cid == currentId
            ))
        }
        return summaries.sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    /// Switch the active conversation. No-op semantics if `id` doesn't correspond to
    /// any stored messages — `messages(in:)` will return `[]` and CoachView will render
    /// the blank composer; the user recovers via the history list.
    public func switchConversation(to id: UUID) {
        cachedConversationId = id
    }

    /// Delete all messages with this `conversationId`. If `id` was the cached current,
    /// mints a fresh `UUID` for the new current (same end-state as
    /// `archiveCurrentConversation()`).
    public func deleteConversation(id: UUID) throws {
        let rows = try context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.conversationId == id }
        ))
        for row in rows {
            context.delete(row)
        }
        try context.save()
        if cachedConversationId == id {
            cachedConversationId = UUID()
        }
    }

    public func replaceToolResults(messageId: UUID, newJSON: String) throws {
        let rows = try context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.id == messageId }
        ))
        guard let m = rows.first else { throw RepositoryError.workoutNotFound }
        if m.toolResultsJSON == newJSON { return }   // idempotent
        m.toolResultsJSON = newJSON
        try context.save()
    }
}
