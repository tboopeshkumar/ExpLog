import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings → Backup: pick a folder for the automatic backup, see when it
/// last ran, and restore from a backup file.
struct BackupView: View {
    @Environment(\.modelContext) private var context
    @State private var store = BackupStore.shared

    /// What the file picker is open for: one picker serves both.
    private enum Picking { case folder, file }
    @State private var picking: Picking?
    /// A backup read from a file, waiting for the restore to be confirmed.
    @State private var pending: Backup?
    @State private var message: (title: String, text: String)?

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: store.isOn ? "checkmark.icloud.fill" : "icloud.slash")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background((store.isOn ? Color.green : Color.gray).gradient, in: .rect(cornerRadius: 14))
                        .accessibilityHidden(true)
                    Text(store.isOn ? "Backup is on" : "Backup is off")
                        .font(.title3.weight(.semibold))
                    Text(store.isOn
                         ? "ExpLog keeps an up-to-date copy of everything in the folder below, rewritten when you leave the app after a change."
                         : "Your expenses are only on this iPhone. Pick a folder in iCloud Drive or another cloud app, and ExpLog keeps a copy of everything there.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if store.isOn {
                Section {
                    LabeledContent("Folder", value: store.folderName ?? "")
                    LabeledContent("Last backup") {
                        if let last = store.lastBackup {
                            Text("\(last.formatted(.relative(presentation: .named))) · \(store.lastCount == 1 ? "1 expense" : "\(store.lastCount) expenses")")
                        } else {
                            Text("Not yet")
                        }
                    }
                    .accessibilityIdentifier("lastBackup")
                    if let error = store.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("The file is “\(BackupStore.fileName)”. The backup before it is kept beside it.")
                }

                Section {
                    Button("Back Up Now") {
                        if store.backUpNow(from: context) {
                            message = ("Backed up", "\(store.lastCount == 1 ? "1 expense" : "\(store.lastCount) expenses") saved to \(store.folderName ?? "the folder").")
                        }
                    }
                    Button("Change Folder…") { picking = .folder }
                    Button("Turn Off Backup", role: .destructive) { store.turnOff() }
                }
            } else {
                Section {
                    Button("Choose a Folder…") { picking = .folder }
                        .fontWeight(.semibold)
                    if let error = store.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Button("Restore from a Backup…") { picking = .file }
            } footer: {
                Text("Adds what's in the backup and missing here: expenses, categories, cards, remembered merchants. Nothing here is removed or replaced.")
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
            allowedContentTypes: picking == .file ? [.json] : [.folder]
        ) { result in
            let purpose = picking
            picking = nil
            guard case .success(let url) = result else { return }
            if purpose == .folder {
                store.choose(url, context: context)
            } else {
                do {
                    pending = try BackupStore.read(url)
                } catch {
                    message = ("Couldn't read that file", error.localizedDescription)
                }
            }
        }
        .alert(
            "Restore this backup?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { backup in
            Button("Restore") { restore(backup) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { backup in
            Text("Made \(backup.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())), with \(backup.expenses.count == 1 ? "1 expense" : "\(backup.expenses.count) expenses"). What's missing here is added; nothing is removed.")
        }
        .alert(
            message?.title ?? "",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("OK") { message = nil }
        } message: {
            Text(message?.text ?? "")
        }
    }

    private func restore(_ backup: Backup) {
        pending = nil
        do {
            let report = try backup.restore(into: context)
            var lines = [report.expenses == 1 ? "1 expense added." : "\(report.expenses) expenses added."]
            if report.alreadyHere > 0 {
                lines.append("\(report.alreadyHere) already here.")
            }
            let extras = [
                (report.categories, "category", "categories"), (report.cards, "card", "cards"),
                (report.merchants, "remembered merchant", "remembered merchants"),
                (report.formats, "message format", "message formats"),
            ].filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
            if !extras.isEmpty { lines.append("Also added: \(extras.joined(separator: ", ")).") }
            message = ("Restored", lines.joined(separator: " "))
        } catch {
            message = ("Restore failed", error.localizedDescription)
        }
    }
}
