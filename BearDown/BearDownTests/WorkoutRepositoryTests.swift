import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class WorkoutRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var plans: PlanRepository!
    private var workouts: WorkoutRepository!
    private var plan: TrainingPlan!

    override func setUpWithError() throws {
        container = try .beardownInMemory()
        plans = PlanRepository(context: container.mainContext)
        workouts = WorkoutRepository(context: container.mainContext, plans: plans)
        plan = try plans.createPlan(title: "P",
                                    startDate: .now,
                                    endDate: .now.addingTimeInterval(28 * 86400))
    }

    func test_upsert_autoCreatesPlanWhenNoneExists() throws {
        // Fresh container, no plan pre-created.
        let c = try ModelContainer.beardownInMemory()
        let p = PlanRepository(context: c.mainContext)
        let w = WorkoutRepository(context: c.mainContext, plans: p)
        XCTAssertNil(try p.activePlan())
        _ = try w.upsert(.init(date: .now, title: "First", summary: "", blocks: []))
        let active = try XCTUnwrap(try p.activePlan())
        XCTAssertEqual(active.title, "Current Block")
    }

    func test_upsert_createsANewWorkout() throws {
        let input = WorkoutInput(
            date: .now,
            title: "Push",
            summary: "Bench + OHP",
            blocks: [
                .init(order: 0, kind: .strength, title: "Push", notes: "",
                      exercises: [.init(order: 0, name: "Bench", sets: 5, reps: "5", load: "60kg", restSeconds: 120)],
                      cardio: nil)
            ]
        )
        let w = try workouts.upsert(input)
        XCTAssertEqual(w.title, "Push")
        XCTAssertEqual(w.blocks.count, 1)
        XCTAssertEqual(w.blocks[0].exercises.count, 1)
        XCTAssertEqual(w.plan?.id, plan.id)
    }

    func test_upsert_replacesExistingWorkoutOnSameDate() throws {
        let date = Date()
        _ = try workouts.upsert(.init(date: date, title: "v1", summary: "", blocks: []))
        let v2 = try workouts.upsert(.init(date: date, title: "v2", summary: "", blocks: []))
        let all = try workouts.workoutsBetween(start: Calendar.current.startOfDay(for: date),
                                               end: Calendar.current.startOfDay(for: date).addingTimeInterval(86400))
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "v2")
        XCTAssertEqual(all[0].id, v2.id)
    }

    func test_upsert_outsidePlanDateRange_extendsPlanEndDate() throws {
        let beyond = plan.endDate.addingTimeInterval(14 * 86400)
        _ = try workouts.upsert(.init(date: beyond, title: "Extra", summary: "", blocks: []))
        XCTAssertEqual(try plans.activePlan()?.endDate, Calendar.current.startOfDay(for: beyond))
    }

    func test_delete_removesTheWorkout() throws {
        let date = Date()
        _ = try workouts.upsert(.init(date: date, title: "x", summary: "", blocks: []))
        try workouts.delete(date: date)
        let all = try workouts.workoutsBetween(start: Calendar.current.startOfDay(for: date),
                                               end: Calendar.current.startOfDay(for: date).addingTimeInterval(86400))
        XCTAssertTrue(all.isEmpty)
    }

    func test_markCompleted_setsStatusAndNote() throws {
        let date = Date()
        let w = try workouts.upsert(.init(date: date, title: "x", summary: "", blocks: []))
        try workouts.markStatus(workoutId: w.id, status: .completed, note: "felt good")
        XCTAssertEqual(w.status, .completed)
        XCTAssertEqual(w.completionNote, "felt good")
        XCTAssertNotNil(w.completedAt)
    }

    func test_recentHistory_returnsRequestedDays() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        for i in 0..<5 {
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            let w = try workouts.upsert(.init(date: d, title: "Day \(i)", summary: "", blocks: []))
            try workouts.markStatus(workoutId: w.id, status: .completed, note: nil)
        }
        let recent = try workouts.recentHistory(days: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent[0].title, "Day 0")
    }
}
