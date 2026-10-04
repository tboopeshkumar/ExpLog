import Foundation

/// Reads a card-transaction SMS into structured fields.
///
/// Deliberately not one rule set per bank. Card alerts across banks share a
/// small grammar — "<card> at <merchant> for <CUR> <amount> on <date>" — so each
/// field is matched independently and the parser tolerates the parts a given
/// bank leaves out. Supporting a new bank usually means adding one pattern to
/// one of the arrays below, not writing a new rule set.
public enum SMSParser {

    // MARK: - Entry point

    /// - Parameter formats: merchant patterns the user taught by picking the
    ///   merchant out of a message (see MerchantFormat). Tried before the
    ///   built-in patterns, so a correction wins over a guess.
    public static func parse(_ text: String, receivedAt: Date = Date(), formats: [String] = []) -> ParsedTransaction? {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        guard !isNonTransaction(message) else { return nil }

        var result = ParsedTransaction()
        result.raw = message

        if let money = matchAmount(in: message) {
            result.currency = money.currency
            result.amount = money.amount
        }
        result.merchant = formats.lazy.compactMap { MerchantFormat.merchant(in: message, pattern: $0) }.first
            ?? matchMerchant(in: message)
        result.card = matchCard(in: message)
        result.date = matchDate(in: message, receivedAt: receivedAt)
        result.reference = matchReference(in: message)

        // No recognisable amount means this isn't an alert we can do anything
        // useful with.
        guard result.amount != nil else { return nil }
        return result
    }

    // MARK: - Rejection

    /// Why a message isn't logged.
    public enum Rejection: Equatable, Sendable {
        /// An OTP, a declined or scheduled payment, a statement notice.
        case notAPayment
        /// No currency and amount to log.
        case noAmount
    }

    /// Why `parse` returns nil for `text`, or nil when it would be read.
    public static func rejection(of text: String) -> Rejection? {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        if isNonTransaction(message) { return .notAPayment }
        return matchAmount(in: message) == nil ? .noAmount : nil
    }

    /// Messages that mention money but are not a completed card transaction.
    private static let rejectPatterns = [
        #"\bOTP\b"#,
        #"one[- ]time (pass(word|code)|pin)"#,
        #"verification code"#,
        #"\bdeclined\b"#,
        #"\bunsuccessful\b"#,
        #"(was|has been|is) (not approved|rejected)"#,
        #"\bwill be (debited|charged)\b"#,          // scheduled, not yet spent
        #"\be-?statement\b"#,
        #"\bminimum (amount )?due\b"#,
    ]

    private static func isNonTransaction(_ text: String) -> Bool {
        rejectPatterns.contains { firstMatch(of: $0, in: text, caseInsensitive: true) != nil }
    }

    // MARK: - Amount

    private static let currencyCodes = Currency.supported.joined(separator: "|")

    /// Anchored on "for <CUR> <amount>" first. Nearly every card alert also
    /// carries a second amount — available balance or credit limit — and
    /// picking that one up would be worse than failing outright.
    private static var amountPatterns: [String] {
        [
            #"\bfor\s+(\#(currencyCodes))\s*[.:]?\s*(\d[\d.,]*)"#,
            #"\b(\#(currencyCodes))\s*[.:]?\s*(\d[\d.,]*)\s+(?:was |has been )?(?:spent|debited|charged|paid|used)"#,
            #"\b(?:amount|txn|transaction)\s+of\s+(\#(currencyCodes))\s*[.:]?\s*(\d[\d.,]*)"#,
            // Last resort: the first currency amount that has a decimal part.
            #"\b(\#(currencyCodes))\s*[.:]?\s*(\d[\d.,]*[.,]\d{2,3})\b"#,
        ]
    }

