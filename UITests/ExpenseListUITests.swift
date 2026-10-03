import XCTest

/// The month's summary: its total, and the chip that narrows the list to
/// uncategorised expenses.
///
/// Expects a month, this one or one of the last three, with both categorised
/// ("Aman Taxi") and uncategorised expenses — Tools/seed-demo.sh provides it.
final class ExpenseListUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Expenses"].tap()
    }

    func testUncategorisedFilter() throws {
        let chip = app.buttons["uncategorisedFilter"].firstMatch
        for _ in 0..<3 where !chip.waitForExistence(timeout: 2) {
            app.buttons["Previous month"].firstMatch.tap()
        }
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "a month with uncategorised expenses")
        let categorised = app.staticTexts["Aman Taxi"].firstMatch
        XCTAssertTrue(categorised.exists, "categorised expenses listed before filtering")
        snapshot("1 month")

        chip.tap()
        XCTAssertTrue(chip.label.hasPrefix("Showing"), "the chip shows it's filtering: \(chip.label)")
        XCTAssertFalse(app.staticTexts["Aman Taxi"].waitForExistence(timeout: 1), "categorised expenses hidden")
        let flags = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Uncategorised'"))
        XCTAssertGreaterThan(flags.count, 0, "uncategorised expenses listed")
        snapshot("2 only uncategorised")

        chip.tap()
        XCTAssertTrue(app.staticTexts["Aman Taxi"].waitForExistence(timeout: 3), "tapping again shows them all")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
