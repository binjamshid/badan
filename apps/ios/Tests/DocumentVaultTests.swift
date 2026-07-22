import Foundation
import XCTest
@testable import BADAN

/// LAB-02: the encrypted on-disk document vault. Covers the round-trip contract (write, read back,
/// confirm bytes AND hash match) and — the CRITICAL, easy-to-miss integration point this slice's
/// own brief calls out — that `Database.purgeSensitiveNamespace()` actually deletes vaulted files,
/// not just whatever metadata rows reference them.
final class DocumentVaultTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-document-vault-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Round trip

    func testStoreAndRetrieveRoundTripsOriginalBytes() throws {
        let vault = try DocumentVault(directory: tempDir.appendingPathComponent("vault"))
        let original = Data("this is a fake lab report PDF's bytes, for test purposes only".utf8)

        let stored = try vault.store(original)
        let retrieved = try vault.retrieve(vaultFileRef: stored.vaultFileRef)

        XCTAssertEqual(retrieved, original, "the vault must hand back exactly what was stored")
    }

    func testStoreComputesSHA256OfTheOriginalPreEncryptionBytes() throws {
        let vault = try DocumentVault(directory: tempDir.appendingPathComponent("vault"))
        let original = Data("another fake document body, distinct from the first fixture".utf8)

        let stored = try vault.store(original)

        // LAB-02's "hash+metadata" requirement: the stored hash must be computable independently
        // from the SAME original bytes, proving it describes the source document's content, not
        // some property of the (necessarily different, GCM-random-nonce) encrypted container.
        XCTAssertEqual(stored.sha256, DocumentVault.sha256Hex(of: original))
        // Confirm the hash is NOT simply the hash of whatever ended up on disk (the encrypted
        // container) — the whole point of computing it pre-encryption.
        let onDiskBytes = try Data(contentsOf: tempDir.appendingPathComponent("vault").appendingPathComponent(stored.vaultFileRef))
        XCTAssertNotEqual(stored.sha256, DocumentVault.sha256Hex(of: onDiskBytes),
                          "the stored hash must describe the ORIGINAL document, not its encrypted container")
    }

    func testVaultedFileOnDiskIsNotPlaintext() throws {
        let vault = try DocumentVault(directory: tempDir.appendingPathComponent("vault"))
        let original = Data("plaintext that must never appear verbatim on disk".utf8)

        let stored = try vault.store(original)
        let onDiskBytes = try Data(contentsOf: tempDir.appendingPathComponent("vault").appendingPathComponent(stored.vaultFileRef))

        XCTAssertNotEqual(onDiskBytes, original, "the vault must actually encrypt — never write original bytes as-is")
    }

    func testDeleteRemovesTheVaultedFile() throws {
        let vault = try DocumentVault(directory: tempDir.appendingPathComponent("vault"))
        let stored = try vault.store(Data("to be deleted".utf8))
        let url = tempDir.appendingPathComponent("vault").appendingPathComponent(stored.vaultFileRef)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try vault.delete(vaultFileRef: stored.vaultFileRef)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Retrieving a deleted file must fail loudly, never return stale/garbage bytes.
        XCTAssertThrowsError(try vault.retrieve(vaultFileRef: stored.vaultFileRef))
    }

    // MARK: - Purge integration (the CRITICAL requirement)

    /// Vault a document, purge, confirm the file is actually gone from disk — not just that
    /// whatever metadata row referenced it disappeared. This is the exact test this slice's brief
    /// demands: `Database.purgeSensitiveNamespace()` deletes only `badan_sensitive.db` on its own;
    /// without `DocumentVault` registering its own wipe hook, "turn off sensitive records" would
    /// leave every vaulted lab-report file (which can contain a name, date of birth, diagnoses)
    /// sitting on disk with nothing in the sensitive DB admitting they exist.
    func testPurgeSensitiveNamespaceDeletesVaultedFiles() throws {
        let db = try Database(directory: tempDir)
        let vault = try DocumentVault(database: db, keyStore: InMemoryVaultKeyStore())

        let stored = try vault.store(Data("a lab report that must not survive a sensitive purge".utf8))
        let fileURL = tempDir.appendingPathComponent(DocumentVault.directoryName).appendingPathComponent(stored.vaultFileRef)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "sanity check: the file must exist before purging")

        try db.purgeSensitiveNamespace()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "purgeSensitiveNamespace() must delete vaulted document files, not just source_documents rows")
        // The vault must stay usable after a purge — a NEW document can still be vaulted, matching
        // how `sensitive` itself stays open and usable via `SQLiteConnection.reopen()`.
        let afterPurge = try vault.store(Data("logged again after the purge".utf8))
        XCTAssertEqual(try vault.retrieve(vaultFileRef: afterPurge.vaultFileRef), Data("logged again after the purge".utf8))
    }

    /// A `Database` with no `DocumentVault` ever constructed against it (the common case for every
    /// OTHER test in this codebase) must purge exactly as before — registering a wipe hook is
    /// opt-in per instance, never a behavior change for callers that never construct a vault.
    func testPurgeSensitiveNamespaceWithNoRegisteredVaultStillSucceeds() throws {
        let db = try Database(directory: tempDir)
        XCTAssertNoThrow(try db.purgeSensitiveNamespace())
    }

    /// Two independent `DocumentVault`s registered against two independent `Database`s must not
    /// cross-wipe each other's files — the hook is per-`Database`-instance state, not global.
    func testTwoDatabasesDoNotShareWipeHooks() throws {
        let secondDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-document-vault-second-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: secondDir) }

        let dbA = try Database(directory: tempDir)
        let vaultA = try DocumentVault(database: dbA, keyStore: InMemoryVaultKeyStore())
        let dbB = try Database(directory: secondDir)
        let vaultB = try DocumentVault(database: dbB, keyStore: InMemoryVaultKeyStore())

        let storedA = try vaultA.store(Data("belongs to database A".utf8))
        let storedB = try vaultB.store(Data("belongs to database B".utf8))
        let urlA = tempDir.appendingPathComponent(DocumentVault.directoryName).appendingPathComponent(storedA.vaultFileRef)
        let urlB = secondDir.appendingPathComponent(DocumentVault.directoryName).appendingPathComponent(storedB.vaultFileRef)

        try dbA.purgeSensitiveNamespace()

        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path), "A's own document must be wiped by A's purge")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path), "B's document must survive A's purge untouched")
    }
}
