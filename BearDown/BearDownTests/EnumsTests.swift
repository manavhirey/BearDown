import XCTest
@testable import BearDown

final class EnumsTests: XCTestCase {
    func test_workoutStatus_rawValues() {
        XCTAssertEqual(WorkoutStatus.pending.rawValue, "pending")
        XCTAssertEqual(WorkoutStatus.completed.rawValue, "completed")
        XCTAssertEqual(WorkoutStatus.failed.rawValue, "failed")
    }

    func test_blockKind_rawValues() {
        XCTAssertEqual(BlockKind.strength.rawValue, "strength")
        XCTAssertEqual(BlockKind.cardio.rawValue, "cardio")
        XCTAssertEqual(BlockKind.mobility.rawValue, "mobility")
    }

    func test_chatRole_rawValues() {
        XCTAssertEqual(ChatRole.user.rawValue, "user")
        XCTAssertEqual(ChatRole.assistant.rawValue, "assistant")
    }

    func test_workoutStatus_isCodable() throws {
        let data = try JSONEncoder().encode(WorkoutStatus.completed)
        let decoded = try JSONDecoder().decode(WorkoutStatus.self, from: data)
        XCTAssertEqual(decoded, .completed)
    }
}
