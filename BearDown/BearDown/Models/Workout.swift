import Foundation
import SwiftData

@Model
public final class Workout {
    @Attribute(.unique) public var id: UUID = UUID()
    public var date: Date = Date()
    public var title: String = ""
    public var summary: String = ""
    public var statusRaw: String = WorkoutStatus.pending.rawValue
    public var completionNote: String?
    public var completedAt: Date?

    @Transient public var notificationId: String?

    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var plan: TrainingPlan?

    @Relationship(deleteRule: .cascade, inverse: \WorkoutBlock.workout)
    public var blocks: [WorkoutBlock] = []

    public var status: WorkoutStatus {
        get { WorkoutStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        summary: String,
        status: WorkoutStatus = .pending
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.title = title
        self.summary = summary
        self.statusRaw = status.rawValue
    }
}
