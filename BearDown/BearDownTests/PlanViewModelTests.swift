import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class PlanViewModelTests: XCTestCase {
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        env = AppEnvironment(
            modelContainer: container,
            keychain: KeychainStore(service: "com.beardown.tests.plan.\(UUID().uuidString)"),
            anthropic: FakeAnthropicClient()
        )
        _ = try env.plans.createPlan(title: "P",
                                     startDate: .now,
                                     endDate: .now.addingTimeInterval(28 * 86400))
    }

    func test_groupedByWeek_returnsOneSectionPerWeek() throws {
        let cal = Calendar.current
        for offset in [0, 1, 8, 15] {
            let d = cal.date(byAdding: .day, value: offset, to: .now)!
            _ = try env.workouts.upsert(.init(date: d, title: "D\(offset)", summary: "", blocks: []))
        }
        let vm = PlanViewModel(env: env)
        vm.refresh()
        XCTAssertEqual(vm.weeks.count, 3)
        XCTAssertEqual(vm.weeks[0].workouts.count, 2)   // days 0 and 1
        XCTAssertEqual(vm.weeks[1].workouts.count, 1)   // day 8
        XCTAssertEqual(vm.weeks[2].workouts.count, 1)   // day 15
    }

    func test_progressString_reflectsCompletion() throws {
        let cal = Calendar.current
        let a = try env.workouts.upsert(.init(date: .now, title: "A", summary: "", blocks: []))
        _   = try env.workouts.upsert(.init(date: cal.date(byAdding: .day, value: 1, to: .now)!,
                                            title: "B", summary: "", blocks: []))
        try env.workouts.markStatus(workoutId: a.id, status: .completed, note: nil)
        let vm = PlanViewModel(env: env)
        vm.refresh()
        XCTAssertEqual(vm.weeks.first?.progress, "1/2 complete")
    }
}
