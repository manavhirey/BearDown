import XCTest

final class ApprovalGateUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func test_addAsInactive_appliesEnvelopeAndShowsPlan() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-stub-validator",
            "--reset-keychain",
            "--ui-test-seed-pending-proposal",
        ]
        app.launch()

        // Onboard
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap(); key.typeText("sk-ant-uitest")
        app.buttons["Continue"].tap()

        // Coach tab
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Coach"].tap()

        // The seeded proposal chip is visible.
        let addInactive = app.buttons["proposal.addInactive"]
        XCTAssertTrue(addInactive.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["proposal.addAndSwitch"].exists)
        XCTAssertTrue(app.buttons["proposal.dismiss"].exists)

        // Tap Add as inactive.
        addInactive.tap()

        // The pending CTAs disappear (applied state has no buttons).
        XCTAssertFalse(addInactive.waitForExistence(timeout: 3))

        // Plans tab: the new plan is present (inactive).
        app.tabBars.buttons["Plan"].tap()
        let newCard = app.buttons["plan.card.Seeded Proposal Plan"]
        XCTAssertTrue(newCard.waitForExistence(timeout: 5))
    }

    func test_dismiss_marksProposalDismissed_andDoesNotCreatePlan() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-stub-validator",
            "--reset-keychain",
            "--ui-test-seed-pending-proposal",
        ]
        app.launch()

        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap(); key.typeText("sk-ant-uitest")
        app.buttons["Continue"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Coach"].tap()
        let dismiss = app.buttons["proposal.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertFalse(dismiss.waitForExistence(timeout: 3))

        app.tabBars.buttons["Plan"].tap()
        XCTAssertFalse(app.buttons["plan.card.Seeded Proposal Plan"].exists)
    }
}
