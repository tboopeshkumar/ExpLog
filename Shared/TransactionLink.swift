import Foundation
import SwiftData

/// Encodes a transaction as an `explog://add?...` URL string, and back.
///
/// This is the payload format SharedInbox stores when there's no App Group. The
/// URL is never opened — iOS won't let a share extension launch its app — it's
/// simply a compact, self-describing encoding. Decoding happens app-side, which
/// is also where the card and category lookups run, since the extension can't
/// see the app's database.
public enum TransactionLink {
    public static let scheme = "explog"
    public static let host = "add"

    private enum Key {
        static let amount = "amount"
        static let currency = "currency"
        static let date = "date"
        static let merchant = "merchant"
        static let note = "note"
        static let reference = "ref"
        static let card = "card"
        static let raw = "raw"
    }

    // MARK: - Encode

    public static func url(for draft: TransactionDraft) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host

        var items: [URLQueryItem] = [
            URLQueryItem(name: Key.amount, value: "\(draft.amount)"),
            URLQueryItem(name: Key.currency, value: draft.currencyCode),
            URLQueryItem(name: Key.date, value: "\(draft.date.timeIntervalSince1970)"),
            URLQueryItem(name: Key.merchant, value: draft.merchant),
        ]
        if !draft.note.isEmpty { items.append(URLQueryItem(name: Key.note, value: draft.note)) }
        if let reference = draft.reference { items.append(URLQueryItem(name: Key.reference, value: reference)) }
        if let card = draft.parsedLast4 { items.append(URLQueryItem(name: Key.card, value: card)) }
        if let raw = draft.rawMessage { items.append(URLQueryItem(name: Key.raw, value: raw)) }

        components.queryItems = items
        return components.url
    }

    // MARK: - Decode

    /// Rebuilds a draft on the app side, resolving the card and any learned
    /// category against the app's own database.
    public static func draft(from url: URL, context: ModelContext) -> TransactionDraft? {
        guard url.scheme == scheme, url.host == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }

        var values: [String: String] = [:]
        for item in items {
            if let value = item.value { values[item.name] = value }
        }

        guard let amountText = values[Key.amount],
              let amount = Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX")),
              amount > 0 else { return nil }

        let draft = TransactionDraft()
        draft.amount = amount
        draft.currencyCode = values[Key.currency] ?? "AED"
        draft.merchant = values[Key.merchant] ?? ""
        draft.note = values[Key.note] ?? ""
        draft.reference = values[Key.reference]
        draft.rawMessage = values[Key.raw]
        draft.parsedLast4 = values[Key.card]

        if let seconds = values[Key.date].flatMap({ Double($0) }) {
            draft.date = Date(timeIntervalSince1970: seconds)
        }

        // The lookups the extension could not do itself.
        if let last4 = draft.parsedLast4 {
            draft.account = TransactionDraft.account(withLast4: last4, in: context)
        }
        if let raw = draft.rawMessage,
           let parsedMerchant = SMSParser.parse(raw)?.merchant,
           let alias = TransactionDraft.alias(for: parsedMerchant, in: context) {
            draft.category = alias.category
            if !alias.displayName.isEmpty { draft.merchant = alias.displayName }
        }

        return draft
    }
}
