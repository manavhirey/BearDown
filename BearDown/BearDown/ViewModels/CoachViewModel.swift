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


    @Published public var messages: [ChatMessage] = []
    @Published public var draft: String = ""
    @Published public var state: State = .idle
    @Published public var liveAssistantText: String = ""
    @Published public private(set) var lastUserText: String?

    private var chipCache: [UUID: [ChatBubble.ToolChip]] = [:]
    private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
        self.env.coach.onTextDelta = { [weak self] delta in
            Task { @MainActor in self?.liveAssistantText += delta }
        }
        // Initial data load happens via the owning view's .onAppear.
    }

    public func refresh() {
        let id = env.chats.currentConversationId()
        let msgs = (try? env.chats.messages(in: id)) ?? []
        messages = msgs
        chipCache = Dictionary(uniqueKeysWithValues:
            msgs.map { ($0.id, Self.computeChips(from: $0)) })
    }

    /// Pre-computed tool-call chips for an assistant message. O(1) lookup.
    public func chips(for message: ChatMessage) -> [ChatBubble.ToolChip] {
        chipCache[message.id] ?? []
    }

    private static func computeChips(from m: ChatMessage) -> [ChatBubble.ToolChip] {
        guard let raw = m.toolCallsJSON,
              let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict in
            let id = (dict["id"] as? String) ?? UUID().uuidString
            let name = (dict["name"] as? String) ?? "?"
            let input = (dict["input"] as? [String: Any]) ?? [:]
            switch name {
            case "upsert_workout":
                let date = input["date"] as? String ?? "?"
                let title = input["title"] as? String ?? "Workout"
                return .init(id: id, label: "Scheduled \(title) — \(date)",
                             isError: false, workoutDate: parseIso(date))
            case "delete_workout":
                let date = input["date"] as? String ?? "?"
                return .init(id: id, label: "Deleted workout on \(date)",
                             isError: false, workoutDate: parseIso(date))
            case "get_recent_history":
                return .init(id: id, label: "Reviewed recent history",
                             isError: false, workoutDate: nil)
            default:
                return .init(id: id, label: "Called \(name)",
                             isError: false, workoutDate: nil)
            }
        }
    }

    private static func parseIso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
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
        // Show the user's bubble immediately. runSend persists + refreshes,
        // but only after the entire stream completes — without this optimistic
        // append, the user wouldn't see their own message during streaming.
        let cid = env.chats.currentConversationId()
        messages.append(ChatMessage(role: .user, text: trimmed, conversationId: cid))
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
