import XCTest

/// Settings → Merchants: the list, sorting, and the editor with its category
/// list. Changes nothing, so it can run again.
///
/// Expects at least two remembered merchants (Tools/seed-demo.sh).
final class MerchantsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.swipeUp()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merchants'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Merchants"].waitForExistence(timeout: 5))
    }

    func testListSortAndEditor() throws {
        let rows = app.buttons.matching(identifier: "merchantRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "merchants are listed")
        sleep(1)
        snapshot("1 merchants")

        // Sorting reorders the list and is remembered; put it back after.
        app.navigationBars["Merchants"].buttons["Sort"].tap()
        app.buttons["Most Expenses"].tap()
        sleep(1)
        snapshot("2 most expenses")
        app.navigationBars["Merchants"].buttons["Sort"].tap()
        app.buttons["Name"].tap()

        // The editor: name, category row opening the shared list.
        rows.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Merchant"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Forget Merchant"].exists)
        sleep(1)
        snapshot("3 editor")
        app.buttons["categoryRow"].tap()
        XCTAssertTrue(app.navigationBars["Category"].waitForExistence(timeout: 3), "the category list opens")
        app.navigationBars["Category"].buttons["Cancel"].tap()
        app.navigationBars["Merchant"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Merchants"].waitForExistence(timeout: 3))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
