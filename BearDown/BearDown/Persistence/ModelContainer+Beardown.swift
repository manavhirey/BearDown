import Foundation
import SwiftData

public extension ModelContainer {
    static var beardownSchema: Schema {
        Schema([
            TrainingPlan.self,
            Workout.self,
            WorkoutBlock.self,
            Exercise.self,
            CardioDetail.self,
            ChatMessage.self,
        ])
    }

    /// Production container: on-disk store with CloudKit sync.
    static func beardownProduction() throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: beardownSchema,
            cloudKitDatabase: .automatic
        )
        return try ModelContainer(for: beardownSchema, configurations: [config])
    }

    /// In-memory container for tests and previews.
    /// Disables CloudKit explicitly — when the app has the CloudKit entitlement,
    /// SwiftData runs CloudKit schema validation even on in-memory stores unless
    /// we opt out here.
    static func beardownInMemory() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: beardownSchema, configurations: [config])
    }
}
