import Foundation

/// Which currencies ExpLog knows, and which one is "main": the default for new
/// expenses and the one totals are counted in.
///
/// Every expense keeps its own currency code. Totals never add different
/// currencies together — there are no exchange rates here — so spending in
/// other currencies is always shown separately (see `totals(of:)`).
public enum Currency {

    /// Recognised in SMS alerts and offered in pickers. ISO 4217 codes: the
    /// Gulf currencies first, since that's where the parser was built, then
    /// major and regional ones.
    public static let supported = [
        "AED", "SAR", "QAR", "KWD", "BHD", "OMR",
        "USD", "EUR", "GBP", "CHF", "JPY", "CNY", "HKD", "SGD", "AUD", "NZD", "CAD",
        "INR", "PKR", "LKR", "BDT", "NPR", "PHP", "MYR", "THB", "IDR", "KRW",
        "EGP", "JOD", "TRY", "ZAR",
    ]

    /// Digits after the decimal point (ISO 4217 minor units): 0 for yen and
    /// won, 3 for the dinars and the Omani rial, 2 for the rest here. Decides
    /// whether "12.345" is twelve and a bit, or twelve thousand.
    public static func minorUnits(of code: String) -> Int {
        switch code {
        case "JPY", "KRW": return 0
        case "KWD", "BHD", "OMR", "JOD": return 3
        default: return 2
        }
    }

    /// Last resort when nothing better is known.
    public static let fallback = "USD"

    // MARK: - Names and symbols

    /// "UAE Dirham", "US Dollar" — in the device's language.
    public static func name(for code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code) ?? code
    }

    /// "$", "€", "₹" where there's a well-known symbol; the code where there
    /// isn't. (AED's sign is drawn separately — no font has it yet.)
    public static func symbol(for code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale.current
        formatter.currencyCode = code
        return formatter.currencySymbol ?? code
    }
}
