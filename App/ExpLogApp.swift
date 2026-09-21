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
    @Environment(\.scenePhase) private var scenePhase
    @State private var imported: [Transaction] = []

    var body: some View {
        TabView {
            Tab("Expenses", systemImage: "list.bullet") {
                NavigationStack { TransactionListView() }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        // Picks up anything the share extension left in SharedInbox — the
        // route taken when there's no App Group. Runs on every return to the
        // foreground, since that's when a newly shared message is waiting.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            let added = SharedInbox.importPending(into: context)
            if !added.isEmpty { imported = added }
        }
        .alert(importTitle, isPresented: .constant(!imported.isEmpty)) {
            Button("OK") { imported = [] }
        } message: {
            Text(importMessage)
        }
    }

    private var importTitle: String {
        imported.count == 1 ? "Added from Messages" : "Added \(imported.count) from Messages"
    }

    private var importMessage: String {
        imported
            .map { "\($0.merchant) — \(Formatting.money($0.amount, code: $0.currencyCode))" }
            .joined(separator: "\n")
    }
}
