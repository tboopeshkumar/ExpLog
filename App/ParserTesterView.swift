import SwiftUI

/// Paste an SMS and see what the parser makes of it. Built in on purpose: new
/// message formats turn up constantly, and this turns "it didn't work" into a
/// precise report of which field failed.
struct ParserTesterView: View {
    @State private var text = ""

    private var parsed: ParsedTransaction? {
        text.isEmpty ? nil : SMSParser.parse(text)
    }

    var body: some View {
        Form {
            Section("Message") {
                TextField("Paste a bank SMS", text: $text, axis: .vertical)
                    .lineLimit(4...12)
                    .font(.footnote)
            }

            if text.isEmpty {
                Section {
                    Text("Paste a message to see the fields ExpLog can read from it.")
                        .foregroundStyle(.secondary)
                }
            } else if let parsed {
                Section("Read") {
                    row("Amount", parsed.amount.map { "\($0)" })
                    row("Currency", parsed.currency)
                    row("Merchant", parsed.merchant)
                    row("Card", parsed.cardLast4.map { "••\($0)" })
                    row("Date", parsed.date?.formatted(.dateTime.day().month().year()))
                    row("Reference", parsed.reference)
                    row("Direction", parsed.kind.rawValue.capitalized)
                }
                if !parsed.missingFields.isEmpty {
                    Section {
                        Label(
                            "Not found: \(parsed.missingFields.joined(separator: ", "))",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            } else {
                Section {
                    Label(
                        "Not recognised as a transaction. Either no amount was found, or it looks like an OTP or a declined payment.",
                        systemImage: "xmark.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Test parsing")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "—")
                .foregroundStyle(value == nil ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
        }
    }
}
