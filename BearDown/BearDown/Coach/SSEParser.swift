import Foundation

/// Line-oriented SSE parser for the Anthropic Messages streaming format.
/// Feed it one line at a time; it returns an event when a complete `data:` block is consumed.
public struct SSEParser {
    private var currentEvent: String?

    public init() {}

    public mutating func feed(line: String) -> AnthropicEvent? {
        if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:") else { return nil }
        let json = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        defer { currentEvent = nil }

        switch currentEvent {
        case "message_start":
            return .messageStart
        case "content_block_start":
            let idx = obj["index"] as? Int ?? 0
            let block = obj["content_block"] as? [String: Any] ?? [:]
            let type = block["type"] as? String ?? ""
            if type == "tool_use" {
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                return .contentBlockStart(index: idx, .toolUse(id: id, name: name))
            }
            return .contentBlockStart(index: idx, .text)
        case "content_block_delta":
            let idx = obj["index"] as? Int ?? 0
            let delta = obj["delta"] as? [String: Any] ?? [:]
            let type = delta["type"] as? String ?? ""
            if type == "text_delta", let t = delta["text"] as? String {
                return .contentBlockDelta(index: idx, .text(t))
            }
            if type == "input_json_delta", let p = delta["partial_json"] as? String {
                return .contentBlockDelta(index: idx, .inputJson(p))
            }
            return .unknown(eventName: "content_block_delta")
        case "content_block_stop":
            let idx = obj["index"] as? Int ?? 0
            return .contentBlockStop(index: idx)
        case "message_delta":
            let delta = obj["delta"] as? [String: Any] ?? [:]
            let stop = delta["stop_reason"] as? String
            return .messageDelta(stopReason: stop)
        case "message_stop":
            return .messageStop
        case let other?:
            return .unknown(eventName: other)
        case nil:
            return nil
        }
    }
}
