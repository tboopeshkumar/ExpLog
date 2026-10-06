import SwiftUI
import SwiftData

/// How to have bank alerts logged as they arrive: the steps for a Messages
/// automation that runs Log Expense from Message, a phrase to match taken
/// from the user's own alerts, and the one setting that goes with it.
struct ShortcutSetupView: View {
    @Query(filter: #Predicate<Transaction> { $0.rawMessage != nil }) private var fromMessages: [Transaction]
    @AppStorage(MessageLogging.reviewKey) private var reviewMessageExpenses = false
    @State private var copied: String?

    /// Checked against Shortcuts on iOS 27. Bold marks what to tap.
    private let steps: [(title: String, detail: LocalizedStringKey)] = [
        ("Start an automation", "In Shortcuts, open **Library → Automation** and tap **+**, then **Edit** to skip Describe a Shortcut."),
        ("Choose the trigger", "In the search sheet, tap **Automation**, then **Message**."),
        ("Match your bank's alerts", "Tap **Sender** and change it to **Message**. Tap **Text** and enter a phrase all its payment alerts use."),
        ("Add ExpLog's action", "Search for **ExpLog** and add **Log Expense from Message**."),
        ("Give it the message", "Tap the action's **Message** field → **Select Variable** → the trigger's **Message**."),
        ("Let it run by itself", "Tap **⌄** beside “where” and check **Confirm Before Run** is off. Tap **‹** to save."),
    ]

    /// Wording card alerts commonly use, to look for in the user's own.
    static let commonPhrases = [
        "was used for", "was used at", "Thank you for using", "A txn on your Card",
        "Purchase of", "has been debited", "was debited", "was spent", "spent on",
    ]

    /// The phrases found in logged messages, most frequent first, with how
    /// many messages each is in; a few usual ones when there are none yet.
    static func phrases(in messages: [String]) -> [(phrase: String, count: Int)] {
        let found = commonPhrases
            .map { phrase in (phrase: phrase, count: messages.filter { $0.localizedCaseInsensitiveContains(phrase) }.count) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
        return found.isEmpty ? commonPhrases.prefix(3).map { ($0, 0) } : Array(found.prefix(3))
    }

    var body: some View {
        let phrases = Self.phrases(in: fromMessages.compactMap(\.rawMessage))
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.indigo.gradient, in: .rect(cornerRadius: 14))
                        .accessibilityHidden(true)
                    Text("Log alerts as they arrive")
                        .font(.title3.weight(.semibold))
                    Text("A Shortcuts automation hands each bank message to ExpLog, which logs it with its card and category. Nothing to tap.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.bold())
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.tint, in: .circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .font(.body.weight(.medium))
                            Text(step.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("step-\(index + 1)")
                }
            } header: {
                Text("Set up, once per bank")
            } footer: {
                Text("The automation then shows under Personal, switched on.")
            }

            Section {
                ForEach(phrases, id: \.phrase) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(item.phrase)”")
                                .font(.body.weight(.medium))
                            if item.count > 0 {
                                Text(item.count == 1 ? "In 1 of your messages" : "In \(item.count) of your messages")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = item.phrase
                            copied = item.phrase
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied == item.phrase ? "checkmark" : "doc.on.doc")
                                Text(copied == item.phrase ? "Copied" : "Copy")
                            }
                            .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .accessibilityIdentifier("copyPhrase")
                    }
                }
            } header: {
                Text("Phrases for step 3")
            } footer: {
                Text(phrases.first?.count ?? 0 > 0
                     ? "Found in the alerts you've logged. Pick one that all of a bank's payment alerts share."
                     : "Common wording. Check one of your bank's alerts and use a phrase they all share.")
            }

            Section {
                Toggle("Review before saving", isOn: $reviewMessageExpenses)
            } footer: {
                Text(reviewMessageExpenses
                     ? "ExpLog opens so you can check each alert before saving."
                     : "Alerts are saved straight away.")
            }

            Section("Good to know") {
                note("checkmark.shield", "OTPs, declined payments, money received and alerts already logged are skipped.")
                note("tag", "A merchant you've categorised once arrives categorised.")
                note("building.columns", "Make one automation per bank if their wording differs.")
            }

            Section {
                Link(destination: URL(string: "shortcuts://")!) {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Automatic logging")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
    }
}