    private static func matchAmount(in text: String) -> (currency: String, amount: Decimal)? {
        for pattern in amountPatterns {
            guard let groups = firstMatch(of: pattern, in: text), groups.count >= 3,
                  let currency = groups[1], let rawAmount = groups[2],
                  let amount = decimal(from: rawAmount, currency: currency.uppercased()) else { continue }
            return (currency.uppercased(), amount)
        }
        return nil
    }

    /// Reads an amount whichever way the bank writes it: "1,234.56",
    /// "1.234,56", "12,50", "1,850", "12.345".
    ///
    /// - Both separators present: the last one is the decimal point.
    /// - One separator, repeated ("1,234,567"): thousands.
    /// - One separator followed by one or two digits ("12,50"): decimal.
    /// - One separator followed by exactly three digits is the ambiguous case:
    ///   a decimal point for currencies with three decimal places (KWD 12.345),
    ///   a thousands separator for the rest (JPY 1,850; EUR 1.850).
    static func decimal(from raw: String, currency: String) -> Decimal? {
        // A sentence can end right after the amount: "AED 2.25."
        let string = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        let separators = string.filter { $0 == "." || $0 == "," }
        let lastSeparator = string.lastIndex { $0 == "." || $0 == "," }

        var normalized: String
        if let lastSeparator, Set(separators).count == 2 {
            let decimalMark = string[lastSeparator]
            normalized = string.filter { $0 != (decimalMark == "." ? "," : ".") }
                .replacingOccurrences(of: String(decimalMark), with: ".")
        } else if let lastSeparator, separators.count == 1 {
            let digitsAfter = string.distance(from: lastSeparator, to: string.endIndex) - 1
            let isDecimal = digitsAfter <= 2 || (digitsAfter == 3 && Currency.minorUnits(of: currency) == 3)
            normalized = isDecimal
                ? string.replacingOccurrences(of: String(string[lastSeparator]), with: ".")
                : string.filter(\.isNumber)
        } else {
            normalized = string.filter(\.isNumber)
        }

        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value > 0 else { return nil }
        return value
    }

    // MARK: - Merchant

    /// Non-greedy up to the amount clause. That matters: "at DIAMOND CABS
    /// CITYCENT for AED 17.00 on 20-Sep at 11:30" contains a second "at" that a
    /// greedy match would run straight into.
    private static var merchantPatterns: [String] {
        [
            #"\b(?:at|@)\s+(.+?)\s+for\s+(?:\#(currencyCodes))\b"#,
            #"\bat\s+(.+?)\s+on\s+\d{1,2}[-/ ]"#,
            #"\b(?:to|towards)\s+(.+?)\s+(?:on|for)\s+"#,
            #"\bmerchant\s*[:\-]\s*(.+?)(?:[.,]|$)"#,
            #"\bat\s+([A-Z0-9][A-Z0-9 &'*.\-]{2,}?)(?:[.,]|\s+(?:is|was)\b|$)"#,
        ]
    }

    private static func matchMerchant(in text: String) -> String? {
        for pattern in merchantPatterns {
            guard let groups = firstMatch(of: pattern, in: text), groups.count >= 2,
                  let raw = groups[1], let cleaned = cleanMerchant(raw) else { continue }
            return cleaned
        }
        return nil
    }

    /// Tidies merchant text for display; nil when it isn't a plausible name.
    static func cleanMerchant(_ raw: String) -> String? {
        var value = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-*"))
        guard isPlausibleMerchant(value) else { return nil }

        // Merchant strings arrive shouting and truncated ("ROUND CLOCK MART
        // SUPERMA"). The truncation is preserved — an alias can map it to a
        // readable name later — but the capitals are not. Words containing
        // digits keep their original case, since `capitalized` renders
        // "20THFLOOR" as the worse-looking "20Thfloor".
        if value == value.uppercased() {
            value = value
                .split(separator: " ")
                .map { word in
                    word.contains(where: \.isNumber) ? String(word) : word.capitalized
                }
                .joined(separator: " ")
        }
        return value
    }

