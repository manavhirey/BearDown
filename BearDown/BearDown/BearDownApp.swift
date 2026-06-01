import SwiftUI
import SwiftData

@main
struct BearDownApp: App {
    @StateObject private var env: AppEnvironment

    init() {
        let environment: AppEnvironment
        do {
            environment = try AppEnvironment.production()
        } catch {
            // Fall back to an in-memory store when CloudKit entitlement is
            // unavailable (e.g. simulator test host). This keeps unit tests
            // running without a fatalError in the app host process.
            do {
                environment = try AppEnvironment(modelContainer: .beardownInMemory())
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
        }
    }
}
