import Combine
import Foundation
import SwiftData

@MainActor
public final class CoachViewModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case streaming
        case error(String)
    }

    public nonisolated let objectWillChange = PassthroughSubject<Void, Never>()

    @Published public var messages: [ChatMessage] = []
    @Published public var draft: String = ""
    @Published public var state: State = .idle
    @Published public var liveAssistantText: String = ""
    @Published public private(set) var lastUserText: String?

    private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
        self.env.coach.onTextDelta = { [weak self] delta in
            Task { @MainActor in self?.liveAssistantText += delta }
        }
        refresh()
    }

    public func refresh() {
        let id = env.chats.currentConversationId()
        messages = (try? env.chats.messages(in: id)) ?? []
    }

    public func newChat() {
        env.chats.archiveCurrentConversation()
        refresh()
    }

    public func send() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        lastUserText = trimmed
        await runSend(userText: trimmed)
    }

    /// Replays the most recent user turn. Used by the inline "Send failed — Retry" affordance.
    public func retry() async {
        guard let text = lastUserText, state != .streaming else { return }
        await runSend(userText: text)
    }

    private func runSend(userText: String) async {
        liveAssistantText = ""
        state = .streaming
        do {
            try await env.coach.send(userText: userText)
            state = .idle
        } catch let e as CoachError {
            state = .error(e.errorDescription ?? "Error")
        } catch {
            state = .error(error.localizedDescription)
        }
        liveAssistantText = ""
        refresh()
    }
}
