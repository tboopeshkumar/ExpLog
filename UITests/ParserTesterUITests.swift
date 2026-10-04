import XCTest

/// Settings → Test message parsing: an example message read into a preview,
/// a message that isn't logged, and opening the form from the result.
/// Changes nothing.
final class ParserTesterUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.swipeUp()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Test message parsing'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Test a Message"].waitForExistence(timeout: 5))
    }

    func testReadingAMessage() throws {
        app.buttons["Example"].tap()
        let preview = app.descendants(matching: .any)["preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3), "the example is read")
        XCTAssertTrue(preview.label.contains("Corner Deli"), "its merchant: \(preview.label)")
        XCTAssertTrue(preview.label.contains("42.10"), "its amount: \(preview.label)")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Not found'")).firstMatch.exists,
                       "every field of the example is read, the date included")
        sleep(1)
        snapshot("1 read")

        // The result opens in the form; not saved here.
        app.swipeUp()
        app.buttons["logThis"].tap()
        XCTAssertTrue(app.navigationBars["New Expense"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["amount"].value as? String, "42.1")
        app.navigationBars["New Expense"].buttons["Cancel"].tap()

        // An OTP is recognised as not a payment.
        app.swipeDown()
        app.buttons["Clear"].tap()
        let field = app.textViews["testMessage"].exists ? app.textViews["testMessage"] : app.textFields["testMessage"]
        field.tap()
        field.typeText("Your OTP for transaction of AED 250.00 is 884213. Do not share it.")
        let rejected = app.descendants(matching: .any)["rejected"]
        XCTAssertTrue(rejected.waitForExistence(timeout: 3))
        XCTAssertTrue(rejected.label.contains("Not a card payment"), rejected.label)
        snapshot("2 not a payment")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
