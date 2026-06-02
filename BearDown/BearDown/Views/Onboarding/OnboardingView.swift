import SwiftUI

public struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    public var onComplete: () -> Void

    @FocusState private var keyFieldFocused: Bool

    public init(viewModel: OnboardingViewModel, onComplete: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onComplete = onComplete
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                hero
                form
                validationBlock
                footnote
                Color.clear.frame(height: 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) { actionBar }
        .animation(.easeInOut(duration: 0.22), value: viewModel.state)
    }

    // MARK: – Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            BDEyebrow("BEAR DOWN · ONBOARDING")
            Text("Set up your coach.")
                .font(BDStyle.displayTitle)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            BDHairline()
            Text("BearDown talks to Anthropic directly from your phone. To start, paste your API key. It’s stored only in this device’s keychain — never on a server, never synced.")
                .font(BDStyle.bodySerif)
                .lineSpacing(5)
                .foregroundStyle(BDStyle.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: – Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            BDSectionHeader(title: "Anthropic API Key")
            SecureField("sk-ant-...", text: $viewModel.apiKey)
                .focused($keyFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .padding(14)
                .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(keyFieldFocused ? 0.4 : 0.1),
                                lineWidth: 1)
                )
                .submitLabel(.go)
                .onSubmit { trySubmit() }

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("STORED IN KEYCHAIN · NEVER LEAVES THIS DEVICE")
                    .font(BDStyle.monoTiny)
                    .tracking(BDStyle.trackingWide)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Link(destination: URL(string: "https://console.anthropic.com")!) {
                HStack(spacing: 6) {
                    Text("GET A KEY AT CONSOLE.ANTHROPIC.COM")
                        .font(BDStyle.monoTiny)
                        .tracking(BDStyle.trackingWide)
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.primary.opacity(0.75))
            }
            .padding(.top, 2)
        }
    }

    // MARK: – Validation states

    @ViewBuilder
    private var validationBlock: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 10) {
                BDStatusPill(label: "Validating", systemImage: "ellipsis", color: .secondary)
                Spacer()
            }
        case .success:
            HStack(spacing: 10) {
                BDStatusPill(label: "Validated", systemImage: "checkmark", color: .green)
                Spacer()
            }
        case .error(let msg):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    BDStatusPill(label: "Error", systemImage: "exclamationmark.triangle.fill", color: .red)
                    Spacer()
                }
                BDQuote(msg)
            }
        }
    }

    // MARK: – Footnote

    private var footnote: some View {
        BDQuote("Showing up is the workout. The coach is just the map.")
    }

    // MARK: – Action bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            BDHairline()
            Button {
                trySubmit()
            } label: {
                HStack(spacing: 8) {
                    if viewModel.state == .validating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Text("Continue")
                            .font(BDStyle.monoSmall)
                            .tracking(BDStyle.trackingWide)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .controlSize(.large)
            .disabled(isSubmitDisabled)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private var isSubmitDisabled: Bool {
        if viewModel.state == .validating { return true }
        return viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func trySubmit() {
        guard !isSubmitDisabled else { return }
        Task {
            await viewModel.submit()
            if viewModel.state == .success { onComplete() }
        }
    }
}
