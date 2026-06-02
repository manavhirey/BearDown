import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class PlanDetailViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var plans: PlanRepository!
    private var workouts: WorkoutRepository!

    override func setUpWithError() throws {
        container = try .beardownInMemory()
        plans = PlanRepository(context: container.mainContext)
        workouts = WorkoutRepository(context: container.mainContext, plans: plans)
    }

    func test_refresh_groupsWorkoutsIntoWeeksSortedAscending() throws {
        let plan = try plans.createPlan(title: "Block",
                                        startDate: .now,
                                        endDate: .now.addingTimeInterval(14 * 86400))
        _ = try workouts.upsert(.init(date: .now, title: "Mon", summary: "", blocks: []))
        _ = try workouts.upsert(.init(date: .now.addingTimeInterval(7 * 86400),
                                       title: "NextMon", summary: "", blocks: []))

        let vm = PlanDetailViewModel(plan: plan)
        vm.refresh()

        XCTAssertEqual(vm.weeks.count, 2)
        XCTAssertEqual(vm.weeks[0].workouts.first?.title, "Mon")
        XCTAssertEqual(vm.weeks[1].workouts.first?.title, "NextMon")
    }

    func test_isActive_reflectsPlanState() throws {
        let plan = try plans.createPlan(title: "Block",
                                        startDate: .now,
                                        endDate: .now)
        let vm = PlanDetailViewModel(plan: plan)
        vm.refresh()
        XCTAssertTrue(vm.isActive)
    }
}
