import Foundation

/// Opens and migrates BADAN's two physical databases. The sensitive-plus namespace
/// (meds/symptoms/conditions) is a **separate file** so "disable this module" is a literal
/// file deletion, not a best-effort row purge (D-9). MVP relies on OS file-level encryption;
/// SQLCipher is a tracked future decision (ADR-0004).
final class Database {
    let main: SQLiteConnection
    let sensitive: SQLiteConnection
    let directory: URL

    static let mainFilename = "badan.db"
    static let sensitiveFilename = "badan_sensitive.db"

    /// Designated init: opens both connections at explicit paths, migrates, and (only when
    /// `hardenDirectory` is set) applies the backup/protection hardening below. Factored out of
    /// `init(directory:)` so `inMemoryFallback()` (EDGE-05) can share the open+migrate logic
    /// without a real on-disk directory to create or protect.
    private init(mainPath: String, sensitivePath: String, directory: URL, hardenDirectory: Bool) throws {
        self.directory = directory
        main = try SQLiteConnection(path: mainPath)
        sensitive = try SQLiteConnection(path: sensitivePath)
        // Only takes effect on a database with no tables yet (i.e. first-ever creation, before
        // `migrate` below runs); a harmless no-op on an already-migrated database (PERF-113).
        // Already-shipped installs with existing data need a separate one-time VACUUM-based
        // migration to actually reclaim space, which is out of scope until any exist.
        try main.execute("PRAGMA auto_vacuum = INCREMENTAL;")
        try sensitive.execute("PRAGMA auto_vacuum = INCREMENTAL;")
        try Self.migrate(main, Schema.mainMigrations)
        try Self.migrate(sensitive, Schema.sensitiveMigrations)
        if hardenDirectory { Self.applyHardening(to: directory) }
    }

