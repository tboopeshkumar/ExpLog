import XCTest

/// Picking a misread merchant out of the original message.
///
/// Expects a "Shopnovaufr Di" expense in this month or one of the last three, from Tools/seed-demo.sh,
/// read from a debit-card alert. Cancels at the end, so it can run again.
final class MerchantPickerUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Expenses"].tap()
    }

    func testPickingTheMerchantFromTheMessage() throws {
        // The seeded alert may be in an earlier month than today's.
        let row = app.staticTexts["Shopnovaufr Di"].firstMatch
        for _ in 0..<3 where !row.waitForExistence(timeout: 2) {
            app.buttons["Previous month"].firstMatch.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the seeded expense is listed")
        row.tap()

        let pick = app.buttons["pickMerchant"].firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "the form offers to pick the merchant")
        snapshot("1 form")
        pick.tap()

        XCTAssertTrue(app.navigationBars["Pick merchant"].waitForExistence(timeout: 5))
        // The parser's reading starts out selected: both words.
        let name = app.buttons.matching(NSPredicate(format: "label == 'SHOPNOVAUFR'")).firstMatch
        let city = app.buttons.matching(NSPredicate(format: "label == 'DI,'")).firstMatch
        XCTAssertTrue(name.isSelected && city.isSelected, "the parser's reading is preselected")
        sleep(1)
        snapshot("2 picker")

        // A tap on a range starts again from that word: just the name.
        name.tap()
        XCTAssertTrue(name.isSelected && !city.isSelected, "one word picked")
        snapshot("3 name only")
        app.buttons["Use"].firstMatch.tap()

        let field = app.textFields["Merchant"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Shopnovaufr", "the merchant is the picked word")
        XCTAssertTrue(app.staticTexts["Messages like this one will read the merchant from the same place."].exists,
                      "the form says the format was learned")
        snapshot("4 picked")

        app.buttons["Cancel"].firstMatch.tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
