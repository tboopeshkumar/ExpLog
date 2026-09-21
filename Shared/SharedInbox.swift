import Foundation
import Security
import SwiftData

/// A queue of transactions waiting for the app to save them, kept in a keychain
/// group the app and the share extension both belong to.
///
/// Only used when there is no App Group — that is, on a free Apple ID, where the
/// two targets can't share a database. The extension can't hand over by opening
/// the app either: iOS refuses `NSExtensionContext.open` from a share
/// extension. So it drops the transaction here and dismisses, and the app
/// imports whatever is waiting each time it comes to the foreground.
///
/// Free team provisioning profiles grant keychain access to "<team>.*", which
/// is what makes this work without the paid program.
public enum SharedInbox {
    private static let service = "ExpLog.SharedInbox"

    public struct Entry {
        public let id: String
        public let url: URL
    }

    public enum InboxError: LocalizedError {
        case notConfigured
        case couldNotEncode
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "ExpLog's shared keychain group isn't configured."
            case .couldNotEncode:
                return "Couldn't prepare this transaction for ExpLog."
            case .keychain(let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "Couldn't hand this to ExpLog: \(reason)"
            }
        }
    }

    /// Set per target in Info.plist from `$(AppIdentifierPrefix)`, so the team
    /// ID isn't hard-coded here.
    private static var accessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "ExpLogKeychainGroup") as? String
    }

    // MARK: - Extension side

    public static func add(_ draft: TransactionDraft) throws {
        // Without the group, each target would silently write to its own
        // keychain and nothing would ever arrive. Fail loudly instead.
        guard let accessGroup else { throw InboxError.notConfigured }
        guard let url = TransactionLink.url(for: draft) else { throw InboxError.couldNotEncode }

        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(url.absoluteString.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw InboxError.keychain(status) }
    }

    // MARK: - App side

    public static func entries() -> [Entry] {
        guard let accessGroup else { return [] }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let id = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let text = String(data: data, encoding: .utf8),
                  let url = URL(string: text) else { return nil }
            return Entry(id: id, url: url)
        }
    }

    public static func remove(_ entry: Entry) {
        guard let accessGroup else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: entry.id,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Saves everything waiting in the inbox. Each entry is removed only after
    /// it's saved (or found to be a duplicate), so nothing is lost if the app
    /// is killed part-way through. Returns the transactions added.
    @discardableResult
    public static func importPending(into context: ModelContext) -> [Transaction] {
        var added: [Transaction] = []
        for entry in entries() {
            guard let draft = TransactionLink.draft(from: entry.url, context: context) else {
                // Unreadable — drop it rather than retrying it forever.
                remove(entry)
                continue
            }
            if TransactionDraft.duplicate(of: draft, in: context) == nil {
                guard let transaction = try? draft.save(in: context) else { continue }
                added.append(transaction)
            }
            remove(entry)
        }
        return added
    }
}
