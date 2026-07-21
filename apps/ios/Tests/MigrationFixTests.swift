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

    // MARK: - v4: the §9 route + export/automation entity set

    /// Every table and index v4 is responsible for. Asserted as a list rather than spot-checked so
    /// that a statement dropped while editing the migration fails here loudly, instead of surfacing
    /// as a "no such table" the first time some feature happens to touch it.
    private static let v4MainTables = [
        "workout_routes", "route_points", "export_templates", "export_destinations",
        "export_runs", "export_cursors", "automation_schedules", "background_runs",
    ]
    private static let v4MainIndexes = [
        "idx_workout_routes_session", "idx_export_templates_name", "idx_export_runs_started",
        "idx_export_runs_template_started", "idx_automation_enabled_tier", "idx_background_runs_started",
    ]
    private static let v3SensitiveTables = ["journal_entries", "context_statuses", "cycle_contexts"]

    private func objectExists(_ conn: SQLiteConnection, type: String, name: String) throws -> Bool {
        try count(conn, "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='\(type)' AND name='\(name)';") == 1
    }

    /// The acceptance case for v4: a database that already holds real v3 rows must reach v4 with
    /// every one of those rows still present. v4 is additive by construction (CREATEs only, no
    /// DELETE/DROP/ALTER anywhere in it), and this is what holds that property in place — a future
    /// edit that "just tidies up" an existing table inside v4 breaks this test rather than a user's
    /// database.
    func testMigratingPopulatedV3DatabaseToV4PreservesData() throws {
        let conn = try connection(atSchemaVersion: 3)
        try insertSession(conn, id: "s-1", kind: "sleepPrimary", externalId: "ext-a", sourceId: "watch-1", updatedAt: 100)
        _ = try conn.run("""
            INSERT INTO raw_samples (id, metric_id, value, unit, original_value, original_unit,
              start_at, tz_id, source_id, ingestion_path, external_id, measured_at, measured_tz,
              recorded_at, ingested_at, updated_at, origin_device_id)
            VALUES ('r-1', 'heart_rate', 60, 'count/min', 60, 'count/min', 0, 'UTC', 'watch-1',
              'platformStore', 'hk-1', 0, 'UTC', 0, 0, 100, 'dev');
            """)

        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM sessions;"), 1,
                       "v4 is additive — an upgrade must not touch existing rows")
        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM raw_samples;"), 1,
                       "v4 is additive — an upgrade must not touch existing rows")
        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM session_stages;"), 2)
        for table in Self.v4MainTables {
            XCTAssertTrue(try objectExists(conn, type: "table", name: table),
                          "v4 must create \(table) on the upgrade path, not only on a fresh database")
        }
        for index in Self.v4MainIndexes {
            XCTAssertTrue(try objectExists(conn, type: "index", name: index), "v4 must create \(index)")
        }
    }

    /// The other half of the acceptance criterion: a database created from nothing lands on the
    /// head schema version directly. Cheap, but it is the only test that would catch a migration
    /// statement that happens to be valid against an upgraded database and invalid against an empty
    /// one. Asserted against the computed head (not a literal) so a new migration — v5 added the
    /// profile HR columns — re-checks this property instead of pinning a number that silently goes
    /// stale.
    func testFreshDatabaseCreatesAtHeadVersion() throws {
        let db = try Database(directory: tempDir)

        XCTAssertEqual(try db.main.query("PRAGMA user_version;").first?.int("user_version"),
                       Int64(Schema.mainMigrations.map(\.version).max() ?? 0),
                       "fresh main DB must land on the head schema version (v5+)")
        for table in Self.v4MainTables {
            XCTAssertTrue(try objectExists(db.main, type: "table", name: table))
        }
        XCTAssertEqual(try db.sensitive.query("PRAGMA user_version;").first?.int("user_version"),
                       Int64(Schema.sensitiveMigrations.map(\.version).max() ?? 0),
                       "fresh sensitive DB must land on the head sensitive version (v3)")
        for table in Self.v3SensitiveTables {
            XCTAssertTrue(try objectExists(db.sensitive, type: "table", name: table))
        }
    }

    /// Sensitive v3 must land on an existing sensitive database too, and — the part worth
    /// asserting explicitly — the three new tables must be in the SENSITIVE file, not the main one.
    /// I7's guarantee is that disabling these modules is a file deletion; a journal table that
    /// drifted into `badan.db` would silently survive `purgeSensitiveNamespace()` and turn that
    /// guarantee into a lie with no visible symptom.
    func testSensitiveV3TablesLiveOnlyInTheSensitiveDatabase() throws {
        let db = try Database(directory: tempDir)

        for table in Self.v3SensitiveTables {
            XCTAssertTrue(try objectExists(db.sensitive, type: "table", name: table))
            XCTAssertFalse(try objectExists(db.main, type: "table", name: table),
                           "\(table) is sensitive-plus (I7) and must not exist in badan.db — "
                               + "purgeSensitiveNamespace() only deletes the sensitive file")
        }
    }

    /// A purge recreates the sensitive file from scratch, so it re-runs the migration list against
    /// an empty database. If v3's statements only worked as an upgrade, the first purge would
    /// leave the user with a sensitive DB missing its newest tables.
    func testPurgeRecreatesSensitiveSchemaAtV3() throws {
        let db = try Database(directory: tempDir)
        _ = try db.sensitive.run("""
            INSERT INTO journal_entries (id, behavior_id, value_kind, occurred_at, tz_id,
              source_id, ingestion_path, measured_at, measured_tz, recorded_at, ingested_at,
              updated_at, origin_device_id)
            VALUES ('j-1', 'caffeine', 'boolean', 0, 'UTC', 'manual', 'manual', 0, 'UTC', 0, 0, 0, 'dev');
            """)

        try db.purgeSensitiveNamespace()

        for table in Self.v3SensitiveTables {
            XCTAssertTrue(try objectExists(db.sensitive, type: "table", name: table),
                          "\(table) must be recreated by the post-purge re-migration")
        }
        XCTAssertEqual(try count(db.sensitive, "SELECT COUNT(*) AS c FROM journal_entries;"), 0,
                       "I7: a purge is a file deletion — nothing may survive it")
    }

    /// `route_points` deliberately carries neither provenance nor the convention columns: it
    /// inherits both from its parent route (see the migration's comment). That is a size and
    /// correctness decision, not an oversight, so it needs a test — otherwise the "obvious"
    /// cleanup of adding them back looks free.
    func testRoutePointsCarryNoProvenanceOrConventionColumns() throws {
        let db = try Database(directory: tempDir)
        let columns = Set(try db.main.query("PRAGMA table_info(route_points);").compactMap { $0.string("name") })

        XCTAssertEqual(columns, ["route_id", "seq", "lat", "lon", "altitude_m", "hacc_m", "timestamp"])
        for inherited in ["source_id", "ingestion_path", "measured_at", "updated_at",
                          "origin_device_id", "deleted_at"] {
            XCTAssertFalse(columns.contains(inherited),
                           "route_points inherits \(inherited) from workout_routes — duplicating it "
                               + "per point multiplies the table's size for no new information")
        }
        // The parent route is where I1 is actually satisfied.
        let routeColumns = Set(try db.main.query("PRAGMA table_info(workout_routes);").compactMap { $0.string("name") })
        for required in ["source_id", "ingestion_path", "measured_at", "ingested_at", "consent_snapshot"] {
            XCTAssertTrue(routeColumns.contains(required),
                          "I1: workout_routes is the provenance-bearing row for a whole trace")
        }
    }

    /// `idx_export_templates_name` is UNIQUE but partial (`WHERE deleted_at IS NULL`). Both halves
    /// matter and a plain UNIQUE(name) would pass only the first assertion: a soft-deleted
    /// template must not keep squatting on a name the user can no longer see.
    func testExportTemplateNameIsUniqueAmongLiveRowsOnly() throws {
        let db = try Database(directory: tempDir)
        func insertTemplate(_ id: String, name: String, deletedAt: Int?) throws {
            _ = try db.main.run("""
                INSERT INTO export_templates (id, name, scope, range_rule, format, aggregation,
                  layout, include_schema_docs, created_at, updated_at, origin_device_id, deleted_at)
                VALUES (?, ?, '{}', 'lastNDays', 'csv', 'raw', 'tidy', 0, 0, 0, 'dev', ?);
                """, [.text(id), .text(name), .int(deletedAt)])
        }

        try insertTemplate("t-1", name: "Weekly to Dropbox", deletedAt: nil)
        XCTAssertThrowsError(try insertTemplate("t-2", name: "Weekly to Dropbox", deletedAt: nil),
                             "two live templates must not share a name (§9.3 unique(name))")

        // Soft-delete the original, then reuse its name — the case a non-partial index would break.
        _ = try db.main.run("UPDATE export_templates SET deleted_at = 1 WHERE id = 't-1';")
        XCTAssertNoThrow(try insertTemplate("t-3", name: "Weekly to Dropbox", deletedAt: nil),
                         "a deleted template must release its name — the user cannot see the row "
                             + "holding the constraint, so the failure would be unexplainable")
    }

    /// `export_cursors` is keyed by (template_id, destination_id). SQLite allows NULL in a
    /// non-INTEGER PRIMARY KEY column and NULLs never compare equal, so this asserts the NOT NULL
    /// declarations that stop one template from accumulating duplicate "no destination" cursors,
    /// each with its own high-watermark — which would make delta exports skip or repeat ranges.
    func testExportCursorIdentityIsEnforced() throws {
        let db = try Database(directory: tempDir)
        func insertCursor(_ template: String, _ destination: SQLValue) throws {
            _ = try db.main.run("""
                INSERT INTO export_cursors (template_id, destination_id, high_watermark, updated_at)
                VALUES (?, ?, 0, 0);
                """, [.text(template), destination])
        }

        try insertCursor("t-1", .text("d-1"))
        XCTAssertThrowsError(try insertCursor("t-1", .text("d-1")),
                             "(template_id, destination_id) must be unique")
        XCTAssertNoThrow(try insertCursor("t-1", .text("d-2")), "a second destination is a distinct cursor")
        XCTAssertThrowsError(try insertCursor("t-1", .null),
                             "destination_id must be NOT NULL — a nullable PK column would let "
                                 + "unlimited 'no destination' cursors coexist under one template")
    }

    /// `resetAll()` drops every table and re-migrates from empty. It has its own fast-path hazard
    /// (BUG-03's `user_version` reset), so the newest migration is worth re-asserting through it
    /// rather than assuming the fresh-create test covers the same ground.
    func testResetAllRebuildsTheHeadSchema() throws {
        let db = try Database(directory: tempDir)
        try db.resetAll()

        XCTAssertEqual(try db.main.query("PRAGMA user_version;").first?.int("user_version"),
                       Int64(Schema.mainMigrations.map(\.version).max() ?? 0))
        for table in Self.v4MainTables {
            XCTAssertTrue(try objectExists(db.main, type: "table", name: table),
                          "\(table) must survive a reset — resetAll re-runs the full migration list")
        }
    }
}
