import Foundation
import Security

/// Where a folder destination's security-scoped bookmark bytes actually live.
///
/// `ExportDestinationConfig.folderBookmarkRef` is a *key*, never the bookmark — its doc comment
/// spells out why ("bookmark data grants standing filesystem access and belongs with the other
/// protected material"). This protocol is the other half of that sentence, and it is a protocol so
/// the destination logic can be tested against an in-memory store: unit tests get no Keychain, and
/// a `FileFolderDestination` that talked to `SecItem` directly would be untestable end to end.
protocol FolderBookmarkStoring {
    func bookmark(for ref: String) -> Data?
    /// Returns false if the write did not stick. Callers must not treat a failed store as fatal to
    /// the run in progress — the export can still be delivered through the URL already in hand; it
    /// is the *next* run that will find no bookmark and report `unreachable`.
    @discardableResult
    func store(_ bookmark: Data, for ref: String) -> Bool
    func remove(ref: String)
}

/// Keychain-backed store. One generic-password item per destination.
///
/// Two attribute choices carry the weight here:
///
///  - **`AfterFirstUnlockThisDeviceOnly`**, not `WhenUnlocked`. EPIC-15 will run exports from a
///    background wake, and a `WhenUnlocked` item is unreadable then — the schedule would fail with
///    an unreachable destination every time the phone happened to be locked, which is the silent
///    scheduling death the whole Export Health design exists to prevent.
///  - **`ThisDeviceOnly`**, so the item never rides a backup to a new phone. A bookmark is
///    meaningful only on the device that minted it; restored onto a new one it resolves to nothing,
///    and the user would meet a destination that has always been broken with no memory of breaking
///    it. Absent, it reports `notConfigured` and asks them to pick a folder — which is the truth.
struct KeychainFolderBookmarkStore: FolderBookmarkStoring {
    /// Namespaced so these items are distinguishable from anything else BADAN may one day put in
    /// the Keychain, and so a future "forget every destination" can delete by service in one call.
    static let service = "net.binjamshid.badan.export.folder-bookmark"

    func bookmark(for ref: String) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: ref,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func store(_ bookmark: Data, for ref: String) -> Bool {
        // Delete-then-add rather than SecItemUpdate: an update against a missing item fails, an add
        // against an existing one fails, and branching on which case we are in means two Keychain
        // round trips to learn something this sequence handles in one path.
        remove(ref: ref)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: ref,
            kSecValueData: bookmark,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        return status == errSecSuccess
    }

    func remove(ref: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: ref,
        ] as CFDictionary)
    }
}

/// Test double, and the reason `FolderBookmarkStoring` is a protocol. Also usable as a deliberate
/// "hold nothing across launches" store if a future build wants a session-only destination.
final class InMemoryFolderBookmarkStore: FolderBookmarkStoring {
    private var items: [String: Data] = [:]
    /// Set by a test to assert the caller survives a store that refuses to persist.
    var failWrites = false

    init(items: [String: Data] = [:]) { self.items = items }

    func bookmark(for ref: String) -> Data? { items[ref] }

    @discardableResult
    func store(_ bookmark: Data, for ref: String) -> Bool {
        if failWrites { return false }
        items[ref] = bookmark
        return true
    }

    func remove(ref: String) { items.removeValue(forKey: ref) }
}
