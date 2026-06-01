import Foundation
import SwiftData

@Model
public final class WorkoutBlock {
    @Attribute(.unique) public var id: UUID = UUID()
    public var order: Int = 0
    public var kindRaw: String = BlockKind.strength.rawValue
    public var title: String = ""
    public var notes: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var workout: Workout?

    @Relationship(deleteRule: .cascade, inverse: \Exercise.block)
    public var exercises: [Exercise] = []

    @Relationship(deleteRule: .cascade, inverse: \CardioDetail.block)
    public var cardio: CardioDetail?

    public var kind: BlockKind {
        get { BlockKind(rawValue: kindRaw) ?? .strength }
        set { kindRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        order: Int,
        kind: BlockKind,
        title: String,
        notes: String
    ) {
        self.id = id
        self.order = order
        self.kindRaw = kind.rawValue
        self.title = title
        self.notes = notes
    }
}
