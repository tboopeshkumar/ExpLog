import XCTest

/// Settings → Categories: adding one with an icon, the duplicate-name
/// warning, a subcategory, and deleting. Deletes what it adds.
///
/// Expects the seeded Dining category.
final class CategoriesUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Categories'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 5))
    }

    func testAddingEditingAndDeletingACategory() throws {
        sleep(1)
        // Left behind if an earlier run was cut short.
        let leftover = app.staticTexts["Dining Out"]
        if leftover.exists {
            leftover.swipeLeft()
            app.buttons["Delete"].firstMatch.tap()
        }
        snapshot("1 categories")
        app.navigationBars["Categories"].buttons["Add Category"].tap()
        XCTAssertTrue(app.navigationBars["New Category"].waitForExistence(timeout: 3))

        let name = app.textFields["Name"]
        name.tap()
        name.typeText("Dining")
        let save = app.navigationBars["New Category"].buttons["Save"]
        XCTAssertTrue(app.staticTexts["There's already a category called “Dining”."].waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled, "a duplicate name can't be saved")

        name.typeText(" Out")
        app.buttons["pawprint"].tap()
        XCTAssertTrue(app.buttons["pawprint"].isSelected, "the icon is chosen")
        snapshot("2 new category")
        save.tap()

        let row = app.staticTexts["Dining Out"]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the new category is listed")
        row.tap()
        XCTAssertTrue(app.navigationBars["Dining Out"].waitForExistence(timeout: 3))

        let sub = app.textFields["Add subcategory"]
        sub.tap()
        sub.typeText("Brunch\n")
        XCTAssertTrue(app.buttons["Brunch"].waitForExistence(timeout: 3), "the subcategory is added")
        sleep(1)
        snapshot("3 detail")

        // The icon is a row that opens the grid; choosing one comes back.
        let iconRow = app.buttons["iconRow"]
        for _ in 0..<3 where !iconRow.isHittable { app.swipeUp() }
        iconRow.tap()
        XCTAssertTrue(app.navigationBars["Icon"].waitForExistence(timeout: 3))
        app.buttons["gift"].tap()
        XCTAssertTrue(app.navigationBars["Dining Out"].waitForExistence(timeout: 3), "back on the category")

        // No expenses: deleted without a question, back to the list.
        app.buttons["Delete Category"].tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Dining Out"].waitForExistence(timeout: 2), "deleted")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
