import XCTest

/// A category's page from Summary: its month switcher (shared with Summary),
/// trend chart, and the subcategory page beneath it.
///
/// Expects Transport expenses with a Taxi subcategory in this month or the
/// last, and in more than one month (Tools/seed-demo.sh, then the copy test).
final class SummaryDrilldownUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Summary"].tap()
    }

    private var monthTitle: XCUIElement { app.buttons["monthTitle"].firstMatch }

    func testCategoryPage() throws {
        // Category view, on a month that has Transport.
        app.buttons["Category"].firstMatch.tap()
        let transport = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Transport'")).firstMatch
        for _ in 0..<2 where !transport.waitForExistence(timeout: 2) {
            app.buttons["Previous month"].firstMatch.tap()
        }
        XCTAssertTrue(transport.waitForExistence(timeout: 3), "Transport in the summary")
        let summaryMonth = monthTitle.label
        transport.tap()

        XCTAssertTrue(app.navigationBars["Transport"].waitForExistence(timeout: 5))
        XCTAssertEqual(monthTitle.label, summaryMonth, "opens on Summary's month")
        sleep(1)
        snapshot("1 category page")

        // Stepping a month here keeps the page, and Summary follows.
        let before = monthTitle.label
        let previous = app.buttons["Previous month"].firstMatch
        let next = app.buttons["Next month"].firstMatch
        let goesBack = previous.isEnabled
        (goesBack ? previous : next).tap()
        XCTAssertNotEqual(monthTitle.label, before, "the month changes in place")
        XCTAssertTrue(app.navigationBars["Transport"].exists, "still on the category")
        snapshot("2 another month")
        (goesBack ? next : previous).tap()
        XCTAssertEqual(monthTitle.label, before, "and back")

        // A subcategory row opens that subcategory. The breakdown shows
        // only with two or more, which may be in the other month.
        let taxi = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Taxi'")).firstMatch
        if !taxi.waitForExistence(timeout: 2) { (goesBack ? previous : next).tap() }
        XCTAssertTrue(taxi.waitForExistence(timeout: 3), "a month with Transport split by subcategory")
        taxi.tap()
        XCTAssertTrue(app.navigationBars["Taxi"].waitForExistence(timeout: 5), "the subcategory's own page")
        sleep(1)
        snapshot("3 subcategory page")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
