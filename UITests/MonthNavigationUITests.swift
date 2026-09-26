import XCTest

/// Month-by-month Expenses: the arrows, the month list, "This month", and
/// Summary following the same month.
///
/// Expects expenses this month and at least one future-dated expense a month
/// or more ahead (an imported instalment is enough).
final class MonthNavigationUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Expenses"].tap()
    }

    private func title(_ monthsFromNow: Int) -> String {
        Calendar.current.date(byAdding: .month, value: monthsFromNow, to: .now)!
            .formatted(.dateTime.month(.wide).year())
    }

    private var monthTitle: XCUIElement { app.buttons["monthTitle"].firstMatch }

    func testSwitchingMonths() throws {
        XCTAssertTrue(monthTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(monthTitle.label, title(0), "opens on this month")
        snapshot("1 this month")

        // Arrow forward: next month, with its own expenses only.
        app.buttons["Next month"].firstMatch.tap()
        XCTAssertTrue(monthTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(monthTitle.label, title(1), "next month")
        snapshot("2 next month")

        // Summary follows the same month.
        app.tabBars.buttons["Summary"].tap()
        XCTAssertTrue(monthTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(monthTitle.label, title(1), "Summary shows the month chosen in Expenses")
        app.tabBars.buttons["Expenses"].tap()

        // The month list: jump several months at once.
        monthTitle.tap()
        XCTAssertTrue(app.navigationBars["Choose month"].waitForExistence(timeout: 5), "month list opens")
        sleep(1)
        snapshot("3 month list")
        let target = Calendar.current.date(byAdding: .month, value: 3, to: .now)!
        let monthName = target.formatted(.dateTime.month(.wide))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", monthName)).firstMatch
        XCTAssertTrue(row.exists, "\(monthName) is listed")
        row.tap()
        XCTAssertTrue(monthTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(monthTitle.label, title(3), "jumped straight there")

        // Back to this month in one tap.
        monthTitle.tap()
        app.buttons["This month"].firstMatch.tap()
        XCTAssertTrue(monthTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(monthTitle.label, title(0), "This month comes back")
        snapshot("4 back to this month")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
