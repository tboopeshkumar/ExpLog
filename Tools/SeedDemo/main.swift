import Foundation
import SwiftData

// Fills a store with the sample messages, for looking at the app with real
// content in the simulator:
//
//     ./Tools/seed-demo.sh
//
// Development convenience only — not part of either app target.

let storePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard !storePath.isEmpty else {
    print("usage: seeddemo <path-to-ExpMgr.store>")
    exit(1)
}

// Anonymised, like the parser fixtures — see Tools/ParserCheck/main.swift.
let messages = [
    "Dear Alex Morgan!  Cardholder, Your card XXXX4417 was used at V NORTHGATE AND SONS L for AED  15.90 on deferred payment basis on 20-Sep ref R77201. As per the agreement we confirm our acceptance to sell to you at the agreed price. Available Balance on your card is AED XXXX.  Regards, Crescent Finance.",
    "Dear Alex Morgan!  Cardholder, Your card XXXX4417 was used at MEGA CENTER RIVERTON XYZ for AED  30.02 on deferred payment basis on 20-Sep ref R77315. As per the agreement we confirm our acceptance to sell to you at the agreed price. Available Balance on your card is AED XXXX.  Regards, Crescent Finance.",
    "A txn on your Card XXXX8802 at DIAMOND CABS CITYCENT for AED  17.00 on 20-Sep at 11:30  is approved. Your available balance is XXXX.95",
    "Thank you for using Card ending 6150 at ROUND CLOCK MART SUPERMA for AED 2.25. Avl. limit is AED XXX.80.",
    "Thank you for using Card ending 6150 at BEANERY PLAZA 20THFLOOR for AED 31.20. Avl. limit is AED XXX.05.",
]

/// Category each sample belongs to, so the demo shows icons rather than blanks.
let categoryForMessage = [
    "V Northgate And Sons L": "Groceries",
    "Mega Center Riverton Xyz": "Groceries",
    "Diamond Cabs Citycent": "Transport",
    "Round Clock Mart Superma": "Groceries",
    "Beanery Plaza 20THFLOOR": "Dining",
]

@MainActor
func seed() throws {
    let schema = Schema([Transaction.self, ExpenseCategory.self, Account.self, MerchantAlias.self])
    let configuration = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: storePath))
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)

    SeedData.seedIfNeeded(context)
    let categories = try context.fetch(FetchDescriptor<ExpenseCategory>())

    for (name, last4) in [("Crescent Credit", "4417"), ("Harbour Platinum", "8802"), ("Summit Cashback", "6150")] {
        if TransactionDraft.account(withLast4: last4, in: context) == nil {
            context.insert(Account(name: name, last4: last4))
        }
    }
    try context.save()

    var added = 0
    for message in messages {
        guard let parsed = SMSParser.parse(message) else { continue }
        let draft = TransactionDraft(parsed: parsed, context: context)
        if TransactionDraft.duplicate(of: draft, in: context) != nil { continue }
        if let wanted = categoryForMessage[draft.merchant] {
            draft.category = categories.first { $0.name == wanted }
        }
        _ = try draft.save(in: context)
        added += 1
    }
    print("Seeded \(added) transaction(s) into \(storePath)")
}

try await MainActor.run { try seed() }
