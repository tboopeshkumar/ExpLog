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
    let card = Account(name: "Crescent Credit", matchKeywords: ["XXXX4417"])
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
    expect(draft.account === card, "card XXXX4417 matched to \"Crescent Credit\" by keyword")
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
        expect(unrelatedDraft.parsedCard == "6150", "unknown card kept as written so the form can offer to add it")
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

    print("\nCARD KEYWORDS\n")

    // Matching rules.
    let alert3 = "Purchase of AED 12.00 with Card XXX453 at QUICKSTOP MART on 22-Sep."
    let alert4 = "Your card XXXX4453 was used at LULU for AED 30.00 on 22-Sep."
    expect(AccountMatching.matches("XXX453", in: alert3), "three-digit keyword matches its alert")
    expect(AccountMatching.matches("xxx453", in: alert3), "matching ignores case")
    expect(!AccountMatching.matches("XXX453", in: alert4), "XXX453 doesn't match XXXX4453")
    expect(AccountMatching.matches("4453", in: alert4), "bare digits match after a mask")
    expect(!AccountMatching.matches("4453", in: "ref 144531 for AED 5.00"), "digits don't match inside a longer number")
    expect(AccountMatching.matches("4453", in: "ref 144531, card ending 4453"), "…but a later clean occurrence still counts")
    expect(AccountMatching.matches("ending 453", in: "Card ending 453 at X for AED 9.00"), "a keyword can include words")

    // Editing rules.
    expect(AccountMatching.keywords(from: " XXX453, xxx453 ,,XXXX4453\n") == ["XXX453", "XXXX4453"],
           "keywords split on commas, trimmed, repeats dropped", "\(AccountMatching.keywords(from: " XXX453, xxx453 ,,XXXX4453\n"))")
    expect(AccountMatching.tooShort(["453", "XXX453"]) == ["453"], "bare three digits is too short")
    expect(AccountMatching.keywords(from: "") == [], "no keywords is allowed (cash, bank accounts)")

    // One card written two ways, both on one account; another card by name.
    let cashback = Account(name: "Cashback card", matchKeywords: ["XXX453", "XXXX4453"])
    let generic = Account(name: "Generic", matchKeywords: ["4453"])
    fresh.insert(cashback)
    fresh.insert(generic)
    try fresh.save()
    expect(AccountMatching.account(for: alert3, in: fresh) === cashback, "3-digit alert finds the card")
    expect(AccountMatching.account(for: alert4, in: fresh) === cashback,
           "4-digit alert finds it too; the longer keyword beats \"4453\" on another account")
    expect(AccountMatching.account(for: "AED 20.00 at SHOP, card XXX999", in: fresh) == nil, "an unknown card matches nothing")

    let parsedAlert3 = SMSParser.parse(alert3, receivedAt: day(9, 22))!
    expect(TransactionDraft(parsed: parsedAlert3, context: fresh).account === cashback,
           "a shared SMS gets its card from the keywords")

    // Clash and merge: ExpLog made "Card 453" on its own from an alert, then
    // the same keyword is added to the imported account.
    let importedCard = Account(name: "Imported Bank")
    let automatic = Account(name: "Card 777", matchKeywords: ["XXX777"])
    fresh.insert(importedCard)
    fresh.insert(automatic)
    fresh.insert(Transaction(amount: 10, date: day(8, 1), merchant: "Old", account: importedCard))
    fresh.insert(Transaction(amount: 20, date: day(8, 2), merchant: "From SMS", account: automatic))
    fresh.insert(Transaction(amount: 30, date: day(8, 3), merchant: "From SMS too", account: automatic))
    try fresh.save()

    let clash = AccountMatching.conflict(for: ["xxx777"], excluding: importedCard, in: fresh)
    expect(clash?.account === automatic && clash?.keyword == "XXX777", "adding XXX777 elsewhere finds the clash")
    expect(AccountMatching.conflict(for: ["XXX777"], excluding: automatic, in: fresh) == nil,
           "an account doesn't clash with itself")

    importedCard.matchKeywords = ["XXXX0777"]
    try AccountMatching.merge(automatic, into: importedCard, in: fresh)
    expect(!(try fresh.fetch(FetchDescriptor<Account>())).contains { $0.name == "Card 777" }, "the duplicate account is removed")
    expect(importedCard.transactions?.count == 3, "its expenses move to the kept account")
    expect(importedCard.matchKeywords == ["XXXX0777", "XXX777"], "keywords are combined", "\(importedCard.matchKeywords)")
    expect(AccountMatching.account(for: "card XXX777 used at Y for AED 3.00", in: fresh) === importedCard,
           "the next alert for the merged card matches the kept account")

    // Accounts from before keywords: digits become the first keyword, once.
    let legacy = Account(name: "Old style")
    legacy.last4 = "8802"
    fresh.insert(legacy)
    try fresh.save()
    AccountMatching.foldLegacyDigits(in: fresh)
    AccountMatching.foldLegacyDigits(in: fresh)
    expect(legacy.matchKeywords == ["8802"] && legacy.last4 == nil, "legacy digits become a keyword, once",
           "\(legacy.matchKeywords) / \(legacy.last4 ?? "nil")")
    expect(AccountMatching.account(for: "A txn on your Card XXXX8802 at TAXI for AED 17.00", in: fresh) === legacy,
           "and still match the card's alerts")

    print("\nSUBCATEGORIES\n")

    let freshCategories = try fresh.fetch(FetchDescriptor<ExpenseCategory>())
    let transport = freshCategories.first { $0.name == "Transport" }!
    let freshDining = freshCategories.first { $0.name == "Dining" }!
    let taxi = ExpenseSubcategory(name: "Taxi", category: transport, sortOrder: 0)
    let bus = ExpenseSubcategory(name: "Bus", category: transport, sortOrder: 1)
    fresh.insert(taxi)
    fresh.insert(bus)
    try fresh.save()
    expect(transport.sortedSubcategories.map(\.name) == ["Taxi", "Bus"], "subcategories belong to their category, in order")

    // Consistency: a subcategory only under its own category.
    let subDraft = TransactionDraft()
    subDraft.amount = 20
    subDraft.merchant = "Ride"
    subDraft.category = transport
    subDraft.subcategory = taxi
    subDraft.category = freshDining
    expect(subDraft.subcategory == nil, "changing the category clears a subcategory from the old one")
    expect(Transaction(amount: 1, merchant: "x", category: freshDining, subcategory: taxi).subcategory == nil,
           "a transaction can't hold another category's subcategory")

    // Learning: the next alert from a merchant arrives with both levels.
    let rideSMS = "Thank you for using Card ending 9911 at CITY RIDES LLC for AED 18.00. Avl. limit is AED XXX.10."
    let firstRide = TransactionDraft(parsed: SMSParser.parse(rideSMS)!, context: fresh)
    firstRide.category = transport
    firstRide.subcategory = taxi
    try firstRide.save(in: fresh)
    let nextRide = TransactionDraft(parsed: SMSParser.parse(rideSMS.replacingOccurrences(of: "18.00", with: "22.00"))!, context: fresh)
    expect(nextRide.category === transport && nextRide.subcategory === taxi,
           "the next alert from the merchant arrives as Transport › Taxi")

    // Breakdown for the drill-down.
    let rides = [
        Transaction(amount: 60, merchant: "a", category: transport, subcategory: taxi),
        Transaction(amount: 10, merchant: "b", category: transport, subcategory: bus),
        Transaction(amount: 30, merchant: "c", category: transport),
    ]
    let breakdown = SubcategoryBreakdown(transactions: rides)
    expect(breakdown.rows.map(\.amount) == [60, 30, 10], "breakdown ranked largest first", "\(breakdown.rows.map(\.amount))")
    expect(breakdown.rows[1].subcategory == nil, "expenses without a subcategory get their own row")
    expect(abs(breakdown.rows.reduce(0) { $0 + $1.share } - 1) < 0.000001, "shares add up to the category's 100%")
    expect(breakdown.isWorthShowing, "shown when any expense has a subcategory")
    expect(!SubcategoryBreakdown(transactions: [rides[2]]).isWorthShowing, "hidden when none do")

    // CSV: the new column, and files from before it.
    let withSubs = """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference,Subcategory
    2026-06-01T09:00:00,15.00,AED,Metro,Transport,,,,Bus
    2026-06-02T09:00:00,40.00,AED,Uni,Education,,,,Schooling
    2026-06-03T09:00:00,5.00,AED,Loose,,,,,Orphan
    """
    let subImport = try CSV.importRows(from: withSubs, into: fresh)
    let metro = try fresh.fetch(FetchDescriptor<Transaction>()).first { $0.merchant == "Metro" }
    expect(metro?.subcategory === bus, "an existing subcategory is matched by name")
    expect(subImport.newSubcategories == ["Education › Schooling"], "a missing one is created under its category",
           "\(subImport.newSubcategories)")
    let loose = try fresh.fetch(FetchDescriptor<Transaction>()).first { $0.merchant == "Loose" }
    expect(loose?.subcategory == nil && subImport.added == 3, "a subcategory with no category is dropped, the row kept")

    let oldFormat = """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference
    2026-06-04T09:00:00,7.00,AED,Old file,Transport,,,
    """
    expect(try CSV.importRows(from: oldFormat, into: fresh).added == 1, "an 8-column file from before subcategories still imports")

    let exportedWithSubs = try String(contentsOf: try CSV.write(try fresh.fetch(FetchDescriptor<Transaction>())), encoding: .utf8)
    expect(exportedWithSubs.hasPrefix("Date,Amount,Currency,Merchant,Category,Account,Note,Reference,Subcategory"),
           "export writes the Subcategory column")
    expect(exportedWithSubs.contains(",Metro,Transport,,,,Bus"), "and fills it")

    // Deleting.
    let busRides = bus.transactions?.count ?? 0
    fresh.delete(bus)
    try fresh.save()
    expect(busRides > 0 && metro?.subcategory == nil && metro?.category === transport,
           "deleting a subcategory keeps its expenses in the category")
    let freshEducation = try fresh.fetch(FetchDescriptor<ExpenseCategory>()).first { $0.name == "Education" }!
    fresh.delete(freshEducation)
    try fresh.save()
    expect(!(try fresh.fetch(FetchDescriptor<ExpenseSubcategory>())).contains { $0.name == "Schooling" },
           "deleting a category takes its subcategories with it")

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
        ExpenseSubcategory.self,
        Account.self,
        MerchantAlias.self,
    ])
}

try await MainActor.run { try run() }
