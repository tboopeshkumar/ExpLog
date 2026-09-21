import Foundation
import SwiftData

/// The single SwiftData store, living in the App Group container so the app and
/// the share extension read and write the same database.
public enum SharedStore {

    /// Must match the App Group capability on BOTH targets, and the value in
    /// project.yml. Change it together with the bundle identifiers.
    public static let appGroupID = "group.com.boopeshkumar.explog"

    public static let schema = Schema([
        Transaction.self,
        ExpenseCategory.self,
        Account.self,
        MerchantAlias.self,
    ])

    /// Whether the app and the extension can share one database.
    ///
    /// App Groups require a paid Apple Developer Program membership. With a
    /// free Apple ID this is false, and the two targets each get their own
    /// sandbox — so the extension hands transactions to the app through a
    /// `explog://` URL instead of writing them itself. See TransactionLink.
    public static var isAppGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    public static func storeURL() throws -> URL {
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return shared.appending(path: "ExpLog.store")
        }
        // No App Group: fall back to this target's own container. For the app
        // that is the real database; for the extension it is a scratch store
        // that only backs the form, since the app does the saving.
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appending(path: "ExpLog.store")
    }

    public static func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            url: try storeURL()
            // To enable iCloud sync later: add the iCloud capability with a
            // CloudKit container to both targets, then add
            //     cloudKitDatabase: .private("iCloud.com.boopeshkumar.explog")
            // here. The schema above is already shaped for it, so no migration
            // is needed.
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Shared instance. Both targets are useless without a store, so a failure
    /// here is a configuration mistake worth surfacing loudly during setup
    /// rather than hiding behind an empty screen.
    public static let shared: Result<ModelContainer, Error> = {
        do {
            return .success(try makeContainer())
        } catch {
            return .failure(error)
        }
    }()
}
