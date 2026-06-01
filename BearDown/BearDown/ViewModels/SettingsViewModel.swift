import Combine
import Foundation
import UserNotifications

@MainActor
public final class SettingsViewModel: ObservableObject {
    public nonisolated let objectWillChange = PassthroughSubject<Void, Never>()

    @Published public var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notifications.enabled")
            Task { await applyNotificationsToggle() }
        }
    }
    @Published public var reminderTime: Date {
        didSet {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
            UserDefaults.standard.set(comps.hour ?? 7, forKey: "notifications.hour")
            UserDefaults.standard.set(comps.minute ?? 0, forKey: "notifications.minute")
            Task { await applyReminderTimeChange() }
        }
    }
    @Published public var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: "notifications.enabled")
        let hour = UserDefaults.standard.object(forKey: "notifications.hour") as? Int ?? 7
        let minute = UserDefaults.standard.object(forKey: "notifications.minute") as? Int ?? 0
        var comps = DateComponents(); comps.hour = hour; comps.minute = minute
        self.reminderTime = Calendar.current.date(from: comps) ?? .now
        Task { await refreshAuthStatus() }
    }

    public func refreshAuthStatus() async {
        let center = UNUserNotificationCenter.current()
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    private func applyNotificationsToggle() async {
        if notificationsEnabled {
            do {
                _ = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                await refreshAuthStatus()
                await reconcileAll(enabled: true)
            } catch { notificationsEnabled = false }
        } else {
            await env.notificationScheduler.cancelAllWorkoutNotifications()
        }
    }

    private func applyReminderTimeChange() async {
        let hour = Calendar.current.component(.hour, from: reminderTime)
        let minute = Calendar.current.component(.minute, from: reminderTime)
        await env.notificationScheduler.setDefaultTime(hour: hour, minute: minute)
        await reconcileAll(enabled: notificationsEnabled)
    }

    private func reconcileAll(enabled: Bool) async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: 365, to: today)!
        guard let ws = try? env.workouts.workoutsBetween(start: today, end: end) else { return }
        try? await env.notificationScheduler.reconcile(workouts: ws, enabled: enabled)
    }
}
