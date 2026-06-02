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
    private let nav: AppNavigation?

    public init(env: AppEnvironment, nav: AppNavigation? = nil) {
        self.env = env
        self.nav = nav
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
        resolveRetroactiveAppliedPlanIds()
    }

    /// Retroactive proposal chips (synthesized in `computeChips`) lack the repo,
    /// so they leave `appliedPlanId == nil`. After the chip cache is populated,
    /// resolve each retroactive chip's `planTitle` via `PlanRepository.plan(title:)`
    /// so tapping the applied chip can navigate to the still-existing plan.
    /// Memoized per-title because the same title may appear across messages.
    private func resolveRetroactiveAppliedPlanIds() {
        var titleCache: [String: UUID?] = [:]
        for (mid, chips) in chipCache {
            chipCache[mid] = chips.map { chip -> CoachChip in
                guard case .proposal(let p) = chip,
                      p.isRetroactive,
                      p.envelope.status == .applied,
                      p.envelope.appliedPlanId == nil else { return chip }
                let title = p.envelope.planTitle
                let resolvedId: UUID?
                if let cached = titleCache[title] {
                    resolvedId = cached
                } else {
                    resolvedId = (try? env.plans.plan(title: title))?.id
                    titleCache[title] = resolvedId
                }
                guard let resolvedId else { return chip }
                var newEnv = p.envelope
                newEnv.appliedPlanId = resolvedId
                return .proposal(ProposalChip(
                    id: p.id, messageId: p.messageId, toolUseId: p.toolUseId,
                    envelope: newEnv,
                    workoutCount: p.workoutCount,
                    firstDate: p.firstDate, lastDate: p.lastDate,
                    isRetroactive: true
                ))
            }
        }
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
        // Decode tool results once.
        var resultsArr: [[String: Any]] = []
        if let raw = m.toolResultsJSON,
           let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
            resultsArr = arr
        }
        // Decode tool calls once.
        var callsArr: [[String: Any]] = []
        if let raw = m.toolCallsJSON,
           let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
            callsArr = arr
        }

        // Pass 1 — real proposals (decoded envelopes).
        var proposalChips: [CoachChip] = []
        var switchChips: [CoachChip] = []
        var seenPlanIds = Set<UUID>()

        for dict in resultsArr {
            guard let content = dict["content"] as? String else { continue }
            if let env = ProposalCodec.decode(contentString: content) {
                let toolUseId = (dict["tool_use_id"] as? String) ?? ""
                let dates = env.workouts.map(\.date).sorted()
                proposalChips.append(.proposal(ProposalChip(
                    id: "\(m.id.uuidString)-\(toolUseId)",
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
                switchChips.append(.planSwitch(.init(
                    id: "switch-\(parsed.id.uuidString)",
                    label: "Switch to: \(parsed.title)",
                    isError: false,
                    workoutDate: nil,
                    planId: parsed.id
                )))
            }
        }

        // Pass 2 — retroactive grouping. Group upsert_workout calls in this message
        // by `plan_title`. Groups of size >= 2 collapse into a virtual applied-state
        // proposal chip. Singletons fall through to per-workout rendering.
        struct RetroGroup { var title: String?; var calls: [(id: String, input: [String: Any])] }
        var groups: [String: RetroGroup] = [:]   // key = plan_title or "" for none
        var absorbedToolUseIds = Set<String>()
        for dict in callsArr {
            guard (dict["name"] as? String) == "upsert_workout" else { continue }
            let id = (dict["id"] as? String) ?? ""
            let input = (dict["input"] as? [String: Any]) ?? [:]
            let title = (input["plan_title"] as? String).flatMap {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
            let key = title ?? ""
            groups[key, default: RetroGroup(title: title, calls: [])].calls.append((id, input))
        }
        for (_, group) in groups where group.calls.count >= 2 {
            let title = group.title ?? "Updated plan"
            let mode: ProposalEnvelope.Mode = (group.title == nil) ? .update : .add
            let goal = (group.calls.first?.input["plan_goal"] as? String) ?? ""
            let dates = group.calls.compactMap { ($0.input["date"] as? String).flatMap(parseIso) }.sorted()
            let envelope = ProposalEnvelope(
                mode: mode, status: .applied,
                planTitle: title, planGoal: goal,
                planId: nil,
                appliedPlanId: nil,             // resolved by caller via PlanRepository.plan(title:) — see Task 19
                appliedAt: nil,
                appliedMode: (mode == .update ? .update : .switchPlan),
                workouts: group.calls.compactMap { call -> ProposalWorkout? in
                    guard let dateStr = call.input["date"] as? String,
                          let date = parseIso(dateStr) else { return nil }
                    return ProposalWorkout(
                        date: date,
                        title: (call.input["title"] as? String) ?? "",
                        summary: (call.input["summary"] as? String) ?? "",
                        blocks: []   // we don't try to reconstruct blocks; the chip only uses count + dates
                    )
                }
            )
            let chipId = "retro-\(m.id.uuidString)-\(title.hashValue)"
            proposalChips.append(.proposal(ProposalChip(
                id: chipId, messageId: m.id, toolUseId: "retro",
                envelope: envelope,
                workoutCount: group.calls.count,
                firstDate: dates.first, lastDate: dates.last,
                isRetroactive: true
            )))
            for c in group.calls { absorbedToolUseIds.insert(c.id) }
        }

        // Pass 3 — workout/per-call chips. Skip anything absorbed by retroactive grouping.
        var workoutChips: [CoachChip] = []
        for dict in callsArr {
            let id = (dict["id"] as? String) ?? UUID().uuidString
            let name = (dict["name"] as? String) ?? "?"
            let input = (dict["input"] as? [String: Any]) ?? [:]
            switch name {
            case "upsert_workout":
                if absorbedToolUseIds.contains(id) { continue }
                let date = input["date"] as? String ?? "?"
                let title = input["title"] as? String ?? "Workout"
                workoutChips.append(.workout(.init(
                    id: id, label: "Scheduled \(title) — \(date)",
                    isError: false, workoutDate: parseIso(date))))
            case "delete_workout":
                let date = input["date"] as? String ?? "?"
                workoutChips.append(.workout(.init(
                    id: id, label: "Deleted workout on \(date)",
                    isError: false, workoutDate: parseIso(date))))
            case "get_recent_history":
                workoutChips.append(.workout(.init(
                    id: id, label: "Reviewed recent history",
                    isError: false, workoutDate: nil)))
            case "propose_plan", "propose_plan_update":
                break
            default:
                workoutChips.append(.workout(.init(
                    id: id, label: "Called \(name)",
                    isError: false, workoutDate: nil)))
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

    public func applyProposal(_ chip: ProposalChip, mode: ProposalApplyMode) async {
        do {
            let applyMode: ProposalApplyService.ApplyMode
            switch mode {
            case .addInactive:   applyMode = .addInactive
            case .addAndSwitch:  applyMode = .addAndSwitch
            case .update:        applyMode = .update
            }
            let result = try env.proposals.apply(chip.envelope, mode: applyMode)
            try writebackEnvelope(messageId: chip.messageId, toolUseId: chip.toolUseId) { env in
                env.status = .applied
                env.appliedPlanId = result.planId
                env.appliedAt = .now
                env.appliedMode = result.appliedMode
            }
            if mode == .addAndSwitch, let nav {
                nav.selectedTab = 1
                nav.pendingPlanDetail = result.planId
            }
            refresh()
        } catch {
            state = .error("Couldn't apply this plan: \(error.localizedDescription)")
        }
    }

    public func dismissProposal(_ chip: ProposalChip) {
        do {
            try writebackEnvelope(messageId: chip.messageId, toolUseId: chip.toolUseId) { env in
                env.status = .dismissed
            }
            refresh()
        } catch {
            state = .error("Couldn't dismiss: \(error.localizedDescription)")
        }
    }

    public func navigateToAppliedProposal(_ chip: ProposalChip) {
        guard let nav, let pid = chip.envelope.appliedPlanId else { return }
        nav.selectedTab = 1
        nav.pendingPlanDetail = pid
    }

    /// Decode toolResultsJSON, locate the entry matching toolUseId, mutate its
    /// envelope via `mutate`, re-encode, and persist via ChatRepository.
    private func writebackEnvelope(messageId: UUID,
                                   toolUseId: String,
                                   mutate: (inout ProposalEnvelope) -> Void) throws {
        let convId = env.chats.currentConversationId()
        let msgs = try env.chats.messages(in: convId)
        guard let target = msgs.first(where: { $0.id == messageId }),
              let raw = target.toolResultsJSON,
              var arr = (try JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]]
        else { throw RepositoryError.workoutNotFound }

        for i in 0..<arr.count {
            guard (arr[i]["tool_use_id"] as? String) == toolUseId,
                  let content = arr[i]["content"] as? String,
                  var decoded = ProposalCodec.decode(contentString: content)
            else { continue }
            mutate(&decoded)
            arr[i]["content"] = try ProposalCodec.encode(decoded)
        }
        let newData = try JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])
        let newJSON = String(data: newData, encoding: .utf8) ?? "[]"
        try env.chats.replaceToolResults(messageId: messageId, newJSON: newJSON)
    }
}
