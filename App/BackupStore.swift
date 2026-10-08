import Foundation
import SwiftData
import Observation

/// Automatic backup to a folder the user picks in Files — iCloud Drive,
/// Google Drive, On My iPhone. Keeps one up-to-date file there, and the one
/// before it, rewritten when the app leaves the foreground after something
/// changed. Works without iCloud entitlements, so on a free Apple ID too.
@MainActor
@Observable
final class BackupStore {
    static let shared = BackupStore()

    static let fileName = "ExpLog Backup.json"
    /// The backup before the latest, in case a write went wrong.
    static let previousName = "ExpLog Backup (previous).json"

    private enum Key {
        static let bookmark = "backupFolderBookmark"
        static let folderName = "backupFolderName"
        static let lastBackup = "backupLastDate"
        static let lastCount = "backupLastCount"
        static let dirty = "backupNeeded"
    }

    private let defaults = UserDefaults.standard
    private(set) var folderName: String?
    private(set) var lastBackup: Date?
    private(set) var lastCount = 0
    /// Why the last attempt failed, if it did.
    private(set) var lastError: String?

    var isOn: Bool { folderName != nil }

    private init() {
        folderName = defaults.data(forKey: Key.bookmark) == nil ? nil : defaults.string(forKey: Key.folderName)
        lastBackup = defaults.object(forKey: Key.lastBackup) as? Date
        lastCount = defaults.integer(forKey: Key.lastCount)
        // Anything saved anywhere in the app means the backup is behind.
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            UserDefaults.standard.set(true, forKey: Key.dirty)
        }
    }

    // MARK: - Folder

    /// Starts backing up to `folder`, and writes the first backup now.
    func choose(_ folder: URL, context: ModelContext) {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? folder.bookmarkData() else {
            lastError = "ExpLog couldn't keep access to that folder. Try another."
            return
        }
        defaults.set(bookmark, forKey: Key.bookmark)
        defaults.set(folder.lastPathComponent, forKey: Key.folderName)
        folderName = folder.lastPathComponent
        backUpNow(from: context)
    }

    /// Stops backing up. The files already written stay where they are.
    func turnOff() {
        for key in [Key.bookmark, Key.folderName, Key.lastBackup, Key.lastCount] {
            defaults.removeObject(forKey: key)
        }
        folderName = nil
        lastBackup = nil
        lastCount = 0
        lastError = nil
    }

    private func resolveFolder() -> URL? {
        guard let bookmark = defaults.data(forKey: Key.bookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            if let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: Key.bookmark) }
            url.stopAccessingSecurityScopedResource()
        }
        return url
    }

    // MARK: - Write

    /// Backs up if a folder is set and something has changed since the last one.
    func backUpIfNeeded(from context: ModelContext) {
        guard isOn, defaults.bool(forKey: Key.dirty) || lastBackup == nil else { return }
        backUpNow(from: context)
    }

    @discardableResult
    func backUpNow(from context: ModelContext) -> Bool {
        guard let folder = resolveFolder() else {
            lastError = "The backup folder can't be found. Choose it again."
            return false
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let backup = Backup(context: context)
        do {
            let data = try backup.encoded()
            let file = folder.appending(path: Self.fileName)
            let previous = folder.appending(path: Self.previousName)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { destination in
                do {
                    // Keep the one before, then replace.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try? FileManager.default.removeItem(at: previous)
                        try? FileManager.default.copyItem(at: destination, to: previous)
                    }
                    try data.write(to: destination, options: .atomic)
                } catch {
                    writeError = error
                }
            }
            if let error = coordinationError ?? writeError { throw error }

            lastBackup = backup.createdAt
            lastCount = backup.expenses.count
            lastError = nil
            defaults.set(backup.createdAt, forKey: Key.lastBackup)
            defaults.set(backup.expenses.count, forKey: Key.lastCount)
            defaults.set(false, forKey: Key.dirty)
            return true
        } catch {
            lastError = "Couldn't write the backup: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Read

    /// Reads a backup file picked in Files.
    static func read(_ url: URL) throws -> Backup {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Backup, Error> = .failure(Backup.BackupError.notABackup)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            result = Result { try Backup.decode(Data(contentsOf: source)) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
