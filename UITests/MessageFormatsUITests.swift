import XCTest

/// Settings → Message formats: a learned format's row, its page, trying
/// another message against it, and forgetting it. Learns the format itself
/// (picking the merchant as already read, so the expense is unchanged) and
/// forgets it at the end.
///
/// Expects a "Shopnovaufr Di" expense from a debit-card alert in this month
/// or one of the last three (Tools/seed-demo.sh).
final class MessageFormatsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }

    private func openFormats() {
        app.tabBars.buttons["Settings"].tap()
        app.swipeUp()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Message formats'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Message formats"].waitForExistence(timeout: 5))
    }

    func testLearnedFormat() throws {
        // Learn: pick the merchant where it already is, and remember it.
        app.tabBars.buttons["Expenses"].tap()
        let expense = app.staticTexts["Shopnovaufr Di"].firstMatch
        for _ in 0..<3 where !expense.waitForExistence(timeout: 2) {
            app.buttons["Previous month"].firstMatch.tap()
        }
        XCTAssertTrue(expense.waitForExistence(timeout: 5), "the seeded expense is listed")
        expense.tap()
        app.buttons["pickMerchant"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Pick merchant"].waitForExistence(timeout: 5))
        app.buttons["Use"].firstMatch.tap()
        app.navigationBars["Edit Expense"].buttons["Save"].tap()

        openFormats()
        let row = app.buttons["formatRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the learned format is listed")
        XCTAssertTrue(app.staticTexts["Debit Card…"].exists, "named by how its messages open")
        sleep(1)
        snapshot("1 formats")

        row.tap()
        XCTAssertTrue(app.navigationBars["Message format"].waitForExistence(timeout: 3))
        sleep(1)
        snapshot("2 format page")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Shopnovaufr Di'")).firstMatch.exists,
                      "what it reads")

        // Another alert in the same format: read from the same place.
        let trial = app.textViews["trialMessage"].exists ? app.textViews["trialMessage"] : app.textFields["trialMessage"]
        trial.tap()
        trial.typeText("Debit Card XX9014 linked to account XX660213 was used for AED15.00 on Oct 2 2026 8:15PM at BLUE DOOR CAFE, AE. Available Balance AED 10.50")
        XCTAssertTrue(app.staticTexts["Reads “Blue Door Cafe”"].waitForExistence(timeout: 3), "a message in the format is read")
        snapshot("3 trial")

        if app.keyboards.firstMatch.exists { app.swipeUp() }
        app.buttons["Forget Format"].tap()
        XCTAssertTrue(app.navigationBars["Message formats"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No message formats"].waitForExistence(timeout: 3), "forgotten")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
