import SwiftUI
import SwiftData

/// What you see after tapping Share → ExpMgr on a bank SMS: the parsed
/// transaction, pre-filled and editable.
///
/// Two ways of saving, depending on the Apple account:
///
/// - **App Group available** (paid Developer Program): writes straight into the
///   shared database and dismisses. The app never launches.
/// - **No App Group** (free Apple ID): opens `expmgr://add?...` and the app
///   saves it. One extra app switch, no retyping either way.
struct ShareRootView: View {
    let sharedText: String
    /// Opens a URL through the extension context. Returns false when iOS
    /// refuses, which is the one failure mode worth showing the user.
    let openHost: (URL, @escaping (Bool) -> Void) -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var context

    @State private var draft: TransactionDraft?
    @State private var duplicate: Transaction?
    @State private var saved = false
    @State private var handoffFailed = false

    private var canSaveDirectly: Bool { SharedStore.isAppGroupAvailable }

    var body: some View {
        NavigationStack {
            Group {
                if handoffFailed {
                    handoffFailedView
                } else if let draft {
                    TransactionFormView(
                        draft: draft,
                        showsCategoryAndAccount: canSaveDirectly,
                        saveAction: canSaveDirectly ? nil : handOffToApp,
                        onSave: { if canSaveDirectly { saved = true } },
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
            Text("No transaction amount was found. You can still log it by hand in ExpMgr.")
        } actions: {
            Button("Enter manually") {
                let manual = TransactionDraft()
                manual.rawMessage = sharedText
                draft = manual
            }
            Button("Cancel", role: .cancel, action: onCancel)
        }
    }

    private var handoffFailedView: some View {
        ContentUnavailableView {
            Label("Couldn't open ExpMgr", systemImage: "arrow.up.forward.app")
        } description: {
            Text("iOS wouldn't switch to ExpMgr from here. Open ExpMgr and add this one by hand — the message is still in Messages.")
        } actions: {
            Button("Close", action: onCancel)
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

    /// No shared database: encode the transaction and let the app save it.
    private func handOffToApp(_ draft: TransactionDraft) throws {
        guard let url = TransactionLink.url(for: draft) else {
            throw HandoffError.couldNotBuildURL
        }
        openHost(url) { success in
            Task { @MainActor in
                if success {
                    onFinish()
                } else {
                    handoffFailed = true
                }
            }
        }
    }

    private enum HandoffError: LocalizedError {
        case couldNotBuildURL

        var errorDescription: String? {
            "Couldn't prepare this transaction to send to ExpMgr."
        }
    }
}
