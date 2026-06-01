import XCTest
import SwiftData
@testable import BearDown

final class ModelContainerTests: XCTestCase {
    func test_inMemoryContainer_canBeBuilt() throws {
        let container = try ModelContainer.beardownInMemory()
        XCTAssertNotNil(container)
    }

    func test_beardownSchema_includesAllModels() {
        let schema = ModelContainer.beardownSchema
        let typeNames = schema.entities.map(\.name).sorted()
        XCTAssertEqual(
            typeNames,
            ["CardioDetail", "ChatMessage", "Exercise", "TrainingPlan", "Workout", "WorkoutBlock"]
        )
    }
}
