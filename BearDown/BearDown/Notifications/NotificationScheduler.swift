import Foundation
import UserNotifications

public actor NotificationScheduler {
    private let center: UserNotificationCenterProtocol
    private(set) var defaultHour: Int
    private(set) var defaultMinute: Int

    public init(center: UserNotificationCenterProtocol,
                defaultHour: Int = 7,
                defaultMinute: Int = 0) {
        self.center = center
        self.defaultHour = defaultHour
        self.defaultMinute = defaultMinute
    }

    public func setDefaultTime(hour: Int, minute: Int) {
        defaultHour = hour; defaultMinute = minute
    }

    public func scheduleOrUpdate(workout: Workout, enabled: Bool) async throws {
        let id = identifier(for: workout)
        let c = center
        await MainActor.run { c.removePendingNotificationRequests(withIdentifiers: [id]) }
        guard enabled,
              workout.status == .pending,
              workout.date >= Calendar.current.startOfDay(for: .now)
        else { return }

        var fire = DateComponents()
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: workout.date)
        fire.year = comps.year; fire.month = comps.month; fire.day = comps.day
        fire.hour = defaultHour; fire.minute = defaultMinute

        let content = UNMutableNotificationContent()
        content.title = workout.title
        content.body = workout.summary
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: fire, repeats: false)
        let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try await c.add(req)
    }

    public func cancel(workout: Workout) async {
        let id = identifier(for: workout)
        let c = center
        await MainActor.run { c.removePendingNotificationRequests(withIdentifiers: [id]) }
    }

    public func cancelByIdentifier(_ id: String) async {
        let c = center
        await MainActor.run { c.removePendingNotificationRequests(withIdentifiers: [id]) }
    }

    public func cancelAllWorkoutNotifications() async {
        let c = center
        let pending = await c.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix("workout-") }
        await MainActor.run { c.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    public func reconcile(workouts: [Workout], enabled: Bool) async throws {
        await cancelAllWorkoutNotifications()
        guard enabled else { return }
        for w in workouts {
            try await scheduleOrUpdate(workout: w, enabled: true)
        }
    }

    private func identifier(for workout: Workout) -> String {
        "workout-\(workout.id.uuidString)"
    }
}
