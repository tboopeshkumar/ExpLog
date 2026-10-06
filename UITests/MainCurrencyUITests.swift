import XCTest

/// Settings → Main currency: the current one, search, and the confirmation
/// before switching. Cancels, so nothing changes.
///
/// Expects AED as the main currency and at least one expense.
final class MainCurrencyUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Main currency'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Main currency"].waitForExistence(timeout: 5))
    }

    func testSearchAndConfirmation() throws {
        let current = app.descendants(matching: .any)["currentMain"]
        XCTAssertTrue(current.waitForExistence(timeout: 3))
        XCTAssertTrue(current.label.contains("AED"), "the current main currency: \(current.label)")
        XCTAssertFalse(app.buttons["currency-AED"].exists, "not offered as a change to itself")
        sleep(1)
        snapshot("1 main currency")

        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("euro")
        let euro = app.buttons["currency-EUR"]
        XCTAssertTrue(euro.waitForExistence(timeout: 3), "search finds the euro by name")
        XCTAssertFalse(app.buttons["currency-USD"].exists, "and hides the rest")
        euro.tap()

        // Switching says what it does, and can be cancelled.
        let change = app.buttons["Change to EUR"]
        XCTAssertTrue(change.waitForExistence(timeout: 3), "the switch is confirmed first")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Totals will be counted in EUR'")).firstMatch.exists)
        snapshot("2 confirmation")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(change.waitForNonExistence(timeout: 3), "cancelled without changing")
        XCTAssertTrue(app.navigationBars["Main currency"].exists, "still on the page")
        XCTAssertTrue(euro.exists, "EUR is still only offered, not chosen")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
