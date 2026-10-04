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
                        let context = ModelContext(container)
                        SeedData.seedIfNeeded(context)
                        AccountMatching.foldLegacyDigits(in: context)
                        LearnedParsing.forgetImplausibleAliases(in: context)
                        Currency.adoptMainIfUnset(from: context)
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
    /// Reopens on the tab you last used.
    @AppStorage("selectedTab") private var selectedTab: AppTab = .expenses
    /// The month on screen in both Expenses and Summary. Not remembered:
    /// the app opens on this month.
    @State private var month = Formatting.monthStart(.now)
    /// An expense the Shortcuts action opened the app to review.
    @State private var review = MessageReview.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Expenses", systemImage: "list.bullet", value: .expenses) {
                NavigationStack { TransactionListView(month: $month) }
            }
            Tab("Summary", systemImage: "chart.bar", value: .summary) {
                NavigationStack { SummaryView(month: $month) }
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack { SettingsView() }
            }
        }
        // Picks up anything the share extension left in SharedInbox — the
        // route taken when there's no App Group. Runs on every return to the
        // foreground, since that's when a newly shared message is waiting.
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Leaving the foreground: hand the share sheet the current
            // categories, cards and learned merchants. Only needed when it
            // can't read the database itself.
            if phase != .active, !SharedStore.isAppGroupAvailable {
                ExtensionSnapshot(context: context).store()
            }
            guard phase == .active else { return }
            let added = SharedInbox.importPending(into: context)
            if !added.isEmpty { imported = added }
        }
        .sheet(item: $review.draft) { draft in
            NavigationStack {
                TransactionFormView(draft: draft, onSave: { review.draft = nil }, onCancel: { review.draft = nil })
                    .navigationTitle("From Messages")
                    .navigationBarTitleDisplayMode(.inline)
            }
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

enum AppTab: String {
    case expenses, summary, settings
}
