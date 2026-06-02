import XCTest

final class ChatHistoryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func test_historyFlow_listSwitchDelete() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-stub-validator",
            "--reset-keychain",
            "--ui-test-seed-chat-history",
        ]
        app.launch()

        // Onboard.
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap(); key.typeText("sk-ant-uitest")
        app.buttons["Continue"].tap()

        // Coach tab.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Coach"].tap()
        XCTAssertTrue(app.staticTexts["Today's session"].waitForExistence(timeout: 5))

        // Open HISTORY.
        let historyButton = app.buttons["Chat history"]
        XCTAssertTrue(historyButton.waitForExistence(timeout: 5))
        historyButton.tap()

        // The page header confirms we landed on the history view.
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))

        // Two rows exist (the current empty conversation is filtered out).
        // We don't know the row UUIDs up front, so match the row by its title text.
        let rowB = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "How heavy on Tuesday?")).firstMatch
        let rowA = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Plan my taper week")).firstMatch
        XCTAssertTrue(rowB.waitForExistence(timeout: 5))
        XCTAssertTrue(rowA.exists)

        // Tap row B -> back to Coach showing B's content.
        rowB.tap()
        XCTAssertTrue(app.staticTexts["Top sets at 80%."].waitForExistence(timeout: 5))

        // Re-open HISTORY, swipe row A, delete.
        historyButton.tap()
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))
        let rowAAgain = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Plan my taper week")).firstMatch
        XCTAssertTrue(rowAAgain.waitForExistence(timeout: 5))
        rowAAgain.swipeLeft()

        // Tap the swipe-revealed Delete button.
        let deleteCell = app.buttons["Delete"]
        XCTAssertTrue(deleteCell.waitForExistence(timeout: 5))
        deleteCell.tap()

        // Destructive confirmation alert.
        let confirm = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Row A is gone; row B remains.
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@",
                                                         "Plan my taper week")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@",
                                                        "How heavy on Tuesday?")).firstMatch.exists)
    }
}
