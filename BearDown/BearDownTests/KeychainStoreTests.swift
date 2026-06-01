import XCTest
@testable import BearDown

final class KeychainStoreTests: XCTestCase {
    private let testService = "com.beardown.tests.\(UUID().uuidString)"
    private var store: KeychainStore!

    override func setUp() {
        store = KeychainStore(service: testService)
        try? store.delete(key: .anthropicAPIKey)
    }

    override func tearDown() {
        try? store.delete(key: .anthropicAPIKey)
    }

    func test_readMissingKey_returnsNil() throws {
        XCTAssertNil(try store.read(key: .anthropicAPIKey))
    }

    func test_writeThenRead_returnsTheValue() throws {
        try store.write(key: .anthropicAPIKey, value: "sk-ant-xyz")
        XCTAssertEqual(try store.read(key: .anthropicAPIKey), "sk-ant-xyz")
    }

    func test_overwrite_replacesPriorValue() throws {
        try store.write(key: .anthropicAPIKey, value: "v1")
        try store.write(key: .anthropicAPIKey, value: "v2")
        XCTAssertEqual(try store.read(key: .anthropicAPIKey), "v2")
    }

    func test_delete_removesTheValue() throws {
        try store.write(key: .anthropicAPIKey, value: "sk-ant-xyz")
        try store.delete(key: .anthropicAPIKey)
        XCTAssertNil(try store.read(key: .anthropicAPIKey))
    }
}
