import SwiftUI
import SwiftData

/// What you see after tapping Share → ExpLog on a bank SMS: the parsed
/// transaction, pre-filled and editable.
///
/// Two ways of saving, depending on the Apple account:
///
/// - **App Group available** (paid Developer Program): writes straight into the
///   shared database and dismisses. The app never launches.
/// - **No App Group** (free Apple ID): works from the snapshot of categories,
///   cards and learned merchants the app left (ExtensionSnapshot), drops the
///   expense in SharedInbox and dismisses. The app saves it the next time it
///   opens.
///
/// You stay in Messages either way.
struct ShareRootView: View {
    let sharedText: String
    let onFinish: () -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var context

    @State private var draft: TransactionDraft?
    @State private var duplicate: Transaction?
    @State private var saved = false
    /// The app's categories and cards are loaded into this sheet's store.
    @State private var hasSnapshot = false
    @State private var prepared = false

    private var canSaveDirectly: Bool { SharedStore.isAppGroupAvailable }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    TransactionFormView(
                        draft: draft,
                        showsCategoryAndAccount: canSaveDirectly || hasSnapshot,
                        canAddCard: canSaveDirectly,
                        saveAction: canSaveDirectly ? nil : SharedInbox.add,
                        onSave: { saved = true },
                        onCancel: onCancel
                    )
                } else if prepared {
                    unreadableView
                }
            }
            .navigationTitle("Log Expense")
            .navigationBarTitleDisplayMode(.inline)
        }
        .overlay {
            if saved { savedView }
        }
        .animation(.snappy, value: saved)
        .task { prepare() }
        .alert("Already logged", isPresented: .constant(duplicate != nil)) {
            Button("Save anyway") { duplicate = nil }
            Button("Cancel", role: .cancel) { onCancel() }
        } message: {
            Text("A transaction with the same reference is already saved.")
        }
        .onChange(of: saved) { _, isSaved in
            // Long enough to read the confirmation, then back to Messages.
            guard isSaved else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                onFinish()
            }
        }
    }

    // MARK: - States

    /// A tick over the form, so there's no doubt it went through.
    private var savedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Saved")
                .font(.title3.weight(.semibold))
            Text(canSaveDirectly ? "Added to ExpLog." : "ExpLog adds it when it next opens.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.15))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private var unreadableView: some View {
        let reason = SMSParser.rejection(of: sharedText)
        let symbol: String, title: String, detail: String
        if sharedText.isEmpty {
            symbol = "text.badge.xmark"
            title = "Nothing to read"
            detail = "ExpLog wasn't given any text. Share a bank message's text."
        } else {
            switch reason {
            case .notAPayment:
                symbol = "hand.raised"
                title = "Not a card payment"
                detail = "This reads as an OTP, a declined or scheduled payment, or a statement notice. You can still log it by hand."
            case .moneyReceived:
                symbol = "arrow.down.circle"
                title = "Money received"
                detail = "This reads as money coming in: a salary, refund, transfer or deposit. ExpLog logs spending only. You can still log it by hand."
            default:
                symbol = "text.badge.xmark"
                title = "No amount found"
                detail = "ExpLog looks for a currency and a number, like \(Currency.main) 42.10. You can still log it by hand."
            }
        }
        return ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            Button("Enter Manually") {
                let manual = TransactionDraft()
                manual.rawMessage = sharedText.isEmpty ? nil : sharedText
                manual.resolvedInExtension = hasSnapshot
                draft = manual
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel", role: .cancel, action: onCancel)
        }
    }

    // MARK: - Actions

    private func prepare() {
        guard draft == nil, !prepared else { return }
        defer { prepared = true }

        // No shared database: take on what the app last left for this sheet,
        // so the message is read and matched as the app would.
        if !canSaveDirectly, let snapshot = ExtensionSnapshot.load() {
            snapshot.apply(to: context)
            hasSnapshot = true
        }

        guard let parsed = LearnedParsing.parse(sharedText, in: context) else { return }

        let newDraft = TransactionDraft(parsed: parsed, context: context)
        newDraft.resolvedInExtension = hasSnapshot
        draft = newDraft
        // Only meaningful when the extension can see the real database.
        if canSaveDirectly {
            duplicate = TransactionDraft.duplicate(of: newDraft, in: context)
        }
    }
}
