import SwiftUI
import UserNotifications

public struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var vm: SettingsViewModel
    @State private var maskedKey: String = ""
    @State private var newKey: String = ""
    @State private var showReplace: Bool = false
    @State private var saveError: String?

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: SettingsViewModel(env: env))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    hero
                    apiKeySection
                    notificationsSection
                    aboutSection
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { refresh(); Task { await vm.refreshAuthStatus() } }
            .sheet(isPresented: $showReplace) { replaceKeySheet }
            .alert("Couldn’t save",
                   isPresented: Binding(get: { saveError != nil },
                                        set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    // MARK: – Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            BDEyebrow("BEAR DOWN · PREFERENCES")
            Text("Settings")
                .font(BDStyle.displayTitle)
            BDHairline()
        }
    }

    // MARK: – API key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            BDSectionHeader(title: "API Key")
            VStack(alignment: .leading, spacing: 0) {
                settingRow(
                    label: "Anthropic",
                    trailing: AnyView(
                        Text(maskedKey.isEmpty ? "NOT SET" : maskedKey)
                            .font(.system(.footnote, design: .monospaced).weight(.semibold))
                            .foregroundStyle(maskedKey.isEmpty ? .secondary : .primary)
                    )
                )
                BDHairline()
                Button {
                    showReplace = true
                } label: {
                    HStack {
                        Text(maskedKey.isEmpty ? "ADD KEY" : "REPLACE KEY")
                            .font(BDStyle.monoSmall)
                            .tracking(BDStyle.trackingWide)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(maskedKey.isEmpty ? Color.primary : Color.red)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: – Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            BDSectionHeader(title: "Notifications")
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BDLabel("Workout Reminders")
                    Spacer()
                    Toggle("", isOn: $vm.notificationsEnabled)
                        .labelsHidden()
                        .tint(.primary)
                }
                .padding(.vertical, 14)

                if vm.notificationsEnabled {
                    BDHairline()
                    HStack {
                        BDLabel("Reminder Time")
                        Spacer()
                        DatePicker("",
                                   selection: $vm.reminderTime,
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    .padding(.vertical, 10)

                    if vm.authorizationStatus == .denied {
                        BDHairline()
                        Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                            HStack {
                                Text("OPEN iOS SETTINGS")
                                    .font(BDStyle.monoSmall)
                                    .tracking(BDStyle.trackingWide)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.vertical, 14)
                        }
                        BDQuote("Notifications are blocked in iOS. Re-enable them in System Settings to receive workout reminders.")
                            .padding(.bottom, 4)
                    }
                }
            }
        }
    }

    // MARK: – About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            BDSectionHeader(title: "About")
            VStack(alignment: .leading, spacing: 0) {
                settingRow(
                    label: "Version",
                    trailing: AnyView(
                        Text("0.1")
                            .font(.system(.footnote, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)
                    )
                )
                BDHairline()
                settingRow(
                    label: "Coach",
                    trailing: AnyView(
                        Text("CLAUDE SONNET 4.6")
                            .font(.system(.footnote, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)
                    )
                )
            }
            BDQuote("BearDown is a hybrid-athlete coaching companion. Your training plan lives on this device and syncs privately via iCloud.")
                .padding(.top, 6)
        }
    }

    // MARK: – Replace key sheet

    private var replaceKeySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        BDEyebrow("BEAR DOWN · KEY")
                        Text("New API key")
                            .font(BDStyle.displayMedium)
                        BDHairline()
                        Text("Paste a new Anthropic API key. It replaces the existing key in the keychain immediately.")
                            .font(BDStyle.bodySerif)
                            .lineSpacing(4)
                            .foregroundStyle(BDStyle.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        BDSectionHeader(title: "Anthropic API Key")
                        SecureField("sk-ant-...", text: $newKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .padding(14)
                            .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(.primary.opacity(0.1), lineWidth: 1)
                            )
                    }
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { newKey = ""; showReplace = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveNewKey() }
                        .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: – Row helper

    private func settingRow(label: String, trailing: AnyView) -> some View {
        HStack(alignment: .firstTextBaseline) {
            BDLabel(label)
            Spacer()
            trailing
        }
        .padding(.vertical, 14)
    }

    // MARK: – Actions

    private func refresh() {
        let v = (try? env.keychain.read(key: .anthropicAPIKey)) ?? ""
        maskedKey = v.isEmpty ? "" : "sk-ant-…" + v.suffix(4)
    }

    private func saveNewKey() {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try env.keychain.write(key: .anthropicAPIKey, value: trimmed)
            newKey = ""
            showReplace = false
            refresh()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
