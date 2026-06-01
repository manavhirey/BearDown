import Foundation

// `@unchecked Sendable` because `[String: Any]` payloads in ContentBlock.toolUse and Tool.inputSchema
// cannot be statically verified as Sendable; the dynamic JSON shape is intentional by design.
public struct AnthropicRequest: Encodable, @unchecked Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: String?
    public var messages: [Message]
    public var tools: [Tool]
    public var stream: Bool = true

    public init(model: String, maxTokens: Int, system: String?,
                messages: [Message], tools: [Tool]) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.tools = tools
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
        case stream
    }

    public struct Message: Encodable {
        public var role: String
        public var content: [ContentBlock]
        public init(role: String, content: [ContentBlock]) {
            self.role = role
            self.content = content
        }
    }

    public enum ContentBlock: Encodable, @unchecked Sendable {
        case text(String)
        case toolUse(id: String, name: String, input: [String: Any])
        case toolResult(toolUseId: String, content: String, isError: Bool)

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            switch self {
            case let .text(s):
                try c.encode("text", forKey: AnyKey("type"))
                try c.encode(s, forKey: AnyKey("text"))
            case let .toolUse(id, name, input):
                try c.encode("tool_use", forKey: AnyKey("type"))
                try c.encode(id, forKey: AnyKey("id"))
                try c.encode(name, forKey: AnyKey("name"))
                let data = try JSONSerialization.data(withJSONObject: input)
                let dyn = try JSONDecoder().decode(JSONAny.self, from: data)
                try c.encode(dyn, forKey: AnyKey("input"))
            case let .toolResult(toolUseId, content, isError):
                try c.encode("tool_result", forKey: AnyKey("type"))
                try c.encode(toolUseId, forKey: AnyKey("tool_use_id"))
                try c.encode(content, forKey: AnyKey("content"))
                try c.encode(isError, forKey: AnyKey("is_error"))
            }
        }
    }

    public struct Tool: Encodable, @unchecked Sendable {
        public var name: String
        public var description: String
        public var inputSchema: [String: Any]

        public init(name: String, description: String, inputSchema: [String: Any]) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(description, forKey: .description)
            let data = try JSONSerialization.data(withJSONObject: inputSchema)
            let dyn = try JSONDecoder().decode(JSONAny.self, from: data)
            try c.encode(dyn, forKey: .inputSchema)
        }
    }
}

/// Type-erased JSON value (for nested unknown-shape dictionaries).
/// `@unchecked Sendable` because `value: Any` cannot be statically verified as Sendable;
/// callers are responsible for passing only sendable JSON-compatible values.
public struct JSONAny: Codable, @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self.value = NSNull(); return }
        if let v = try? container.decode(Bool.self) { self.value = v; return }
        if let v = try? container.decode(Int.self) { self.value = v; return }
        if let v = try? container.decode(Double.self) { self.value = v; return }
        if let v = try? container.decode(String.self) { self.value = v; return }
        if let v = try? container.decode([JSONAny].self) { self.value = v.map(\.value); return }
        if let v = try? container.decode([String: JSONAny].self) {
            self.value = v.mapValues(\.value); return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map(JSONAny.init))
        case let v as [String: Any]: try c.encode(v.mapValues(JSONAny.init))
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: c.codingPath, debugDescription: "Unsupported"))
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { self.stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
