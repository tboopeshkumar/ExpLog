import XCTest

/// Adding an expense by hand: the amount field, Next, category and
/// subcategory chips, Save. Deletes what it adds, so it can run again.
///
/// Expects the seeded Transport category with a Taxi subcategory.
final class ExpenseFormUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Expenses"].tap()
    }

    func testAddingAnExpenseByHand() throws {
        app.navigationBars.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Expense"].waitForExistence(timeout: 5))

        // Focused on its own, so typing goes straight in.
        let amount = app.textFields["amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertTrue(amount.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "the amount has the keyboard")
        // A key at a time, as a person types: a stray second "." and a
        // third decimal are both ignored.
        for key in "42.5.67" {
            amount.typeText(String(key))
            usleep(150_000)
        }
        XCTAssertEqual(amount.value as? String, "42.56", "one decimal mark, two decimals for dirhams")
        snapshot("1 amount")

        app.buttons["Next"].firstMatch.tap()
        let merchant = app.textFields["Merchant"]
        XCTAssertTrue(merchant.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "Next moves to the merchant")
        merchant.typeText("Form Test Cab\n")

        let transport = app.buttons["category-Transport"]
        XCTAssertTrue(transport.waitForExistence(timeout: 3))
        transport.tap()
        XCTAssertTrue(transport.isSelected, "the chip shows it's chosen")
        let taxi = app.buttons["subcategory-Taxi"]
        XCTAssertTrue(taxi.waitForExistence(timeout: 3), "the category's subcategories appear")
        taxi.tap()
        XCTAssertTrue(taxi.isSelected)
        snapshot("2 category chosen")

        let save = app.navigationBars["New Expense"].buttons["Save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let row = app.staticTexts["Form Test Cab"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "saved into the list")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Taxi'")).firstMatch.exists,
                      "with its subcategory")

        // Reopened, it's an edit with its choices showing.
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit Expense"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["amount"].value as? String, "42.56")
        XCTAssertTrue(app.buttons["category-Transport"].isSelected)
        snapshot("3 editing")
        app.navigationBars["Edit Expense"].buttons["Cancel"].tap()

        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Form Test Cab"].waitForExistence(timeout: 2), "cleaned up")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
