import Foundation
import SwiftData

@Model
public final class TrainingPlan {
    @Attribute(.unique) public var id: UUID = UUID()
    public var title: String = ""
    public var startDate: Date = Date()
    public var endDate: Date = Date()
    public var isActive: Bool = false
    public var archivedAt: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \Workout.plan)
    public var workouts: [Workout] = []

    public init(
        id: UUID = UUID(),
        title: String,
        startDate: Date,
        endDate: Date,
        isActive: Bool = true
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = isActive
    }
}