    convenience init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.init(mainPath: directory.appendingPathComponent(Self.mainFilename).path,
                     sensitivePath: directory.appendingPathComponent(Self.sensitiveFilename).path,
                     directory: directory, hardenDirectory: true)
    }

    /// EDGE-05: last-resort fallback for `AppEnvironment.makeDefault()` when even a scratch temp
    /// directory can't be opened — an in-memory SQLite database has no filesystem dependency at
    /// all, so the app can still boot (with a visible warning — see `AppEnvironment.
    /// isStorageFallback`) instead of crashing via `try!`. `directory` is a label only here;
    /// nothing is ever written under it, and nothing survives process exit.
    static func inMemoryFallback() throws -> Database {
        try Database(mainPath: ":memory:", sensitivePath: ":memory:",
                    directory: FileManager.default.temporaryDirectory.appendingPathComponent("BADAN-inmemory"),
                    hardenDirectory: false)
    }

    /// Best-effort, non-fatal hardening applied after the databases exist (COMP-05): exclude the
    /// BADAN directory (and therefore both DB files + their -wal/-shm siblings) from iCloud/device
    /// backup, and set file protection. Failures here must never take down the open path — a health
    /// app that can't launch because a backup flag couldn't be set is worse than one that launches
    /// with the flag unset, so every step below is `try?`.
    private static func applyHardening(to directory: URL) {
        var mutableDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(resourceValues)

        // `.completeUntilFirstUserAuthentication` (not `.complete`): `.complete` makes the files
        // unreadable whenever the device is locked, which would break any future background
        // ingest/maintenance (see performBackgroundMaintenance) that runs while the phone is
        // locked but has been unlocked at least once since boot.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        if let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for fileURL in contents {
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: fileURL.path
                )
            }
        }
    }

    /// Default on-device location: Application Support/BADAN. The directory (and thus both DB
    /// files and their -wal/-shm siblings) is excluded from iCloud/device backup and protected
    /// with `.completeUntilFirstUserAuthentication` — see `applyHardening` (COMP-05). Local-first
    /// means this file IS the source of truth, so it must not silently leave the device via backup.
    static func applicationDefault() throws -> Database {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        return try Database(directory: base.appendingPathComponent("BADAN", isDirectory: true))
    }

    /// Internal rather than private (F3) so migration tests can drive a connection to an OLD
    /// schema version — pass a truncated `migrations` list, write the era-appropriate rows, then
    /// run the full list to exercise the real upgrade. There is no other way to build a
    /// dirty-old-database fixture: `init` always migrates straight to the newest version.
    static func migrate(_ conn: SQLiteConnection, _ migrations: [Migration]) throws {
        let targetVersion = Int64(migrations.map(\.version).max() ?? 0)
        // Fast path (PERF-111): `PRAGMA user_version` is a single integer read from the file
        // header, free compared to a table-existence check + `SELECT MAX(version)` — when it
        // already matches the schema this connection expects, skip both entirely. Installs
        // that predate this change read 0 here, fall through to the full path once, and get
        // `user_version` stamped at the end so every later launch takes the fast path.
        if let cached = try conn.query("PRAGMA user_version;").first?.int("user_version"), cached == targetVersion {
            return
        }
        try conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);")
        let current = try conn.query("SELECT MAX(version) AS v FROM schema_migrations;").first?.int("v") ?? 0
        for migration in migrations where Int64(migration.version) > current {
            try conn.transaction {
                for statement in migration.statements { try conn.execute(statement) }
                try conn.run("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);",
                             [.int(migration.version), .date(Date())])
            }
        }
        try conn.execute("PRAGMA user_version = \(targetVersion);")
    }

    /// Purge the sensitive-plus namespace by deleting its file and recreating it empty. The
    /// main DB is untouched. This is the mechanical guarantee behind "hide Medications".
    ///
    /// The `sensitive` connection **object is preserved** (its handle is closed, the files are
    /// deleted, then the handle is reopened) so repositories already holding a reference to it
    /// keep working after the purge — otherwise sensitive logging would silently break.
    func purgeSensitiveNamespace() throws {
        sensitive.closeHandle()
        let mainURL = directory.appendingPathComponent(Self.sensitiveFilename)
        // EDGE-01: a failed delete of the *main* sensitive file must not be swallowed — the
        // whole point of this method is "medications/symptoms are gone from this device," and
        // `try?` here used to let that claim be false with no trace. Missing `-wal`/`-shm`
        // siblings are still tolerated (very common — nothing to check in) via `try?` below.
        var removeError: Error?
        if FileManager.default.fileExists(atPath: mainURL.path) {
            do { try FileManager.default.removeItem(at: mainURL) } catch { removeError = error }
        }
        for suffix in ["-wal", "-shm"] {
            let url = directory.appendingPathComponent(Self.sensitiveFilename + suffix)
            try? FileManager.default.removeItem(at: url)
        }
        // Reopen (and re-migrate) regardless of whether the delete above succeeded, so the
        // connection — and every repository already holding a reference to it — stays usable
        // either way; a failed purge must not also leave sensitive logging broken for the rest
        // of the session. If the file wasn't actually removed, `migrate` just sees its existing
        // (already up to date) schema and no-ops.
        try sensitive.reopen()
        // The reopened file is brand new, so it needs the same first-creation pragma `init`
        // sets (PERF-113) — otherwise every purge would silently revert this db to auto_vacuum=NONE.
        try sensitive.execute("PRAGMA auto_vacuum = INCREMENTAL;")
        try Self.migrate(sensitive, Schema.sensitiveMigrations)
        if let removeError { throw removeError }
    }

    /// Developer reset: wipe both databases and recreate empty schemas. Used by the
    /// "reset demo data" affordance and the reset script.
    ///
    /// EDGE-08: no `PRAGMA foreign_keys = OFF/ON` around the drops — SQLite ignores toggling
    /// that pragma mid-transaction anyway, and this schema has zero foreign keys to begin with,
    /// so the old pair of statements was a no-op either way.
    func resetAll() throws {
        try purgeSensitiveNamespace()
        // Recreate main by dropping every user table then re-migrating. This intentionally
        // includes `schema_migrations` itself (it isn't `sqlite_`-prefixed) — a reset is meant
        // to be a full re-migration from empty, and since there has only ever been a handful of
        // forward-only migration versions, replaying all of them from scratch is safe (OPT-189).
        let tables = try main.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
        try main.transaction {
            for row in tables { if let name = row.string("name") { try main.execute("DROP TABLE IF EXISTS \"\(name)\";") } }
            // BUG-03: `PRAGMA user_version` writes are transactional in SQLite, so resetting it
            // *inside* the same transaction as the drops means a crash between the two can never
            // happen — either both land, or (on rollback) neither does. Previously this ran as a
            // separate statement after `COMMIT`, so a crash in between left a permanently
            // schema-less database whose stale nonzero `user_version` made `migrate`'s PERF-111
            // fast path wrongly skip recreating the schema that was just dropped.
            try main.execute("PRAGMA user_version = 0;")
        }
        try Self.migrate(main, Schema.mainMigrations)
        // Reclaim the physical space freed by the drops above so repeated dev/QA resets don't
        // silently bloat the file (PERF-114); safe here since resetAll always runs outside any
        // caller-held transaction and the DB is momentarily near-empty.
        try main.execute("VACUUM;")
    }

    /// Delete only *ingested* measurement data — sources/devices, raw samples, interval
    /// records, sleep sessions, derived values, baselines, insights, and dedup bookkeeping —
    /// leaving every manual-log table (workouts/nutrition/notes), `customization_profile`,
    /// `goals`, `metric_pins`, `export_jobs`, and the whole sensitive DB untouched (BUG-01).
    ///
    /// Used by `AppEnvironment.connectHealthKit()`'s post-authorization backfill in place of
    /// `resetAll()`, which used to wipe *both* databases — deleting a user's own logged
    /// medications, symptoms, workouts, nutrition, and notes just because they connected Apple
    /// Health. This purges exactly the tables a real backfill needs to start clean from (a
    /// stale `read_anchors` row would otherwise make `HealthKitAdapter`'s incremental resume
    /// silently skip history) and nothing else.
    ///
    /// Same ordering discipline as `resetAll` (BUG-03): a single transaction, no interstitial
    /// pragma to reset (there's no schema drop/re-migrate here, just row deletes).
    ///
    /// (F2) The three *measurement* tables are purged by `ingestion_path`, not wholesale. They
    /// hold user-entered rows as well as ingested ones — a quick-logged weight is a `RawSample`
    /// with `ingestionPath: .manual` in `raw_samples` (`LogHubScreen.logWeight`), not a row in
    /// some manual-only table — so the old unconditional `DELETE FROM raw_samples` deleted the
    /// user's own logged weight history the moment they connected Apple Health. That is the exact
    /// class of loss BUG-01 set out to stop; it just missed that "manual log" and "manual-log
    /// table" aren't the same set. `.manual` is the only path a human types in
    /// (`IngestionPath`), so excluding it keeps every ingested/demo/derived row in scope while
    /// leaving anything the user entered by hand alone.
    ///
    /// Both callers want this: `connectHealthKit()` must not charge the user their own logs for
    /// connecting, and `SeedController.markStartEmpty` only needs the *demo seed* gone — which is
    /// written through `FakeHealthStore`/`IngestionPipeline` as `.platformStore`, so no demo row
    /// is `.manual` and none survives the predicate.
    func purgeIngestedData() throws {
        // Tables with no `ingestion_path` column: bookkeeping, catalogs, and BADAN-derived rows,
        // none of which a user can enter by hand. All are rebuilt by the backfill/derive chain.
        let ingestedOnlyTables = ["dedup_decisions", "insights", "baselines", "input_manifests",
                                  "derived_values", "read_anchors", "source_devices", "sources"]
        // Tables carrying `provenanceCols` (see `Schema`), which mix ingested and manual rows.
        let measurementTables = ["sessions", "interval_records", "raw_samples"]
        let manualPath = IngestionPath.manual.rawValue
        try main.transaction {
            for table in ingestedOnlyTables { try main.execute("DELETE FROM \"\(table)\";") }
            // Ahead of `sessions`, and scoped to the sessions actually being deleted: this table
            // has no `ingestion_path` of its own, so wiping it wholesale would strip the stages
            // off any session the predicate below preserves. Nothing writes a `.manual` session
            // today, which makes this a no-op in practice — but a stage-less orphan session is
            // the kind of silent corruption that only shows up long after the change that caused
            // it, so the delete follows the sessions it belongs to rather than assuming.
            try main.execute("""
                DELETE FROM session_stages WHERE session_id IN (
                  SELECT id FROM sessions WHERE ingestion_path != '\(manualPath)'
                );
                """)
            for table in measurementTables {
                try main.execute("DELETE FROM \"\(table)\" WHERE ingestion_path != '\(manualPath)';")
            }
        }
        // Reclaim space freed by the deletes above (PERF-114's rationale applies equally here).
        try main.execute("VACUUM;")
    }

    /// Delete the main-DB manual-log tables (workouts/nutrition/notes) — used *only* once, the
    /// first time `connectHealthKit()` runs after a bootstrap demo-seed, per the `demoSeedActive`
    /// flag `SeedController.seed()` sets (BUG-01's documented exception: a connected user's
    /// *first* connect also clears whatever demo manual logs bootstrap seeded before onboarding
    /// even reached the connect screen). Medications/symptoms are cleared via
    /// `purgeSensitiveNamespace()` alongside this, not here — they live in the sensitive DB.
    ///
    /// Never called once `demoSeedActive` is cleared, so a connected user's own manual logs
    /// (entered after that point) are never at risk from this path.
    func purgeDemoManualLogs() throws {
        try main.transaction {
            for table in ["workout_entries", "nutrition_entries", "note_entries"] {
                try main.execute("DELETE FROM \"\(table)\";")
            }
        }
    }

    // MARK: - Maintenance (PERF-112, PERF-113, PERF-121, PERF-122, PERF-198, PERF-199)

    /// Fold the WAL back into each database's main file. `truncate: true` also shrinks the
    /// `-wal` file to zero bytes; passive checkpoints are safe to call opportunistically after
    /// large write batches (post-seed, post-ingest) without blocking readers (PERF-112).
    func checkpoint(truncate: Bool = false) throws {
        let mode = truncate ? "TRUNCATE" : "PASSIVE"
        try main.execute("PRAGMA wal_checkpoint(\(mode));")
        try sensitive.execute("PRAGMA wal_checkpoint(\(mode));")
    }

    /// Reclaim space freed by soft-deleted/suppressed rows once `auto_vacuum = INCREMENTAL` is
    /// active (PERF-113). Cheap to call opportunistically after large suppress/delete batches
    /// (e.g. post-dedup); a no-op if auto_vacuum never took effect for this file.
    func incrementalVacuum(pages: Int = 100) throws {
        try main.execute("PRAGMA incremental_vacuum(\(pages));")
        try sensitive.execute("PRAGMA incremental_vacuum(\(pages));")
    }

    /// Single Storage-layer entry point for background-transition maintenance: checkpoints the
    /// WAL and refreshes planner statistics on both databases (PERF-112, PERF-121, PERF-198).
    /// The `UIApplication` background-transition hook that calls this belongs to the App layer.
    /// Best-effort by design — maintenance failing should never crash a backgrounding app.
    func performBackgroundMaintenance() {
        try? checkpoint(truncate: true)
        try? main.execute("PRAGMA optimize;")
        try? sensitive.execute("PRAGMA optimize;")
    }

    /// On-disk size (bytes) of each database, including its `-wal`/`-shm` siblings — the
    /// minimal instrumentation needed to observe storage growth in the field (PERF-122).
    func diskUsage() throws -> (main: Int64, sensitive: Int64) {
        func size(of filename: String) -> Int64 {
            var total: Int64 = 0
            for suffix in ["", "-wal", "-shm"] {
                let path = directory.appendingPathComponent(filename + suffix).path
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let bytes = attrs[.size] as? Int64 {
                    total += bytes
                }
            }
            return total
        }
        return (size(of: Self.mainFilename), size(of: Self.sensitiveFilename))
    }

    /// Combined footprint across both databases — the single number a future "storage used"
    /// Settings row would actually show, without callers needing to know about the two-file
    /// main/sensitive split (PERF-199).
    func totalDiskUsage() throws -> Int64 {
        let usage = try diskUsage()
        return usage.main + usage.sensitive
    }
}
