import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class ModelsTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            TrainingPlan.self, Workout.self, WorkoutBlock.self,
            Exercise.self, CardioDetail.self, ChatMessage.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    func test_canPersistAFullWorkoutGraph() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let plan = TrainingPlan(title: "Block 1", startDate: .now, endDate: .now.addingTimeInterval(86400 * 28))
        ctx.insert(plan)

        let workout = Workout(date: .now, title: "Push day", summary: "Bench, OHP, dips")
        workout.plan = plan
        ctx.insert(workout)

        let strength = WorkoutBlock(order: 0, kind: .strength, title: "Push", notes: "")
        strength.workout = workout
        ctx.insert(strength)

        let bench = Exercise(order: 0, name: "Bench Press", sets: 5, reps: "5", load: "60kg")
        bench.block = strength
        ctx.insert(bench)

        let cardio = WorkoutBlock(order: 1, kind: .cardio, title: "Easy run", notes: "")
        cardio.workout = workout
        ctx.insert(cardio)
        let cardioDetail = CardioDetail(modality: "run", durationMinutes: 20)
        cardioDetail.block = cardio
        ctx.insert(cardioDetail)

        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].blocks.count, 2)
        XCTAssertEqual(fetched[0].plan?.title, "Block 1")
    }

    func test_defaultStatusIsPending() {
        let w = Workout(date: .now, title: "T", summary: "S")
        XCTAssertEqual(w.status, .pending)
        XCTAssertNil(w.completionNote)
        XCTAssertNil(w.completedAt)
    }

    func test_chatMessage_storesToolJSON() {
        let m = ChatMessage(role: .assistant, text: "Done.", conversationId: UUID())
        m.toolCallsJSON = #"[{"name":"upsert_workout"}]"#
        XCTAssertEqual(m.role, .assistant)
        XCTAssertNotNil(m.toolCallsJSON)
    }
}
