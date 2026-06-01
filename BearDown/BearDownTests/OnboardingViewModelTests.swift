import XCTest
@testable import BearDown

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private let service = "com.beardown.tests.onboarding.\(UUID().uuidString)"
    private var keychain: KeychainStore!

    override func setUp() {
        keychain = KeychainStore(service: service)
        try? keychain.delete(key: .anthropicAPIKey)
    }

    override func tearDown() {
        try? keychain.delete(key: .anthropicAPIKey)
    }

    func test_submit_savesKeyOnSuccess() async throws {
        let vm = OnboardingViewModel(keychain: keychain, validate: { _ in })
        vm.apiKey = "sk-ant-xyz"
        await vm.submit()
        XCTAssertEqual(vm.state, .success)
        XCTAssertEqual(try keychain.read(key: .anthropicAPIKey), "sk-ant-xyz")
    }

    func test_submit_doesNotSaveOnFailure() async throws {
        struct E: Error {}
        let vm = OnboardingViewModel(keychain: keychain, validate: { _ in throw E() })
        vm.apiKey = "sk-ant-bad"
        await vm.submit()
        if case let .error(msg) = vm.state {
            XCTAssertFalse(msg.isEmpty)
        } else {
            XCTFail("Expected .error, got \(vm.state)")
        }
        XCTAssertNil(try keychain.read(key: .anthropicAPIKey))
    }

    func test_submit_rejectsEmptyKey() async {
        let vm = OnboardingViewModel(keychain: keychain, validate: { _ in })
        vm.apiKey = "   "
        await vm.submit()
        XCTAssertEqual(vm.state, .error("Enter your Anthropic API key."))
    }
}
