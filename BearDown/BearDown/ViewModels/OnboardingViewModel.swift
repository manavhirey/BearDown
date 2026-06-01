import Combine
import Foundation

@MainActor
public final class OnboardingViewModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case validating
        case success
        case error(String)
    }


    @Published public var apiKey: String = ""
    @Published public var state: State = .idle

    private let keychain: KeychainStore
    private let validate: (String) async throws -> Void

    public init(keychain: KeychainStore,
                validate: @escaping (String) async throws -> Void) {
        self.keychain = keychain
        self.validate = validate
    }

    public func submit() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .error("Enter your Anthropic API key.")
            return
        }
        state = .validating
        do {
            try await validate(trimmed)
            try keychain.write(key: .anthropicAPIKey, value: trimmed)
            state = .success
        } catch {
            state = .error("Couldn't validate that key. Check it and try again.")
        }
    }
}
