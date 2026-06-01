import Combine
import Foundation
import SwiftData

@MainActor
public final class AppEnvironment: ObservableObject {
    public nonisolated let objectWillChange = PassthroughSubject<Void, Never>()

    public let modelContainer: ModelContainer
    public let keychain: KeychainStore
    public let plans: PlanRepository
    public let workouts: WorkoutRepository
    public let chats: ChatRepository

    public init(modelContainer: ModelContainer,
                keychain: KeychainStore? = nil) {
        self.modelContainer = modelContainer
        self.keychain = keychain ?? KeychainStore()
        let ctx = modelContainer.mainContext
        self.plans = PlanRepository(context: ctx)
        self.workouts = WorkoutRepository(context: ctx, plans: plans)
        self.chats = ChatRepository(context: ctx)
    }

    public static func production() throws -> AppEnvironment {
        AppEnvironment(modelContainer: try .beardownProduction())
    }
}
