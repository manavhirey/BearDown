import SwiftUI

public struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    public var onComplete: () -> Void

    public init(viewModel: OnboardingViewModel, onComplete: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("BearDown").font(.largeTitle.bold())
            Text("Paste your Anthropic API key to get started. It's stored only on this device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            SecureField("sk-ant-...", text: $viewModel.apiKey)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal)

            if case let .error(msg) = viewModel.state {
                Text(msg).foregroundStyle(.red).font(.footnote)
            }

            Button {
                Task {
                    await viewModel.submit()
                    if viewModel.state == .success { onComplete() }
                }
            } label: {
                if viewModel.state == .validating {
                    ProgressView()
                } else {
                    Text("Continue").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .disabled(viewModel.state == .validating)

            Link("Get a key at console.anthropic.com",
                 destination: URL(string: "https://console.anthropic.com")!)
                .font(.footnote)

            Spacer()
        }
        .padding()
    }
}
