import Foundation

public enum ContentBlockStart: Equatable {
    case text
    case toolUse(id: String, name: String)
}

public enum ContentBlockDelta: Equatable {
    case text(String)
    case inputJson(String)
}

public enum AnthropicEvent: Equatable {
    case messageStart
    case contentBlockStart(index: Int, ContentBlockStart)
    case contentBlockDelta(index: Int, ContentBlockDelta)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?)
    case messageStop
    case unknown(eventName: String)
}
