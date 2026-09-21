import SwiftUI
import SwiftData

@main
struct ExpLogApp: App {
    var body: some Scene {
        WindowGroup {
            switch SharedStore.shared {
            case .success(let container):
                RootView()
                    .modelContainer(container)
                    .task {
                        SeedData.seedIfNeeded(ModelContext(container))
                    }
            case .failure(let error):
                ContentUnavailableView {
                    Label("Storage unavailable", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text(error.localizedDescription)
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var received: ReceivedTransaction?

    var body: some View {
        TabView {
            Tab("Expenses", systemImage: "list.bullet") {
                NavigationStack { TransactionListView() }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        .onOpenURL(perform: receive)
        .alert(received?.title ?? "", isPresented: .constant(received != nil)) {
            Button("OK") { received = nil }
        } message: {
            Text(received?.message ?? "")
        }
    }

    /// Handles `explog://add?...` from the share extension — the path taken when
    /// there's no App Group, so the extension can't write to the database
    /// itself. See TransactionLink.
    private func receive(_ url: URL) {
        guard let draft = TransactionLink.draft(from: url, context: context) else { return }

        if TransactionDraft.duplicate(of: draft, in: context) != nil {
            received = ReceivedTransaction(
                title: "Already logged",
                message: "\(draft.merchant) for \(Formatting.money(draft.amount, code: draft.currencyCode)) is already in your expenses."
            )
            return
        }

        do {
            try draft.save(in: context)
            received = ReceivedTransaction(
                title: "Added",
                message: "\(draft.merchant) — \(Formatting.money(draft.amount, code: draft.currencyCode))"
            )
        } catch {
            received = ReceivedTransaction(title: "Couldn't save", message: error.localizedDescription)
        }
    }
}

struct ReceivedTransaction {
    let title: String
    let message: String
}
