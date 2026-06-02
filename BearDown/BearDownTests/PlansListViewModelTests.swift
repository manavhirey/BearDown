import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class PlansListViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        container = try .beardownInMemory()
        env = AppEnvironment(modelContainer: container,
                             keychain: KeychainStore(service: "com.beardown.tests.plans.\(UUID().uuidString)"),
                             anthropic: FakeAnthropicClient())
    }

    func test_refresh_buildsSummariesActiveFirstWithCompletionCounts() throws {
        let active = try env.plans.createPlan(title: "Active",
                                              startDate: .now,
                                              endDate: .now.addingTimeInterval(7 * 86400))
        _ = try env.workouts.upsert(.init(date: .now, title: "A1", summary: "", blocks: []))
        let archivedW = try env.workouts.upsert(.init(date: .now.addingTimeInterval(-86400),
                                                     title: "AR1", summary: "",
                                                     blocks: [], planTitle: "Archived"))
        try env.workouts.markStatus(workoutId: archivedW.id, status: .completed, note: nil)

        let vm = PlansListViewModel(env: env)
        vm.refresh()

        XCTAssertEqual(vm.plans.count, 2)
        XCTAssertEqual(vm.plans[0].id, active.id)
        XCTAssertTrue(vm.plans[0].isActive)
        XCTAssertEqual(vm.plans[0].completed, 0)
        XCTAssertEqual(vm.plans[0].total, 1)

        XCTAssertFalse(vm.plans[1].isActive)
        XCTAssertEqual(vm.plans[1].title, "Archived")
        XCTAssertEqual(vm.plans[1].completed, 1)
        XCTAssertEqual(vm.plans[1].total, 1)
    }
}
