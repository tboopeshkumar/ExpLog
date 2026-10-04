import XCTest

/// Searching expenses: the summary, matching by merchant and by amount, and
/// a month heading opening that month. Changes nothing.
///
/// Expects "Aman Taxi" expenses and a Skyways Air instalment of 444.25
/// (Tools/seed-demo.sh).
final class SearchUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Expenses"].tap()
    }

    private func search(_ text: String) {
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 2) { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the search field")
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty, existing != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }

    func testSearchingAcrossMonths() throws {
        search("taxi")
        let summary = app.descendants(matching: .any)["searchSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3), "results are summarised")
        XCTAssertTrue(summary.label.contains("expenses"), summary.label)
        XCTAssertTrue(app.staticTexts["Aman Taxi"].firstMatch.exists)
        sleep(1)
        snapshot("1 by merchant")

        // By amount: only the instalments of exactly that much.
        search("444.25")
        XCTAssertTrue(app.staticTexts["Skyways Air"].firstMatch.waitForExistence(timeout: 3), "found by amount")
        XCTAssertFalse(app.staticTexts["Aman Taxi"].firstMatch.exists, "and nothing else")
        snapshot("2 by amount")

        // A month's heading leaves search and opens that month.
        let heading = app.buttons["searchMonth"].firstMatch
        let month = heading.label.components(separatedBy: ",").first ?? heading.label
        heading.tap()
        let title = app.buttons["monthTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(month.contains(title.label), "opened \(title.label), from the heading “\(month)”")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
