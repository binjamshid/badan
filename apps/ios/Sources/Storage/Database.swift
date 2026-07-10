import Foundation

/// Opens and migrates BADAN's two physical databases. The sensitive-plus namespace
/// (meds/symptoms/conditions) is a **separate file** so "disable this module" is a literal
/// file deletion, not a best-effort row purge (D-9). MVP relies on OS file-level encryption;
/// SQLCipher is a tracked future decision (ADR-0004).
final class Database {
    let main: SQLiteConnection
    private(set) var sensitive: SQLiteConnection
    let directory: URL

    static let mainFilename = "badan.db"
    static let sensitiveFilename = "badan_sensitive.db"

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        main = try SQLiteConnection(path: directory.appendingPathComponent(Self.mainFilename).path)
        sensitive = try SQLiteConnection(path: directory.appendingPathComponent(Self.sensitiveFilename).path)
        try Self.migrate(main, Schema.mainMigrations)
        try Self.migrate(sensitive, Schema.sensitiveMigrations)
    }

    /// Default on-device location: Application Support/BADAN (excluded from iCloud backup
    /// would be a later hardening step; local-first means this file IS the source of truth).
    static func applicationDefault() throws -> Database {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        return try Database(directory: base.appendingPathComponent("BADAN", isDirectory: true))
    }

    private static func migrate(_ conn: SQLiteConnection, _ migrations: [Migration]) throws {
        try conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);")
        let current = try conn.query("SELECT MAX(version) AS v FROM schema_migrations;").first?.int("v") ?? 0
        for migration in migrations where Int64(migration.version) > current {
            try conn.transaction {
                for statement in migration.statements { try conn.execute(statement) }
                try conn.run("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);",
                             [.int(migration.version), .date(Date())])
            }
        }
    }

    /// Purge the sensitive-plus namespace by deleting its file and recreating it empty. The
    /// main DB is untouched. This is the mechanical guarantee behind "hide Medications".
    func purgeSensitiveNamespace() throws {
        // Drop our reference so the connection closes, then remove the WAL set.
        sensitive = try SQLiteConnection(path: directory.appendingPathComponent("__closing__.tmp").path)
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent(Self.sensitiveFilename + suffix)
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("__closing__.tmp"))
        sensitive = try SQLiteConnection(path: directory.appendingPathComponent(Self.sensitiveFilename).path)
        try Self.migrate(sensitive, Schema.sensitiveMigrations)
    }

    /// Developer reset: wipe both databases and recreate empty schemas. Used by the
    /// "reset demo data" affordance and the reset script.
    func resetAll() throws {
        try purgeSensitiveNamespace()
        // Recreate main by dropping every user table then re-migrating.
        let tables = try main.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
        try main.transaction {
            try main.execute("PRAGMA foreign_keys = OFF;")
            for row in tables { if let name = row.string("name") { try main.execute("DROP TABLE IF EXISTS \"\(name)\";") } }
            try main.execute("PRAGMA foreign_keys = ON;")
        }
        try Self.migrate(main, Schema.mainMigrations)
    }
}
