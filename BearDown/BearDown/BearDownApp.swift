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
        }
    }
}
