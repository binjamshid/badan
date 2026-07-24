import Foundation
import Security

/// Where the AI coach's per-install device token lives (A9 / ADR-0010 / D-22). A protocol —
/// mirroring `RESTCredentialStoring` (`Export/Destinations/RESTDestination.swift`) and
/// `SensitiveDatabaseKeyStoring` (`Storage/SQLite/SensitiveDatabaseKeyStore.swift`) exactly — so
/// `AICoachClient` is unit-testable without touching the real Keychain.
///
/// The token itself is opaque and carries no identity of its own (ADR-0002/D-2: BADAN has zero
/// accounts, and this must not become one) — it is proof-of-registration with
/// `backend/api/main.py`'s `DeviceTokenStore`, nothing more.
protocol AICoachDeviceTokenStoring {
    func token() -> String?
    @discardableResult
    func store(_ token: String) -> Bool
    func remove()
}

/// Keychain-backed store, matching `KeychainSensitiveDatabaseKeyStore`'s attribute choices for
/// the same reasons (that type's own doc explains them in full): `AfterFirstUnlockThisDeviceOnly`
/// so the token survives relaunches and stays readable to a background pass after the phone has
/// been unlocked once since boot, and `ThisDeviceOnly` (no `kSecAttrSynchronizable`) so the token
/// never rides a backup or iCloud Keychain sync to another device — a restored device must go
/// through its own explicit opt-in and get its own token, never inherit one.
struct KeychainAICoachDeviceTokenStore: AICoachDeviceTokenStoring {
    static let service = "net.binjamshid.badan.aicoach.device-token"
    static let account = "device-token"

    func token() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func store(_ token: String) -> Bool {
        // Delete-then-add rather than SecItemUpdate, matching `KeychainSensitiveDatabaseKeyStore
        // .store`'s own reasoning: branching on "does an item already exist" costs a Keychain
        // round trip this sequence avoids entirely.
        remove()
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecValueData: Data(token.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        return status == errSecSuccess
    }

    func remove() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
        ] as CFDictionary)
    }
}

/// In-memory test double — also usable as a deliberate "forget the token every launch" store, the
/// same dual purpose `InMemorySensitiveDatabaseKeyStore` serves. Tests should inject this rather
/// than exercising the real Keychain, matching how every sibling `*Tests.swift` in this codebase
/// passes an in-memory double explicitly.
final class InMemoryAICoachDeviceTokenStore: AICoachDeviceTokenStoring {
    private var stored: String?
    init(_ initial: String? = nil) { stored = initial }
    func token() -> String? { stored }
    @discardableResult func store(_ token: String) -> Bool { stored = token; return true }
    func remove() { stored = nil }
}
