import Foundation
import XCTest
@testable import BADAN

/// D-23/A16 (ADR-0010 §A16): SQLCipher adoption for `badan_sensitive.db` only. Covers the three
/// guarantees the ADR's own consequences section names explicitly:
///   1. `main` (`badan.db`) is unaffected — still plain SQLite, opened with no key.
///   2. A pre-existing, pre-SQLCipher plaintext `badan_sensitive.db` is transparently converted
///      in place with NO DATA LOSS, and the result is genuinely SQLCipher-encrypted — verified by
///      proving the raw sqlite3 API cannot read it without the key.
///   3. A conversion that can't proceed safely never touches the original file.
///   4. `purgeSensitiveNamespace()` keeps working exactly as before: file delete, fresh (still
///      encrypted) file afterward.
final class SQLCipherMigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-sqlcipher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var sensitivePath: String { tempDir.appendingPathComponent(Database.sensitiveFilename).path }
    private var mainPath: String { tempDir.appendingPathComponent(Database.mainFilename).path }

    /// SQLite's own on-disk magic header — the first 16 bytes of every plain, unencrypted SQLite
    /// file. A SQLCipher-encrypted file, by contrast, has random-looking bytes here (SQLCipher
    /// stores a per-file random salt in that region by default) — so comparing against this magic
    /// string is a direct, format-level way to distinguish "plain SQLite" from "SQLCipher".
    private static let sqliteMagicHeader = Data("SQLite format 3\0".utf8)

    private func fileHeader(_ path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { handle.closeFile() }
        return handle.readData(ofLength: Self.sqliteMagicHeader.count)
    }

    // MARK: - main (`badan.db`) is unaffected

    func testMainDatabaseStaysPlainUnencryptedSQLite() throws {
        let db = try Database(directory: tempDir, sensitiveKeyStore: InMemorySensitiveDatabaseKeyStore())
        try db.checkpoint(truncate: true) // force badan.db's header to actually reflect the schema

        XCTAssertEqual(try fileHeader(mainPath), Self.sqliteMagicHeader,
                       "badan.db must remain byte-for-byte plain SQLite — D-23 scopes SQLCipher to badan_sensitive.db only")
        // And a fresh, no-key connection can read it straight off disk, exactly as before this change.
        let plainConn = try SQLiteConnection(path: mainPath)
        XCTAssertNoThrow(try plainConn.query("SELECT count(*) AS c FROM sqlite_master;"))
    }

    // MARK: - A fresh sensitive DB is genuinely encrypted

    func testFreshSensitiveDatabaseIsGenuinelyEncrypted() throws {
        let db = try Database(directory: tempDir, sensitiveKeyStore: InMemorySensitiveDatabaseKeyStore())
        try db.checkpoint(truncate: true)

        XCTAssertNotEqual(try fileHeader(sensitivePath), Self.sqliteMagicHeader,
                          "a freshly-created badan_sensitive.db must NOT look like plain SQLite on disk")
        // Even `SQLiteConnection`'s own `init` fails here — it runs `PRAGMA journal_mode = WAL`
        // immediately after open, which already forces a real page-1 read against the encrypted
        // file, so the raw sqlite3 API can't get as far as a usable connection without the key.
        XCTAssertThrowsError(try SQLiteConnection(path: sensitivePath),
                             "opening the encrypted file with the raw sqlite3 API and no key must fail")
    }

    // MARK: - Legacy plaintext → SQLCipher conversion, no data loss

    /// Builds a `badan_sensitive.db` exactly as it would exist on disk for an already-installed
    /// user BEFORE this change ever shipped: fully migrated to the head schema, real rows, no key
    /// ever set — i.e. `SQLiteConnection(path:)` with no `key` argument, which is still exactly
    /// how `main` is opened today, proving this really is "the old plaintext format."
    @discardableResult
    private func writeLegacyPlaintextFixture() throws -> (regimenId: String, symptomId: String) {
        let conn = try SQLiteConnection(path: sensitivePath) // no key — legacy, pre-SQLCipher shape
        try Database.migrate(conn, Schema.sensitiveMigrations)
        let regimenId = "regimen-\(UUID().uuidString)"
        let symptomId = "symptom-\(UUID().uuidString)"
        try conn.run("""
            INSERT INTO medication_regimens (id, name, strength, form, schedule, started_at, ended_at,
              notes, updated_at, origin_device_id, deleted_at)
            VALUES (?, 'Sertraline', '50mg', 'tablet', 'daily', 1000, NULL, 'pre-SQLCipher row', 1000, 'dev-1', NULL);
            """, [.text(regimenId)])
        try conn.run("""
            INSERT INTO symptom_entries (id, symptom_id, custom_label, severity, occurred_at, tz_id,
              duration_s, body_location, triggers, note, updated_at, origin_device_id, deleted_at)
            VALUES (?, NULL, 'headache', 3, 2000, 'UTC', NULL, NULL, '[]', 'pre-SQLCipher row', 2000, 'dev-1', NULL);
            """, [.text(symptomId)])
        conn.closeHandle()
        return (regimenId, symptomId)
    }

    func testExistingPlaintextSensitiveDatabaseIsTransparentlyReencryptedWithNoDataLoss() throws {
        let (regimenId, symptomId) = try writeLegacyPlaintextFixture()
        // Sanity check on the FIXTURE itself: it really is plain, unencrypted SQLite before we
        // touch it — otherwise this test would not actually be exercising the migration path.
        XCTAssertEqual(try fileHeader(sensitivePath), Self.sqliteMagicHeader,
                       "fixture setup bug: the pre-migration file must itself be plain SQLite")

        let db = try Database(directory: tempDir, sensitiveKeyStore: InMemorySensitiveDatabaseKeyStore())
        try db.checkpoint(truncate: true)

        // 1. Every row survived, with its original values intact.
        let regimenRows = try db.sensitive.query("SELECT * FROM medication_regimens WHERE id = ?;", [.text(regimenId)])
        XCTAssertEqual(regimenRows.count, 1)
        XCTAssertEqual(regimenRows.first?.string("name"), "Sertraline")
        XCTAssertEqual(regimenRows.first?.string("notes"), "pre-SQLCipher row")

        let symptomRows = try db.sensitive.query("SELECT * FROM symptom_entries WHERE id = ?;", [.text(symptomId)])
        XCTAssertEqual(symptomRows.count, 1)
        XCTAssertEqual(symptomRows.first?.string("custom_label"), "headache")
        XCTAssertEqual(symptomRows.first?.int("severity"), 3)

        // 2. The on-disk file is now genuinely SQLCipher-encrypted, not just "still readable
        //    because Database happened to have the key in memory."
        XCTAssertNotEqual(try fileHeader(sensitivePath), Self.sqliteMagicHeader,
                          "the converted file must no longer look like plain SQLite on disk")
        XCTAssertThrowsError(try SQLiteConnection(path: sensitivePath),
                             "the converted file must not be readable via the raw sqlite3 API without the key")
    }

    /// The schema migrations still apply correctly on top of a converted database — the
    /// conversion isn't a dead end that leaves the sensitive namespace stuck pre-head-version.
    func testMigratedDatabaseSchemaVersionMatchesHead() throws {
        try writeLegacyPlaintextFixture()
        let db = try Database(directory: tempDir, sensitiveKeyStore: InMemorySensitiveDatabaseKeyStore())
        let expected = Int64(Schema.sensitiveMigrations.map(\.version).max() ?? 0)
        let actual = try db.sensitive.query("PRAGMA user_version;").first?.int("user_version")
        XCTAssertEqual(actual, expected)
    }

    // MARK: - A failed / impossible conversion never destroys the original

    func testUnreadableSensitiveFileIsNeverTouchedOrDestroyed() throws {
        let garbage = Data("this is neither plain SQLite nor SQLCipher — just garbage bytes on disk".utf8)
        try garbage.write(to: URL(fileURLWithPath: sensitivePath))

        XCTAssertThrowsError(try Database(directory: tempDir, sensitiveKeyStore: InMemorySensitiveDatabaseKeyStore())) { error in
            guard case SensitiveDatabaseMigrationError.sourceUnreadable = error else {
                return XCTFail("expected .sourceUnreadable, got \(error)")
            }
        }
        // The original bytes must be completely untouched — no partial conversion, no truncation.
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: sensitivePath))
        XCTAssertEqual(onDisk, garbage, "a failed conversion must never modify the original file")
        // And no leftover temp artifact from the aborted attempt.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(siblings.contains { $0.contains(".sqlcipher-migrate-") },
                       "an aborted conversion must not leave a temp file behind")
    }

    // MARK: - `badan_sensitive.db`'s own pre-migration sidecars are never removed ahead of the
    // atomic replace (regression test for the HIGH finding in the A16 SQLCipher migration audit:
    // `SensitiveDatabaseMigrator.convert()` used to delete `path`'s `-wal`/`-shm` siblings as a
    // separate, non-atomic step BEFORE `replaceItemAt`, which could permanently drop whatever
    // committed-but-not-yet-checkpointed data was sitting only in that WAL if a crash or a thrown
    // error landed in the gap between the deletion and the replace actually succeeding.)

    /// Observes every `FileManager.removeItem` call the migration makes and, whenever it is asked
    /// to remove one of `sensitivePath`'s OWN pre-migration `-wal`/`-shm` siblings, records whether
    /// `sensitivePath` itself STILL reads back as the old plaintext file at that exact moment — a
    /// regression back to deleting those siblings BEFORE the atomic replace lands would observe
    /// the old plaintext header here; the fixed ordering never does, because the replace has
    /// already swapped in the new encrypted file by the time any such deletion happens.
    private final class SidecarDeletionOrderRecorder: NSObject, FileManagerDelegate {
        private let sensitivePath: String
        private let plaintextMagicHeader: Data
        private(set) var observedOriginalSidecarRemoval = false
        private(set) var observedRemovalBeforeReplaceLanded = false

        init(sensitivePath: String, plaintextMagicHeader: Data) {
            self.sensitivePath = sensitivePath
            self.plaintextMagicHeader = plaintextMagicHeader
        }

        private func record(_ path: String) {
            guard path == sensitivePath + "-wal" || path == sensitivePath + "-shm" else { return }
            observedOriginalSidecarRemoval = true
            guard let handle = FileHandle(forReadingAtPath: sensitivePath) else { return }
            defer { handle.closeFile() }
            if handle.readData(ofLength: plaintextMagicHeader.count) == plaintextMagicHeader {
                observedRemovalBeforeReplaceLanded = true
            }
        }

        func fileManager(_ fileManager: FileManager, shouldRemoveItemAtPath path: String) -> Bool {
            record(path)
            return true
        }

        func fileManager(_ fileManager: FileManager, shouldRemoveItemAt URL: URL) -> Bool {
            record(URL.path)
            return true
        }
    }

    func testOriginalSidecarsAreOnlyRemovedAfterTheAtomicReplaceSucceeds() throws {
        try writeLegacyPlaintextFixture()
        // A real installed copy of `badan_sensitive.db` routinely has `-wal`/`-shm` siblings
        // sitting next to it — WAL is `SQLiteConnection`'s default journal mode — so simulate that
        // here, otherwise the migrator would have nothing of `path`'s own to clean up during this
        // run and the assertions below would pass vacuously.
        try Data("stale-wal-bytes".utf8).write(to: URL(fileURLWithPath: sensitivePath + "-wal"))
        try Data("stale-shm-bytes".utf8).write(to: URL(fileURLWithPath: sensitivePath + "-shm"))

        let recorder = SidecarDeletionOrderRecorder(sensitivePath: sensitivePath, plaintextMagicHeader: Self.sqliteMagicHeader)
        let previousDelegate = FileManager.default.delegate
        FileManager.default.delegate = recorder
        defer { FileManager.default.delegate = previousDelegate }

        _ = try Database(directory: tempDir, sensitiveKeyStore: InMemorySensitiveDatabaseKeyStore())

        XCTAssertTrue(recorder.observedOriginalSidecarRemoval,
                     "test setup bug: expected migration to clean up badan_sensitive.db's own pre-migration -wal/-shm siblings at some point")
        XCTAssertFalse(recorder.observedRemovalBeforeReplaceLanded,
                       "badan_sensitive.db's own -wal/-shm siblings must only be deleted AFTER the atomic replace has already landed the encrypted file — deleting them first reopens the exact non-atomic corruption window the migrator's own header comment promises can't happen")
    }

    // MARK: - Already-migrated databases are a no-op (steady state, every launch after the first)

    func testAlreadyEncryptedDatabaseOpensDirectlyWithoutReconversion() throws {
        let seededKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let keyStore = InMemorySensitiveDatabaseKeyStore(seededKey)

        let first = try Database(directory: tempDir, sensitiveKeyStore: keyStore)
        try first.sensitive.run("""
            INSERT INTO medication_regimens (id, name, schedule, started_at, updated_at, origin_device_id)
            VALUES ('steady-state-row', 'Metformin', 'daily', 1000, 1000, 'dev-1');
            """)
        try first.checkpoint(truncate: true)

        // A second, independent `Database` instance at the SAME directory with the SAME key must
        // open straight through (no re-migration attempted) and see the row the first instance
        // wrote — proving steady-state opens are correct, not just that migration-once works.
        let second = try Database(directory: tempDir, sensitiveKeyStore: keyStore)
        let rows = try second.sensitive.query("SELECT * FROM medication_regimens WHERE id = 'steady-state-row';")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.string("name"), "Metformin")
    }

    // MARK: - purgeSensitiveNamespace() still works exactly as before, now on an encrypted file

    func testPurgeSensitiveNamespaceDeletesEncryptedFileAndRecreatesUsableEncryptedDatabase() throws {
        let db = try Database(directory: tempDir, sensitiveKeyStore: InMemorySensitiveDatabaseKeyStore())
        try db.sensitive.run("""
            INSERT INTO medication_regimens (id, name, schedule, started_at, updated_at, origin_device_id)
            VALUES ('to-be-purged', 'Ibuprofen', 'as-needed', 1000, 1000, 'dev-1');
            """)

        try db.purgeSensitiveNamespace()

        // The purged-then-recreated connection is immediately usable, and the old row is gone.
        let rows = try db.sensitive.query("SELECT * FROM medication_regimens WHERE id = 'to-be-purged';")
        XCTAssertEqual(rows.count, 0)
        XCTAssertNoThrow(try db.sensitive.run("""
            INSERT INTO medication_regimens (id, name, schedule, started_at, updated_at, origin_device_id)
            VALUES ('after-purge', 'Naproxen', 'as-needed', 2000, 2000, 'dev-1');
            """))

        // And the FILE that purge recreated is still genuinely SQLCipher-encrypted — a purge must
        // not silently regress the sensitive DB back to a plaintext file.
        try db.checkpoint(truncate: true)
        XCTAssertNotEqual(try fileHeader(sensitivePath), Self.sqliteMagicHeader,
                          "the file purgeSensitiveNamespace() recreates must still be SQLCipher-encrypted")
        XCTAssertThrowsError(try SQLiteConnection(path: sensitivePath))
    }

    func testPurgeSensitiveNamespaceWithNoPriorMigrationStillSucceeds() throws {
        // A fresh install (no pre-existing file at all) — never touches the migrator's conversion
        // path, only its fast "file doesn't exist yet" no-op.
        let db = try Database(directory: tempDir, sensitiveKeyStore: InMemorySensitiveDatabaseKeyStore())
        XCTAssertNoThrow(try db.purgeSensitiveNamespace())
    }

    // MARK: - Key store plumbing

    func testSensitiveDatabaseEncryptionGeneratesAndPersistsA32ByteKey() throws {
        let store = InMemorySensitiveDatabaseKeyStore()
        XCTAssertNil(store.key())

        let generated = try SensitiveDatabaseEncryption.key(using: store)
        XCTAssertEqual(generated.count, 32)
        XCTAssertEqual(store.key(), generated, "the generated key must be persisted back to the store")

        // Calling again must reuse the SAME key rather than silently rotating it — a rotated key
        // would make every previously-encrypted file permanently unreadable.
        let second = try SensitiveDatabaseEncryption.key(using: store)
        XCTAssertEqual(second, generated)
    }

    func testSQLCipherKeySpecFormatsRawHexKeyLiteral() {
        let key = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(SQLCipherKeySpec.string(for: key), "x'deadbeef'")
    }
}
