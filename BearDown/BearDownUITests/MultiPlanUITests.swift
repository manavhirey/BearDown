import XCTest

final class MultiPlanUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func test_listShowsBothPlans_switchActive_deleteArchived() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-stub-validator",
            "--reset-keychain",
            "--ui-test-seed-two-plans",
        ]
        app.launch()

        // Onboard
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap(); key.typeText("sk-ant-uitest")
        app.buttons["Continue"].tap()

        // Plans tab
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Plan"].tap()

        // Two cards visible (active first), one with ACTIVE pill.
        let currentCard = app.buttons["plan.card.Current Block"]
        let raceCard = app.buttons["plan.card.Race Prep — June 24"]
        XCTAssertTrue(currentCard.waitForExistence(timeout: 10))
        XCTAssertTrue(raceCard.waitForExistence(timeout: 5))

        // Tap the inactive (race) card -> detail with MAKE ACTIVE.
        raceCard.tap()
        let makeActive = app.buttons["plan.makeActive"]
        XCTAssertTrue(makeActive.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plan.delete"].exists)

        // Make it active. MAKE ACTIVE disappears (button no longer rendered).
        makeActive.tap()
        XCTAssertFalse(makeActive.waitForExistence(timeout: 3))

        // Pop back via the nav bar back button.
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Open the (now archived) "Current Block" card and delete it.
        let currentCard2 = app.buttons["plan.card.Current Block"]
        XCTAssertTrue(currentCard2.waitForExistence(timeout: 5))
        currentCard2.tap()
        app.buttons["plan.delete"].tap()
        // Confirm destructive alert.
        app.alerts.buttons["Delete"].tap()

        // Pops back to list with only Race Prep present.
        XCTAssertTrue(app.buttons["plan.card.Race Prep — June 24"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["plan.card.Current Block"].exists)
    }
}
