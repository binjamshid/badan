import Foundation
import Security

/// Where `badan_sensitive.db`'s SQLCipher encryption key lives (D-23/A16, ADR-0010 §A16). A
/// protocol — mirroring `VaultKeyStoring` (`DocumentVault.swift`) and `FolderBookmarkStoring`
/// (`Export/Destinations/FolderBookmarkStore.swift`) exactly — so `Database` is unit-testable
/// without touching the real Keychain.
protocol SensitiveDatabaseKeyStoring {
    func key() -> Data?
    @discardableResult
    func store(_ key: Data) -> Bool
    func remove()
}

/// Keychain-backed store for the sensitive database's key. One generic-password item, namespaced
/// by service — the same shape, and the same two attribute choices, as `KeychainVaultKeyStore`
/// (`DocumentVault.swift`), which solves the identical problem (a random symmetric key that must
/// survive relaunches but never leave the device) for the vault's own AES key. This codebase has
/// no HealthKit-specific Keychain precedent to match instead — `HealthKitAdapter` never stores a
/// secret of its own, it only holds an OS-granted authorization — so `KeychainVaultKeyStore` is
/// the closest, and only, existing analogue, and is matched deliberately rather than picked fresh:
///  - **`AfterFirstUnlockThisDeviceOnly`**, not `WhenUnlocked`: `badan_sensitive.db` must stay
///    readable to HealthKit background-delivery observers and the BGTaskScheduler passes (A2/
///    ADR-0009) after the phone has been unlocked at least once since boot, even if it is locked
///    again by the time a background pass actually runs. `WhenUnlocked` would make every such
///    pass fail to open the sensitive DB the moment the screen locks — a regression `DocumentVault`
///    already deliberately avoided for the exact same class of background access.
///  - **`ThisDeviceOnly`**: a key that rode a backup/iCloud-Keychain sync to a new phone would
///    silently make every row in a *restored* `badan_sensitive.db` permanently undecipherable
///    ciphertext with no key ever available to open it. `badan_sensitive.db` itself is excluded
///    from backup (`Database.applyHardening`), so a restored device has no file to match a synced
///    key against anyway — `ThisDeviceOnly` keeps the honest state simple: no key present means no
///    sensitive data exists yet on this device, and a fresh key is generated for a fresh file.
struct KeychainSensitiveDatabaseKeyStore: SensitiveDatabaseKeyStoring {
    static let service = "net.binjamshid.badan.storage.sensitive-db-key"
    static let account = "sensitive-db-key"

    func key() -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func store(_ key: Data) -> Bool {
        // Delete-then-add rather than SecItemUpdate, matching `KeychainVaultKeyStore.store`'s own
        // reasoning: branching on "does an item already exist" costs a Keychain round trip this
        // sequence avoids entirely.
        remove()
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecValueData: key,
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

/// In-memory test double — also usable as a deliberate "forget the key every launch" store, the
/// same dual purpose `InMemoryVaultKeyStore` serves. Tests should inject this (or a pre-seeded
/// instance) rather than exercising the real Keychain, matching how `DocumentVaultTests` always
/// passes `InMemoryVaultKeyStore()` explicitly.
final class InMemorySensitiveDatabaseKeyStore: SensitiveDatabaseKeyStoring {
    private var stored: Data?
    init(_ initial: Data? = nil) { stored = initial }
    func key() -> Data? { stored }
    @discardableResult func store(_ key: Data) -> Bool { stored = key; return true }
    func remove() { stored = nil }
}

enum SensitiveDatabaseKeyError: Error, Equatable {
    /// `SecRandomCopyBytes` reported failure generating a fresh sensitive-DB key — never
    /// reachable in normal operation, listed for the same reason `DocumentVaultError
    /// .keyGenerationFailed` is.
    case keyGenerationFailed
    /// The freshly-generated key could not be persisted to `SensitiveDatabaseKeyStoring` —
    /// surfaced rather than silently proceeding with an unpersisted key that the NEXT launch
    /// would fail to find (and so could never re-open the very file just encrypted with it).
    case keyPersistFailed
}

/// Get-or-create the sensitive database's SQLCipher key: a random 256-bit key, generated once and
/// persisted via `store`. Unlike a user-typed export passphrase (ADR-0008, unaffected by this),
/// this key's strength comes entirely from its own entropy — there is no KDF step at all on the
/// SQLCipher side either (see `SQLCipherKeySpec`), matching how `DocumentVault.passphrase()`
/// generates a random 256-bit key for the exact same reason (D-23/A16: "device Keychain/Keystore-
/// backed, not user-typed").
enum SensitiveDatabaseEncryption {
    static func key(using store: SensitiveDatabaseKeyStoring) throws -> Data {
        if let existing = store.key() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else {
            throw SensitiveDatabaseKeyError.keyGenerationFailed
        }
        let key = Data(bytes)
        guard store.store(key) else { throw SensitiveDatabaseKeyError.keyPersistFailed }
        return key
    }
}

/// Formats a raw key as SQLCipher's documented "raw key data" literal: `x'<64 hex chars>'`. Both
/// `sqlite3_key()`/`sqlite3_key_v2()` (called directly, e.g. from `SQLiteConnection`) and SQL text
/// (`ATTACH ... KEY "..."`, from `SensitiveDatabaseMigrator`) recognize this exact form and use the
/// 32 bytes it decodes to directly as the encryption key — bypassing PBKDF2 derivation entirely.
/// That bypass is deliberate and correct here specifically because the input is already a full
/// 256 bits of `SecRandomCopyBytes` entropy, not a low-entropy human passphrase that would need
/// stretching; running a already-random key through a KDF would add per-open PBKDF2 latency for
/// zero security benefit.
enum SQLCipherKeySpec {
    static func string(for key: Data) -> String {
        "x'" + key.map { String(format: "%02x", $0) }.joined() + "'"
    }
}
