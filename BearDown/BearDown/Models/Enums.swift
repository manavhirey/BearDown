import Foundation

public enum WorkoutStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case completed
    case failed
}

public enum BlockKind: String, Codable, CaseIterable, Sendable {
    case strength
    case cardio
    case mobility
}

public enum ChatRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
}
