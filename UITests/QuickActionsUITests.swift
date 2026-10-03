import XCTest

/// Drives the expense row's quick actions in the simulator — the parts a
/// logic test can't reach: that the swipes are there, and that they work.
///
///     xcodebuild test -scheme ExpLog -destination 'platform=iOS Simulator,name=…'
///
/// Expects an uncategorised expense named "Aman Taxi" on the Expenses tab,
/// and a Transport category with a Taxi subcategory (the seed data plus a
/// scratch row are enough). Screenshots are attached to the result bundle.
final class QuickActionsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Expenses"].tap()
    }

    func testSwipeToCategoriseCopyAndDelete() throws {
        // The seeded taxi rides may be in an earlier month than today's.
        let row = app.staticTexts["Aman Taxi"].firstMatch
        for _ in 0..<3 where !row.waitForExistence(timeout: 2) {
            app.buttons["Previous month"].firstMatch.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "expected an expense named Aman Taxi")

        // Swipe right: Categorise and Copy.
        row.swipeRight()
        snapshot("1 swipe right")
        XCTAssertTrue(app.buttons["Copy"].exists, "Copy action")
        let categorise = app.buttons["Categorise"]
        XCTAssertTrue(categorise.exists, "Categorise action")

        // Categorise → Transport › Taxi.
        categorise.tap()
        let taxi = app.buttons["Taxi"].firstMatch
        XCTAssertTrue(taxi.waitForExistence(timeout: 5), "subcategories listed under their category")
        sleep(1)   // let the sheet finish sliding in before the screenshot
        snapshot("2 categorise sheet")
        taxi.tap()
        XCTAssertTrue(app.staticTexts["Aman Taxi"].waitForExistence(timeout: 5))
        // The details line under a day heading: "Taxi · SIB Cashback".
        let details = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Taxi'")).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5), "the row now shows the subcategory")
        snapshot("3 after categorising")

        // Swipe left: Delete is still there (not tapped).
        app.staticTexts["Aman Taxi"].firstMatch.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3), "swipe left still offers Delete")
        snapshot("4 swipe left")
        app.staticTexts["Aman Taxi"].firstMatch.swipeRight()   // close it again

        // Copy opens the form, dated today, and saving adds a second one.
        app.staticTexts["Aman Taxi"].firstMatch.swipeRight()
        app.buttons["Copy"].tap()
        XCTAssertTrue(app.navigationBars["Expense"].waitForExistence(timeout: 5), "the copy opens in the form")
        snapshot("5 copy form")
        // Saved with today's date, so it's under Today in this month.
        app.navigationBars["Expense"].buttons["Save"].tap()
        app.buttons["monthTitle"].firstMatch.tap()
        app.buttons["This month"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 5), "the copy is dated today")
        XCTAssertTrue(app.staticTexts["Aman Taxi"].exists, "the copy was added")
        snapshot("6 after copying")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
