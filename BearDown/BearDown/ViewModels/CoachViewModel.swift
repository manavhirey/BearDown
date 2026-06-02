import Combine
import Foundation
import SwiftData

public enum CoachChip: Identifiable, Equatable {
    case workout(ChatBubble.ToolChip)
    case planSwitch(ChatBubble.ToolChip)
    case proposal(ProposalChip)

    public var id: String {
        switch self {
        case .workout(let c): return "w-\(c.id)"
        case .planSwitch(let c): return "s-\(c.id)"
        case .proposal(let p): return "p-\(p.id)"
        }
    }
}

/// View-ready snapshot of a proposal envelope, paired with the source message
/// info needed to write status changes back through ChatRepository.
public struct ProposalChip: Identifiable, Equatable {
    public let id: String           // stable: messageId-toolUseId
    public let messageId: UUID
    public let toolUseId: String
    public let envelope: ProposalEnvelope
    public let workoutCount: Int    // pre-computed for sub-label rendering
    public let firstDate: Date?
    public let lastDate: Date?
    /// True if this chip is a retroactive applied-state synthesis (from pre-feature
    /// chat history). Not user-actionable: no buttons, no tap-target if appliedPlanId
    /// can't be resolved. Filled by computeChips() — see Task 16.
    public let isRetroactive: Bool

    public init(id: String, messageId: UUID, toolUseId: String,
                envelope: ProposalEnvelope,
                workoutCount: Int, firstDate: Date?, lastDate: Date?,
                isRetroactive: Bool = false) {
        self.id = id; self.messageId = messageId; self.toolUseId = toolUseId
        self.envelope = envelope
        self.workoutCount = workoutCount
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.isRetroactive = isRetroactive
    }
}

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

    private var chipCache: [UUID: [CoachChip]] = [:]
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
        // CoachService persists tool-result rows as role=.user with empty text
        // (required by Anthropic's tool-use API for replay). They're protocol
        // metadata, not conversation — hide them from the UI.
        let visible = msgs.filter { !($0.role == .user && $0.text.isEmpty) }
        messages = visible
        chipCache = Dictionary(uniqueKeysWithValues:
            visible.map { ($0.id, Self.computeChips(from: $0)) })
    }

    /// Pre-computed tool-call chips for an assistant message. O(1) lookup.
    public func chips(for message: ChatMessage) -> [CoachChip] {
        chipCache[message.id] ?? []
    }

    // Test seam — same body as the real computeChips, mirrors its signature.
    internal static func computeChipsForTest(from m: ChatMessage) -> [CoachChip] {
        computeChips(from: m)
    }

    private static func computeChips(from m: ChatMessage) -> [CoachChip] {
        var proposalChips: [CoachChip] = []
        var switchChips: [CoachChip] = []
        var workoutChips: [CoachChip] = []
        var seenPlanIds = Set<UUID>()

        // Pass 1 — tool results. Try envelope decode; fall back to plan-switch parser.
        var resultsArr: [[String: Any]] = []
        if let raw = m.toolResultsJSON,
           let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
            resultsArr = arr
        }
        for dict in resultsArr {
            guard let content = dict["content"] as? String else { continue }
            if let env = ProposalCodec.decode(contentString: content) {
                let toolUseId = (dict["tool_use_id"] as? String) ?? ""
                let id = "\(m.id.uuidString)-\(toolUseId)"
                let dates = env.workouts.map(\.date).sorted()
                proposalChips.append(.proposal(ProposalChip(
                    id: id,
                    messageId: m.id,
                    toolUseId: toolUseId,
                    envelope: env,
                    workoutCount: env.workouts.count,
                    firstDate: dates.first,
                    lastDate: dates.last,
                    isRetroactive: false
                )))
            } else if let parsed = parsePlanSwitchMarker(in: content),
                      seenPlanIds.insert(parsed.id).inserted {
                let tc = ChatBubble.ToolChip(
                    id: "switch-\(parsed.id.uuidString)",
                    label: "Switch to: \(parsed.title)",
                    isError: false,
                    workoutDate: nil,
                    planId: parsed.id
                )
                switchChips.append(.planSwitch(tc))
            }
        }

        // Pass 2 — tool calls.
        if let raw = m.toolCallsJSON,
           let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
            for dict in arr {
                let id = (dict["id"] as? String) ?? UUID().uuidString
                let name = (dict["name"] as? String) ?? "?"
                let input = (dict["input"] as? [String: Any]) ?? [:]
                switch name {
                case "upsert_workout":
                    let date = input["date"] as? String ?? "?"
                    let title = input["title"] as? String ?? "Workout"
                    workoutChips.append(.workout(.init(
                        id: id,
                        label: "Scheduled \(title) — \(date)",
                        isError: false,
                        workoutDate: parseIso(date)
                    )))
                case "delete_workout":
                    let date = input["date"] as? String ?? "?"
                    workoutChips.append(.workout(.init(
                        id: id,
                        label: "Deleted workout on \(date)",
                        isError: false,
                        workoutDate: parseIso(date)
                    )))
                case "get_recent_history":
                    workoutChips.append(.workout(.init(
                        id: id, label: "Reviewed recent history",
                        isError: false, workoutDate: nil
                    )))
                case "propose_plan", "propose_plan_update":
                    break  // surfaced via proposalChips above
                default:
                    workoutChips.append(.workout(.init(
                        id: id, label: "Called \(name)",
                        isError: false, workoutDate: nil
                    )))
                }
            }
        }

        return proposalChips + switchChips + workoutChips
    }

    /// Parses `... in plan "<title>" (plan_id=<uuid>).` out of a tool result string.
    /// Returns nil if the marker is absent (the common case — writes to the active plan).
    private static func parsePlanSwitchMarker(in content: String) -> (id: UUID, title: String)? {
        guard let idRange = content.range(of: "plan_id=") else { return nil }
        let after = content[idRange.upperBound...]
        let uuidStr = after.prefix(36)
        guard uuidStr.count == 36, let id = UUID(uuidString: String(uuidStr)) else { return nil }

        // Title sits between the first `in plan "` and the next `"`.
        guard let titleStart = content.range(of: "in plan \"") else {
            return (id, "plan")
        }
        let titleTail = content[titleStart.upperBound...]
        guard let titleEnd = titleTail.range(of: "\"") else {
            return (id, "plan")
        }
        let title = String(titleTail[..<titleEnd.lowerBound])
        return (id, title)
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
