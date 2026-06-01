import Foundation
import SwiftData

@Model
public final class CardioDetail {
    @Attribute(.unique) public var id: UUID = UUID()
    public var modality: String = ""
    public var durationMinutes: Int?
    public var distanceMeters: Double?
    public var targetDescription: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var block: WorkoutBlock?

    public init(
        id: UUID = UUID(),
        modality: String,
        durationMinutes: Int? = nil,
        distanceMeters: Double? = nil,
        targetDescription: String? = nil
    ) {
        self.id = id
        self.modality = modality
        self.durationMinutes = durationMinutes
        self.distanceMeters = distanceMeters
        self.targetDescription = targetDescription
    }
}
