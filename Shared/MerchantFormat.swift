import Foundation

/// Where the merchant sits in one bank's alerts, learned from a single message
/// in which the user picked the merchant's words.
///
/// The words before the merchant become the pattern's anchor: the fixed words
/// kept as they are, and the parts that change between alerts — anything with
/// a digit (amounts, cards, dates, times), month and day names, AM/PM,
/// currency codes — as wildcards. So a pattern learned from
///
///     Debit Card XX0171 linked to account XX810001 was used for AED72.57
///     on Sep 27 2026 12:10PM at AMAZONUFR DI, AE. Available Balance …
///
/// with "AMAZONUFR DI" picked reads the merchant from the next alert of that
/// shape, whatever the card, amount, date or shop. Picking just "AMAZONUFR"
/// learns to leave out the capitalised word before the comma (a city, "DI"),
/// so "CARREFOUR MOE DU," gives "Carrefour Moe".
///
/// Stored as a regular expression string (see MessageFormat) and matched
/// case-insensitively.
public enum MerchantFormat {

    public struct Word {
        public let text: String
        public let range: Range<String.Index>
    }

    /// The message split on whitespace, the units the user picks from.
    public static func words(of message: String) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        for index in message.indices {
            if message[index].isWhitespace {
                if let wordStart = start {
                    words.append(Word(text: String(message[wordStart..<index]), range: wordStart..<index))
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        if let wordStart = start {
            words.append(Word(text: String(message[wordStart...]), range: wordStart..<message.endIndex))
        }
        return words
    }

    /// The merchant as it would be shown, for words `picked` of `message`.
    public static func merchant(picking picked: ClosedRange<Int>, of message: String) -> String? {
        let words = words(of: message)
        guard picked.lowerBound >= 0, picked.upperBound < words.count else { return nil }
        return SMSParser.cleanMerchant(words[picked].map(\.text).joined(separator: " "))
    }

    /// A pattern that finds the words `picked` in `message`, and the words in
    /// the same place in messages like it. nil when the pattern wouldn't read
    /// the picked merchant back out of the message it came from.
    public static func pattern(from message: String, picking picked: ClosedRange<Int>) -> String? {
        let words = words(of: message)
        guard picked.lowerBound >= 0, picked.upperBound < words.count,
              let expected = merchant(picking: picked, of: message) else { return nil }

        // Before: every word up to the merchant, runs of changing parts
        // collapsed into one wildcard so a date written in more or fewer
        // words still matches.
        var parts: [String] = []
        for word in words[..<picked.lowerBound] {
            let part = isChanging(word.text) ? ".+?" : NSRegularExpression.escapedPattern(for: word.text)
            if part == ".+?", parts.last == ".+?" { continue }
            parts.append(part)
        }
        parts.append("(.+?)")
        let before = parts.joined(separator: #"\s+"#)

        let pattern = "(?is)^" + before + after(picked.upperBound, in: words)
        guard merchant(in: message, pattern: pattern) == expected else { return nil }
        return pattern
    }

    /// The merchant `pattern` finds in `message`, tidied like any other; nil
    /// when the message isn't in that format.
    public static func merchant(in message: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return SMSParser.cleanMerchant(String(text[range]))
    }

    // MARK: - Building

    /// What must follow the merchant: where it stops.
    private static func after(_ last: Int, in words: [Word]) -> String {
        // The picked words end at punctuation: "AMAZONUFR DI," stops at the comma.
        if let mark = trailingPunctuation(of: words[last].text) {
            return NSRegularExpression.escapedPattern(for: mark)
        }
        // Capitalised words left out after the merchant — the city in
        // "AMAZONUFR DI, AE" — are skipped as wildcards, up to their comma.
        var skipped = 0
        var index = last + 1
        while index < words.count, skipped < 3, isShouted(words[index].text) {
            skipped += 1
            if let mark = trailingPunctuation(of: words[index].text) {
                return String(repeating: #"\s+\S+?"#, count: skipped) + NSRegularExpression.escapedPattern(for: mark)
            }
            index += 1
        }
        let skip = String(repeating: #"\s+\S+"#, count: skipped)
        guard index < words.count else { return skip + #"\s*$"# }
        // Otherwise the next word: "at SHOP for AED …" stops before "for".
        let next = words[index].text
        return skip + #"\s+"# + (isChanging(next) ? #"\S+"# : NSRegularExpression.escapedPattern(for: next))
    }

    private static let changingWords: Set<String> = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let names = (formatter.monthSymbols ?? []) + (formatter.shortMonthSymbols ?? [])
            + (formatter.weekdaySymbols ?? []) + (formatter.shortWeekdaySymbols ?? [])
            + ["sept", "am", "pm", "a.m", "p.m"]
        return Set(names.map { $0.lowercased() })
    }()

    /// Parts of a message that differ from one alert to the next.
    private static func isChanging(_ word: String) -> Bool {
        if word.contains(where: \.isNumber) { return true }
        let bare = word.trimmingCharacters(in: .punctuationCharacters)
        return changingWords.contains(bare.lowercased()) || Currency.supported.contains(bare.uppercased())
    }

    /// All capitals, as card-network merchant descriptors are written.
    private static func isShouted(_ word: String) -> Bool {
        word.contains(where: \.isLetter) && !word.contains(where: \.isLowercase) && !isChanging(word)
    }

    private static func trailingPunctuation(of word: String) -> String? {
        guard let last = word.last, ",.;:)".contains(last), word.count > 1 else { return nil }
        return String(last)
    }
}
