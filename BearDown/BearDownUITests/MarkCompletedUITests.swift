import XCTest

final class MarkCompletedUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func test_tapTodayCard_markCompleted_setsGreenCheck() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-stub-validator", "--reset-keychain", "--ui-test-seed-week"]
        app.launch()

        // Onboard
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap(); key.typeText("sk-ant-uitest")
        app.buttons["Continue"].tap()

        // Today tab is default; wait for tab bar then select Today
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Today"].tap()

        // Wait for the seeded workout card to appear (async seed + SwiftData query)
        let pushCard = app.staticTexts.matching(NSPredicate(format: "label == %@", "Push UI")).firstMatch
        XCTAssertTrue(pushCard.waitForExistence(timeout: 10))

        // Tap the card — opens the workout detail sheet
        pushCard.tap()

        // Detail sheet: primary "Complete" action lives in the bottom action bar.
        // Button label is uppercased ("COMPLETE") via the redesigned sheet.
        let completeBtn = app.buttons["COMPLETE"]
        XCTAssertTrue(completeBtn.waitForExistence(timeout: 5))
        completeBtn.tap()

        // Inline note editor appears; SAVE commits the status change.
        let saveBtn = app.buttons["SAVE"]
        XCTAssertTrue(saveBtn.waitForExistence(timeout: 3))
        saveBtn.tap()

        // Close via the top-left Close button (accessibilityLabel "Close").
        app.buttons["Close"].tap()

        // Verify the saved status by re-opening the detail sheet:
        // once completed, the bottom action bar collapses to "RESET TO PENDING".
        XCTAssertTrue(pushCard.waitForExistence(timeout: 5))
        pushCard.tap()

        let resetBtn = app.buttons["RESET TO PENDING"]
        XCTAssertTrue(resetBtn.waitForExistence(timeout: 5))
    }
}
