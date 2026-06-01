import SwiftUI
import SwiftData

@main
struct BearDownApp: App {
    @StateObject private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment: AppEnvironment
        do {
            environment = try AppEnvironment.production()
        } catch {
            // CloudKit unavailable (simulator without iCloud, user signed out,
            // entitlement missing). Fall back to on-disk-without-sync so user
            // data still persists across launches — never to in-memory, which
            // would silently throw away the user's training plans.
            do {
                environment = try AppEnvironment(modelContainer: .beardownLocalOnly())
            } catch {
                fatalError("Failed to initialize AppEnvironment: \(error)")
            }
        }
        _env = StateObject(wrappedValue: environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .modelContainer(env.modelContainer)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await reconcileNotifications() } }
                }
        }
    }

    @MainActor
    private func reconcileNotifications() async {
        let on = UserDefaults.standard.bool(forKey: "notifications.enabled")
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: 365, to: today)!
        guard let ws = try? env.workouts.workoutsBetween(start: today, end: end) else { return }
        try? await env.notificationScheduler.reconcile(workouts: ws, enabled: on)
    }
}
