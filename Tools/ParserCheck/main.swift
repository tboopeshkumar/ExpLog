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
    let card: String?        // as the SMS writes it, mask included
    let day: String?          // "yyyy-MM-dd", nil when the SMS carries no date
    let reference: String?
    var time: String? = nil   // "HH:mm", checked when given
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
        merchant: "V Northgate And Sons L", card: "XXXX4417",
        day: "2026-09-20", reference: "R77201"
    ),
    Expectation(
        label: "Deferred-payment alert 2",
        message: "Dear Alex Morgan!  Cardholder, Your card XXXX4417 was used at MEGA CENTER RIVERTON XYZ for AED  30.02 on deferred payment basis on 20-Sep ref R77315. As per the agreement we confirm our acceptance to sell to you at the agreed price. Available Balance on your card is AED XXXX.  Regards, Crescent Finance.",
        amount: Decimal(string: "30.02"), currency: "AED",
        merchant: "Mega Center Riverton Xyz", card: "XXXX4417",
        day: "2026-09-20", reference: "R77315"
    ),
    Expectation(
        label: "Approved txn with time",
        message: "A txn on your Card XXXX8802 at DIAMOND CABS CITYCENT for AED  17.00 on 20-Sep at 11:30  is approved. Your available balance is XXXX.95",
        amount: Decimal(string: "17.00"), currency: "AED",
        merchant: "Diamond Cabs Citycent", card: "XXXX8802",
        day: "2026-09-20", reference: nil
    ),
    Expectation(
        label: "Thank-you, no date",
        message: "Thank you for using Card ending 6150 at ROUND CLOCK MART SUPERMA for AED 2.25. Avl. limit is AED XXX.80.",
        amount: Decimal(string: "2.25"), currency: "AED",
        merchant: "Round Clock Mart Superma", card: "6150",
        day: nil, reference: nil
    ),
    Expectation(
        label: "Thank-you, no date 2",
        message: "Thank you for using Card ending 6150 at BEANERY PLAZA 20THFLOOR for AED 31.20. Avl. limit is AED XXX.05.",
        amount: Decimal(string: "31.20"), currency: "AED",
        merchant: "Beanery Plaza 20THFLOOR", card: "6150",
        day: nil, reference: nil
    ),
    Expectation(
        label: "Three-digit mask",
        message: "Purchase of AED 12.00 with Card XXX453 at QUICKSTOP MART on 22-Sep. Avl bal AED XXXX.10",
        amount: Decimal(string: "12.00"), currency: "AED",
        merchant: "Quickstop Mart", card: "XXX453",
        day: "2026-09-22", reference: nil
    ),
    Expectation(
        label: "Star mask",
        message: "Your card ****7731 was used at NORTH LANE PHARMACY for AED 64.50 on 21-Sep.",
        amount: Decimal(string: "64.50"), currency: "AED",
        merchant: "North Lane Pharmacy", card: "****7731",
        day: "2026-09-21", reference: nil
    ),
    Expectation(
        label: "US dollars, abroad",
        message: "Your card XXXX4417 was used at HARBOR BOOKS NYC for USD 42.10 on 18-Sep.",
        amount: Decimal(string: "42.10"), currency: "USD",
        merchant: "Harbor Books Nyc", card: "XXXX4417",
        day: "2026-09-18", reference: nil
    ),
    Expectation(
        label: "Yen, no decimals",
        message: "Thank you for using Card ending 6150 at SAKURA RAMEN for JPY 1,850. Avl. limit is AED XXX.05.",
        amount: Decimal(string: "1850"), currency: "JPY",
        merchant: "Sakura Ramen", card: "6150",
        day: nil, reference: nil
    ),
    Expectation(
        label: "Kuwaiti dinar, three decimals",
        message: "Your card XXXX1234 was used at SOUQ SHARQ for KWD 12.345 on 20-Sep.",
        amount: Decimal(string: "12.345"), currency: "KWD",
        merchant: "Souq Sharq", card: "XXXX1234",
        day: "2026-09-20", reference: nil
    ),
    Expectation(
        label: "Omani rial, trailing zero",
        message: "Your card XXXX1234 was used at MUTTRAH MART for OMR 3.500 on 19-Sep.",
        amount: Decimal(string: "3.5"), currency: "OMR",
        merchant: "Muttrah Mart", card: "XXXX1234",
        day: "2026-09-19", reference: nil
    ),
    Expectation(
        label: "European thousands and decimal comma",
        message: "Your card XXXX1234 was used at MARKTHALLE for EUR 1.234,56 on 18.09.2026.",
        amount: Decimal(string: "1234.56"), currency: "EUR",
        merchant: "Markthalle", card: "XXXX1234",
        day: "2026-09-18", reference: nil
    ),
    Expectation(
        label: "European decimal comma",
        message: "Your card XXXX1234 was used at KAFFEEHAUS for EUR 12,50 on 18.09.2026.",
        amount: Decimal(string: "12.50"), currency: "EUR",
        merchant: "Kaffeehaus", card: "XXXX1234",
        day: "2026-09-18", reference: nil
    ),
    Expectation(
        label: "US date, reads either way",
        message: "Your card XXXX1234 was used at CORNER DELI for USD 5.00 on 09/05/2026.",
        amount: Decimal(string: "5.00"), currency: "USD",
        merchant: "Corner Deli", card: "XXXX1234",
        day: "2026-09-05", reference: nil
    ),
    Expectation(
        label: "US date, month first only",
        message: "Your card XXXX1234 was used at CORNER DELI for USD 7.25 on 09/19/2026.",
        amount: Decimal(string: "7.25"), currency: "USD",
        merchant: "Corner Deli", card: "XXXX1234",
        day: "2026-09-19", reference: nil
    ),
    Expectation(
        label: "ISO date",
        message: "Your card XXXX1234 was used at HARBOUR CAFE for SGD 8.80 on 2026-09-17.",
        amount: Decimal(string: "8.80"), currency: "SGD",
        merchant: "Harbour Cafe", card: "XXXX1234",
        day: "2026-09-17", reference: nil
    ),
    Expectation(
        label: "Debit card linked to account, month-first date",
        message: "Debit Card XX5528 linked to account XX660213 was used for AED72.57 on Sep 27 2026 12:10PM at SHOPNOVAUFR DI, AE. Available Balance AED 4210.50",
        amount: Decimal(string: "72.57"), currency: "AED",
        merchant: "Shopnovaufr Di", card: "XX5528",
        day: "2026-09-27", reference: nil, time: "12:10"
    ),
    Expectation(
        label: "Month-first date with comma and ordinal",
        message: "Your card XXXX1234 was used at CORNER DELI for USD 9.00 on Sep 5th, 2026 at 9:05 AM.",
        amount: Decimal(string: "9.00"), currency: "USD",
        merchant: "Corner Deli", card: "XXXX1234",
        day: "2026-09-05", reference: nil, time: "09:05"
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

let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "HH:mm"
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
    check("card", parsed.card, testCase.card)
    check("date", parsed.date.map { dayFormatter.string(from: $0) }, testCase.day)
    check("ref", parsed.reference, testCase.reference)
    if let time = testCase.time {
        check("time", parsed.date.map { timeFormatter.string(from: $0) }, time)
    }
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

print("\nLEARNED MERCHANT FORMATS\n")

// The user picks the merchant's words in one message; the next message in
// the same format should give up its merchant from the same place.
let sample = "Debit Card XX5528 linked to account XX660213 was used for AED72.57 on Sep 27 2026 12:10PM at SHOPNOVAUFR DI, AE. Available Balance AED 4210.50"
let sameBank = "Debit Card XX9014 linked to account XX660213 was used for USD 1,204.00 on Oct 3 2026 9:02AM at CITYMART MOE DU, AE. Available Balance AED 3006.50"
let otherBank = "Your card XXXX4417 was used at NORTH LANE PHARMACY for AED 64.50 on 21-Sep."
let sampleWords = MerchantFormat.words(of: sample).map(\.text)
let first = sampleWords.firstIndex(of: "SHOPNOVAUFR")!

func checkFormat(_ label: String, picking picked: ClosedRange<Int>, sameBankGives expected: String) {
    print("  \(label)")
    check("picked", MerchantFormat.merchant(picking: picked, of: sample), picked.count == 1 ? "Shopnovaufr" : "Shopnovaufr Di")
    guard let pattern = MerchantFormat.pattern(from: sample, picking: picked) else {
        print("    ✗ no pattern learned\n")
        failures += 1
        return
    }
    check("sample", MerchantFormat.merchant(in: sample, pattern: pattern), MerchantFormat.merchant(picking: picked, of: sample))
    check("next", MerchantFormat.merchant(in: sameBank, pattern: pattern), expected)
    check("other", MerchantFormat.merchant(in: otherBank, pattern: pattern), nil)
    // Through the parser: the learned format wins, other formats are untouched.
    check("parse", SMSParser.parse(sameBank, receivedAt: referenceDate, formats: [pattern])?.merchant, expected)
    check("parse 2", SMSParser.parse(otherBank, receivedAt: referenceDate, formats: [pattern])?.merchant, "North Lane Pharmacy")
    print("")
}

checkFormat("Whole descriptor picked", picking: first...(first + 1), sameBankGives: "Citymart Moe Du")
checkFormat("Name only, city left out", picking: first...first, sameBankGives: "Citymart Moe")

print("  Merchant mid-sentence, followed by a plain word")
let midSentence = "Purchase of AED 12.00 with Card XXX453 at QUICKSTOP MART on 22-Sep. Avl bal AED XXXX.10"
let midWords = MerchantFormat.words(of: midSentence).map(\.text)
let quickstop = midWords.firstIndex(of: "QUICKSTOP")!
let midPattern = MerchantFormat.pattern(from: midSentence, picking: quickstop...(quickstop + 1))
check("next", midPattern.flatMap {
    MerchantFormat.merchant(in: "Purchase of AED 7.50 with Card XXX453 at BLUE DOOR CAFE on 23-Sep. Avl bal AED XXXX.60", pattern: $0)
}, "Blue Door Cafe")
print("")

print("SENTENCE FRAGMENTS AREN'T MERCHANTS\n")
for (text, plausible) in [
    ("account XX660213 was used", false), ("Card ending 6150", false),
    ("amount debited", false), ("Used Books Corner", true), ("Mega Center Riverton Xyz", true),
] {
    check(text, SMSParser.isPlausibleMerchant(text), plausible, indent: "  ")
}

print("")
if failures == 0 {
    print("All checks passed.\n")
} else {
    print("\(failures) check(s) failed.\n")
    exit(1)
}
