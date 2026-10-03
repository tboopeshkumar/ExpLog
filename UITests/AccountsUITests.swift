import XCTest

/// Settings → Cards & accounts: adding a card, the keyword clash warning,
/// deleting. Deletes what it adds, so it can run again.
///
/// Expects at least one card with a keyword (Tools/seed-demo.sh).
final class AccountsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Cards & accounts'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Cards & accounts"].waitForExistence(timeout: 5))
    }

    func testAddingAndDeletingACard() throws {
        sleep(1)
        snapshot("1 cards")
        let taken = app.staticTexts["keyword"].firstMatch.label
        XCTAssertFalse(taken.isEmpty, "a card with a keyword to clash with")
        app.navigationBars["Cards & accounts"].buttons["Add Card"].tap()
        XCTAssertTrue(app.navigationBars["New Card"].waitForExistence(timeout: 3))

        let fields = app.textFields
        fields.element(boundBy: 0).tap()
        fields.element(boundBy: 0).typeText("UI Test Card")
        fields.element(boundBy: 1).tap()
        fields.element(boundBy: 1).typeText(taken)
        let save = app.navigationBars["New Card"].buttons["Save"]
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'is already on'")).firstMatch
            .waitForExistence(timeout: 3), "another card's keyword is flagged")
        XCTAssertFalse(save.isEnabled, "and can't be saved")
        snapshot("2 clash")

        // Replace it with a keyword of its own.
        fields.element(boundBy: 1).press(forDuration: 1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        fields.element(boundBy: 1).typeText("XXXX7777")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let row = app.staticTexts["UI Test Card"]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the new card is listed")
        XCTAssertTrue(app.staticTexts["XXXX7777"].exists, "with its keyword")

        // No expenses: swipe deletes it without asking.
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["UI Test Card"].waitForExistence(timeout: 2), "deleted")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
