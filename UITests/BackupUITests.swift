import XCTest

/// Settings → Backup: choosing a folder in Files writes a backup and shows
/// when; turning it off puts the page back. Leaves backup off.
final class BackupUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.swipeUp()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backup'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 5))
    }

    func testChoosingAFolderBacksUp() throws {
        if app.buttons["Turn Off Backup"].exists { app.buttons["Turn Off Backup"].tap() }
        XCTAssertTrue(app.staticTexts["Backup is off"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Restore from a Backup…"].exists)
        snapshot("1 off")

        // The Files picker starts on Recents, where Open is greyed out:
        // browse to On My iPhone and open that.
        app.buttons["Choose a Folder…"].tap()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8), "the folder picker opens")
        if !open.isEnabled {
            app.buttons["Browse"].firstMatch.tap()
            let onPhone = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
            if onPhone.waitForExistence(timeout: 4), onPhone.isHittable { onPhone.tap() }
        }
        sleep(1)
        snapshot("2 picker")
        XCTAssertTrue(open.isEnabled, "a folder is chosen")
        open.tap()

        XCTAssertTrue(app.staticTexts["Backup is on"].waitForExistence(timeout: 8), "a folder turns backup on")
        let last = app.descendants(matching: .any)["lastBackup"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(last.label.contains("expenses"), "the first backup is written straight away: \(last.label)")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'write the backup'")).firstMatch.exists,
                       "no write error")
        snapshot("3 on")

        app.buttons["Turn Off Backup"].tap()
        XCTAssertTrue(app.staticTexts["Backup is off"].waitForExistence(timeout: 3))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
