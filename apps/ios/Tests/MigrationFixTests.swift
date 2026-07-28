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

    // MARK: - v8: reports (§9.12 / EPIC-31) + notification_deliveries (EPIC-32 budget ledger)

    private static let v8MainTables = ["reports", "notification_deliveries"]
    private static let v8MainIndexes = ["idx_reports_period_algorithm", "idx_notification_deliveries_class_scheduled"]

    /// The acceptance case for v8: a database that already holds real v7 rows (a hydration ledger
    /// entry, a raw sample) must reach v8 with every one of those rows intact. v8 is additive by
    /// construction (CREATEs only), and this holds that property in place — an edit that "just
    /// tidies up" an existing table inside v8 breaks this test rather than a user's database.
    func testMigratingPopulatedV7DatabaseToV8PreservesData() throws {
        let conn = try connection(atSchemaVersion: 7)
        _ = try conn.run("""
            INSERT INTO raw_samples (id, metric_id, value, unit, original_value, original_unit,
              start_at, tz_id, source_id, ingestion_path, external_id, measured_at, measured_tz,
              recorded_at, ingested_at, updated_at, origin_device_id)
            VALUES ('r-1', 'heart_rate', 60, 'count/min', 60, 'count/min', 0, 'UTC', 'watch-1',
              'platformStore', 'hk-1', 0, 'UTC', 0, 0, 100, 'dev');
            """)
        _ = try conn.run("""
            INSERT INTO hydration_entries (id, volume_ml, fluid_type, occurred_at, tz_id, original_id,
              revision, source_id, ingestion_path, measured_at, measured_tz, recorded_at, ingested_at,
              updated_at, origin_device_id)
            VALUES ('h-1', 500, 'water', 0, 'UTC', 'h-1', 1, 'manual', 'manual', 0, 'UTC', 0, 0, 100, 'dev');
            """)

        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM raw_samples;"), 1,
                       "v8 is additive — an upgrade must not touch existing rows")
        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM hydration_entries;"), 1,
                       "v8 is additive — an upgrade must not touch existing rows")
        for table in Self.v8MainTables {
            XCTAssertTrue(try objectExists(conn, type: "table", name: table),
                          "v8 must create \(table) on the upgrade path, not only on a fresh database")
        }
        for index in Self.v8MainIndexes {
            XCTAssertTrue(try objectExists(conn, type: "index", name: index), "v8 must create \(index)")
        }
        XCTAssertEqual(try conn.query("PRAGMA user_version;").first?.int("user_version"),
                       Int64(Schema.mainMigrations.map(\.version).max() ?? 0),
                       "the upgraded database must land on the v8 head")
    }

    /// `idx_reports_period_algorithm` is UNIQUE but partial (`WHERE deleted_at IS NULL`). Both halves
    /// matter: two live reports must not share a (period, algorithm) identity, but a soft-deleted
    /// report must release that identity so the user can regenerate a report they deleted — the same
    /// shape `idx_export_templates_name` uses, for the same reason. Reports are derived and
    /// regenerable, so unlike `baselines` this is intentionally NOT append-only.
    func testReportsIdentityIsUniqueAmongLiveRowsOnly() throws {
        let db = try Database(directory: tempDir)
        func insertReport(_ id: String, periodKey: String, algorithmVersion: String, deletedAt: Int?) throws {
            _ = try db.main.run("""
                INSERT INTO reports (id, period_key, generated_at, algorithm_version_id,
                  sections_included, sha256, updated_at, origin_device_id, deleted_at)
                VALUES (?, ?, 0, ?, '[]', 'model-sha', 0, 'dev', ?);
                """, [.text(id), .text(periodKey), .text(algorithmVersion), .int(deletedAt)])
        }

        try insertReport("rep-1", periodKey: "week:2026-W29", algorithmVersion: "v1", deletedAt: nil)
        XCTAssertThrowsError(try insertReport("rep-2", periodKey: "week:2026-W29", algorithmVersion: "v1", deletedAt: nil),
                             "two live reports must not share (period_key, algorithm_version_id)")
        XCTAssertNoThrow(try insertReport("rep-3", periodKey: "week:2026-W29", algorithmVersion: "v2", deletedAt: nil),
                         "a new algorithm version is a genuinely different report, not a duplicate")

        // Soft-delete the original, then regenerate the same period+version — the case a non-partial
        // index would wrongly block over a row the user can no longer see.
        _ = try db.main.run("UPDATE reports SET deleted_at = 1 WHERE id = 'rep-1';")
        XCTAssertNoThrow(try insertReport("rep-4", periodKey: "week:2026-W29", algorithmVersion: "v1", deletedAt: nil),
                         "a deleted report must release its (period, version) identity so it can be regenerated")
    }

    /// Both v8 tables are DERIVED/operational, not measurements: `reports` is a rollup BADAN computed
    /// from provenance-bearing rows, and `notification_deliveries` is value-free scheduling metadata.
    /// So neither carries the provenance struct (I1 is satisfied by their inputs), but both DO carry
    /// the convention columns (D-7) — a report is user-deletable and reconcilable, a queued delivery
    /// transitions state. Asserting the exact column set catches an "obvious" cleanup that adds either
    /// the wrong columns back.
    func testV8TablesCarryConventionColumnsButNoProvenance() throws {
        let db = try Database(directory: tempDir)
        let reportCols = Set(try db.main.query("PRAGMA table_info(reports);").compactMap { $0.string("name") })
        XCTAssertEqual(reportCols, ["id", "period_key", "generated_at", "algorithm_version_id",
                                    "sections_included", "artifact_path", "sha256",
                                    "updated_at", "origin_device_id", "deleted_at"])

        let deliveryCols = Set(try db.main.query("PRAGMA table_info(notification_deliveries);").compactMap { $0.string("name") })
        XCTAssertEqual(deliveryCols, ["id", "notification_class", "scheduled_for", "delivered_at",
                                      "outcome", "updated_at", "origin_device_id", "deleted_at"])

        for provenance in ["source_id", "measured_at", "ingested_at", "ingestion_path", "device_id"] {
            XCTAssertFalse(reportCols.contains(provenance),
                           "reports is derived — a \(provenance) column would claim provenance it has not (I1)")
            XCTAssertFalse(deliveryCols.contains(provenance),
                           "a notification-log row is metadata — \(provenance) does not belong (EPIC-32 value-free)")
        }
        // The notification ledger stores no health value at all — it is metadata by contract.
        XCTAssertFalse(deliveryCols.contains("value"),
                       "notification_deliveries is value-free: 'readiness summary at 07:00' is metadata, the score is not stored")
    }

    /// The budget/cap counting query the ledger exists for must actually run against the shipped
    /// schema: count this class's deliveries in a scheduled-for window. This is a smoke test of the
    /// column names + index target, not of EPIC-32's engine logic.
    func testNotificationDeliveriesBacksTheBudgetCountQuery() throws {
        let db = try Database(directory: tempDir)
        func insertDelivery(_ id: String, _ notificationClass: String, scheduledFor: Int, outcome: String) throws {
            _ = try db.main.run("""
                INSERT INTO notification_deliveries (id, notification_class, scheduled_for, outcome,
                  updated_at, origin_device_id)
                VALUES (?, ?, ?, ?, 0, 'dev');
                """, [.text(id), .text(notificationClass), .int(scheduledFor), .text(outcome)])
        }

        try insertDelivery("n-1", "readiness", scheduledFor: 100, outcome: "delivered")
        try insertDelivery("n-2", "readiness", scheduledFor: 200, outcome: "scheduled")
        try insertDelivery("n-3", "windDown", scheduledFor: 150, outcome: "delivered")

        let readinessInWindow = try count(db.main, """
            SELECT COUNT(*) AS c FROM notification_deliveries
            WHERE notification_class = 'readiness' AND scheduled_for BETWEEN 0 AND 300;
            """)
        XCTAssertEqual(readinessInWindow, 2, "the ledger must count queued + delivered rows of a class in a window")
    }

    // MARK: - v11: D-35 drops metric_pins, D-36 adds feedback + calibrations

    /// **The failure mode this file exists for.** `Database.migrate` runs
    /// `where migration.version > current`, so a migration numbered at or below the highest one an
    /// install has already applied is silently skipped — no error, no log. The main array was
    /// already at 10 (`data_conflicts`), so numbering this one 10 would have worked perfectly on
    /// every fresh simulator and created nothing at all on every device in the field.
    ///
    /// Driving the schema to 10 first is what makes this test able to see that.
    func testMigratingFromV10CreatesTheFeedbackAndCalibrationTablesAndDropsMetricPins() throws {
        let conn = try connection(atSchemaVersion: 10)
        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='metric_pins';"), 1,
                       "precondition: a v10 database still has the table v11 removes")

        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='metric_pins';"), 0,
                       "metric_pins survived v11")
        for table in ["derived_feedback", "metric_calibrations"] {
            XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='\(table)';"), 1,
                           "\(table) was not created on an upgrade from v10. If this migration is "
                           + "numbered at or below an already-applied version, migrate() skips it "
                           + "silently — green on a fresh install, absent on every real device.")
        }
    }

    /// A dropped table must not take the user's preferences with it. `metric_pins` had no callers,
    /// but `customization_profile` — where D-35's pins actually live — is in the same database.
    func testDroppingMetricPinsLeavesTheCustomizationProfileIntact() throws {
        let conn = try connection(atSchemaVersion: 10)
        _ = try conn.run("INSERT INTO customization_profile (id, json) VALUES (1, ?);",
                         [.text(#"{"language":"ar"}"#)])

        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertEqual(try count(conn, "SELECT COUNT(*) AS c FROM customization_profile;"), 1,
                       "v11 disturbed the profile row while dropping an unrelated table")
    }

    /// Every migration version must be unique and ascending. A duplicate is the C1 failure mode in
    /// its most direct form, and it is cheaper to assert than to rediscover.
    func testMainMigrationVersionsAreUniqueAndAscending() {
        let versions = Schema.mainMigrations.map(\.version)
        XCTAssertEqual(versions, versions.sorted(), "migrations must be listed in ascending order")
        XCTAssertEqual(Set(versions).count, versions.count,
                       "duplicate migration version: migrate() runs `version > current`, so the "
                       + "second copy never executes on an install that already applied the first.")
    }
}
