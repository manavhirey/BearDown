import Combine
import Foundation
import SwiftData
import UserNotifications

@MainActor
public final class AppEnvironment: ObservableObject {
    public nonisolated let objectWillChange = PassthroughSubject<Void, Never>()

    public let modelContainer: ModelContainer
    public let keychain: KeychainStore
    public let anthropic: AnthropicClientProtocol
    public let plans: PlanRepository
    public let notificationScheduler: NotificationScheduler
    public let workouts: WorkoutRepository
    public let chats: ChatRepository
    public let coach: CoachService

    public init(modelContainer: ModelContainer,
                keychain: KeychainStore? = nil,
                anthropic: AnthropicClientProtocol = AnthropicClient()) {
        self.modelContainer = modelContainer
        self.keychain = keychain ?? KeychainStore()
        self.anthropic = anthropic
        let ctx = modelContainer.mainContext
        self.plans = PlanRepository(context: ctx)

        let center = SystemUserNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        self.notificationScheduler = scheduler

        let prefsEnabled: @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: "notifications.enabled")
        }

        self.workouts = WorkoutRepository(
            context: ctx,
            plans: plans,
            onChange: { workout, enabled in
                Task { try? await scheduler.scheduleOrUpdate(workout: workout, enabled: enabled) }
            },
            onCancel: { id in
                Task { await scheduler.cancelByIdentifier("workout-\(id.uuidString)") }
            },
            notificationsEnabled: prefsEnabled
        )
        self.chats = ChatRepository(context: ctx)
        let toolsImpl = CoachTools(plans: plans, workouts: workouts)
        self.coach = CoachService(client: anthropic,
                                  keychain: self.keychain,
                                  chats: chats,
                                  tools: toolsImpl,
                                  workouts: workouts,
                                  plans: plans)
    }

    public static func production() throws -> AppEnvironment {
        AppEnvironment(modelContainer: try .beardownProduction())
    }
}
