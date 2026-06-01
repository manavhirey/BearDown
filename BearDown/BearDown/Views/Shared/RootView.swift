import SwiftUI

public struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var hasKey: Bool = false

    public init() {}

    public var body: some View {
        Group {
            if hasKey {
                TabView {
                    WeekView()
                        .tabItem { Label("Week", systemImage: "calendar") }
                    PlanView()
                        .tabItem { Label("Plan", systemImage: "list.bullet.rectangle") }
                    CoachView()
                        .tabItem { Label("Coach", systemImage: "bubble.left.and.bubble.right") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gear") }
                }
            } else {
                let vm = OnboardingViewModel(
                    keychain: env.keychain,
                    validate: { _ in /* stub — replaced with real AnthropicClient.validate in Task 17 */ }
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
