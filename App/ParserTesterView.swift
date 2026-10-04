import SwiftUI
import SwiftData

/// Paste an SMS and see what ExpLog makes of it: how it would be logged,
/// which fields were read, and what it was matched to. Built in on purpose:
/// new message formats turn up constantly, and this turns "it didn't work"
/// into a precise report of which field failed. The result can be logged
/// from here too.
struct ParserTesterView: View {
    @Environment(\.modelContext) private var context
    @State private var text = ""
    @State private var logging: TransactionDraft?
    @FocusState private var editing: Bool

    private var message: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A made-up alert in the main currency, dated today, to show what the
    /// page does without a real message to hand.
    static var example: String {
        // "4-Oct", as bank alerts write it.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM"
        let day = formatter.string(from: .now)
        return "Your card XXXX4417 was used at CORNER DELI for \(Currency.main) 42.10 on \(day). Avl limit \(Currency.main) XXXX.80"
    }

    var body: some View {
        Form {
            Section {
                TextField("Paste a bank SMS", text: $text, axis: .vertical)
                    .lineLimit(3...10)
                    .font(.footnote)
                    .focused($editing)
                    .accessibilityIdentifier("testMessage")
                HStack(spacing: 10) {
                    PasteButton(payloadType: String.self) { strings in
                        text = strings.first ?? ""
                        editing = false
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    Button("Example") {
                        text = Self.example
                        editing = false
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    Spacer()
                    if !text.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            } footer: {
                if message.isEmpty {
                    Text("See what ExpLog reads from a bank message, and what it matches it to.")
                }
            }

            if !message.isEmpty {
                if let parsed = LearnedParsing.parse(message, in: context) {
                    result(parsed)
                } else {
                    rejected(SMSParser.rejection(of: message))
                }
            }
        }
        .navigationTitle("Test a Message")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.immediately)
        .sheet(item: $logging) { draft in
            NavigationStack {
                TransactionFormView(
                    draft: draft,
                    onSave: { logging = nil; text = "" },
                    onCancel: { logging = nil }
                )
                .navigationTitle("New Expense")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - Read

    @ViewBuilder
    private func result(_ parsed: ParsedTransaction) -> some View {
        // What the form would open with: remembered name, category and card.
        let draft = TransactionDraft(parsed: parsed, context: context)
        let alias = parsed.merchant.flatMap { TransactionDraft.alias(for: $0, in: context) }
        let usedFormat = parsed.merchant != SMSParser.parse(message)?.merchant

        Section("Would be logged as") {
            preview(draft, hasDate: parsed.date != nil)
        }

        Section {
            field("Amount", parsed.amount.map { Formatting.money($0, code: parsed.currency ?? Currency.main) })
            field("Merchant", parsed.merchant)
            field("Card", parsed.card)
            field("Date", parsed.date.map(Self.dateText), missing: "Not found; today is used")
            // Optional: most alerts have none, so its absence isn't flagged.
            if let reference = parsed.reference {
                field("Reference", reference)
            }
        } header: {
            Text("Read from the message")
        } footer: {
            if usedFormat {
                Text("The merchant was read with a format you taught (Settings → Message formats).")
            }
        }

        Section("Matched to") {
            if let account = draft.account {
                match("creditcard.fill", .blue, account.name, "Card, by its SMS keyword")
            } else if let card = parsed.card {
                match("creditcard", .orange, "No card has “\(card)”", "Add it as a keyword in Cards & accounts")
            } else {
                match("creditcard", .secondary, "No card", "The message doesn't name one")
            }
            if let alias {
                let place = [alias.category?.name, alias.subcategory?.name].compactMap { $0 }.joined(separator: " › ")
                match("storefront.fill", .pink, MerchantsView.name(of: alias),
                      place.isEmpty ? "Remembered merchant" : "Remembered as \(place)")
            } else if parsed.merchant != nil {
                match("storefront", .secondary, "Merchant not remembered yet", "Categorise it once and it will be")
            }
        }

        Section {
            Button("Log This Expense") { logging = draft }
                .accessibilityIdentifier("logThis")
        }
    }

    /// The expense as a row of the list would show it.
    private func preview(_ draft: TransactionDraft, hasDate: Bool) -> some View {
        HStack(spacing: 12) {
            CategoryIcon(draft.category)
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.merchant.isEmpty ? "No merchant" : draft.merchant)
                    .font(.body.weight(.medium))
                    .foregroundStyle(draft.merchant.isEmpty ? Color.orange : Color.primary)
                    .lineLimit(1)
                Text(Self.details(of: draft))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Formatting.moneyText(draft.amount, code: draft.currencyCode)
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("preview")
    }

    /// "4 Oct · Dining · Crescent Credit"
    private static func details(of draft: TransactionDraft) -> String {
        var parts = [draft.date.formatted(.dateTime.day().month(.abbreviated))]
        if let category = draft.category {
            parts.append(draft.subcategory?.name ?? category.name)
        } else {
            parts.append("Uncategorised")
        }
        if let account = draft.account { parts.append(account.name) }
        return parts.joined(separator: " · ")
    }

    /// The day, with the time when the message gave one.
    private static func dateText(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hasTime = (parts.hour ?? 0) != 0 || (parts.minute ?? 0) != 0
        return hasTime
            ? date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// A field with whether it was found: a tick and the value, or a flag.
    private func field(_ label: String, _ value: String?, missing: String = "Not found") -> some View {
        HStack(spacing: 10) {
            Image(systemName: value == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(value == nil ? Color.orange : Color.green)
                .accessibilityLabel(value == nil ? "Missing" : "Read")
            Text(label)
            Spacer(minLength: 12)
            Text(value ?? missing)
                .foregroundStyle(value == nil ? Color.orange : Color.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func match(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Not read

    private func rejected(_ reason: SMSParser.Rejection?) -> some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: reason == .notAPayment ? "hand.raised.circle.fill" : "questionmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(reason == .notAPayment ? "Not a card payment" : "No amount found")
                    .font(.headline)
                Text(reason == .notAPayment
                     ? "This reads as an OTP, a declined or scheduled payment, or a statement notice, so it isn't logged."
                     : "ExpLog looks for a currency and a number, like \(Currency.main) 42.10. Without one there's nothing to log.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("rejected")
        }
    }
}
