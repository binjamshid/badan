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

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        main = try SQLiteConnection(path: directory.appendingPathComponent(Self.mainFilename).path)
        sensitive = try SQLiteConnection(path: directory.appendingPathComponent(Self.sensitiveFilename).path)
        // Only takes effect on a database with no tables yet (i.e. first-ever creation, before
        // `migrate` below runs); a harmless no-op on an already-migrated database (PERF-113).
        // Already-shipped installs with existing data need a separate one-time VACUUM-based
        // migration to actually reclaim space, which is out of scope until any exist.
        try main.execute("PRAGMA auto_vacuum = INCREMENTAL;")
        try sensitive.execute("PRAGMA auto_vacuum = INCREMENTAL;")
        try Self.migrate(main, Schema.mainMigrations)
        try Self.migrate(sensitive, Schema.sensitiveMigrations)
        Self.applyHardening(to: directory)
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

    private static func migrate(_ conn: SQLiteConnection, _ migrations: [Migration]) throws {
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
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent(Self.sensitiveFilename + suffix)
            try? FileManager.default.removeItem(at: url)
        }
        try sensitive.reopen()
        // The reopened file is brand new, so it needs the same first-creation pragma `init`
        // sets (PERF-113) — otherwise every purge would silently revert this db to auto_vacuum=NONE.
        try sensitive.execute("PRAGMA auto_vacuum = INCREMENTAL;")
        try Self.migrate(sensitive, Schema.sensitiveMigrations)
    }

    /// Developer reset: wipe both databases and recreate empty schemas. Used by the
    /// "reset demo data" affordance and the reset script.
    func resetAll() throws {
        try purgeSensitiveNamespace()
        // Recreate main by dropping every user table then re-migrating. This intentionally
        // includes `schema_migrations` itself (it isn't `sqlite_`-prefixed) — a reset is meant
        // to be a full re-migration from empty, and since there has only ever been a handful of
        // forward-only migration versions, replaying all of them from scratch is safe (OPT-189).
        let tables = try main.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
        try main.transaction {
            try main.execute("PRAGMA foreign_keys = OFF;")
            for row in tables { if let name = row.string("name") { try main.execute("DROP TABLE IF EXISTS \"\(name)\";") } }
            try main.execute("PRAGMA foreign_keys = ON;")
        }
        // `PRAGMA user_version` lives in the file header, not a table, so dropping every table
        // above does NOT reset it — without this, migrate()'s PERF-111 fast path would see the
        // stale version number and wrongly skip recreating the schema we just dropped.
        try main.execute("PRAGMA user_version = 0;")
        try Self.migrate(main, Schema.mainMigrations)
        // Reclaim the physical space freed by the drops above so repeated dev/QA resets don't
        // silently bloat the file (PERF-114); safe here since resetAll always runs outside any
        // caller-held transaction and the DB is momentarily near-empty.
        try main.execute("VACUUM;")
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
