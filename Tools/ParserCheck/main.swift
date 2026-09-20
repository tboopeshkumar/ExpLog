import Foundation

// Command-line harness for SMSParser. Builds against the same source the app
// and share extension use, so it can be run on a Mac without Xcode:
//
//     ./Tools/check-parser.sh
//
// Add every new SMS format here with its expected fields before touching the
// parser — this is the regression suite.

struct Expectation {
    let label: String
    let message: String
    let amount: Decimal?
    let currency: String?
    let merchant: String?
    let cardLast4: String?
    let day: String?          // "yyyy-MM-dd", nil when the SMS carries no date
    let reference: String?
}

let referenceDate: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 20
    components.hour = 14
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(from: components)!
}()

// Fixtures are anonymised: fictional cardholder, banks, merchants, card digits
// and reference numbers. Every structural quirk of the real messages is kept
// intact, because that is what the parser is actually being tested against —
// the doubled spaces, the truncated merchant names, the second amount at the
// end, the "on <word> basis on <date>" phrasing, the trailing "at the agreed
// price". Anonymise the same way when adding a new format.
let cases: [Expectation] = [
    Expectation(
        label: "Deferred-payment alert with reference",
        message: "Dear Alex Morgan!  Cardholder, Your card XXXX4417 was used at V NORTHGATE AND SONS L for AED  15.90 on deferred payment basis on 20-Sep ref R77201. As per the agreement we confirm our acceptance to sell to you at the agreed price. Available Balance on your card is AED XXXX.  Regards, Crescent Finance.",
        amount: Decimal(string: "15.90"), currency: "AED",
        merchant: "V Northgate And Sons L", cardLast4: "4417",
        day: "2026-09-20", reference: "R77201"
    ),
    Expectation(
        label: "Deferred-payment alert 2",
        message: "Dear Alex Morgan!  Cardholder, Your card XXXX4417 was used at MEGA CENTER RIVERTON XYZ for AED  30.02 on deferred payment basis on 20-Sep ref R77315. As per the agreement we confirm our acceptance to sell to you at the agreed price. Available Balance on your card is AED XXXX.  Regards, Crescent Finance.",
        amount: Decimal(string: "30.02"), currency: "AED",
        merchant: "Mega Center Riverton Xyz", cardLast4: "4417",
        day: "2026-09-20", reference: "R77315"
    ),
    Expectation(
        label: "Approved txn with time",
        message: "A txn on your Card XXXX8802 at DIAMOND CABS CITYCENT for AED  17.00 on 20-Sep at 11:30  is approved. Your available balance is XXXX.95",
        amount: Decimal(string: "17.00"), currency: "AED",
        merchant: "Diamond Cabs Citycent", cardLast4: "8802",
        day: "2026-09-20", reference: nil
    ),
    Expectation(
        label: "Thank-you, no date",
        message: "Thank you for using Card ending 6150 at ROUND CLOCK MART SUPERMA for AED 2.25. Avl. limit is AED XXX.80.",
        amount: Decimal(string: "2.25"), currency: "AED",
        merchant: "Round Clock Mart Superma", cardLast4: "6150",
        day: nil, reference: nil
    ),
    Expectation(
        label: "Thank-you, no date 2",
        message: "Thank you for using Card ending 6150 at BEANERY PLAZA 20THFLOOR for AED 31.20. Avl. limit is AED XXX.05.",
        amount: Decimal(string: "31.20"), currency: "AED",
        merchant: "Beanery Plaza 20THFLOOR", cardLast4: "6150",
        day: nil, reference: nil
    ),
]

/// Messages the parser must refuse, so an OTP never lands in the ledger.
let mustReject: [(String, String)] = [
    ("OTP", "Your OTP for transaction of AED 250.00 is 884213. Do not share it with anyone."),
    ("Declined", "Your card XXXX4417 transaction at MEGA CENTER for AED 90.00 was declined due to insufficient balance."),
    ("Statement reminder", "Your credit card statement is ready. Minimum amount due AED 150.00 by 05-Oct."),
    ("No amount", "Dear Customer, your card XXXX4417 has been activated successfully."),
]

// MARK: - Runner

let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

var failures = 0

func check<T: Equatable>(_ field: String, _ actual: T?, _ expected: T?, indent: String = "    ") {
    let ok = actual == expected
    if !ok { failures += 1 }
    let mark = ok ? "✓" : "✗"
    let actualText = actual.map { "\($0)" } ?? "nil"
    let expectedText = expected.map { "\($0)" } ?? "nil"
    if ok {
        print("\(indent)\(mark) \(field.padding(toLength: 9, withPad: " ", startingAt: 0)) \(actualText)")
    } else {
        print("\(indent)\(mark) \(field.padding(toLength: 9, withPad: " ", startingAt: 0)) got \(actualText)  —  expected \(expectedText)")
    }
}

print("\nPARSING\n")

for testCase in cases {
    print("  \(testCase.label)")
    guard let parsed = SMSParser.parse(testCase.message, receivedAt: referenceDate) else {
        print("    ✗ parser returned nil\n")
        failures += 1
        continue
    }
    check("amount", parsed.amount, testCase.amount)
    check("currency", parsed.currency, testCase.currency)
    check("merchant", parsed.merchant, testCase.merchant)
    check("card", parsed.cardLast4, testCase.cardLast4)
    check("date", parsed.date.map { dayFormatter.string(from: $0) }, testCase.day)
    check("ref", parsed.reference, testCase.reference)
    print("")
}

print("REJECTING\n")

for (label, message) in mustReject {
    let parsed = SMSParser.parse(message, receivedAt: referenceDate)
    if parsed == nil {
        print("  ✓ \(label)")
    } else {
        print("  ✗ \(label) — parsed as \(parsed!.amount.map { "\($0)" } ?? "?") at \(parsed!.merchant ?? "?")")
        failures += 1
    }
}

print("")
if failures == 0 {
    print("All checks passed.\n")
} else {
    print("\(failures) check(s) failed.\n")
    exit(1)
}
