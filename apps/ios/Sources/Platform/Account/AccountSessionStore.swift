import Foundation
import Security

/// Where the account session token lives (ADR-0014 / D-44).
///
/// A protocol for the same reason `AICoachDeviceTokenStoring` is one: so `AccountClient` and
/// `AccountController` are testable without touching the real Keychain.
///
/// Unlike the coach's device token, this one IS an identifier — it resolves to an account row on
/// the server. That is the reversal ADR-0014 records, and it is why the token is held to the same
/// storage rules rather than looser ones.
protocol AccountSessionStoring {
    func token() -> String?
    @discardableResult
    func store(_ token: String) -> Bool
    func remove()
}

/// Keychain-backed, with the same attribute choices as `KeychainAICoachDeviceTokenStore`.
///
/// `AfterFirstUnlockThisDeviceOnly` so a background entitlement refresh can read it once the phone
/// has been unlocked since boot. `ThisDeviceOnly` — no `kSecAttrSynchronizable` — so the session
/// never rides an iCloud Keychain sync or an encrypted backup onto another device.
///
/// That last choice is worth stating plainly, because it looks like it fights the feature: this is
/// a *cross-platform subscription* and the credential deliberately does not travel. It does not need
/// to. Each device signs in with Apple itself and gets its own session; what crosses devices is the
/// entitlement, not the credential. A session token that rode a backup would mean a restored or
/// handed-down phone silently inheriting an account nobody signed into on it, which is a worse
/// failure than one extra sign-in tap.
struct KeychainAccountSessionStore: AccountSessionStoring {
    static let service = "net.binjamshid.badan.account.session"
    static let account = "session-token"

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

final class InMemoryAccountSessionStore: AccountSessionStoring {
    private var stored: String?
    init(_ initial: String? = nil) { stored = initial }
    func token() -> String? { stored }
    @discardableResult func store(_ token: String) -> Bool { stored = token; return true }
    func remove() { stored = nil }
}

/// The cached account identity and entitlement snapshot, on disk.
///
/// `UserDefaults`, not Keychain: none of it is a credential, and all of it must be readable at
/// launch before any network call so the app can answer `access` offline without a flash of
/// "unsubscribed" on every cold start.
///
/// Cleared on sign-out and on account deletion, in that order and by the same call, so there is no
/// path that forgets the credential but leaves the snapshot behind still granting access.
protocol AccountCacheStoring {
    func identity() -> AccountIdentity?
    func snapshot() -> EntitlementSnapshot?
    func store(identity: AccountIdentity?, snapshot: EntitlementSnapshot?)
    func clear()
}

struct DefaultsAccountCacheStore: AccountCacheStoring {
    static let identityKey = "badan.account.identity"
    static let snapshotKey = "badan.account.snapshot"

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func identity() -> AccountIdentity? {
        guard let data = defaults.data(forKey: Self.identityKey) else { return nil }
        return try? Self.decoder.decode(AccountIdentity.self, from: data)
    }

    func snapshot() -> EntitlementSnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey) else { return nil }
        return try? Self.decoder.decode(EntitlementSnapshot.self, from: data)
    }

    func store(identity: AccountIdentity?, snapshot: EntitlementSnapshot?) {
        if let identity, let data = try? Self.encoder.encode(identity) {
            defaults.set(data, forKey: Self.identityKey)
        } else if identity == nil {
            defaults.removeObject(forKey: Self.identityKey)
        }
        if let snapshot, let data = try? Self.encoder.encode(snapshot) {
            defaults.set(data, forKey: Self.snapshotKey)
        } else if snapshot == nil {
            defaults.removeObject(forKey: Self.snapshotKey)
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.identityKey)
        defaults.removeObject(forKey: Self.snapshotKey)
    }
}

final class InMemoryAccountCacheStore: AccountCacheStoring {
    private var cachedIdentity: AccountIdentity?
    private var cachedSnapshot: EntitlementSnapshot?

    init(identity: AccountIdentity? = nil, snapshot: EntitlementSnapshot? = nil) {
        cachedIdentity = identity
        cachedSnapshot = snapshot
    }

    func identity() -> AccountIdentity? { cachedIdentity }
    func snapshot() -> EntitlementSnapshot? { cachedSnapshot }
    func store(identity: AccountIdentity?, snapshot: EntitlementSnapshot?) {
        cachedIdentity = identity
        cachedSnapshot = snapshot
    }
    func clear() {
        cachedIdentity = nil
        cachedSnapshot = nil
    }
}
