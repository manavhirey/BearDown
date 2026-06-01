import XCTest

final class OnboardingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func test_pasteKey_andLandOnCoachTab() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-stub-validator", "--reset-keychain"]
        app.launch()

        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.typeText("sk-ant-uitest")

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Coach"].tap()
        XCTAssertTrue(app.navigationBars["Coach"].exists)
    }
}
