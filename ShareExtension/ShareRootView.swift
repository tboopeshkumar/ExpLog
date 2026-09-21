import SwiftUI
import SwiftData

/// What you see after tapping Share → ExpLog on a bank SMS: the parsed
/// transaction, pre-filled and editable.
///
/// Two ways of saving, depending on the Apple account:
///
/// - **App Group available** (paid Developer Program): writes straight into the
///   shared database and dismisses. The app never launches.
/// - **No App Group** (free Apple ID): drops it in SharedInbox and dismisses.
///   The app saves it the next time it opens.
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

    private var canSaveDirectly: Bool { SharedStore.isAppGroupAvailable }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    TransactionFormView(
                        draft: draft,
                        showsCategoryAndAccount: canSaveDirectly,
                        saveAction: canSaveDirectly ? nil : SharedInbox.add,
                        onSave: { saved = true },
                        onCancel: onCancel
                    )
                } else {
                    unreadableView
                }
            }
            .navigationTitle(saved ? "Saved" : "Log expense")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { prepare() }
        .alert("Already logged", isPresented: .constant(duplicate != nil)) {
            Button("Save anyway") { duplicate = nil }
            Button("Cancel", role: .cancel) { onCancel() }
        } message: {
            Text("A transaction with the same reference is already saved.")
        }
        .onChange(of: saved) { _, isSaved in
            // Brief confirmation, then dismiss back to Messages.
            guard isSaved else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                onFinish()
            }
        }
    }

    // MARK: - States

    private var unreadableView: some View {
        ContentUnavailableView {
            Label("Couldn't read that message", systemImage: "text.badge.xmark")
        } description: {
            Text("No transaction amount was found. You can still log it by hand in ExpLog.")
        } actions: {
            Button("Enter manually") {
                let manual = TransactionDraft()
                manual.rawMessage = sharedText
                draft = manual
            }
            Button("Cancel", role: .cancel, action: onCancel)
        }
    }

    // MARK: - Actions

    private func prepare() {
        guard draft == nil else { return }
        guard let parsed = SMSParser.parse(sharedText) else { return }

        let newDraft = TransactionDraft(parsed: parsed, context: context)
        draft = newDraft
        // Only meaningful when the extension can see the real database.
        if canSaveDirectly {
            duplicate = TransactionDraft.duplicate(of: newDraft, in: context)
        }
    }
}
