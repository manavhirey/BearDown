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
                    WeekView()
                        .tabItem { Label("Week", systemImage: "calendar") }
                        .tag(0)
                    PlanView()
                        .tabItem { Label("Plan", systemImage: "list.bullet.rectangle") }
                        .tag(1)
                    CoachView(env: env)
                        .tabItem { Label("Coach", systemImage: "bubble.left.and.bubble.right") }
                        .tag(2)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gear") }
                        .tag(3)
                }
                .environmentObject(nav)
            } else {
                let vm = OnboardingViewModel(
                    keychain: env.keychain,
                    validate: { [client = env.anthropic] key in
                        try await client.validate(apiKey: key)
                    }
                )
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
