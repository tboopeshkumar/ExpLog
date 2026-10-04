import XCTest

/// Settings → Set up automatic logging: the steps, a phrase to copy, and the
/// review setting (put back as found). Doesn't open Shortcuts.
final class ShortcutSetupUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Set up automatic logging'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Automatic logging"].waitForExistence(timeout: 5))
    }

    func testStepsPhraseAndSetting() throws {
        XCTAssertTrue(app.staticTexts["Log alerts as they arrive"].exists)
        let first = app.descendants(matching: .any)["step-1"]
        XCTAssertTrue(first.exists && first.label.contains("Start an automation"), "the first step")
        sleep(1)
        snapshot("1 top")

        // A phrase from the logged alerts, copied for step 3.
        let copy = app.buttons["copyPhrase"].firstMatch
        for _ in 0..<3 where !copy.isHittable { app.swipeUp() }
        copy.tap()
        XCTAssertEqual(copy.label, "Copied")
        XCTAssertTrue(app.descendants(matching: .any)["step-6"].exists, "six steps")
        snapshot("2 phrases")

        // The same setting as on the Settings page.
        let review = app.switches["Review before saving"]
        for _ in 0..<3 where !review.isHittable { app.swipeUp() }
        let was = review.value as? String
        review.switches.firstMatch.exists ? review.switches.firstMatch.tap() : review.tap()
        XCTAssertNotEqual(review.value as? String, was, "the setting changes")
        review.switches.firstMatch.exists ? review.switches.firstMatch.tap() : review.tap()
        XCTAssertEqual(review.value as? String, was, "and back")

        app.swipeUp()
        XCTAssertTrue(app.buttons["Open Shortcuts"].exists || app.links["Open Shortcuts"].exists)
        sleep(1)
        snapshot("3 bottom")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
