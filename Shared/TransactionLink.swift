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
        static let rate = "rate"
        static let rateBase = "rateBase"
        static let raw = "raw"
        static let format = "format"
        static let picked = "picked"
        static let known = "known"
        static let category = "category"
        static let subcategory = "subcategory"
        static let account = "account"
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
        if let card = draft.parsedCard { items.append(URLQueryItem(name: Key.card, value: card)) }
        if let rate = draft.exchangeRate, let base = draft.rateBase {
            items.append(URLQueryItem(name: Key.rate, value: "\(rate)"))
            items.append(URLQueryItem(name: Key.rateBase, value: base))
        }
        if let raw = draft.rawMessage { items.append(URLQueryItem(name: Key.raw, value: raw)) }
        if let format = draft.pickedFormat {
            items.append(URLQueryItem(name: Key.format, value: format.pattern))
            items.append(URLQueryItem(name: Key.picked, value: format.picked))
        }

        // Chosen in a share sheet that had the app's categories and cards:
        // sent by name, for the app to find its own.
        if draft.resolvedInExtension {
            items.append(URLQueryItem(name: Key.known, value: "1"))
            if let category = draft.category { items.append(URLQueryItem(name: Key.category, value: category.name)) }
            if let subcategory = draft.subcategory { items.append(URLQueryItem(name: Key.subcategory, value: subcategory.name)) }
            if let account = draft.account { items.append(URLQueryItem(name: Key.account, value: account.name)) }
        }

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
        // Setting the currency picks up the app's current rate for it...
        draft.currencyCode = values[Key.currency] ?? Currency.main
        // ...unless the share form already had one, which wins.
        if let rate = values[Key.rate].flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }),
           let base = values[Key.rateBase] {
            draft.exchangeRate = rate
            draft.rateBase = base
        }
        draft.merchant = values[Key.merchant] ?? ""
        draft.note = values[Key.note] ?? ""
        draft.reference = values[Key.reference]
        draft.rawMessage = values[Key.raw]
        draft.parsedCard = values[Key.card]

        if let seconds = values[Key.date].flatMap({ Double($0) }) {
            draft.date = Date(timeIntervalSince1970: seconds)
        }

        // The lookups the extension could not do itself.
        // Matched against the whole message, as the extension would have.
        if let text = draft.rawMessage ?? draft.parsedCard {
            draft.account = AccountMatching.account(for: text, in: context)
        }
        if let raw = draft.rawMessage {
            // A merchant picked in the share sheet, remembered when saved here.
            if let pattern = values[Key.format], let picked = values[Key.picked] {
                draft.pickedFormat = .init(pattern: pattern, sample: raw, picked: picked)
            }
            // The extension read the message without the formats learned
            // here. Unless its merchant was edited or picked, read it again
            // with them.
            let formats = (draft.pickedFormat.map { [$0.pattern] } ?? []) + LearnedParsing.formats(in: context)
            let unedited = draft.pickedFormat == nil && draft.merchant == (SMSParser.parse(raw)?.merchant ?? "")
            if let merchant = SMSParser.parse(raw, formats: formats)?.merchant {
                if unedited { draft.merchant = merchant }
                if let alias = TransactionDraft.alias(for: merchant, in: context) {
                    draft.category = alias.category
                    draft.subcategory = alias.subcategory
                    if unedited, !alias.displayName.isEmpty { draft.merchant = alias.displayName }
                }
            }
        }

        // The share sheet showed the app's categories and cards, so what it
        // sent is what was chosen there — leaving one empty included.
        if values[Key.known] == "1" {
            let same: (String, String) -> Bool = { $0.caseInsensitiveCompare($1) == .orderedSame }
            let categories = (try? context.fetch(FetchDescriptor<ExpenseCategory>())) ?? []
            let category = values[Key.category].flatMap { name in categories.first { same($0.name, name) } }
            draft.category = category
            draft.subcategory = values[Key.subcategory].flatMap { name in
                category?.sortedSubcategories.first { same($0.name, name) }
            }
            if let name = values[Key.account] {
                let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
                // Renamed or deleted since: keep the keyword match above.
                if let account = accounts.first(where: { same($0.name, name) }) { draft.account = account }
            } else {
                draft.account = nil
            }
        }

        return draft
    }
}
