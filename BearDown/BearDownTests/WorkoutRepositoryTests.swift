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

    func test_upsert_withPlanTitle_routesToNamedPlanAndLeavesActiveAlone() throws {
        let active = try plans.createPlan(title: "Current Block",
                                          startDate: .now,
                                          endDate: .now.addingTimeInterval(7 * 86400))

        let input = WorkoutInput(
            date: .now.addingTimeInterval(14 * 86400),
            title: "Race long run",
            summary: "12mi",
            blocks: [],
            planTitle: "Race Prep",
            planGoal: "3.5mi race June 24"
        )
        let workout = try workouts.upsert(input)

        XCTAssertNotEqual(workout.plan?.id, active.id)
        XCTAssertEqual(workout.plan?.title, "Race Prep")
        XCTAssertEqual(workout.plan?.goal, "3.5mi race June 24")
        XCTAssertFalse(workout.plan!.isActive)

        // Active plan untouched.
        XCTAssertEqual(try plans.activePlan()?.id, active.id)
    }

    func test_upsert_withPlanTitle_extendsThatPlansEndDate() throws {
        _ = try plans.createPlan(title: "Current Block",
                                 startDate: .now,
                                 endDate: .now.addingTimeInterval(86400))
        let firstDate = Calendar.current.startOfDay(for: .now)
        let lateDate = firstDate.addingTimeInterval(20 * 86400)

        _ = try workouts.upsert(.init(date: firstDate, title: "W1", summary: "",
                                      blocks: [], planTitle: "Race Prep", planGoal: ""))
        _ = try workouts.upsert(.init(date: lateDate, title: "W2", summary: "",
                                      blocks: [], planTitle: "Race Prep", planGoal: ""))

        let racePrep = try plans.allPlans().first { $0.title == "Race Prep" }
        XCTAssertEqual(racePrep?.endDate, lateDate)
    }

    func test_upsert_withoutPlanTitle_stillRoutesToActivePlan() throws {
        let active = try plans.createPlan(title: "Current Block",
                                          startDate: .now,
                                          endDate: .now.addingTimeInterval(86400))
        let workout = try workouts.upsert(.init(date: .now, title: "W", summary: "", blocks: []))
        XCTAssertEqual(workout.plan?.id, active.id)
    }
}
