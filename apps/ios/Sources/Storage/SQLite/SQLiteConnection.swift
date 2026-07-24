import Foundation
// D-23/A16 (ADR-0010 §A16): `import SQLCipher` rather than `import SQLite3`. SQLCipher.swift
// (Zetetic's own official package) ships a drop-in-compatible sqlite3 C API — same symbol names
// (`sqlite3_open_v2`, `sqlite3_exec`, …), same behavior for any connection that never calls
// `sqlite3_key`. Only ONE sqlite3 C implementation can be linked into the app at a time (both a
// system `libsqlite3` and SQLCipher's statically-linked archive would each define the same
// `sqlite3_*` symbols, which the linker cannot resolve twice) — so this import change is what
// makes `SQLiteConnection` the single seam ADR-0005 named for this swap: EVERY `sqlite3_*` call
// in the app now runs through SQLCipher's implementation, but `main` (`badan.db`, D-23 scope:
// unaffected) is opened with `key: nil` below and never calls `sqlite3_key` — its open flags,
// PRAGMAs, and resulting file format are byte-for-byte identical to before this change. Only
// `sensitive` (`badan_sensitive.db`, wired in `Database.swift`) is ever constructed with a key.
import SQLCipher

/// A minimal, dependency-free* wrapper over the SQLite3 C API.
///
/// BADAN deliberately uses raw SQLite rather than an ORM (ADR-0005): the plan's storage
/// design is expressed as raw DDL with explicit provenance columns and named indexes, and
/// an offline, zero-dependency build eliminates a whole risk class (package resolution) for
/// a local-first app. This wrapper is the single seam a future GRDB/SQLCipher swap targets.
///
/// *One exception, deliberate and scoped (D-23/A16): the C library backing every call in this
/// file is now SQLCipher's, not the system's, so that a `key` can be supplied for
/// `badan_sensitive.db`. See the `import` comment above for why that is unavoidable, and why it
/// does not change `badan.db`'s own behavior.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()   // serialize all access to this connection
    let path: String
    /// The SQLCipher key this connection was constructed with, or `nil` for a plain (unencrypted)
    /// connection — `main` (`badan.db`) always passes `nil` here; only `sensitive`
    /// (`badan_sensitive.db`) ever passes a real key. Re-applied on every `openHandle()` call —
    /// both the initial open AND every `reopen()` after `purgeSensitiveNamespace()` deletes the
    /// file — so a purge-then-recreate transparently produces a freshly-encrypted empty file with
    /// the SAME key, with no special-casing needed at the `Database.purgeSensitiveNamespace()`
    /// call site.
    private let key: Data?

    // SQLite wants a copy of bound text/blob, not our transient Swift buffer.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // PERF-101/PERF-109: prepared-statement cache keyed by SQL text, so repeated identical SQL
    // shapes (every upsert, every listing query) pay `sqlite3_prepare_v2` once instead of on
    // every call; the resolved column-name array is cached alongside the statement since it
    // can't change across `reset()` calls for the same prepared statement.
    private var statementCache: [String: (stmt: OpaquePointer, columnNames: [String])] = [:]

    // OPT-186: tracks same-thread transaction nesting (the recursive lock allows it) so a
    // nested `transaction { ... transaction { ... } ... }` call joins the outer transaction
    // instead of issuing a second `BEGIN IMMEDIATE` and failing with a generic SQL error.
    private var transactionDepth = 0

    /// - Parameter key: `nil` (the default) opens a plain, unencrypted connection — the exact
    ///   behavior this initializer always had before D-23/A16, preserved verbatim for `main`.
    ///   A non-nil value keys the connection immediately after open, before any other statement
    ///   runs, via SQLCipher's raw-key form (`SQLCipherKeySpec`) — used only for `sensitive`.
    ///   Callers are responsible for ensuring a pre-existing plaintext file at `path` has already
    ///   been converted (`SensitiveDatabaseMigrator`) before ever passing a key here: keying an
    ///   connection to a file that already contains plaintext pages does NOT retroactively
    ///   encrypt them, it just makes every existing page unreadable.
    init(path: String, key: Data? = nil) throws {
        self.path = path
        self.key = key
        try openHandle()
    }

    private func openHandle() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.openFailed(path: path, message: message)
        }
        // Must happen before any other statement — including the PRAGMAs immediately below —
        // since an unkeyed statement against an encrypted file (or vice versa) fails.
        if let key { try applyKey(key) }
        // Durable + concurrent-friendly defaults for a local store.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA busy_timeout = 3000;")
        // PERF-104: BADAN's temp b-trees (14-day baseline windows, per-metric exports) are
        // small, so keeping them in memory instead of spilling to disk is safe unconditionally.
        // cache_size/mmap_size are left at SQLite defaults pending real-device benchmarking.
        try execute("PRAGMA temp_store = MEMORY;")
    }

    /// Stages `key` on the just-opened handle via SQLCipher's raw-key form, then forces a genuine
    /// page read to actually PROVE the key is correct. `sqlite3_key()` alone always returns
    /// `SQLITE_OK` — even for a wrong key, or a key applied to a plaintext file — because it only
    /// stores the key for later use; SQLCipher does not attempt to decrypt anything until the
    /// first real page read, which is exactly why that read cannot be deferred to whatever query
    /// a caller happens to run first (a bare `sqlite3_key` failure would otherwise surface as a
    /// confusing, unrelated-looking error deep inside some later repository call).
    private func applyKey(_ key: Data) throws {
        let keySpec = SQLCipherKeySpec.string(for: key)
        let keyResult = sqlite3_key(handle, keySpec, Int32(keySpec.utf8CString.count))
        guard keyResult == SQLITE_OK else {
            throw SQLiteError.keyFailed(path: path, message: lastMessage())
        }
        guard sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.keyFailed(path: path, message: lastMessage())
        }
    }

    /// Close the underlying handle (so the file can be deleted) without destroying this object,
    /// so repositories holding a reference stay valid across a purge/reset.
    func closeHandle() {
        lock.lock(); defer { lock.unlock() }
        clearStatementCache()
        if let handle { sqlite3_close_v2(handle); self.handle = nil }
    }

    /// Reopen the same path after `closeHandle()` (e.g. the file was deleted). Object identity is
    /// preserved, so existing repository references keep working.
    func reopen() throws {
        lock.lock(); defer { lock.unlock() }
        clearStatementCache()
        if handle != nil { sqlite3_close_v2(handle); handle = nil }
        try openHandle()
    }

    deinit {
        for cached in statementCache.values { sqlite3_finalize(cached.stmt) }
        if let handle { sqlite3_close_v2(handle) }
    }

    private func clearStatementCache() {
        for cached in statementCache.values { sqlite3_finalize(cached.stmt) }
        statementCache.removeAll()
    }

    // MARK: - Execute (no results)

    func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var errPtr: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errPtr) != SQLITE_OK {
            let message = errPtr.map { String(cString: $0) } ?? lastMessage()
            sqlite3_free(errPtr)
            throw SQLiteError.execFailed(sql: sql, message: message)
        }
    }

    /// Run a parameterized statement that returns no rows (INSERT/UPDATE/DELETE).
    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let (stmt, _) = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(sql: sql, message: lastMessage())
        }
        return Int(sqlite3_changes(handle))
    }

    /// Run a parameterized query and materialize all rows.
    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLiteRow] {
        lock.lock(); defer { lock.unlock() }
        let (stmt, names) = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(params, to: stmt)

        let columnCount = names.count
        var rows: [SQLiteRow] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError.stepFailed(sql: sql, message: lastMessage())
            }
            var values: [String: SQLValue] = [:]
            for i in 0..<columnCount {
                values[names[i]] = readColumn(stmt, Int32(i))
            }
            rows.append(SQLiteRow(values: values))
        }
        return rows
    }

    /// Run a parameterized query, reading columns positionally off the raw statement inside
    /// `map` — avoids building a `[String: SQLValue]` dictionary per row for hot-path readers
    /// that already know their column shape by index (PERF-102).
    func query<T>(_ sql: String, _ params: [SQLValue] = [], map: (OpaquePointer) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let (stmt, _) = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(params, to: stmt)

        var results: [T] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError.stepFailed(sql: sql, message: lastMessage())
            }
            results.append(map(stmt))
        }
        return results
    }

    /// Execute a block inside an IMMEDIATE transaction; rolls back on any thrown error. Same-
    /// thread nested calls (allowed by the recursive lock) join the outer transaction rather
    /// than issuing a second `BEGIN IMMEDIATE` (OPT-186).
    func transaction<T>(_ block: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let isOutermost = transactionDepth == 0
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        if isOutermost { try execute("BEGIN IMMEDIATE;") }
        do {
            let result = try block()
            if isOutermost { try execute("COMMIT;") }
            return result
        } catch {
            if isOutermost { try? execute("ROLLBACK;") }
            throw error
        }
    }

    // MARK: - Internals

    private func prepare(_ sql: String) throws -> (stmt: OpaquePointer, columnNames: [String]) {
        if let cached = statementCache[sql] { return cached }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(sql: sql, message: lastMessage())
        }
        let columnCount = Int(sqlite3_column_count(stmt))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for i in 0..<columnCount {
            let name = String(cString: sqlite3_column_name(stmt, Int32(i)))
            // OPT-188: SQLite allows duplicate column names in a result set (e.g. an unaliased
            // JOIN on same-named convention columns); this wrapper's dictionary-based row would
            // silently drop the earlier column, so flag it loudly in DEBUG instead.
            assert(!names.contains(name), "SQLiteConnection: duplicate column name '\(name)' in result set — a later column will silently overwrite an earlier one. SQL: \(sql)")
            names.append(name)
        }
        let entry = (stmt: stmt, columnNames: names)
        statementCache[sql] = entry
        return entry
    }

    private func bind(_ params: [SQLValue], to stmt: OpaquePointer) throws {
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(stmt, index)
            case .integer(let v):
                status = sqlite3_bind_int64(stmt, index, v)
            case .real(let v):
                status = sqlite3_bind_double(stmt, index, v)
            case .text(let v):
                status = sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case .blob(let data):
                status = data.isEmpty
                    ? sqlite3_bind_zeroblob(stmt, index, 0)
                    : data.withUnsafeBytes { raw in
                        sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(data.count), Self.transient)
                    }
            }
            guard status == SQLITE_OK else {
                throw SQLiteError.bindFailed(index: Int(index), message: lastMessage())
            }
        }
    }

    private func readColumn(_ stmt: OpaquePointer, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, i))
        case SQLITE_NULL: return .null
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(stmt, i) {
                let count = Int(sqlite3_column_bytes(stmt, i))
                return .blob(Data(bytes: bytes, count: count))
            }
            return .blob(Data())
        default:
            if let c = sqlite3_column_text(stmt, i) { return .text(String(cString: c)) }
            return .null
        }
    }

    private func lastMessage() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }
}
