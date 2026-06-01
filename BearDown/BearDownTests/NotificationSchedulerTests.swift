import XCTest
import UserNotifications
@testable import BearDown

@MainActor
final class NotificationSchedulerTests: XCTestCase {
    private final class Fake: UserNotificationCenterProtocol, @unchecked Sendable {
        var added: [UNNotificationRequest] = []
        var removed: [String] = []
        var pendingIds: [String] = []
        var authStatus: UNAuthorizationStatus = .authorized

        func authorizationStatus() async -> UNAuthorizationStatus { authStatus }
        func requestAuthorization() async throws -> Bool { authStatus == .authorized }
        func add(_ request: UNNotificationRequest) async throws { added.append(request) }
        @MainActor func removePendingNotificationRequests(withIdentifiers ids: [String]) {
            removed.append(contentsOf: ids); pendingIds.removeAll { ids.contains($0) }
        }
        func pendingNotificationRequests() async -> [UNNotificationRequest] {
            pendingIds.map { id in
                UNNotificationRequest(identifier: id,
                                      content: UNMutableNotificationContent(),
                                      trigger: nil)
            }
        }
    }

    private var fake: Fake!
    private var scheduler: NotificationScheduler!

    override func setUp() {
        fake = Fake()
        scheduler = NotificationScheduler(center: fake, defaultHour: 7, defaultMinute: 0)
    }

    func test_schedule_pendingFutureWorkout_addsRequest() async throws {
        let w = makeWorkout(daysFromToday: 2, status: .pending)
        try await scheduler.scheduleOrUpdate(workout: w, enabled: true)
        XCTAssertEqual(fake.added.count, 1)
        XCTAssertEqual(fake.added[0].identifier, "workout-\(w.id.uuidString)")
    }

    func test_schedule_completedWorkout_doesNotAdd() async throws {
        let w = makeWorkout(daysFromToday: 2, status: .completed)
        try await scheduler.scheduleOrUpdate(workout: w, enabled: true)
        XCTAssertTrue(fake.added.isEmpty)
    }

    func test_schedule_pastWorkout_doesNotAdd() async throws {
        let w = makeWorkout(daysFromToday: -1, status: .pending)
        try await scheduler.scheduleOrUpdate(workout: w, enabled: true)
        XCTAssertTrue(fake.added.isEmpty)
    }

    func test_schedule_disabled_doesNotAdd() async throws {
        let w = makeWorkout(daysFromToday: 2, status: .pending)
        try await scheduler.scheduleOrUpdate(workout: w, enabled: false)
        XCTAssertTrue(fake.added.isEmpty)
    }

    func test_cancel_removesById() async {
        let w = makeWorkout(daysFromToday: 2, status: .pending)
        await scheduler.cancel(workout: w)
        XCTAssertEqual(fake.removed.last, "workout-\(w.id.uuidString)")
    }

    func test_cancelAll_clearsAllWorkoutRequests() async {
        fake.pendingIds = ["workout-aaa", "workout-bbb", "other-x"]
        await scheduler.cancelAllWorkoutNotifications()
        XCTAssertEqual(fake.removed.sorted(), ["workout-aaa", "workout-bbb"])
    }

    private func makeWorkout(daysFromToday: Int, status: WorkoutStatus) -> Workout {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: daysFromToday, to: cal.startOfDay(for: .now))!
        let w = Workout(date: day, title: "Push", summary: "Bench")
        w.status = status
        return w
    }
}
