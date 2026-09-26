import SwiftUI

extension Formatting {
    /// An amount for display, as Text so a currency sign can be an image.
    ///
    /// Dirhams get the UAE Dirham sign (U+20C3) as the custom "dirham" symbol:
    /// no iOS 27 font has a glyph for it, so typed as a character it would
    /// render as the LastResort placeholder box. A symbol image interpolated
    /// into Text sits on the baseline and takes the surrounding font size and
    /// colour, like a character would.
    ///
    /// Everything else falls back to the system currency format. Strings that
    /// leave the app — the CSV export, alerts — keep using `money`, which
    /// writes "AED".
    public static func moneyText(_ amount: Decimal, code: String) -> Text {
        guard code == "AED" else {
            return Text(money(amount, code: code))
        }
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        // Narrow no-break space: keeps the sign attached to the amount without
        // the full word gap "AED 31.20" needed.
        return Text("\(dirhamSign)\u{202F}\(number)")
    }

    /// Per-currency totals on one line, main currency first:
    /// "Ð 1,465.12 + ₹2,500.00". Each stays in its own currency.
    public static func totalsText(_ totals: [Currency.Total]) -> Text {
        guard let first = totals.first else { return moneyText(0, code: Currency.main) }
        return totals.dropFirst().reduce(moneyText(first.amount, code: first.code)) { line, next in
            line + Text(" + ") + moneyText(next.amount, code: next.code)
        }
    }

    /// A total in the main currency, others converted at the rate each was
    /// logged with: "Ð 1,575.25". An expense without a rate can't be counted,
    /// so it's shown after: "Ð 1,465.12 + ₹2,500.00".
    public static func mainTotalText(of transactions: [Transaction], main: String) -> Text {
        let result = Currency.mainTotal(of: transactions, main: main)
        let total = Currency.Total(code: main, amount: result.total, count: 0)
        return totalsText([total] + result.unconverted)
    }

    /// The currency marker on its own, for a field's leading label: the
    /// Dirham sign, a symbol like "$" or "€", or the code where there's none.
    public static func currencySign(for code: String) -> Text {
        code == "AED" ? Text(dirhamSign) : Text(Currency.symbol(for: code))
    }

    private static var dirhamSign: Image {
        // Labelled so VoiceOver says "dirhams" rather than the asset name.
        Image("dirham", label: Text("dirhams"))
    }
}
