import Foundation
import SwiftData

/// Logging an expense straight from a bank SMS, with no form: what the
/// Shortcuts action does when a Messages automation hands it an alert. Goes
/// through the same steps as sharing a message — learned formats, card
/// keywords, remembered merchants, the duplicate check — then saves.
public enum MessageLogging {

    /// Settings → Shortcuts → "Review before saving": open the filled-in form
    /// instead of saving. Off by default.
    public static let reviewKey = "reviewMessageExpenses"

    public enum Outcome {
        /// An OTP, a declined payment, or no amount: nothing to log.
        case notAnExpense
        /// This alert is already logged — shared by hand, or the automation
        /// ran twice.
        case duplicate(Transaction)
        /// Read and matched, not yet saved.
        case ready(TransactionDraft)
    }

    /// Reads `message` into a draft ready to save, or says why there isn't one.
    public static func prepare(_ message: String, receivedAt: Date = .now, in context: ModelContext) -> Outcome {
        guard let parsed = LearnedParsing.parse(message, receivedAt: receivedAt, in: context) else { return .notAnExpense }
        let draft = TransactionDraft(parsed: parsed, context: context, receivedAt: receivedAt)
        // Saved without a look, so a missing merchant needs something to show.
        if draft.merchant.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.merchant = parsed.card.map { "Card \($0)" } ?? "Unknown merchant"
        }
        if let existing = TransactionDraft.duplicate(of: draft, in: context) { return .duplicate(existing) }
        return .ready(draft)
    }

    /// "AED 72.57 at Amazon · Shopping › Online", for the action's result.
    public static func summary(amount: Decimal, currency: String, merchant: String,
                               category: ExpenseCategory?, subcategory: ExpenseSubcategory?) -> String {
        let money = Formatting.money(amount, code: currency)
        let place = [category?.name, subcategory?.name].compactMap { $0 }.joined(separator: " › ")
        return "\(money) at \(merchant) · \(place.isEmpty ? "Uncategorised" : place)"
    }

    public static func summary(of transaction: Transaction) -> String {
        summary(amount: transaction.amount, currency: transaction.currencyCode, merchant: transaction.merchant,
                category: transaction.category, subcategory: transaction.subcategory)
    }

    public static func summary(of draft: TransactionDraft) -> String {
        summary(amount: draft.amount, currency: draft.currencyCode, merchant: draft.merchant,
                category: draft.category, subcategory: draft.subcategory)
    }
}
