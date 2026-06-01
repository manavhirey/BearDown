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

        // Week tab is default; wait for tab bar then select Week
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Week"].tap()

        // Wait for the seeded workout card to appear (async seed + SwiftData query)
        let pushCard = app.staticTexts.matching(NSPredicate(format: "label == %@", "Push UI")).firstMatch
        XCTAssertTrue(pushCard.waitForExistence(timeout: 10))

        // Tap the card — tapping the static text triggers the parent Button's action
        pushCard.tap()

        // Detail sheet: tap status menu (toolbar button "Mark…"), then Mark Completed, then Save
        let markMenu = app.buttons["Mark…"]
        XCTAssertTrue(markMenu.waitForExistence(timeout: 5))
        markMenu.tap()

        let markCompletedBtn = app.buttons["Mark Completed"]
        XCTAssertTrue(markCompletedBtn.waitForExistence(timeout: 3))
        markCompletedBtn.tap()

        app.buttons["Save"].tap()
        app.buttons["Done"].tap()

        // Verify the saved status by re-opening the detail sheet:
        // the toolbar menu label should now be "✓ Completed" instead of "Mark…"
        XCTAssertTrue(pushCard.waitForExistence(timeout: 5))
        pushCard.tap()

        // WorkoutDetailSheet currentLabel() returns "✓ Completed" for .completed status
        let completedMenu = app.buttons["✓ Completed"]
        XCTAssertTrue(completedMenu.waitForExistence(timeout: 5))
    }
}
