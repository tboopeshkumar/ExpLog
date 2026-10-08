import SwiftUI
import SwiftData
import Observation

/// Expenses deleted in the last few seconds, kept so the delete can be
/// undone. Every delete in the app goes through here.
@MainActor
@Observable
final class RecentlyDeleted {
    static let shared = RecentlyDeleted()

    /// How long Undo stays on offer.
    static let window: Duration = .seconds(6)

    private(set) var pending: [ExpenseSnapshot] = []
    private var expiry: Task<Void, Never>?

    var message: String {
        guard pending.count == 1, let only = pending.first else { return "Deleted \(pending.count) expenses" }
        return only.merchant.isEmpty ? "Deleted 1 expense" : "Deleted “\(only.merchant)”"
    }

    func delete(_ expense: Transaction, in context: ModelContext) {
        pending.append(ExpenseSnapshot(expense))
        context.delete(expense)
        try? context.save()
        // Each delete restarts the clock; Undo brings back all of them.
        expiry?.cancel()
        expiry = Task {
            try? await Task.sleep(for: Self.window)
            if !Task.isCancelled { pending = [] }
        }
    }

    func undo(in context: ModelContext) {
        expiry?.cancel()
        for snapshot in pending { snapshot.restore(in: context) }
        pending = []
    }
}

/// "Deleted “Aman Taxi” · Undo", floating above the tab bar for a few seconds.
struct UndoDeleteBar: View {
    @Environment(\.modelContext) private var context
    @State private var deleted = RecentlyDeleted.shared

    var body: some View {
        if !deleted.pending.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                Text(deleted.message)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Undo") {
                    withAnimation { deleted.undo(in: context) }
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("undoDelete")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: .capsule)
            .overlay { Capsule().strokeBorder(.quaternary) }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
