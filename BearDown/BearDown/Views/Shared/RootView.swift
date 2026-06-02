import SwiftUI

public struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var hasKey: Bool = false
    @StateObject private var nav = AppNavigation()

    public init() {}

    public var body: some View {
        Group {
            if hasKey {
                TabView(selection: $nav.selectedTab) {
                    TodayView(env: env)
                        .tabItem { Label("Today", systemImage: "figure.run") }
                        .tag(0)
                    PlansListView(env: env)
                        .tabItem { Label("Plan", systemImage: "list.bullet.rectangle") }
                        .tag(1)
                    CoachView(env: env, nav: nav)
                        .tabItem { Label("Coach", systemImage: "bubble.left.and.bubble.right") }
                        .tag(2)
                    SettingsView(env: env)
                        .tabItem { Label("Settings", systemImage: "gear") }
                        .tag(3)
                }
                .environmentObject(nav)
            } else {
                let validator: (String) async throws -> Void = ProcessInfo.processInfo.arguments.contains("--ui-test-stub-validator")
                    ? { _ in }
                    : { [client = env.anthropic] key in try await client.validate(apiKey: key) }
                let vm = OnboardingViewModel(keychain: env.keychain, validate: validator)
                OnboardingView(viewModel: vm) { hasKey = true }
            }
        }
        .onAppear { refreshHasKey() }
    }

    private func refreshHasKey() {
        let v = (try? env.keychain.read(key: .anthropicAPIKey)) ?? ""
        hasKey = !v.isEmpty
    }
}
