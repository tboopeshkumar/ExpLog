import XCTest

/// Adding an expense by hand: the amount field, Next, the currency,
/// category and card lists, Save. Deletes what it adds, so it can run again.
///
/// Expects the seeded Transport category with a Taxi subcategory, and a card.
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

        // Currency: a list in a sheet, searchable; a sign only where it's a symbol.
        app.buttons["currencyPill"].tap()
        XCTAssertTrue(app.navigationBars["Currency"].waitForExistence(timeout: 3))
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("rial")
        let omr = app.buttons["currency-OMR"]
        XCTAssertTrue(omr.waitForExistence(timeout: 3), "search finds the Omani rial by name")
        snapshot("2 currency search")
        omr.tap()
        XCTAssertTrue(app.staticTexts["OMR"].waitForExistence(timeout: 3), "the pill says OMR once")
        XCTAssertFalse(app.staticTexts["OMR OMR"].exists)
        app.buttons["currencyPill"].tap()
        app.buttons["currency-AED"].tap()

        // Category: the row opens the list; a subcategory sets both.
        app.buttons["categoryRow"].tap()
        XCTAssertTrue(app.navigationBars["Category"].waitForExistence(timeout: 3))
        sleep(1)
        snapshot("3 category list")
        app.buttons["subcategory-Taxi"].tap()
        XCTAssertTrue(app.staticTexts["Transport › Taxi"].waitForExistence(timeout: 3), "the row shows the choice")

        // Paid with: the same pattern.
        app.buttons["accountRow"].tap()
        XCTAssertTrue(app.navigationBars["Paid with"].waitForExistence(timeout: 3))
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'account-' AND identifier != 'account-none'")).firstMatch
        XCTAssertTrue(card.exists, "cards are listed")
        let cardName = String(card.identifier.dropFirst("account-".count))
        card.tap()
        XCTAssertTrue(app.staticTexts[cardName].waitForExistence(timeout: 3), "the row shows the card")
        snapshot("4 filled in")

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
        XCTAssertTrue(app.staticTexts["Transport › Taxi"].exists, "editing shows the category")
        snapshot("5 editing")
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
