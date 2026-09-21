import Foundation
import SwiftData

// Exercises the data layer end to end against a real SwiftData store — the same
// models, draft logic and parser the app and share extension use. Runs on macOS
// with no simulator:
//
//     ./Tools/check-store.sh
//
// Covers what the share extension does when you tap Save: parse, resolve the
// card, apply a learned category, write, read back, and refuse a duplicate.

@MainActor
func run() throws {
    var failures = 0

    func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            let extra = detail()
            print("  ✗ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    // A fresh on-disk store, standing in for the App Group container.
    let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "ExpLogCheck-\(UUID().uuidString).store")
    let configuration = ModelConfiguration(schema: SharedStoreSchema.schema, url: storeURL)
    let container = try ModelContainer(for: SharedStoreSchema.schema, configurations: [configuration])
    let context = ModelContext(container)

    defer { try? FileManager.default.removeItem(at: storeURL) }

    print("\nSETUP\n")
    SeedData.seedIfNeeded(context)
    let categories = try context.fetch(FetchDescriptor<ExpenseCategory>())
    expect(categories.count == 10, "seeded \(categories.count) categories")

    let groceries = categories.first { $0.name == "Groceries" }
    expect(groceries != nil, "Groceries category exists")

    // The card has to exist for the SMS to be matched to an account.
    let card = Account(name: "Crescent Credit", last4: "4417")
    context.insert(card)
    try context.save()

    // Anonymised, like the parser fixtures — see Tools/ParserCheck/main.swift.
    let supermarket = "Dear Alex Morgan!  Cardholder, Your card XXXX4417 was used at MEGA CENTER RIVERTON XYZ for AED  30.02 on deferred payment basis on 20-Sep ref R77315. As per the agreement we confirm our acceptance to sell to you at the agreed price. Available Balance on your card is AED XXXX.  Regards, Crescent Finance."

    print("\nFIRST SAVE  (what happens on Share → ExpLog → Save)\n")

    guard let parsed = SMSParser.parse(supermarket) else {
        print("  ✗ parser returned nil — cannot continue")
        exit(1)
    }
    let draft = TransactionDraft(parsed: parsed, context: context)
    expect(draft.account === card, "card ••4417 matched to \"Crescent Credit\" automatically")
    expect(draft.category == nil, "no category yet (nothing learned)")
    expect(draft.amount == Decimal(string: "30.02"), "amount 30.02", "got \(draft.amount)")

    // Categorising by hand, exactly as you would in the form.
    draft.category = groceries
    let saved = try draft.save(in: context)
    expect(saved.merchant == "Mega Center Riverton Xyz", "merchant stored", saved.merchant)
    expect(saved.rawMessage == supermarket, "original SMS retained on the record")

    let stored = try context.fetch(FetchDescriptor<Transaction>())
    expect(stored.count == 1, "one transaction in the store", "found \(stored.count)")

    print("\nLEARNING  (second visit to the same merchant)\n")

    let supermarketAgain = "Dear Alex Morgan!  Cardholder, Your card XXXX4417 was used at MEGA CENTER RIVERTON XYZ for AED  12.75 on deferred payment basis on 21-Sep ref R77502. As per the agreement we confirm our acceptance to sell to you at the agreed price. Available Balance on your card is AED XXXX.  Regards, Crescent Finance."

    guard let parsedAgain = SMSParser.parse(supermarketAgain) else {
        print("  ✗ parser returned nil")
        exit(1)
    }
    let secondDraft = TransactionDraft(parsed: parsedAgain, context: context)
    expect(secondDraft.category === groceries, "category filled in automatically from the learned alias")
    expect(secondDraft.account === card, "card matched again")
    expect(secondDraft.amount == Decimal(string: "12.75"), "amount 12.75", "got \(secondDraft.amount)")
    _ = try secondDraft.save(in: context)

    print("\nDUPLICATES\n")

    let repeatDraft = TransactionDraft(parsed: parsed, context: context)
    let duplicate = TransactionDraft.duplicate(of: repeatDraft, in: context)
    expect(duplicate != nil, "re-sharing the same SMS is detected as already logged")

    let unrelated = "Thank you for using Card ending 6150 at BEANERY PLAZA 20THFLOOR for AED 31.20. Avl. limit is AED XXX.80."
    if let parsedUnrelated = SMSParser.parse(unrelated) {
        let unrelatedDraft = TransactionDraft(parsed: parsedUnrelated, context: context)
        expect(TransactionDraft.duplicate(of: unrelatedDraft, in: context) == nil, "a different transaction is not flagged")
        expect(unrelatedDraft.account == nil, "unknown card ••6150 left unassigned")
        expect(unrelatedDraft.parsedLast4 == "6150", "unknown card digits kept so the form can offer to add it")
    }

    print("\nTOTALS\n")

    let all = try context.fetch(FetchDescriptor<Transaction>())
    let total = all.reduce(Decimal(0)) { $0 + $1.amount }
    expect(all.count == 2, "two transactions stored", "found \(all.count)")
    expect(total == Decimal(string: "42.77"), "month total 42.77", "got \(total)")

    // The route taken on a free Apple ID, where the extension has no database
    // to write to and hands the transaction to the app as a URL instead.
    print("\nHANDOFF LINK  (no App Group)\n")

    let outgoing = TransactionDraft(parsed: parsedAgain, context: context)
    outgoing.note = "tea & a sandwich, 50% off"
    guard let link = TransactionLink.url(for: outgoing) else {
        print("  ✗ could not build a link")
        exit(1)
    }
    expect(link.scheme == "explog" && link.host == "add", "link is explog://add", link.absoluteString)

    guard let incoming = TransactionLink.draft(from: link, context: context) else {
        print("  ✗ link did not decode")
        exit(1)
    }
    expect(incoming.amount == outgoing.amount, "amount survives the round trip", "got \(incoming.amount)")
    expect(incoming.currencyCode == "AED", "currency survives")
    expect(incoming.merchant == outgoing.merchant, "merchant survives", incoming.merchant)
    expect(incoming.note == outgoing.note, "note with & and % survives intact", incoming.note)
    expect(incoming.reference == "R77502", "reference survives", incoming.reference ?? "nil")
    expect(incoming.rawMessage == outgoing.rawMessage, "original SMS survives")
    expect(abs(incoming.date.timeIntervalSince(outgoing.date)) < 1, "date survives")

    // The lookups the extension couldn't do, done app-side on receipt.
    expect(incoming.account === card, "app matches card ••4417 on receipt")
    expect(incoming.category === groceries, "app applies the learned category on receipt")

    expect(TransactionLink.draft(from: URL(string: "explog://add?merchant=Nothing")!, context: context) == nil,
           "a link with no amount is rejected")
    expect(TransactionLink.draft(from: URL(string: "https://example.com/add?amount=5")!, context: context) == nil,
           "a non-explog URL is rejected")

    // Monthly summary by category. The store already holds two Groceries
    // transactions in September 2026 (30.02 + 12.75); add one Dining, one
    // uncategorised, and one in October that September must not include.
    print("\nMONTHLY SUMMARY\n")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    func day(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }
    let dining = categories.first { $0.name == "Dining" }
    context.insert(Transaction(amount: Decimal(string: "20.00")!, date: day(9, 22), merchant: "Cafe", category: dining))
    context.insert(Transaction(amount: Decimal(string: "7.23")!, date: day(9, 23), merchant: "Kiosk"))
    context.insert(Transaction(amount: Decimal(string: "99.00")!, date: day(10, 2), merchant: "Next month", category: groceries))
    try context.save()

    let everything = try context.fetch(FetchDescriptor<Transaction>())
    let september = MonthSummary(month: day(9, 15), transactions: everything, calendar: calendar)

    expect(september.total == Decimal(string: "70.00"), "September total 70.00, October excluded", "got \(september.total)")
    expect(september.count == 4, "four September transactions", "got \(september.count)")
    expect(september.rows.count == 3, "three rows: Groceries, Dining, uncategorised", "got \(september.rows.count)")
    expect(september.rows.map(\.amount) == [Decimal(string: "42.77"), Decimal(string: "20.00"), Decimal(string: "7.23")].compactMap { $0 },
           "rows ranked largest first", "\(september.rows.map(\.amount))")
    expect(september.rows.first?.category === groceries && september.rows.first?.count == 2,
           "top row is Groceries with 2 transactions")
    expect(september.rows.last?.category == nil, "uncategorised spending is its own row")
    let shareSum = september.rows.reduce(0) { $0 + $1.share }
    expect(abs(shareSum - 1) < 0.000001, "shares add up to 100%", "got \(shareSum)")
    expect(abs((september.rows.first?.share ?? 0) - 42.77 / 70) < 0.000001, "Groceries share is 42.77 / 70")

    let october = MonthSummary(month: day(10, 1), transactions: everything, calendar: calendar)
    expect(october.total == Decimal(99) && october.rows.count == 1, "October has only its own transaction")

    let empty = MonthSummary(month: day(3, 1), transactions: everything, calendar: calendar)
    expect(empty.isEmpty && empty.rows.isEmpty && empty.total == 0, "a month with no spending is empty, not an error")

    print("\nCSV IMPORT / EXPORT\n")

    let csvRows = CSV.parse("a,b\r\n\"x, y\",\"he said \"\"hi\"\"\"\n\"multi\nline\",z\n\nlast,row")
    expect(csvRows == [["a", "b"], ["x, y", "he said \"hi\""], ["multi\nline", "z"], ["last", "row"]],
           "parses quoted commas, doubled quotes, line breaks, CRLF, blank lines, no final newline",
           "\(csvRows)")

    // Round trip: export this store, import into a fresh one.
    let exportedURL = try CSV.write(everything)
    let exported = try String(contentsOf: exportedURL, encoding: .utf8)
    let freshURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ExpLogCSV-\(UUID().uuidString).store")
    defer { try? FileManager.default.removeItem(at: freshURL) }
    let freshContainer = try ModelContainer(
        for: SharedStoreSchema.schema,
        configurations: [ModelConfiguration(schema: SharedStoreSchema.schema, url: freshURL)]
    )
    let fresh = ModelContext(freshContainer)
    SeedData.seedIfNeeded(fresh)

    let firstImport = try CSV.importRows(from: exported, into: fresh)
    let restored = try fresh.fetch(FetchDescriptor<Transaction>())
    expect(firstImport.added == everything.count && firstImport.duplicates == 0 && firstImport.rejected.isEmpty,
           "export then import restores all \(everything.count) transactions", "\(firstImport)")
    expect(restored.reduce(Decimal(0)) { $0 + $1.amount } == everything.reduce(Decimal(0)) { $0 + $1.amount },
           "restored total matches the original")
    let originalTimes = everything.map(\.date.timeIntervalSince1970).sorted()
    let restoredTimes = restored.map(\.date.timeIntervalSince1970).sorted()
    expect(zip(originalTimes, restoredTimes).allSatisfy { abs($0 - $1) < 1 }, "times of day survive, not just dates")
    expect(Set(restored.compactMap(\.category?.name)) == Set(everything.compactMap(\.category?.name)),
           "categories reattached by name")
    expect(firstImport.newAccounts == ["Crescent Credit"], "missing account created", "\(firstImport.newAccounts)")

    let secondImport = try CSV.importRows(from: exported, into: fresh)
    expect(secondImport.added == 0 && secondImport.duplicates == everything.count,
           "importing the same file again adds nothing", "\(secondImport)")

    let mixed = """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference
    2026-08-10T10:00:00,85.00,AED,Bookshop,Education,Cash,,
    2026-08-11,12.5,aed,Plain date,,,,
    not-a-date,1,AED,Broken,,,,
    2026-08-12T10:00:00,abc,AED,Broken,,,,
    2026-08-13T10:00:00,5,AED,,,,,
    """
    let mixedResult = try CSV.importRows(from: mixed, into: fresh)
    expect(mixedResult.added == 2, "good rows imported alongside bad ones", "\(mixedResult.added)")
    expect(mixedResult.rejected.map(\.line) == [4, 5, 6], "bad rows reported by line number",
           "\(mixedResult.rejected)")
    expect(mixedResult.newCategories == ["Education"] && mixedResult.newAccounts == ["Cash"],
           "new category and account created")
    let education = try fresh.fetch(FetchDescriptor<ExpenseCategory>()).first { $0.name == "Education" }
    expect(education?.symbol == "book", "Education gets the book icon", education?.symbol ?? "missing")
    let plainDate = try fresh.fetch(FetchDescriptor<Transaction>()).first { $0.merchant == "Plain date" }
    expect(plainDate?.currencyCode == "AED", "currency code normalised to upper case")

    let twoFares = """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference
    2026-07-01T08:00:00,13.00,AED,Taxi,Transport,Cash,,
    2026-07-01T08:00:07,13.00,AED,Taxi,Transport,Cash,,
    """
    let fares = try CSV.importRows(from: twoFares, into: fresh)
    expect(fares.added == 2 && fares.duplicates == 0,
           "two matching rows in one file are both imported", "\(fares)")
    let faresAgain = try CSV.importRows(from: twoFares, into: fresh)
    expect(faresAgain.added == 0 && faresAgain.duplicates == 2,
           "…and re-importing that file adds neither", "\(faresAgain)")

    do {
        _ = try CSV.importRows(from: "Name,Value\nx,1\n", into: fresh)
        expect(false, "a non-ExpLog CSV is refused")
    } catch {
        expect(error is CSV.ImportError, "a non-ExpLog CSV is refused")
    }

    print("")
    if failures == 0 {
        print("All checks passed.\n")
    } else {
        print("\(failures) check(s) failed.\n")
        exit(1)
    }
}

/// Mirrors SharedStore.schema without pulling in the App Group lookup, which
/// only resolves inside a sandboxed app.
enum SharedStoreSchema {
    static let schema = Schema([
        Transaction.self,
        ExpenseCategory.self,
        Account.self,
        MerchantAlias.self,
    ])
}

try await MainActor.run { try run() }
