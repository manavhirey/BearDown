import Foundation
import SwiftData

@Model
public final class Exercise {
    @Attribute(.unique) public var id: UUID = UUID()
    public var order: Int = 0
    public var name: String = ""
    public var sets: Int = 0
    public var reps: String = ""
    public var load: String?
    public var restSeconds: Int?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var block: WorkoutBlock?

    public init(
        id: UUID = UUID(),
        order: Int,
        name: String,
        sets: Int,
        reps: String,
        load: String? = nil,
        restSeconds: Int? = nil
    ) {
        self.id = id
        self.order = order
        self.name = name
        self.sets = sets
        self.reps = reps
        self.load = load
        self.restSeconds = restSeconds
    }
}
