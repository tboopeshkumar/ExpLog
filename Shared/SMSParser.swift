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

    public static func parse(_ text: String, receivedAt: Date = Date()) -> ParsedTransaction? {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        guard !isNonTransaction(message) else { return nil }

        var result = ParsedTransaction()
        result.raw = message
        result.kind = isCredit(message) ? .credit : .debit

        if let money = matchAmount(in: message) {
            result.currency = money.currency
            result.amount = money.amount
        }
        result.merchant = matchMerchant(in: message)
        result.cardLast4 = matchCardLast4(in: message)
        result.date = matchDate(in: message, receivedAt: receivedAt)
        result.reference = matchReference(in: message)

        // No recognisable amount means this isn't an alert we can do anything
        // useful with.
        guard result.amount != nil else { return nil }
        return result
    }

    // MARK: - Rejection

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

    private static func isCredit(_ text: String) -> Bool {
        let creditPatterns = [
            #"\bcredited\b"#,
            #"\brefund(ed)?\b"#,
            #"\brevers(al|ed)\b"#,
        ]
        return creditPatterns.contains { firstMatch(of: $0, in: text, caseInsensitive: true) != nil }
    }

    // MARK: - Amount

    private static let currencyCodes = "AED|SAR|QAR|KWD|BHD|OMR|USD|EUR|GBP|INR|PKR|LKR|PHP"

    /// Anchored on "for <CUR> <amount>" first. Nearly every card alert also
    /// carries a second amount — available balance or credit limit — and
    /// picking that one up would be worse than failing outright.
    private static var amountPatterns: [String] {
        [
            #"\bfor\s+(\#(currencyCodes))\s*[.:]?\s*([\d,]+(?:\.\d{1,2})?)"#,
            #"\b(\#(currencyCodes))\s*[.:]?\s*([\d,]+(?:\.\d{1,2})?)\s+(?:was |has been )?(?:spent|debited|charged|paid|used)"#,
            #"\b(?:amount|txn|transaction)\s+of\s+(\#(currencyCodes))\s*[.:]?\s*([\d,]+(?:\.\d{1,2})?)"#,
            // Last resort: the first properly-formed currency amount present.
            #"\b(\#(currencyCodes))\s*[.:]?\s*([\d,]+\.\d{2})\b"#,
        ]
    }

    private static func matchAmount(in text: String) -> (currency: String, amount: Decimal)? {
        for pattern in amountPatterns {
            guard let groups = firstMatch(of: pattern, in: text), groups.count >= 3,
                  let currency = groups[1], let rawAmount = groups[2],
                  let amount = decimal(from: rawAmount) else { continue }
            return (currency.uppercased(), amount)
        }
        return nil
    }

    private static func decimal(from string: String) -> Decimal? {
        let cleaned = string.replacingOccurrences(of: ",", with: "")
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
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

    private static func cleanMerchant(_ raw: String) -> String? {
        var value = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-*"))

        // Guard against a match having swallowed a sentence fragment rather
        // than a merchant name.
        guard value.count >= 2, value.count <= 60 else { return nil }
        guard value.rangeOfCharacter(from: .letters) != nil else { return nil }

        let noise: Set<String> = ["your card", "card", "the agreed price", "a txn", "txn", "you"]
        if noise.contains(value.lowercased()) { return nil }

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

    // MARK: - Card

    private static let cardPatterns = [
        #"\bcard\s+(?:no\.?\s*)?(?:ending(?:\s+(?:with|in))?\s+)?[X*#]{0,}(\d{4})\b"#,
        #"\bcard\s+[X*#]{2,}\s*(\d{4})\b"#,
        #"\b[X*]{4,}(\d{4})\b"#,
        #"\bending\s+(?:with\s+|in\s+)?(\d{4})\b"#,
    ]

    private static func matchCardLast4(in text: String) -> String? {
        for pattern in cardPatterns {
            if let groups = firstMatch(of: pattern, in: text, caseInsensitive: true),
               groups.count >= 2, let digits = groups[1] {
                return digits
            }
        }
        return nil
    }

    // MARK: - Date

    /// Each pattern requires digits after "on", so "on deferred payment basis on
    /// 20-Sep" resolves to the date and not to the word after the first "on".
    private static let datePatterns = [
        #"\bon\s+(\d{1,2}[-/ ][A-Za-z]{3,9}(?:[-/ ]\d{2,4})?)"#,
        #"\bon\s+(\d{1,2}[-/]\d{1,2}[-/]\d{2,4})"#,
        #"\b(\d{1,2}[-/ ][A-Za-z]{3,9}[-/ ]\d{2,4})\b"#,
        #"\b(\d{1,2}[-/][A-Za-z]{3,9})\b"#,
    ]

    private static let dateFormats = [
        "d-MMM-yyyy", "d-MMM-yy", "d-MMM",
        "d/MMM/yyyy", "d/MMM/yy", "d/MMM",
        "d MMM yyyy", "d MMM yy", "d MMM",
        "d-MM-yyyy", "d-MM-yy",
        "d/MM/yyyy", "d/MM/yy",
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

        // Fold in a time of day when the message carries one.
        guard let groups = firstMatch(of: #"\bat\s+(\d{1,2}):(\d{2})(?::\d{2})?\s*([AaPp][Mm])?"#, in: text),
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
        let normalized = token.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.calendar = calendar
        formatter.isLenient = false

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
