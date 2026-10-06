import AppIntents
import SwiftData
import SwiftUI

/// "Log Expense from Message", for a Shortcuts Messages automation: gets the
/// SMS text and logs it without opening the app — or, with Settings →
/// Shortcuts → Review before saving on, opens the filled-in form instead.
struct LogExpenseFromMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Expense from Message"
    static let description = IntentDescription(
        "Reads a bank card alert and logs it as an expense, matching the card and category the way sharing the message would. Messages that aren't spending, such as OTPs, declined payments and money received, are skipped."
    )

    /// Saves in the background; opens the app only to review.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Message", description: "The SMS text. In a Messages automation, choose Shortcut Input.")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log expense from \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let container = try SharedStore.shared.get()
        // The app's own context, so an open expense list updates at once.
        let context = container.mainContext

        switch MessageLogging.prepare(message, in: context) {
        case .notAnExpense:
            let received = SMSParser.rejection(of: message) == .moneyReceived
            return .result(value: "", dialog: received
                           ? "Money received, not spending, so nothing was logged."
                           : "Not a card payment, so nothing was logged.")

        case .duplicate(let existing):
            let summary = MessageLogging.summary(of: existing)
            return .result(value: summary, dialog: "Already logged: \(summary)")

        case .ready(let draft):
            if UserDefaults.standard.bool(forKey: MessageLogging.reviewKey) {
                try await continueInForeground(alwaysConfirm: false)
                MessageReview.shared.draft = draft
                return .result(value: MessageLogging.summary(of: draft), dialog: "Opened in ExpLog to review.")
            }
            let saved = try draft.save(in: context)
            let summary = MessageLogging.summary(of: saved)
            return .result(value: summary, dialog: "Logged \(summary)")
        }
    }
}

/// A message the Shortcuts action opened the app to review. RootView shows it
/// in the form.
@MainActor
@Observable
final class MessageReview {
    static let shared = MessageReview()
    var draft: TransactionDraft?
}
