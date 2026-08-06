import Foundation
import CryptoKit
import Security

/// Where the vault's one symmetric encryption key lives. A protocol — mirroring
/// `FolderBookmarkStoring` (`Export/Destinations/FolderBookmarkStore.swift`) — so `DocumentVault`
/// is unit-testable without touching the real Keychain.
protocol VaultKeyStoring {
    func key() -> Data?
    @discardableResult
    func store(_ key: Data) -> Bool
    func remove()
}

/// Keychain-backed store for the vault's key. One generic-password item, namespaced by service.
///
/// Two attribute choices carry the weight here, mirroring `KeychainFolderBookmarkStore`'s own
/// reasoning exactly:
///  - **`AfterFirstUnlockThisDeviceOnly`**, not `WhenUnlocked`: a future background OCR/import pass
///    must be able to read a vaulted document after the phone has been unlocked at least once
///    since boot, even if it is locked again by the time the pass actually runs.
///  - **`ThisDeviceOnly`**: a key that rode a backup to a new phone would silently make every
///    vaulted file on THAT phone permanently unreadable ciphertext with no key ever available to
///    open it — restored without the key at all (absent), a fresh key is simply generated and the
///    (now genuinely undecryptable) old files are the honest state, matching how a restored,
///    keyless `FolderBookmarkStoring` item reports `notConfigured` rather than a lie.
struct KeychainVaultKeyStore: VaultKeyStoring {
    static let service = "net.binjamshid.badan.labs.document-vault-key"
    static let account = "vault-key"

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
        // Delete-then-add rather than SecItemUpdate, matching `KeychainFolderBookmarkStore.store`'s
        // own reasoning: branching on "does an item already exist" costs a Keychain round trip this
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
/// same dual purpose `InMemoryFolderBookmarkStore` serves.
final class InMemoryVaultKeyStore: VaultKeyStoring {
    private var stored: Data?
    init(_ initial: Data? = nil) { stored = initial }
    func key() -> Data? { stored }
    @discardableResult func store(_ key: Data) -> Bool { stored = key; return true }
    func remove() { stored = nil }
}

enum DocumentVaultError: Error, Equatable {
    /// `SecRandomCopyBytes` reported failure generating a fresh vault key — never reachable in
    /// normal operation, listed for the same reason `ExportEncryptionError.internalFailure` is.
    case keyGenerationFailed
    /// The freshly-generated key could not be persisted to `VaultKeyStoring` — surfaced rather
    /// than silently proceeding with an unpersisted key that the NEXT launch would fail to find.
    case keyPersistFailed
    /// `ExportEncryptor.decrypt` returned zero inner files for a container this vault wrote —
    /// unreachable via `DocumentVault.store` itself (which always wraps exactly one file), kept as
    /// a typed failure rather than a forced-unwrap in case a future format change violates that.
    case emptyContainer
}

/// One vaulted document as `DocumentVault.store` leaves it: where to find it again, and the hash
/// of what it actually contained.
struct VaultedDocument: Equatable {
    let vaultFileRef: String
    let sha256: String
}

/// The on-disk, encrypted lab-document vault (LAB-02): stores an uploaded/scanned lab-report PDF
/// or photo as an AES-256-GCM-sealed file under a dedicated app-sandboxed directory — never as a
/// `badan_sensitive.db` BLOB (see `SourceDocument`'s own header for the full reasoning).
///
/// Reuses `ExportEncryptor` (the "BDNX" container this codebase already ships for encrypted export
/// bundles, `Export/ExportEncryption.swift`) rather than inventing a second encryption scheme. The
/// only difference from an export bundle is WHERE the passphrase comes from: an export's
/// passphrase is typed by the user for one deliberate, one-off share, while the vault's is a
/// random 256-bit key this type generates once and keeps in the Keychain — nobody should have to
/// re-type a passphrase just to view a lab result they saved months ago, and there is no "share
/// this with someone else" story for the vault the way there is for an export (partner/caregiver
/// sharing is on the founder/legal do-not-build list — `docs/HANDOFF.md` §5 — so a vaulted
/// document is only ever decrypted back to the same device that encrypted it, by design, not as an
/// accidental limitation).
///
/// `sha256` is always computed over the ORIGINAL, pre-encryption bytes — LAB-02's "hash+metadata"
/// requirement needs the hash to keep proving what the source document contained independent of
/// however the storage encryption layer evolves.
final class DocumentVault {
    private let directory: URL
    private let keyStore: VaultKeyStoring