    /// False for text a pattern swallowed that is a sentence fragment rather
    /// than a name — "account XX810001 was used" from "linked to account
    /// XX810001 was used for …". Public so learned merchants saved from such a
    /// misreading can be recognised and dropped.
    public static func isPlausibleMerchant(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 60 else { return false }
        guard value.rangeOfCharacter(from: .letters) != nil else { return false }

        let noise: Set<String> = ["your card", "card", "the agreed price", "a txn", "txn", "you"]
        if noise.contains(value.lowercased()) { return false }

        let fragments = [
            // A masked card or account number belongs to the sentence, not a shop.
            #"[X*#]{2,}\d"#,
            #"^(?:your\s+)?(?:account|a/c|card)\b"#,
            // Verbs a shop name doesn't contain, but the rest of the sentence does.
            #"\b(?:was|were|has been|have been|linked to|debited|credited)\b"#,
        ]
        return !fragments.contains { firstMatch(of: $0, in: value, caseInsensitive: true) != nil }
    }

    // MARK: - Card

    /// Three or four digits: banks disagree, and "XXX453" and "XXXX4453" are
    /// both in use. The capture keeps any mask, so the result can be matched
    /// back against the next alert verbatim.
    private static let cardPatterns = [
        #"\bcard\s+(?:no\.?\s*)?(?:ending(?:\s+(?:with|in))?\s+)?([X*#]*\d{3,4})\b"#,
        #"\bcard\s+([X*#]{2,}\s*\d{3,4})\b"#,
        #"(?<![\w*#])([X*#]{2,}\d{3,4})\b"#,
        #"\bending\s+(?:with\s+|in\s+)?(\d{3,4})\b"#,
    ]

    private static func matchCard(in text: String) -> String? {
        for pattern in cardPatterns {
            if let groups = firstMatch(of: pattern, in: text, caseInsensitive: true),
               groups.count >= 2, let card = groups[1] {
                return card.replacingOccurrences(of: " ", with: "")
            }
        }
        return nil
    }

    // MARK: - Date

    /// Each pattern requires digits after "on", so "on deferred payment basis on
    /// 20-Sep" resolves to the date and not to the word after the first "on".
    private static let datePatterns = [
        #"\bon\s+(\d{1,2}[-/ ][A-Za-z]{3,9}(?:[-/ ]\d{2,4})?)"#,
        // Month first — "on Sep 27 2026", "on Sep 27, 2026", "on September 27".
        #"\bon\s+([A-Za-z]{3,9}\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?)\b"#,
        #"\bon\s+(\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})"#,
        #"\bon\s+(\d{4}-\d{1,2}-\d{1,2})"#,
        #"\b(\d{1,2}[-/ ][A-Za-z]{3,9}[-/ ]\d{2,4})\b"#,
        #"\b(\d{1,2}[-/][A-Za-z]{3,9})\b"#,
        // Numeric dates without "on" — "dated 20.09.2026", "2026-09-20".
        #"\b(\d{1,2}[/.]\d{1,2}[/.]\d{4})\b"#,
        #"\b(\d{4}-\d{2}-\d{2})\b"#,
    ]

    private static let dateFormats = [
        "d-MMM-yyyy", "d-MMM-yy", "d-MMM",
        "d/MMM/yyyy", "d/MMM/yy", "d/MMM",
        "d MMM yyyy", "d MMM yy", "d MMM",
        "MMM d yyyy", "MMM d", "MMMM d yyyy", "MMMM d",
    ]

    /// Both orders, day-first and month-first; parseDateToken chooses.
    private static let numericDateFormats = [
        "d-M-yyyy", "d-M-yy", "d/M/yyyy", "d/M/yy", "d.M.yyyy", "d.M.yy",
        "M-d-yyyy", "M-d-yy", "M/d/yyyy", "M/d/yy", "M.d.yyyy", "M.d.yy",
        "yyyy-M-d", "yyyy/M/d",
    ]

