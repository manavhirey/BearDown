import Combine
import Foundation

@MainActor
public final class ChatHistoryViewModel: ObservableObject {
    @Published public private(set) var conversations: [ConversationSummary] = []

    private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
        // Cheap init — no repo calls. The owning view's .onAppear triggers refresh().
    }

    public func refresh() {
        conversations = (try? env.chats.conversations()) ?? []
    }

    public func delete(id: UUID) {
        // Silent-swallow per spec: destructive alert is the user gate; a real SwiftData
        // write failure is rare and the row would reappear on next refresh as the
        // visible failure mode. If we later want explicit error UX, add a
        // `lastError: String?` field and surface via `.alert`.
        try? env.chats.deleteConversation(id: id)
        refresh()
    }

    public func switchTo(id: UUID) {
        env.chats.switchConversation(to: id)
        // No refresh — the calling view dismisses, and CoachView's .onAppear
        // re-reads currentConversationId() through CoachViewModel.refresh().
    }
}
