import SwiftUI
import UserNotifications

public struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var vm: SettingsViewModel
    @State private var maskedKey: String = ""
    @State private var newKey: String = ""
    @State private var showReplace: Bool = false

    public init(vm: SettingsViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("API key") {
                    Text(maskedKey.isEmpty ? "Not set" : maskedKey)
                    Button("Replace") { showReplace = true }
                }
                Section("Notifications") {
                    Toggle("Workout reminders", isOn: $vm.notificationsEnabled)
                    if vm.notificationsEnabled {
                        DatePicker("Reminder time",
                                   selection: $vm.reminderTime,
                                   displayedComponents: .hourAndMinute)
                        if vm.authorizationStatus == .denied {
                            Link("Open iOS Settings",
                                 destination: URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                }
                Section("About") {
                    Text("BearDown v0.1").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear { refresh(); Task { await vm.refreshAuthStatus() } }
            .sheet(isPresented: $showReplace) {
                NavigationStack {
                    Form {
                        SecureField("sk-ant-...", text: $newKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .navigationTitle("New API key")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showReplace = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                try? env.keychain.write(key: .anthropicAPIKey, value: newKey)
                                newKey = ""; showReplace = false; refresh()
                            }
                        }
                    }
                }
            }
        }
    }

    private func refresh() {
        let v = (try? env.keychain.read(key: .anthropicAPIKey)) ?? ""
        maskedKey = v.isEmpty ? "" : "sk-ant-…" + v.suffix(4)
    }
}
