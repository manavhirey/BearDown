import Foundation
import SwiftData

@MainActor
public final class CoachService {
    public static let maxToolIterations = 10
    public static let maxResponseTokens = 8192
    public static let model = "claude-sonnet-4-6"

    private let client: AnthropicClientProtocol
    private let keychain: KeychainStore
    private let chats: ChatRepository
    private let tools: CoachTools
    private let workouts: WorkoutRepository
    private let plans: PlanRepository

    /// Optional callback invoked for every text delta during streaming so the UI can render live.
    public var onTextDelta: ((String) -> Void)?

    public init(client: AnthropicClientProtocol,
                keychain: KeychainStore,
                chats: ChatRepository,
                tools: CoachTools,
                workouts: WorkoutRepository,
                plans: PlanRepository) {
        self.client = client
        self.keychain = keychain
        self.chats = chats
        self.tools = tools
        self.workouts = workouts
        self.plans = plans
    }

    public func send(userText: String) async throws {
        guard let apiKey = try keychain.read(key: .anthropicAPIKey), !apiKey.isEmpty else {
            throw CoachError.missingAPIKey
        }
        try chats.append(role: .user, text: userText,
                         toolCallsJSON: nil, toolResultsJSON: nil)

        let convId = chats.currentConversationId()
        var iter = 0
        while iter < Self.maxToolIterations {
            iter += 1
            let history = try chats.messages(in: convId)
            let req = try await buildRequest(history: history)

            var accumulatedText = ""
            var indexedToolCalls: [Int: PendingToolCall] = [:]
            var stopReason: String?

            for try await event in client.stream(apiKey: apiKey, request: req) {
                switch event {
                case .contentBlockStart(let idx, .toolUse(let id, let name)):
                    indexedToolCalls[idx] = PendingToolCall(id: id, name: name, jsonBuf: "")
                case .contentBlockStart, .messageStart:
                    break
                case .contentBlockDelta(_, .text(let t)):
                    accumulatedText += t
                    onTextDelta?(t)
                case .contentBlockDelta(let idx, .inputJson(let p)):
                    indexedToolCalls[idx]?.jsonBuf += p
                case .contentBlockStop:
                    break
                case .messageDelta(let stop):
                    stopReason = stop
                case .messageStop:
                    break
                case .unknown:
                    break
                }
            }

            let pendingToolCalls: [PendingToolCall] = indexedToolCalls
                .sorted { $0.key < $1.key }
                .map(\.value)

            // Persist the assistant message.
            let callsJSON: String? = pendingToolCalls.isEmpty ? nil
                : (try? encodeToolCalls(pendingToolCalls))
            try chats.append(role: .assistant, text: accumulatedText,
                             toolCallsJSON: callsJSON, toolResultsJSON: nil)

            // If no tool use, we're done.
            guard stopReason == "tool_use", !pendingToolCalls.isEmpty else {
                return
            }

            // Execute each tool, build the tool_result user message.
            var results: [(id: String, content: String, isError: Bool)] = []
            for call in pendingToolCalls {
                let inputObj = (try? JSONSerialization.jsonObject(
                    with: Data(call.jsonBuf.utf8))) as? [String: Any] ?? [:]
                let result = (try? tools.dispatch(name: call.name, input: inputObj))
                    ?? ToolResult(content: "Tool dispatch crashed.", isError: true)
                results.append((call.id, result.content, result.isError))
            }
            let resultsJSON = try encodeToolResults(results)
            try chats.append(role: .user, text: "",
                             toolCallsJSON: nil, toolResultsJSON: resultsJSON)
        }
        throw CoachError.toolLoopLimitExceeded
    }

    private struct PendingToolCall {
        let id: String
        let name: String
        var jsonBuf: String
    }

    private func encodeToolCalls(_ calls: [PendingToolCall]) throws -> String {
        let arr: [[String: Any]] = calls.map {
            let parsed = (try? JSONSerialization.jsonObject(with: Data($0.jsonBuf.utf8))) ?? [:]
            return ["type": "tool_use", "id": $0.id, "name": $0.name, "input": parsed]
        }
        let data = try JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func encodeToolResults(_ results: [(id: String, content: String, isError: Bool)]) throws -> String {
        let arr: [[String: Any]] = results.map {
            ["type": "tool_result", "tool_use_id": $0.id, "content": $0.content, "is_error": $0.isError]
        }
        let data = try JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func buildRequest(history: [ChatMessage]) async throws -> AnthropicRequest {
        let active = try plans.activePlan()
        let snapshot: TrainingPlanSnapshot? = active.map { plan in
            let cal = Calendar.current
            let totalDays = max(1, cal.dateComponents([.day], from: plan.startDate, to: plan.endDate).day ?? 0)
            let totalWeeks = max(1, Int(ceil(Double(totalDays) / 7.0)))
            let elapsedDays = cal.dateComponents([.day], from: plan.startDate, to: .now).day ?? 0
            let weekNumber = max(1, min(totalWeeks, (elapsedDays / 7) + 1))
            return TrainingPlanSnapshot(title: plan.title,
                                        planId: plan.id,
                                        weekNumber: weekNumber,
                                        totalWeeks: totalWeeks,
                                        startDate: plan.startDate,
                                        endDate: plan.endDate)
        }
        let history14 = try workouts.recentHistory(days: 14)
        let system = CoachPrompt.assembled(today: .now, plan: snapshot, history: history14)

        let messages = try Self.convertToAPIMessages(history: history)

        return AnthropicRequest(
            model: Self.model,
            maxTokens: Self.maxResponseTokens,
            system: system,
            messages: messages,
            tools: tools.definitions
        )
    }

    /// Convert persisted ChatMessage rows into Anthropic API message content blocks.
    static func convertToAPIMessages(history: [ChatMessage]) throws -> [AnthropicRequest.Message] {
        var out: [AnthropicRequest.Message] = []
        for m in history {
            switch m.role {
            case .user:
                if let resultsJSON = m.toolResultsJSON,
                   let arr = try? JSONSerialization.jsonObject(with: Data(resultsJSON.utf8)) as? [[String: Any]] {
                    let blocks: [AnthropicRequest.ContentBlock] = arr.compactMap {
                        guard let id = $0["tool_use_id"] as? String,
                              let content = $0["content"] as? String else { return nil }
                        return .toolResult(toolUseId: id, content: content,
                                           isError: ($0["is_error"] as? Bool) ?? false)
                    }
                    out.append(.init(role: "user", content: blocks))
                } else {
                    out.append(.init(role: "user", content: [.text(m.text)]))
                }
            case .assistant:
                var blocks: [AnthropicRequest.ContentBlock] = []
                if !m.text.isEmpty { blocks.append(.text(m.text)) }
                if let callsJSON = m.toolCallsJSON,
                   let arr = try? JSONSerialization.jsonObject(with: Data(callsJSON.utf8)) as? [[String: Any]] {
                    for c in arr {
                        guard let id = c["id"] as? String,
                              let name = c["name"] as? String else { continue }
                        let input = (c["input"] as? [String: Any]) ?? [:]
                        blocks.append(.toolUse(id: id, name: name, input: input))
                    }
                }
                if blocks.isEmpty { blocks.append(.text("")) }
                out.append(.init(role: "assistant", content: blocks))
            }
        }
        return out
    }
}
