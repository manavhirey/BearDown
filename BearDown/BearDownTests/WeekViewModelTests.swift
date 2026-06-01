import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class WeekViewModelTests: XCTestCase {
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        env = AppEnvironment(
            modelContainer: container,
            keychain: KeychainStore(service: "com.beardown.tests.week.\(UUID().uuidString)"),
            anthropic: FakeAnthropicClient()
        )
        _ = try env.plans.createPlan(title: "P",
                                     startDate: .now.addingTimeInterval(-14 * 86400),
                                     endDate: .now.addingTimeInterval(14 * 86400))
    }

    func test_initialAnchor_isThisWeekStart() {
        let vm = WeekViewModel(env: env, anchor: .now)
        let cal = Calendar.current
        let expected = cal.dateInterval(of: .weekOfYear, for: .now)!.start
        XCTAssertEqual(vm.weekStart, expected)
    }

    func test_days_returnsSevenConsecutiveDays() {
        let vm = WeekViewModel(env: env, anchor: .now)
        XCTAssertEqual(vm.days.count, 7)
        let diffs = zip(vm.days, vm.days.dropFirst()).map {
            Calendar.current.dateComponents([.day], from: $0.0, to: $0.1).day!
        }
        XCTAssertEqual(diffs, Array(repeating: 1, count: 6))
    }

    func test_workoutsByDate_populatesPersistedWorkouts() throws {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: .now)!.start
        let wed = cal.date(byAdding: .day, value: 2, to: weekStart)!
        _ = try env.workouts.upsert(.init(date: wed, title: "Push", summary: "", blocks: []))
        let vm = WeekViewModel(env: env, anchor: .now)
        vm.refresh()
        XCTAssertEqual(vm.workoutsByDate[cal.startOfDay(for: wed)]?.title, "Push")
    }

    func test_step_advancesByOneWeek() {
        let vm = WeekViewModel(env: env, anchor: .now)
        let start = vm.weekStart
        vm.step(by: 1)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: vm.weekStart).day, 7)
        vm.step(by: -2)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: vm.weekStart).day, -7)
    }
}