    private static func matchDate(in text: String, receivedAt: Date) -> Date? {
        var day: Date?
        for pattern in datePatterns {
            guard let groups = firstMatch(of: pattern, in: text), groups.count >= 2,
                  let token = groups[1], let parsed = parseDateToken(token, receivedAt: receivedAt) else { continue }
            day = parsed
            break
        }
        guard let day else { return nil }

        // Fold in a time of day when the message carries one: "at 11:30",
        // or straight after the date, "Sep 27 2026 12:10PM".
        guard let groups = firstMatch(of: #"\b(\d{1,2}):(\d{2})(?::\d{2})?\s*([AaPp][Mm])?\b"#, in: text),
              groups.count >= 3,
              var hour = groups[1].flatMap({ Int($0) }),
              let minute = groups[2].flatMap({ Int($0) }) else { return day }

        if groups.count > 3, let meridiem = groups[3]?.lowercased() {
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(bySettingHour: min(hour, 23), minute: min(minute, 59), second: 0, of: day) ?? day
    }

    private static func parseDateToken(_ token: String, receivedAt: Date) -> Date? {
        var normalized = token.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if normalized.contains(where: \.isLetter) {
            // "Sep. 27th, 2026" → "Sep 27 2026", the shape the formats expect.
            normalized = normalized
                .replacingOccurrences(of: #"(\d)(?:st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[.,]"#, with: "", options: .regularExpression)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.calendar = calendar
        formatter.isLenient = false

        // An all-digit date ("09/05/2026") reads either way round: 9 May or
        // 5 September. A card alert arrives within a day or two of the
        // purchase, so take whichever reading is nearest the message's
        // arrival — more reliable than guessing the bank's convention from the
        // phone's region.
        if normalized.allSatisfy({ $0.isNumber || $0 == "/" || $0 == "-" || $0 == "." }) {
            let readings = numericDateFormats.compactMap { format -> Date? in
                formatter.dateFormat = format
                return formatter.date(from: normalized)
            }
            return readings
                .min { abs($0.timeIntervalSince(receivedAt)) < abs($1.timeIntervalSince(receivedAt)) }
                .map { calendar.startOfDay(for: $0) }
        }

        for format in dateFormats {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: normalized) else { continue }

            if format.contains("y") {
                return calendar.startOfDay(for: parsed)
            }
            // Year-less dates such as "20-Sep" parse to 1970. Anchor them to the
            // year of the message, stepping back a year when that would place
            // the transaction in the future (a December SMS opened in January).
            let parts = calendar.dateComponents([.month, .day], from: parsed)
            var components = calendar.dateComponents([.year], from: receivedAt)
            components.month = parts.month
            components.day = parts.day
            guard var candidate = calendar.date(from: components),
                  let cutoff = calendar.date(byAdding: .day, value: 2, to: receivedAt) else { continue }
            if candidate > cutoff {
                components.year = (components.year ?? 0) - 1
                candidate = calendar.date(from: components) ?? candidate
            }
            return calendar.startOfDay(for: candidate)
        }
        return nil
    }

    // MARK: - Reference

    private static func matchReference(in text: String) -> String? {
        let patterns = [
            #"\bref(?:erence)?(?:\s+(?:no|number|id))?\.?\s*[:#]?\s*([A-Za-z0-9\-]{4,20})\b"#,
            #"\btrn\s*[:#]?\s*([A-Za-z0-9\-]{4,20})\b"#,
        ]
        for pattern in patterns {
            if let groups = firstMatch(of: pattern, in: text, caseInsensitive: true),
               groups.count >= 2, let reference = groups[1] {
                return reference
            }
        }
        return nil
    }

    // MARK: - Regex helper

    /// Capture groups of the first match, index 0 being the whole match.
    private static func firstMatch(of pattern: String, in text: String, caseInsensitive: Bool = false) -> [String?]? {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }

        return (0..<match.numberOfRanges).map { index in
            guard let groupRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[groupRange])
        }
    }
}
