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
    let total = all.reduce(Decimal(0)) { $0 + $1.signedAmount }
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
