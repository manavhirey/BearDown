import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class TodayViewModelTests: XCTestCase {
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        env = AppEnvironment(
            modelContainer: container,
            keychain: KeychainStore(service: "com.beardown.tests.today.\(UUID().uuidString)"),
            anthropic: FakeAnthropicClient()
        )
        _ = try env.plans.createPlan(title: "P",
                                     startDate: .now.addingTimeInterval(-14 * 86400),
                                     endDate: .now.addingTimeInterval(14 * 86400))
    }

    func test_initialAnchor_isStartOfToday() {
        let vm = TodayViewModel(env: env, anchor: .now)
        XCTAssertEqual(vm.focusedDate, Calendar.current.startOfDay(for: .now))
        XCTAssertTrue(vm.isToday)
    }

    func test_step_advancesByOneDay() {
        let vm = TodayViewModel(env: env, anchor: .now)
        let start = vm.focusedDate
        vm.step(by: 1)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: vm.focusedDate).day, 1)
        XCTAssertFalse(vm.isToday)
        vm.step(by: -2)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: vm.focusedDate).day, -1)
    }

    func test_jumpToToday_resetsToToday() {
        let vm = TodayViewModel(env: env, anchor: .now)
        vm.step(by: 5)
        XCTAssertFalse(vm.isToday)
        vm.jumpToToday()
        XCTAssertTrue(vm.isToday)
    }

    func test_refresh_loadsWorkoutsForFocusedDate() throws {
        let today = Calendar.current.startOfDay(for: .now)
        _ = try env.workouts.upsert(.init(date: today, title: "Today's Push", summary: "", blocks: []))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        _ = try env.workouts.upsert(.init(date: tomorrow, title: "Tomorrow's Pull", summary: "", blocks: []))

        let vm = TodayViewModel(env: env, anchor: .now)
        vm.refresh()
        XCTAssertEqual(vm.workouts.map(\.title), ["Today's Push"])

        vm.step(by: 1)
        XCTAssertEqual(vm.workouts.map(\.title), ["Tomorrow's Pull"])
    }

    func test_jumpTo_normalizesToStartOfDay() {
        let vm = TodayViewModel(env: env, anchor: .now)
        let middleOfDay = Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: .now)!
        vm.jumpTo(middleOfDay)
        XCTAssertEqual(vm.focusedDate, Calendar.current.startOfDay(for: middleOfDay))
    }
}
