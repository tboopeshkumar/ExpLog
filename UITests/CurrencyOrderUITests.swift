import XCTest

/// Your currencies' order, as dragged in Settings, deciding what the expense
/// form offers first.
///
/// The order is set through a launch argument (it's a UserDefaults value):
/// XCUITest's synthetic drag doesn't register on a List's reorder handles, so
/// the drag itself is checked by hand. Expects USD and INR among your
/// currencies (the seeded expenses), and AED as the main currency.
final class CurrencyOrderUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(order: String) {
        app.launchArguments = ["-currencyOrder", order]
        app.launch()
    }

    /// Codes of the rows in Settings → Other currencies, top to bottom.
    private func listedCodes() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'currency-'"))
            .allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst("currency-".count)) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The form's currency list, opened; rows' top edges by code.
    private func openCurrencyMenu() -> (XCUIElement) -> CGFloat {
        app.tabBars.buttons["Expenses"].tap()
        app.navigationBars.buttons["Add"].firstMatch.tap()
        let pill = app.buttons["currencyPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        pill.tap()
        XCTAssertTrue(item("AED").waitForExistence(timeout: 5), "the currency list opens")
        sleep(1)
        return { $0.frame.minY }
    }

    private func item(_ code: String) -> XCUIElement {
        app.buttons["currency-\(code)"]
    }

    private func checkOrder(_ order: [String], name: String) {
        launch(order: order.joined(separator: ","))

        app.tabBars.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Other currencies'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Other currencies"].waitForExistence(timeout: 5))
        XCTAssertEqual(Array(listedCodes().prefix(order.count)), order, "Settings lists them in the saved order")
        XCTAssertTrue(app.buttons["Edit"].exists, "Edit, to drag them")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let top = openCurrencyMenu()
        snapshot(name)
        let positions = (["AED"] + order).map { top(item($0)) }
        XCTAssertEqual(positions, positions.sorted(), "main, then yours in order: \(positions)")
        // One not among yours comes after them all.
        let other = ["EUR", "GBP", "JPY"].first { !order.contains($0) }!
        XCTAssertTrue(item(other).exists)
        XCTAssertGreaterThan(top(item(other)), positions.last!, "\(other) comes after yours")
        app.terminate()
    }

    func testThePickerFollowsTheSavedOrder() throws {
        checkOrder(["USD", "INR"], name: "1 USD first")
        checkOrder(["INR", "USD"], name: "2 INR first")
    }

    /// Adding a currency from the searchable list, giving it a rate, and
    /// removing it again.
    func testAddingRatingAndRemovingACurrency() throws {
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Other currencies'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Other currencies"].waitForExistence(timeout: 5))
        sleep(1)
        // Left behind if an earlier run was cut short.
        if app.textFields["currency-JPY"].exists {
            app.textFields["currency-JPY"].swipeLeft()
            app.buttons["Delete"].firstMatch.tap()
        }
        snapshot("3 currencies")

        app.navigationBars["Other currencies"].buttons["Add Currency"].tap()
        XCTAssertTrue(app.navigationBars["Add Currency"].waitForExistence(timeout: 3))
        XCTAssertFalse(item("AED").exists, "the main currency isn't offered")
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("yen")
        XCTAssertTrue(item("JPY").waitForExistence(timeout: 3))
        item("JPY").tap()

        // The row's identifier covers its parts, the rate field included.
        let rate = app.textFields["currency-JPY"]
        XCTAssertTrue(rate.waitForExistence(timeout: 5), "added to the list")
        rate.tap()
        rate.typeText("40")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '≈' AND label CONTAINS '25.00'")).firstMatch
            .waitForExistence(timeout: 3), "what a round amount comes to: ¥1,000 ≈ 25.00")
        snapshot("4 rate entered")
        app.buttons["Done"].firstMatch.tap()

        rate.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(app.textFields["currency-JPY"].waitForExistence(timeout: 2), "removed")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
