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
        let row = app.staticTexts["Aman Taxi"].firstMatch
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
        // The details line, "26 Sep · Taxi · …", whatever day the expense is on.
        let details = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '· Taxi'")).firstMatch
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
        // Counted among today's rows, at the top: the list only keeps the
        // rows on screen, so a count of every "Aman Taxi" wouldn't grow.
        app.navigationBars["Expense"].buttons["Cancel"].tap()
        let today = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS '· Taxi'",
                                                         Date.now.formatted(.dateTime.day().month(.abbreviated))))
        let before = today.count
        app.staticTexts["Aman Taxi"].firstMatch.swipeRight()
        app.buttons["Copy"].tap()
        XCTAssertTrue(app.navigationBars["Expense"].waitForExistence(timeout: 5))
        app.navigationBars["Expense"].buttons["Save"].tap()
        XCTAssertTrue(today.element(boundBy: before).waitForExistence(timeout: 5), "the copy was added, dated today")
        snapshot("6 after copying")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
