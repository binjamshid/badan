import Foundation
import SQLite3

/// A minimal, dependency-free wrapper over the system SQLite3 C library.
///
/// BADAN deliberately uses raw SQLite rather than an ORM (ADR-0005): the plan's storage
/// design is expressed as raw DDL with explicit provenance columns and named indexes, and
/// an offline, zero-dependency build eliminates a whole risk class (package resolution) for
/// a local-first app. This wrapper is the single seam a future GRDB/SQLCipher swap targets.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()   // serialize all access to this connection
    let path: String

    // SQLite wants a copy of bound text/blob, not our transient Swift buffer.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.openFailed(path: path, message: message)
        }
        // Durable + concurrent-friendly defaults for a local store.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA busy_timeout = 3000;")
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

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
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(sql: sql, message: lastMessage())
        }
        return Int(sqlite3_changes(handle))
    }

    /// Run a parameterized query and materialize all rows.
    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLiteRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(params, to: stmt)

        let columnCount = Int(sqlite3_column_count(stmt))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for i in 0..<columnCount { names.append(String(cString: sqlite3_column_name(stmt, Int32(i)))) }

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

    /// Execute a block inside an IMMEDIATE transaction; rolls back on any thrown error.
    func transaction<T>(_ block: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try block()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Internals

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(sql: sql, message: lastMessage())
        }
        return stmt
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
