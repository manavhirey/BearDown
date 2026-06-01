import Foundation

public enum CoachError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse(status: Int, body: String)
    case networkFailure(String)
    case toolLoopLimitExceeded
    case toolValidation(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your API key in Settings."
        case let .invalidResponse(status, _): return "Anthropic API error (HTTP \(status))."
        case let .networkFailure(msg): return msg
        case .toolLoopLimitExceeded: return "Coach got stuck — try rephrasing."
        case let .toolValidation(msg): return msg
        }
    }
}
