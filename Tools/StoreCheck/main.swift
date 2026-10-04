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

func timeFormatter(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

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

    // Pin the main currency to AED in a private settings store, so results
    // don't depend on this Mac's region or leave anything behind.
    let settingsSuite = "ExpLogChecks-\(UUID().uuidString)"
    Currency.defaults = UserDefaults(suiteName: settingsSuite)!
    Currency.setMain("AED")
    defer { UserDefaults().removePersistentDomain(forName: settingsSuite) }

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

    print("\nFILLING SUBCATEGORIES ON RE-IMPORT\n")

    // As first imported: subcategory written into the note, no column.
    let before = """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference
    2026-05-01T08:00:00,13.00,AED,Fare,Transport,,Taxi,
    2026-05-01T08:00:05,13.00,AED,Fare,Transport,,Taxi,
    2026-05-02T12:00:00,4.00,AED,Canteen,Dining,,Lunch · INR 100.00,
    2026-05-03T12:00:00,9.00,AED,Moved,Transport,,Taxi,
    2026-05-04T12:00:00,6.00,AED,Already set,Transport,,,
    """
    _ = try CSV.importRows(from: before, into: fresh)
    let storedAs = { (merchant: String) in try fresh.fetch(FetchDescriptor<Transaction>()).filter { $0.merchant == merchant } }
    // Edits made in the app since: one recategorised, one given a subcategory.
    try storedAs("Moved").first!.category = fresh.fetch(FetchDescriptor<ExpenseCategory>()).first { $0.name == "Travel" }
    try storedAs("Already set").first!.subcategory = taxi
    try fresh.save()

    // The same data again, with the column.
    let after = """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference,Subcategory
    2026-05-01T08:00:00,13.00,AED,Fare,Transport,,,,Taxi
    2026-05-01T08:00:05,13.00,AED,Fare,Transport,,,,Taxi
    2026-05-02T12:00:00,4.00,AED,Canteen,Dining,,INR 100.00,,Lunch
    2026-05-03T12:00:00,9.00,AED,Moved,Transport,,,,Taxi
    2026-05-04T12:00:00,6.00,AED,Already set,Transport,,,,Metro
    """
    let refill = try CSV.importRows(from: after, into: fresh)
    expect(refill.added == 0 && refill.duplicates == 5, "nothing is added twice", "\(refill)")
    expect(refill.filledSubcategories == 3, "missing subcategories filled in", "\(refill.filledSubcategories)")
    expect(try storedAs("Fare").allSatisfy { $0.subcategory?.name == "Taxi" }, "both of an identical pair get theirs")
    expect(try storedAs("Fare").allSatisfy { $0.note.isEmpty }, "the note copy of the subcategory is removed")
    expect(try storedAs("Canteen").first?.subcategory?.name == "Lunch"
               && storedAs("Canteen").first?.note == "INR 100.00",
           "…and the rest of the note is kept")
    expect(try storedAs("Moved").first?.subcategory == nil && storedAs("Moved").first?.note == "Taxi",
           "a recategorised expense is left as edited")
    expect(try storedAs("Already set").first?.subcategory === taxi, "an existing subcategory isn't overwritten")

    let refillAgain = try CSV.importRows(from: after, into: fresh)
    expect(refillAgain.added == 0 && refillAgain.filledSubcategories == 0, "running it again changes nothing")
    // Two near-identical expenses where only the later one had a subcategory
    // in the source: it must land on that one, and a second run must not
    // move on to the other.
    let pairBefore = """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference
    2026-04-01T08:00:00,11.00,AED,Twin,Transport,,,
    2026-04-01T08:00:05,11.00,AED,Twin,Transport,,Taxi,
    """
    let pairAfter = """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference,Subcategory
    2026-04-01T08:00:00,11.00,AED,Twin,Transport,,,,
    2026-04-01T08:00:05,11.00,AED,Twin,Transport,,,,Taxi
    """
    _ = try CSV.importRows(from: pairBefore, into: fresh)
    let pairFill = try CSV.importRows(from: pairAfter, into: fresh)
    let twins = try storedAs("Twin").sorted { $0.date < $1.date }
    expect(pairFill.filledSubcategories == 1 && twins[0].subcategory == nil && twins[1].subcategory?.name == "Taxi",
           "the subcategory lands on the row's own twin, by time")
    expect(try CSV.importRows(from: pairAfter, into: fresh).filledSubcategories == 0,
           "…and a second run doesn't move on to the other")
    expect(CSV.removingNotePart("taxi", from: "Airport · Taxi") == "Airport", "note parts match ignoring case")
    expect(CSV.removingNotePart("Taxi", from: "Taxi rank") == "Taxi rank", "only whole parts are removed")

    print("\nCURRENCIES\n")

    // Choosing the main currency, in a throwaway settings store.
    let probeSuite = "ExpLogCurrencyProbe-\(UUID().uuidString)"
    let probe = UserDefaults(suiteName: probeSuite)!
    defer { UserDefaults().removePersistentDomain(forName: probeSuite) }
    let pinned = Currency.defaults
    Currency.defaults = probe
    expect(Currency.supported.contains(Currency.main), "with nothing chosen, main is a supported currency")
    Currency.setMain("XYZ")
    expect(probe.string(forKey: "mainCurrency") == nil, "an unsupported code is refused")

    // First launch with existing data: adopt what most expenses use.
    let adoptURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "adopt-\(UUID()).store")
    defer { try? FileManager.default.removeItem(at: adoptURL) }
    let adoptContext = ModelContext(try ModelContainer(
        for: SharedStoreSchema.schema,
        configurations: [ModelConfiguration(schema: SharedStoreSchema.schema, url: adoptURL)]
    ))
    for code in ["INR", "INR", "INR", "USD"] {
        adoptContext.insert(Transaction(amount: 1, currencyCode: code, merchant: "x"))
    }
    try adoptContext.save()
    Currency.adoptMainIfUnset(from: adoptContext)
    expect(Currency.main == "INR", "first launch adopts the currency most expenses use", Currency.main)
    Currency.setMain("GBP")
    Currency.adoptMainIfUnset(from: adoptContext)
    expect(Currency.main == "GBP", "…and never overrides a choice")
    expect(Currency.pickerOrder.first == "GBP" && Set(Currency.pickerOrder) == Set(Currency.supported),
           "pickers list the main currency first")

    // Your currencies: dragged into an order in Settings, offered first.
    let noRates = ExchangeRates(main: "AED", json: "")
    expect(Currency.yours(order: "", main: "AED", rates: noRates).isEmpty, "no rates, nothing arranged: no currencies of yours")
    let someRates = ExchangeRates(main: "AED", stored: ["AED>INR": 22.7, "AED>USD": Decimal(string: "0.2723")!])
    expect(Currency.yours(order: "", main: "AED", rates: someRates) == Currency.supported.filter { ["INR", "USD"].contains($0) },
           "currencies with a rate are yours, in the usual order until arranged")
    expect(Currency.yours(order: "USD,INR", main: "AED", rates: someRates) == ["USD", "INR"], "…then in the order dragged")
    expect(Currency.yours(order: "EUR,USD", main: "AED", rates: someRates) == ["EUR", "USD", "INR"],
           "one added without a rate keeps its place; one with a rate not yet arranged follows")
    expect(Currency.yours(order: "AED,XYZ,USD,USD", main: "AED", rates: noRates) == ["USD"],
           "the main currency, unknown codes and repeats are ignored")
    expect(Currency.yours(order: "", main: "AED", rates: noRates, alsoUsed: ["EUR", "AED"]) == ["EUR"],
           "a currency already spent in is listed too")
    expect(Currency.yours(order: "", main: "AED", rates: noRates, alsoUsed: ["EUR", "JPY"], hidden: "EUR") == ["JPY"],
           "…unless it was removed from the list")
    expect(Currency.yours(order: "EUR", main: "AED", rates: noRates, alsoUsed: ["EUR"], hidden: "") == ["EUR"],
           "added back, it's listed again")
    Currency.defaults = UserDefaults(suiteName: "\(probeSuite)-order")!
    Currency.setMain("AED")
    Currency.setOrder(["INR", "USD"])
    expect(Array(Currency.pickerOrder.prefix(3)) == ["AED", "INR", "USD"] && Set(Currency.pickerOrder) == Set(Currency.supported),
           "the picker lists main, then yours in order, then every other currency once",
           Currency.pickerOrder.prefix(4).joined(separator: " "))
    UserDefaults().removePersistentDomain(forName: "\(probeSuite)-order")
    Currency.defaults = pinned

    // Never one number across currencies.
    let mixedCurrencies: [Transaction] = [
        Transaction(amount: 100, currencyCode: "AED", date: .now, merchant: "a", category: transport),
        Transaction(amount: 50, currencyCode: "AED", date: .now, merchant: "b", category: freshDining),
        Transaction(amount: 2500, currencyCode: "INR", date: .now, merchant: "c", category: transport),
        Transaction(amount: 40, currencyCode: "USD", date: .now, merchant: "d", category: transport),
    ]
    let totals = Currency.totals(of: mixedCurrencies, main: "AED")
    expect(totals.map(\.code) == ["AED", "INR", "USD"] && totals.first?.amount == 150,
           "totals are per currency, main first", "\(totals.map { "\($0.code) \($0.amount)" })")
    expect(Currency.totals(of: mixedCurrencies, main: "USD").first?.code == "USD", "switching main reorders, nothing converts")

    let mixedMonth = MonthSummary(month: .now, transactions: mixedCurrencies, mainCurrency: "AED")
    expect(mixedMonth.total == 150, "the Summary total counts only the main currency", "\(mixedMonth.total)")
    expect(mixedMonth.count == 4, "…while the expense count includes all of them")
    expect(mixedMonth.rows.reduce(Decimal(0)) { $0 + $1.amount } == 150 && mixedMonth.rows.count == 2,
           "category rows compare like with like")
    expect(mixedMonth.otherCurrencies.map(\.code) == ["INR", "USD"], "other currencies are listed beside it")
    expect(SubcategoryBreakdown(transactions: mixedCurrencies, mainCurrency: "AED").rows.reduce(Decimal(0)) { $0 + $1.amount } == 150,
           "the subcategory breakdown counts only the main currency")

    // New expenses and imports start in the main currency.
    expect(TransactionDraft().currencyCode == Currency.main, "a new expense starts in the main currency")
    let noCode = try CSV.importRows(from: """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference
    2026-03-01T10:00:00,9.00,,No code given,,,,
    2026-03-02T10:00:00,9.00,usd,Lower case,,,,
    """, into: fresh)
    expect(noCode.added == 2, "rows imported")
    expect(try storedAs("No code given").first?.currencyCode == Currency.main, "a row without a currency takes the main one")
    expect(try storedAs("Lower case").first?.currencyCode == "USD", "a given currency is kept")

    print("\nMERCHANTS\n")

    let shopping: [Transaction] = [
        Transaction(amount: 40, currencyCode: "AED", merchant: "Lulu Hypermarket", category: transport),
        Transaction(amount: 20, currencyCode: "AED", merchant: "LULU  Hypermarket", category: freshDining),
        Transaction(amount: 10, currencyCode: "AED", merchant: " lulu hypermarket", category: freshDining),
        Transaction(amount: 25, currencyCode: "AED", merchant: "Lulu Center", category: freshDining),
        Transaction(amount: 25, currencyCode: "AED", merchant: "Bakery", category: freshDining),
        Transaction(amount: 900, currencyCode: "INR", merchant: "Lulu Hypermarket", category: freshDining),
    ]
    let merchants = MerchantBreakdown(transactions: shopping, mainCurrency: "AED")
    expect(merchants.rows.first?.amount == 70 && merchants.rows.first?.count == 3,
           "case and extra spaces are one merchant", "\(merchants.rows.map { "\($0.name) \($0.amount)" })")
    expect(merchants.rows.first?.name == "Lulu Hypermarket",
           "each spelling used once: the first seen is shown", merchants.rows.first?.name ?? "")
    expect(merchants.rows.contains { $0.name == "Lulu Center" }, "a different name stays its own row")
    expect(merchants.rows.map(\.name).suffix(2) == ["Bakery", "Lulu Center"], "ties ordered by name")
    expect(merchants.rows.reduce(Decimal(0)) { $0 + $1.amount } == 120, "main currency only — the INR expense isn't in")
    expect(abs(merchants.rows.reduce(0) { $0 + $1.share } - 1) < 0.000001, "shares add up to 100%")
    expect(merchants.rows.first?.category === freshDining, "icon from the merchant's most common category")
    let spellings = MerchantBreakdown(transactions: [
        Transaction(amount: 1, currencyCode: "AED", merchant: "LULU"),
        Transaction(amount: 1, currencyCode: "AED", merchant: "Lulu"),
        Transaction(amount: 1, currencyCode: "AED", merchant: "Lulu"),
    ], mainCurrency: "AED")
    expect(spellings.rows.first?.name == "Lulu", "the most common spelling wins")

    print("\nEXCHANGE RATES\n")

    // Storage: per pair, inverse understood, other mains ignored.
    var ratesJSON = ExchangeRates.setting(Decimal(string: "22.70")!, for: "INR", main: "AED", in: "")
    ratesJSON = ExchangeRates.setting(Decimal(string: "0.25")!, for: "EUR", main: "AED", in: ratesJSON)
    let fromAED = ExchangeRates(main: "AED", json: ratesJSON)
    expect(fromAED.rate(for: "INR") == Decimal(string: "22.70") && fromAED.rate(for: "AED") == 1, "rates read back per pair")
    expect(ExchangeRates(main: "INR", json: ratesJSON).rate(for: "AED") == 1 / Decimal(string: "22.70")!,
           "an inverse pair is understood")
    expect(ExchangeRates(main: "USD", json: ratesJSON).rate(for: "INR") == nil,
           "rates for another main currency aren't reused")
    expect(ExchangeRates(main: "AED", json: ExchangeRates.setting(nil, for: "INR", main: "AED", in: ratesJSON)).rate(for: "INR") == nil,
           "clearing a rate removes it")

    // Each expense counts at its own rate, against its own base.
    let rated = Transaction(amount: 2270, currencyCode: "INR", merchant: "rated")
    rated.exchangeRate = Decimal(string: "22.70")
    rated.rateBase = "AED"
    expect(rated.amount(in: "AED") == 100, "an expense converts at its stored rate")
    expect(rated.amount(in: "USD") == nil, "…only against the main currency it was logged with")
    expect(Transaction(amount: 500, currencyCode: "INR", merchant: "unrated").amount(in: "AED") == nil,
           "no stored rate: not counted, never guessed")

    // Logging captures today's rate; changing the rate later changes nothing.
    Currency.defaults.set(ratesJSON, forKey: Currency.exchangeRatesKey)
    let abroad = TransactionDraft()
    abroad.amount = 454
    abroad.merchant = "Chai stall"
    abroad.currencyCode = "INR"
    expect(abroad.exchangeRate == Decimal(string: "22.70") && abroad.rateBase == "AED",
           "choosing a currency starts from the rate in Settings")
    let loggedAbroad = try abroad.save(in: fresh)
    Currency.defaults.set(ExchangeRates.setting(Decimal(30), for: "INR", main: "AED", in: ratesJSON), forKey: Currency.exchangeRatesKey)
    expect(loggedAbroad.amount(in: "AED") == 20, "changing the rate later leaves a logged expense alone",
           "\(loggedAbroad.amount(in: "AED").map { "\($0)" } ?? "nil")")
    let reopened = TransactionDraft(editing: loggedAbroad)
    expect(reopened.exchangeRate == Decimal(string: "22.70"), "editing an expense keeps the rate it was logged with")
    let newAbroad = TransactionDraft()
    newAbroad.currencyCode = "INR"
    expect(newAbroad.exchangeRate == 30, "a new expense takes the updated rate")
    newAbroad.currencyCode = "AED"
    expect(newAbroad.exchangeRate == nil, "back in the main currency: no rate")
    Currency.defaults.set(ratesJSON, forKey: Currency.exchangeRatesKey)

    // Totals: one main-currency number when every expense has a rate.
    let spentAbroad: [Transaction] = [
        Transaction(amount: 100, currencyCode: "AED", date: .now, merchant: "home", category: transport),
        rated,
    ]
    rated.date = .now
    rated.category = freshDining
    let converted = MonthSummary(month: .now, transactions: spentAbroad, mainCurrency: "AED")
    expect(converted.total == 200 && converted.otherCurrencies.isEmpty, "rated spending joins the main total", "\(converted.total)")
    expect(converted.rows.map(\.amount).sorted() == [100, 100], "categories count it converted too")
    let withUnrated = MonthSummary(month: .now,
        transactions: spentAbroad + [Transaction(amount: 500, currencyCode: "INR", date: .now, merchant: "old")],
        mainCurrency: "AED")
    expect(withUnrated.total == 200 && withUnrated.otherCurrencies.first?.amount == 500,
           "an expense without a rate is shown beside the total, not in it")
    expect(MerchantBreakdown(transactions: spentAbroad, mainCurrency: "AED").rows.reduce(Decimal(0)) { $0 + $1.amount } == 200,
           "merchant breakdown converts")

    // Giving older expenses a rate: only the ones without one.
    let older = [
        Transaction(amount: 100, currencyCode: "INR", merchant: "older 1"),
        Transaction(amount: 200, currencyCode: "INR", merchant: "older 2"),
        rated,
    ]
    expect(Currency.unrated("INR", in: older).count == 2, "counts only expenses without a rate")
    let applied = Currency.applyRate(25, toUnrated: "INR", main: "AED", in: older)
    expect(applied == 2 && older[0].exchangeRate == 25 && rated.exchangeRate == Decimal(string: "22.70"),
           "fills in unrated ones and never touches a rated one")

    // CSV keeps each expense's rate; imported history doesn't get today's rate.
    let ratedExport = try String(contentsOf: try CSV.write([loggedAbroad]), encoding: .utf8)
    expect(ratedExport.contains(",22.7,AED"), "export writes the expense's own rate", ratedExport)
    let restoreURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rates-\(UUID()).store")
    defer { try? FileManager.default.removeItem(at: restoreURL) }
    let restore = ModelContext(try ModelContainer(for: SharedStoreSchema.schema,
        configurations: [ModelConfiguration(schema: SharedStoreSchema.schema, url: restoreURL)]))
    _ = try CSV.importRows(from: ratedExport, into: restore)
    let restoredRated = try restore.fetch(FetchDescriptor<Transaction>()).first
    expect(restoredRated?.exchangeRate == Decimal(string: "22.7") && restoredRated?.rateBase == "AED",
           "a restore brings the rate back")
    _ = try CSV.importRows(from: """
    Date,Amount,Currency,Merchant,Category,Account,Note,Reference
    2025-01-05T10:00:00,300.00,INR,Old trip,,,,
    """, into: restore)
    expect(try restore.fetch(FetchDescriptor<Transaction>()).first { $0.merchant == "Old trip" }?.exchangeRate == nil,
           "imported history isn't given today's rate")

    // The share-sheet handoff carries a rate typed in the share form.
    let shared = TransactionDraft()
    shared.amount = 90
    shared.merchant = "Shared"
    shared.currencyCode = "INR"
    shared.exchangeRate = 18
    let received = TransactionLink.draft(from: TransactionLink.url(for: shared)!, context: fresh)
    expect(received?.exchangeRate == 18 && received?.rateBase == "AED", "a rate set in the share form survives the handoff")

    print("\nQUICK CATEGORISE AND COPY\n")

    // Quick categorise: same rules and learning as the editor.
    let fareSMS = "Thank you for using Card ending 9911 at SPEEDY CABS LLC for AED 14.00. Avl. limit is AED XXX.10."
    let fareDraft = TransactionDraft(parsed: SMSParser.parse(fareSMS)!, context: fresh)
    let fare = try fareDraft.save(in: fresh)
    expect(fare.category == nil, "arrives uncategorised")
    try TransactionDraft.categorise(fare, as: transport, subcategory: taxi, in: fresh)
    expect(fare.category === transport && fare.subcategory === taxi, "one step sets category and subcategory")
    let nextFare = TransactionDraft(parsed: SMSParser.parse(fareSMS.replacingOccurrences(of: "14.00", with: "16.00"))!, context: fresh)
    expect(nextFare.category === transport && nextFare.subcategory === taxi,
           "…and the merchant is learned, so the next SMS arrives categorised")
    try TransactionDraft.categorise(fare, as: freshDining, subcategory: taxi, in: fresh)
    expect(fare.category === freshDining && fare.subcategory == nil, "a subcategory from another category is dropped")

    // Copy with today's date.
    let lunchCard = Account(name: "Lunch card")
    fresh.insert(lunchCard)
    let lunch = Transaction(amount: 32.5, currencyCode: "AED", date: day(9, 1), merchant: "Canteen",
                            note: "team lunch", reference: "R123", rawMessage: "an SMS",
                            category: transport, subcategory: taxi, account: lunchCard)
    fresh.insert(lunch)
    try fresh.save()
    let now = Date.now
    let copy = TransactionDraft(copying: lunch, on: now)
    expect(copy.amount == 32.5 && copy.merchant == "Canteen" && copy.note == "team lunch",
           "amount, merchant and note are copied")
    expect(copy.category === transport && copy.subcategory === taxi && copy.account === lunchCard,
           "category, subcategory and account are copied")
    expect(copy.date == now, "the copy is dated now")
    expect(copy.reference == nil && copy.rawMessage == nil, "the bank reference and SMS stay with the original")
    let copied = try copy.save(in: fresh)
    expect(copied !== lunch && lunch.date == day(9, 1) && lunch.reference == "R123", "the original is untouched")

    let abroadLunch = Transaction(amount: 454, currencyCode: "INR", date: day(9, 2), merchant: "Chai")
    abroadLunch.exchangeRate = 20
    abroadLunch.rateBase = "AED"
    Currency.defaults.set(ExchangeRates.setting(Decimal(string: "22.70")!, for: "INR", main: "AED", in: ""),
                          forKey: Currency.exchangeRatesKey)
    let abroadCopy = TransactionDraft(copying: abroadLunch)
    expect(abroadCopy.exchangeRate == Decimal(string: "22.70") && abroadCopy.rateBase == "AED",
           "a foreign copy takes today's rate, not the original's")

    print("\nMONTH NAVIGATION\n")

    let ledger: [Transaction] = [
        Transaction(amount: 10, currencyCode: "AED", date: day(7, 3), merchant: "a"),
        Transaction(amount: 20, currencyCode: "AED", date: day(9, 1), merchant: "b"),
        Transaction(amount: 30, currencyCode: "AED", date: day(9, 1).addingTimeInterval(3600), merchant: "c"),
        Transaction(amount: 5, currencyCode: "AED", date: day(9, 14), merchant: "d"),
        Transaction(amount: 450, currencyCode: "INR", date: day(9, 14), merchant: "e"),
    ]
    let monthList = MonthIndex.months(of: ledger, mainCurrency: "AED", calendar: calendar)
    expect(monthList.map(\.start) == [day(9, 1), day(7, 1)].map { Formatting.monthStart($0, calendar: calendar) },
           "months with expenses, newest first; empty August isn't listed")
    expect(monthList.first?.count == 4 && monthList.first?.total == 55, "a month's count and main-currency total",
           "\(monthList.first.map { "\($0.count) \($0.total)" } ?? "")")
    expect(monthList.first?.unconverted.first?.code == "INR", "an unrated currency is carried separately")

    let navNow = day(9, 20)
    let range = MonthIndex.bounds(earliest: day(7, 3), latest: day(9, 14), now: navNow, calendar: calendar)
    expect(range.lowerBound == Formatting.monthStart(day(7, 3), calendar: calendar)
               && range.upperBound == Formatting.monthStart(navNow, calendar: calendar),
           "arrows reach back to the first month with expenses, forward to this month")
    let withFuture = MonthIndex.bounds(earliest: day(7, 3), latest: calendar.date(byAdding: .month, value: 4, to: navNow), now: navNow, calendar: calendar)
    expect(withFuture.upperBound == Formatting.monthStart(calendar.date(byAdding: .month, value: 4, to: navNow)!, calendar: calendar),
           "…or further, to the latest future instalment")
    expect(MonthIndex.bounds(earliest: nil, latest: nil, now: navNow, calendar: calendar)
               == Formatting.monthStart(navNow, calendar: calendar)...Formatting.monthStart(navNow, calendar: calendar),
           "no expenses: just this month")

    let navSeptember = Formatting.monthStart(day(9, 1), calendar: calendar)
    expect(MonthIndex.step(navSeptember, by: -1, within: range, calendar: calendar) == Formatting.monthStart(day(8, 1), calendar: calendar),
           "stepping back a month")
    expect(MonthIndex.step(navSeptember, by: 1, within: range, calendar: calendar) == navSeptember,
           "can't step past the last month")
    expect(MonthIndex.step(Formatting.monthStart(day(7, 1), calendar: calendar), by: -1, within: range, calendar: calendar)
               == Formatting.monthStart(day(7, 1), calendar: calendar),
           "…or before the first")

    let septemberDays = MonthIndex.days(of: Array(ledger.dropFirst()), calendar: calendar)
    expect(septemberDays.map(\.day) == [calendar.startOfDay(for: day(9, 14)), calendar.startOfDay(for: day(9, 1))],
           "grouped by day, newest day first")
    expect(septemberDays.last?.items.map(\.merchant) == ["c", "b"], "newest first within a day")

    do {
        _ = try CSV.importRows(from: "Name,Value\nx,1\n", into: fresh)
        expect(false, "a non-ExpLog CSV is refused")
    } catch {
        expect(error is CSV.ImportError, "a non-ExpLog CSV is refused")
    }

    print("\nLEARNING FROM MESSAGES  (pick the merchant once, the next alert follows)\n")

    let learnURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ExpLogLearn-\(UUID().uuidString).store")
    defer { try? FileManager.default.removeItem(at: learnURL) }
    let learnContainer = try ModelContainer(
        for: SharedStoreSchema.schema,
        configurations: [ModelConfiguration(schema: SharedStoreSchema.schema, url: learnURL)]
    )
    let learn = ModelContext(learnContainer)
    SeedData.seedIfNeeded(learn)
    let shopCategory = try learn.fetch(FetchDescriptor<ExpenseCategory>()).first { $0.name == "Shopping" }!
    let online = ExpenseSubcategory(name: "Online", category: shopCategory)
    learn.insert(online)

    // A memory keyed on a misreading, as the old parser left for this format.
    learn.insert(MerchantAlias(key: "account xx660213 was used", displayName: "ShopNova", category: shopCategory))
    learn.insert(MerchantAlias(key: "aman taxi", category: shopCategory))
    try learn.save()
    expect(LearnedParsing.forgetImplausibleAliases(in: learn) == 1, "a merchant memory keyed on a sentence fragment is forgotten")
    expect(try learn.fetch(FetchDescriptor<MerchantAlias>()).map(\.key) == ["aman taxi"], "…and real ones are kept")

    let bankSample = "Debit Card XX5528 linked to account XX660213 was used for AED72.57 on Sep 27 2026 12:10PM at SHOPNOVAUFR DI, AE. Available Balance AED 4210.50"
    let firstDraft = TransactionDraft(parsed: LearnedParsing.parse(bankSample, in: learn)!, context: learn)
    expect(firstDraft.merchant == "Shopnovaufr Di", "the parser reads the descriptor", firstDraft.merchant)

    let nameWord = MerchantFormat.words(of: bankSample).firstIndex { $0.text == "SHOPNOVAUFR" }!
    expect(firstDraft.pickMerchant(nameWord...nameWord, remember: true, context: learn), "picking the name learns the format")
    expect(firstDraft.merchant == "Shopnovaufr", "the picked words become the merchant", firstDraft.merchant)
    firstDraft.merchant = "ShopNova"
    firstDraft.category = shopCategory
    firstDraft.subcategory = online
    try firstDraft.save(in: learn)
    expect(try learn.fetchCount(FetchDescriptor<MessageFormat>()) == 1, "the format is saved with the expense")
    let learnedAlias = TransactionDraft.alias(for: "Shopnovaufr", in: learn)
    expect(learnedAlias?.displayName == "ShopNova" && learnedAlias?.subcategory === online,
           "the merchant is remembered under the picked name, with its name and subcategory")

    let nextAlert = "Debit Card XX9014 linked to account XX660213 was used for AED15.00 on Oct 2 2026 8:15PM at SHOPNOVAUFR DI, AE. Available Balance AED 4195.50"
    let nextDraft = TransactionDraft(parsed: LearnedParsing.parse(nextAlert, in: learn)!, context: learn)
    expect(nextDraft.merchant == "ShopNova" && nextDraft.category === shopCategory && nextDraft.subcategory === online,
           "the next alert from that shop arrives named, categorised and subcategorised",
           "\(nextDraft.merchant) \(nextDraft.category?.name ?? "-") \(nextDraft.subcategory?.name ?? "-")")
    expect(timeFormatter(nextDraft.date) == "2026-10-02 20:15", "…on its own date and time", timeFormatter(nextDraft.date))

    let otherShop = "Debit Card XX5528 linked to account XX660213 was used for AED40.00 on Oct 3 2026 1:00PM at CITYMART MOE DU, AE. Available Balance AED 4155.50"
    let otherDraft = TransactionDraft(parsed: LearnedParsing.parse(otherShop, in: learn)!, context: learn)
    expect(otherDraft.merchant == "Citymart Moe" && otherDraft.category == nil,
           "another shop in the same format gets its own name, not the first shop's category",
           "\(otherDraft.merchant) \(otherDraft.category?.name ?? "-")")

    // Through the share extension: it reads without the learned format; the
    // app reads the message again with it on receipt.
    let fromShare = TransactionDraft()
    fromShare.amount = 15
    fromShare.merchant = SMSParser.parse(nextAlert)!.merchant!
    fromShare.rawMessage = nextAlert
    let arrived = TransactionLink.url(for: fromShare).flatMap { TransactionLink.draft(from: $0, context: learn) }
    expect(arrived?.merchant == "ShopNova" && arrived?.subcategory === online,
           "an alert shared from Messages is named and categorised on arrival", arrived?.merchant ?? "nil")

    let edited = TransactionDraft()
    edited.amount = 15
    edited.merchant = "Birthday present"
    edited.rawMessage = nextAlert
    let receivedEdited = TransactionLink.url(for: edited).flatMap { TransactionLink.draft(from: $0, context: learn) }
    expect(receivedEdited?.merchant == "Birthday present", "…but a merchant typed in the share sheet is kept")

    // Picked in the share sheet: carried across and learned when saved.
    let pickedInShare = TransactionDraft()
    pickedInShare.amount = 40
    pickedInShare.rawMessage = otherShop
    let cityWord = MerchantFormat.words(of: otherShop).firstIndex { $0.text == "CITYMART" }!
    pickedInShare.pickMerchant(cityWord...(cityWord + 2), remember: true, context: nil)
    let carried = TransactionLink.url(for: pickedInShare).flatMap { TransactionLink.draft(from: $0, context: learn) }
    expect(carried?.pickedFormat == pickedInShare.pickedFormat && carried?.merchant == "Citymart Moe Du",
           "a merchant picked in the share sheet travels with it", carried?.merchant ?? "nil")
    try carried?.save(in: learn)
    let formatsNow = try learn.fetch(FetchDescriptor<MessageFormat>())
    expect(formatsNow.count == 1 && formatsNow.first?.picked == "CITYMART MOE DU,",
           "picking again in the same format replaces the old pattern rather than adding one",
           formatsNow.map(\.picked).joined(separator: " | "))
    expect(LearnedParsing.parse(nextAlert, in: learn)?.merchant == "Shopnovaufr Di", "…and the newest pick is what's read")

    print("\nLOGGING FROM A SHORTCUT  (a Messages automation, no form)\n")

    // Continues from the learning checks: ShopNova is remembered as
    // Shopping › Online, and its format is learned.
    let shortcutAlert = "Debit Card XX5528 linked to account XX660213 was used for AED33.10 on Oct 5 2026 7:45PM at SHOPNOVAUFR DI, AE. Available Balance AED 4122.40"
    guard case .ready(let shortcutDraft) = MessageLogging.prepare(shortcutAlert, in: learn) else {
        expect(false, "a card alert is ready to log")
        exit(1)
    }
    expect(shortcutDraft.merchant == "Shopnovaufr Di", "read with the newest learned format", shortcutDraft.merchant)
    let shortcutSaved = try shortcutDraft.save(in: learn)
    expect(shortcutSaved.amount == Decimal(string: "33.10") && timeFormatter(shortcutSaved.date) == "2026-10-05 19:45",
           "saved with its amount, date and time", timeFormatter(shortcutSaved.date))
    expect(MessageLogging.summary(of: shortcutSaved).contains("33.10"), "a one-line summary for the action's result",
           MessageLogging.summary(of: shortcutSaved))

    if case .duplicate = MessageLogging.prepare(shortcutAlert, in: learn) {
        expect(true, "the same alert again is recognised as already logged")
    } else {
        expect(false, "the same alert again is recognised as already logged")
    }
    if case .notAnExpense = MessageLogging.prepare("Your OTP for transaction of AED 250.00 is 884213. Do not share it.", in: learn) {
        expect(true, "an OTP is skipped")
    } else {
        expect(false, "an OTP is skipped")
    }
    if case .ready(let nameless) = MessageLogging.prepare("AED 45.00 debited from card XXXX4417.", in: learn) {
        expect(nameless.merchant == "Card XXXX4417", "no merchant in the alert: named after the card, so it can still be saved", nameless.merchant)
    } else {
        expect(false, "an alert with no merchant is still logged")
    }

    print("\nMONTH PACE  (per day, and against the month before)\n")

    let paceNow = day(9, 20)
    let paceSeptember = Formatting.monthStart(day(9, 1), calendar: calendar)
    let paceAugust = Formatting.monthStart(day(8, 1), calendar: calendar)
    let paceOctober = Formatting.monthStart(day(10, 1), calendar: calendar)
    expect(MonthPace.daysCounted(in: paceSeptember, now: paceNow, calendar: calendar) == 20, "the current month counts the days so far")
    expect(MonthPace.daysCounted(in: paceAugust, now: paceNow, calendar: calendar) == 31, "a past month counts all its days")
    expect(MonthPace.daysCounted(in: paceOctober, now: paceNow, calendar: calendar) == nil, "a future month has no pace")
    expect(MonthPace.dailyAverage(of: 400, in: paceSeptember, now: paceNow, calendar: calendar) == 20, "AED 400 over 20 days is 20 a day")

    let sameDays = MonthPace.comparisonRange(for: paceSeptember, now: paceNow, calendar: calendar)
    expect(sameDays?.lowerBound == paceAugust && sameDays?.upperBound == calendar.date(byAdding: .day, value: 20, to: paceAugust),
           "the current month is compared with the same days of the last one")
    let wholeMonth = MonthPace.comparisonRange(for: paceAugust, now: paceNow, calendar: calendar)
    expect(wholeMonth == Formatting.monthRange(containing: day(7, 1), calendar: calendar),
           "a past month is compared with all of the one before")
    let lateNow = day(3, 31)
    let afterFebruary = MonthPace.comparisonRange(for: Formatting.monthStart(lateNow, calendar: calendar), now: lateNow, calendar: calendar)
    expect(afterFebruary?.upperBound == Formatting.monthRange(containing: day(2, 1), calendar: calendar).upperBound,
           "on the 31st, a shorter month before is compared whole")
    let counted = MonthPace.countedRange(for: paceSeptember, now: paceNow, calendar: calendar)
    expect(counted?.lowerBound == paceSeptember && counted?.upperBound == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: paceNow)),
           "the current month's pace runs to the end of today, leaving out future instalments")
    expect(MonthPace.countedRange(for: paceAugust, now: paceNow, calendar: calendar) == Formatting.monthRange(containing: paceAugust, calendar: calendar),
           "a past month's pace covers all of it")
    expect(MonthPace.change(from: 100, to: 118).map { abs($0 - 0.18) < 0.0001 } == true, "18% more")
    expect(MonthPace.change(from: 0, to: 50) == nil, "nothing last month: no comparison")

    print("\nMONTH TREND  (six months of a category or merchant)\n")

    let trendNow = day(9, 20)
    let trendItems: [Transaction] = [
        Transaction(amount: 40, currencyCode: "AED", date: day(9, 3), merchant: "a"),
        Transaction(amount: 10, currencyCode: "AED", date: day(9, 9), merchant: "a"),
        Transaction(amount: 25, currencyCode: "AED", date: day(7, 15), merchant: "a"),
        Transaction(amount: 99, currencyCode: "AED", date: day(1, 15), merchant: "a"),
    ]
    let trend = MonthTrend.points(of: trendItems, selected: day(9, 1), mainCurrency: "AED", now: trendNow, calendar: calendar)
    expect(trend.count == 6 && trend.first?.month == Formatting.monthStart(day(4, 1), calendar: calendar)
               && trend.last?.month == Formatting.monthStart(day(9, 1), calendar: calendar),
           "six months, oldest first, ending this month")
    expect(trend.map(\.total) == [0, 0, 0, 25, 0, 50], "each month's total, zero where there's nothing",
           trend.map { "\($0.total)" }.joined(separator: " "))
    let steppedBack = MonthTrend.points(of: trendItems, selected: day(7, 1), mainCurrency: "AED", now: trendNow, calendar: calendar)
    expect(steppedBack == trend, "stepping to a recent month leaves the chart where it is")
    let olderWindow = MonthTrend.points(of: trendItems, selected: day(1, 1), mainCurrency: "AED", now: trendNow, calendar: calendar)
    expect(olderWindow.last?.month == Formatting.monthStart(day(1, 1), calendar: calendar) && olderWindow.last?.total == 99,
           "an older month moves the window to end there")
    let future = MonthTrend.windowEnd(for: day(11, 1), now: trendNow, calendar: calendar)
    expect(future == Formatting.monthStart(day(11, 1), calendar: calendar), "a future month ends the window too")

    print("\nSHARE SHEET SNAPSHOT  (categories and cards without a shared database)\n")

    // The app's side: `learn` has Shopping › Online, the ShopNova merchant
    // and a learned format. Add a card, then snapshot it.
    learn.insert(Account(name: "Harbour Debit", matchKeywords: ["XX5528"]))
    try learn.save()
    let snapshot = ExtensionSnapshot(context: learn)
    let wire = try JSONDecoder().decode(ExtensionSnapshot.self, from: JSONEncoder().encode(snapshot))
    expect(wire == snapshot, "the snapshot survives encoding")
    expect(wire.categories.first { $0.name == "Shopping" }?.subcategories == ["Online"], "categories carry their subcategories")
    expect(wire.cards.contains { $0.name == "Harbour Debit" && $0.keywords == ["XX5528"] }, "cards carry their keywords")
    expect(!wire.formats.isEmpty, "learned formats are included")

    // The share sheet's side: its own empty store takes the snapshot on.
    let sheetURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ExpLogSheet-\(UUID().uuidString).store")
    defer { try? FileManager.default.removeItem(at: sheetURL) }
    let sheet = ModelContext(try ModelContainer(
        for: SharedStoreSchema.schema,
        configurations: [ModelConfiguration(schema: SharedStoreSchema.schema, url: sheetURL)]
    ))
    wire.apply(to: sheet)
    wire.apply(to: sheet)
    expect(try sheet.fetchCount(FetchDescriptor<ExpenseCategory>()) == wire.categories.count
               && sheet.fetchCount(FetchDescriptor<Account>()) == wire.cards.count,
           "applying it twice leaves one copy of everything")

    let sheetAlert = "Debit Card XX5528 linked to account XX660213 was used for AED61.00 on Oct 6 2026 9:30AM at SHOPNOVAUFR DI, AE. Available Balance AED 4061.40"
    let asTheApp = TransactionDraft(parsed: LearnedParsing.parse(sheetAlert, in: learn)!, context: learn)
    let sheetDraft = TransactionDraft(parsed: LearnedParsing.parse(sheetAlert, in: sheet)!, context: sheet)
    sheetDraft.resolvedInExtension = true
    expect(sheetDraft.account?.name == "Harbour Debit", "the sheet matches the card by keyword", sheetDraft.account?.name ?? "nil")
    expect(sheetDraft.merchant == asTheApp.merchant && sheetDraft.category?.name == asTheApp.category?.name
               && sheetDraft.subcategory?.name == asTheApp.subcategory?.name,
           "…and reads the merchant and its category as the app would",
           "\(sheetDraft.merchant) \(sheetDraft.category?.name ?? "-") vs \(asTheApp.merchant) \(asTheApp.category?.name ?? "-")")

    // Chosen in the sheet, sent by name, found again in the app's store.
    let sheetDining = try sheet.fetch(FetchDescriptor<ExpenseCategory>()).first { $0.name == "Dining" }
    sheetDraft.category = sheetDining
    let backInApp = TransactionLink.url(for: sheetDraft).flatMap { TransactionLink.draft(from: $0, context: learn) }
    let appDining = try learn.fetch(FetchDescriptor<ExpenseCategory>()).first { $0.name == "Dining" }
    expect(backInApp?.category === appDining && appDining != nil, "a category chosen in the sheet arrives as the app's own",
           backInApp?.category?.name ?? "nil")
    expect(backInApp?.account?.name == "Harbour Debit", "…and so does the card")

    sheetDraft.category = nil
    sheetDraft.account = nil
    let cleared = TransactionLink.url(for: sheetDraft).flatMap { TransactionLink.draft(from: $0, context: learn) }
    expect(cleared != nil && cleared?.category == nil && cleared?.account == nil,
           "leaving them empty in the sheet is respected, not filled back in")

    print("\nSEARCH\n")

    let searchCard = Account(name: "Harbour Debit")
    let taxiRide = Transaction(amount: Decimal(string: "72.57")!, currencyCode: "AED", date: day(9, 27), merchant: "Aman Taxi",
                               note: "airport run", reference: "R77315")
    taxiRide.account = searchCard
    let bigShop = Transaction(amount: 720, currencyCode: "INR", date: day(3, 2), merchant: "Mega Mart")
    func finds(_ query: String, _ transaction: Transaction) -> Bool {
        ExpenseSearch.matches(transaction, query: query, calendar: calendar)
    }
    expect(finds("aman", taxiRide) && finds("AIRPORT", taxiRide) && finds("harbour", taxiRide) && finds("r773", taxiRide),
           "merchant, note, card and reference, ignoring case")
    expect(finds("taxi airport", taxiRide) && !finds("taxi dinner", taxiRide), "every word must match")
    expect(finds("72", taxiRide) && finds("72.5", taxiRide) && finds("72.57", taxiRide), "an amount, whole or to the fils")
    expect(!finds("72", bigShop) && finds("720", bigShop), "72 isn't 720")
    expect(finds("sep", taxiRide) && finds("september", taxiRide) && finds("2026", taxiRide) && !finds("oct", taxiRide),
           "a month's name or a year")
    expect(finds("mar", bigShop) && finds("mart", bigShop), "\"mar\" finds March, \"mart\" the merchant")
    expect(finds("inr", bigShop) && !finds("inr", taxiRide), "a currency code")
    expect(finds("uncat", bigShop) && finds("uncategorized", taxiRide), "uncategorised, either spelling")
    expect(!finds("", taxiRide) && !finds("   ", taxiRide), "nothing typed matches nothing")

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
        MessageFormat.self,
    ])
}

try await MainActor.run { try run() }
