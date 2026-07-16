import XCTest
@testable import BADAN

/// Upgrade-path coverage: migrations run against a database that already holds real rows, not
/// just against an empty file.
///
/// This was the blind spot F3 lived in. Every other test builds its database through
/// `Database(directory:)`, which migrates an empty file straight to the newest version — so a
/// migration whose statements are only valid against *clean* data passed the whole suite while
/// bricking upgrading installs in the field. The fixture pattern here (drive the schema to an old
/// version with a truncated migration list, write era-appropriate rows, then run the full list)
/// is what any future migration touching existing rows should reuse.
final class MigrationFixTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-migration-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture helpers

    /// A connection migrated to `version` and no further — i.e. a database as some earlier
    /// release actually left it on disk.
    private func connection(atSchemaVersion version: Int) throws -> SQLiteConnection {
        let conn = try SQLiteConnection(path: tempDir.appendingPathComponent("badan.db").path)
        try Database.migrate(conn, Schema.mainMigrations.filter { $0.version <= version })
        return conn
    }

    /// Inserts a v2-era sleep session directly (no repository — repositories always write the
    /// current schema, and the point here is to reproduce what v2 rows really looked like).
    private func insertSession(_ conn: SQLiteConnection, id: String, kind: String,
                               externalId: String, sourceId: String, updatedAt: Int,
                               stageCount: Int = 2) throws {
        _ = try conn.run("""
            INSERT INTO sessions (id, kind, start_at, end_at, tz_id, local_night, detail,
              source_id, ingestion_path, external_id, measured_at, measured_tz, recorded_at,
              ingested_at, updated_at, origin_device_id)
            VALUES (?, ?, 0, 1, 'UTC', '2023-11-14', '{}', ?, 'platformStore', ?, 0, 'UTC', 0, 0, ?, 'dev');
            """, [.text(id), .text(kind), .text(sourceId), .text(externalId), .int(updatedAt)])
        for seq in 0..<stageCount {
            _ = try conn.run("""
                INSERT INTO session_stages (session_id, seq, stage, start_at, end_at)
                VALUES (?, ?, 'light', 0, 1);
                """, [.text(id), .int(seq)])
        }
    }

    private func count(_ conn: SQLiteConnection, _ sql: String) throws -> Int {
        Int(try conn.query(sql).first?.int("c") ?? 0)
    }

    // MARK: - F3: v3 must survive the duplicates it exists to prevent

    /// The exact shape v3 was written for: one night, one source, reclassified between syncs, so
    /// v2 stored it twice under one `(external_id, source_id)` differing only in `kind`. v3 adds a
    /// UNIQUE index over precisely that pair — which cannot be created while those rows exist.
    func testMigratingV2WithDuplicateSessionIdentitiesSucceeds() throws {
        let conn = try connection(atSchemaVersion: 2)
        try insertSession(conn, id: "s-nap", kind: "sleepNap", externalId: "healthkit-sleep-watch-1-2023-11-14",
                          sourceId: "watch-1", updatedAt: 100)
        try insertSession(conn, id: "s-primary", kind: "sleepPrimary", externalId: "healthkit-sleep-watch-1-2023-11-14",
                          sourceId: "watch-1", updatedAt: 200)

        XCTAssertNoThrow(try Database.migrate(conn, Schema.mainMigrations),
                         "F3: a v2 database holding the duplicates v3 exists to prevent must "
                             + "still upgrade — otherwise the affected users are exactly the ones "
                             + "whose database stops opening")

        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM sessions;"), 1,
                       "F3: the duplicate must be resolved, not left to fail the unique index")
        XCTAssertEqual(try conn.query("SELECT id FROM sessions;").first?.string("id"), "s-primary",
                       "F3: the freshest row by updated_at is the survivor")
    }

    func testV3DedupRemovesTheStagesOfDeletedSessionsOnly() throws {
        let conn = try connection(atSchemaVersion: 2)
        try insertSession(conn, id: "s-old", kind: "sleepNap", externalId: "ext-a", sourceId: "watch-1",
                          updatedAt: 100, stageCount: 3)
        try insertSession(conn, id: "s-new", kind: "sleepPrimary", externalId: "ext-a", sourceId: "watch-1",
                          updatedAt: 200, stageCount: 2)

        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM session_stages WHERE session_id = 's-old';"), 0,
                       "F3: the losing session's stages must not be orphaned")
        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM session_stages WHERE session_id = 's-new';"), 2,
                       "F3: the surviving session must keep every one of its stages")
    }

    /// Rows that were never in conflict must be left completely alone — a dedup that also eats
    /// legitimate data trades one data-loss bug for another.
    func testV3DedupPreservesDistinctSessions() throws {
        let conn = try connection(atSchemaVersion: 2)
        try insertSession(conn, id: "s-1", kind: "sleepPrimary", externalId: "ext-a", sourceId: "watch-1", updatedAt: 100)
        try insertSession(conn, id: "s-2", kind: "sleepPrimary", externalId: "ext-b", sourceId: "watch-1", updatedAt: 100)
        // Same external_id, different source: distinct identity under the new index.
        try insertSession(conn, id: "s-3", kind: "sleepPrimary", externalId: "ext-a", sourceId: "phone-1", updatedAt: 100)

        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM sessions;"), 3,
                       "F3: only rows colliding on (external_id, source_id) may be removed")
    }

    /// `external_id IS NULL` rows are outside the partial index entirely, so any number of them
    /// may coexist; SQL's `NULL != NULL` makes it easy to write a dedup that wrongly collapses
    /// them to one.
    func testV3DedupIgnoresSessionsWithoutAnExternalId() throws {
        let conn = try connection(atSchemaVersion: 2)
        for i in 0..<3 {
            _ = try conn.run("""
                INSERT INTO sessions (id, kind, start_at, end_at, tz_id, local_night, detail,
                  source_id, ingestion_path, measured_at, measured_tz, recorded_at, ingested_at,
                  updated_at, origin_device_id)
                VALUES (?, 'sleepPrimary', 0, 1, 'UTC', '2023-11-14', '{}', 'watch-1',
                  'platformStore', 0, 'UTC', 0, 0, 100, 'dev');
                """, [.text("s-null-\(i)")])
        }

        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM sessions;"), 3,
                       "F3: sessions with no external_id are outside the unique index and must "
                           + "never be deduped against each other")
    }

    /// The clean-upgrade path must keep working — the dedup is additive, not a rewrite.
    func testMigratingCleanV2DatabaseStillReachesV3() throws {
        let conn = try connection(atSchemaVersion: 2)
        try insertSession(conn, id: "s-1", kind: "sleepPrimary", externalId: "ext-a", sourceId: "watch-1", updatedAt: 100)

        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertEqual(try conn.query("PRAGMA user_version;").first?.int("user_version"),
                       Int64(Schema.mainMigrations.map(\.version).max() ?? 0))
        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM sessions;"), 1)
    }

    /// After the upgrade the index must actually be enforcing the new identity — a dedup that
    /// silently skipped the CREATE would also pass every assertion above.
    func testV3IndexIsEnforcedAfterUpgrade() throws {
        let conn = try connection(atSchemaVersion: 2)
        try insertSession(conn, id: "s-1", kind: "sleepPrimary", externalId: "ext-a", sourceId: "watch-1", updatedAt: 100)
        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertThrowsError(try insertSession(conn, id: "s-2", kind: "sleepNap", externalId: "ext-a",
                                               sourceId: "watch-1", updatedAt: 300),
                             "F3: (external_id, source_id) must be unique once v3 has run")
    }
}