    /// The name every `DocumentVault` uses under a `Database`'s own directory — a single constant
    /// so the purge, the purge test and any future diagnostics agree on where these files live
    /// without duplicating the literal.
    static let directoryName = "SensitiveDocumentVault"

    /// The vault directory belonging to a `Database` whose own directory is `databaseDirectory`.
    /// The ONE place that path is composed: `init(database:)` and
    /// `Database.purgeSensitiveNamespace()` both go through it, so the purge cannot end up aiming
    /// at a directory the vault does not actually write to.
    static func directory(inDatabaseDirectory databaseDirectory: URL) -> URL {
        databaseDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Wires this vault's directory under `database`'s own `Application Support/BADAN/…`
    /// directory. Constructing a vault registers NOTHING — the sensitive purge finds these files
    /// by path (`wipeAll(inDatabaseDirectory:)`), not by a callback this initializer left behind.
    /// See that method for why the callback had to go.
    init(database: Database, keyStore: VaultKeyStoring = KeychainVaultKeyStore()) throws {
        self.directory = Self.directory(inDatabaseDirectory: database.directory)
        self.keyStore = keyStore
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Directory-only entry point that skips the `Database` wiring — for tests/callers that only
    /// care about read/write/hash behavior in isolation. Pointed at
    /// `DocumentVault.directory(inDatabaseDirectory:)` it also models the shipped app state a
    /// purge has to survive: files on disk from an earlier launch with no `DocumentVault(database:)`
    /// ever constructed in THIS process (`DocumentVaultTests
    /// .testPurgeWipesVaultedFilesWhenNoVaultWasEverConstructedAgainstTheDatabase`).
    init(directory: URL, keyStore: VaultKeyStoring = InMemoryVaultKeyStore()) throws {
        self.directory = directory
        self.keyStore = keyStore
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Store / retrieve / delete

    /// Encrypts `data` and writes it under a freshly-minted filename; returns the file's
    /// vault-relative reference and the SHA-256 of the ORIGINAL bytes (computed before
    /// encryption, per LAB-02).
    @discardableResult
    func store(_ data: Data) throws -> VaultedDocument {
        let sha256 = Self.sha256Hex(of: data)
        let vaultFileRef = ULID.newID() + ".bdnx"
        let container = try ExportEncryptor.encrypt(
            files: [ExportContainerFile(name: "document", data: data)],
            passphrase: try passphrase())
        let url = directory.appendingPathComponent(vaultFileRef)
        // Re-created rather than assumed to exist from `init`: a sensitive purge deletes this
        // directory outright (it does NOT recreate it — see `wipeAll(inDatabaseDirectory:)`, which
        // runs with no live vault to recreate anything for), and a `DocumentVault` that happened to
        // be alive across that purge would otherwise fail every subsequent write. One idempotent
        // syscall on a path that is already writing a file.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `.completeFileProtectionUntilFirstUserAuthentication` is set explicitly at write time
        // rather than relied upon via `Database.applyHardening`: that pass only walks its OWN
        // directory's TOP-LEVEL entries, so it would set protection on `SensitiveDocumentVault`
        // itself (one entry in `Database`'s directory) but never reach a file created inside it
        // afterward. AES-256-GCM already protects these bytes' confidentiality regardless: this is
        // defense in depth, matching the same protection class `Database.applyHardening` uses for
        // the SQLite files, not the only thing standing between this file and being read.
        try container.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return VaultedDocument(vaultFileRef: vaultFileRef, sha256: sha256)
    }

    /// Decrypts and returns the original bytes for a previously-stored file.
    func retrieve(vaultFileRef: String) throws -> Data {
        let url = directory.appendingPathComponent(vaultFileRef)
        let container = try Data(contentsOf: url)
        let files = try ExportEncryptor.decrypt(container, passphrase: try passphrase())
        guard let file = files.first else { throw DocumentVaultError.emptyContainer }
        return file.data
    }

    /// Deletes one vaulted file. A no-op (not an error) when the file is already gone — matching
    /// `Database.purgeSensitiveNamespace`'s own tolerance for a missing `-wal`/`-shm` sibling,
    /// since the caller's actual goal ("this file is gone") is already satisfied either way.
    func delete(vaultFileRef: String) throws {
        let url = directory.appendingPathComponent(vaultFileRef)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Purge integration

    /// Delete every vaulted file under a database directory, needing NO live `DocumentVault`.
    /// Called unconditionally by `Database.purgeSensitiveNamespace()`.
    ///
    /// "Turn off sensitive records" must delete every vaulted lab-report file, not just the
    /// `source_documents` metadata rows that reference them, or a purge leaves PDFs/photos that can
    /// carry a name, a date of birth or diagnoses sitting on disk with nothing in the sensitive DB
    /// even admitting they exist.
    ///
    /// **Why this is a static path operation and not the registered callback it used to be
    /// (STORAGE-1).** The wipe was previously a closure `init(database:)` handed to
    /// `Database.registerSensitiveWipeHook`, and the app's only call site for that initializer was
    /// `LabNotebookServices` — built lazily into a `@State` the first time someone opens the Lab
    /// Notebook screen. So in any process where the Labs tab was never visited, nothing had
    /// registered: the purge deleted `badan_sensitive.db` and left every `.bdnx` file exactly where
    /// it was, still openable by the Keychain key, while the rows that even NAME those files were
    /// gone. The closure additionally captured `[weak self]`, so it silently degraded back to a
    /// no-op once the screen's `@State` was torn down. The old comment here claimed the outcome
    /// this method now actually delivers.
    ///
    /// Depending on nothing but the directory `Database` already owns removes that whole class of
    /// failure: no registration to miss, no object lifetime for the guarantee to ride on, and no
    /// ordering between "the user opened a screen" and "the user erased their sensitive records".
    /// `Database` still learns nothing about this type's key storage, file naming or encryption —
    /// only the directory name that was already published as `DocumentVault.directoryName`.
    ///
    /// The directory is removed, not emptied-and-recreated: there is no live vault here to keep
    /// usable, and `store` recreates the directory on demand for any vault that outlives a purge.
    /// The Keychain key is deliberately left alone. It opens nothing once the sealed files are
    /// gone, `Database` has no business reaching into this type's key store, and if a removal ever
    /// does fail (which this method reports by throwing) the survivors stay readable — a file the
    /// user can still see and delete beats undecryptable ciphertext BADAN can no longer name.
    static func wipeAll(inDatabaseDirectory databaseDirectory: URL) throws {
        let directory = Self.directory(inDatabaseDirectory: databaseDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Instance-scoped wipe of THIS vault's directory — used by the directory-only construction
    /// path and by any caller holding a vault it wants emptied. The sensitive purge does not go
    /// through here (see the static above); an empty directory is left behind so a vault that is
    /// still in use keeps working exactly as it did before the wipe.
    func wipeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Key management

    /// The vault's passphrase into `ExportEncryptor` — a random 256-bit key, generated once and
    /// persisted via `keyStore`, base64-encoded into the `String` `ExportEncryptor.encrypt`/
    /// `decrypt` expect. Unlike a user-typed export passphrase, this key's strength comes entirely
    /// from its own entropy rather than from `ExportEncryptor`'s slow KDF — but this type still
    /// reuses that exact primitive rather than adding a second, lower-level encryption path solely
    /// for this one caller, per this slice's own brief.
    private func passphrase() throws -> String {
        if let existing = keyStore.key() { return existing.base64EncodedString() }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else {
            throw DocumentVaultError.keyGenerationFailed
        }
        let key = Data(bytes)
        guard keyStore.store(key) else { throw DocumentVaultError.keyPersistFailed }
        return key.base64EncodedString()
    }

    // MARK: - Hashing

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
