import Foundation
import SQLCipher

/// D-23/A16: transparently converts a pre-existing, pre-SQLCipher `badan_sensitive.db` (plain
/// SQLite, protected only by OS file-level encryption per the now-superseded ADR-0004 posture)
/// into a genuinely SQLCipher-encrypted file, in place, with no data loss — using SQLCipher's own
/// documented conversion recipe (`ATTACH` a new keyed database, `sqlcipher_export()` into it,
/// `DETACH`). Simply calling `sqlite3_key()` on a connection to an already-populated plaintext
/// file does NOT retroactively encrypt its existing pages — the codec only applies to pages
/// written AFTER a key is set — so this ATTACH/export dance, not a same-connection rekey, is the
/// only correct way to convert a file that already has real rows in it.
///
/// `Database.init` calls `migrateIfNeeded` once, before ever constructing the keyed
/// `SQLiteConnection` for `sensitive` — by the time that connection opens the file, it must
/// already be a genuinely-encrypted file (or not exist yet at all, for a fresh install).
enum SensitiveDatabaseMigrator {

    /// Runs the conversion described above if, and only if, `path` holds a file that needs it.
    /// A no-op in the two steady-state cases every launch after the first hits:
    ///   - no file exists yet at `path` (fresh install, or `:memory:` — `SQLiteConnection` will
    ///     create a freshly-keyed file/DB directly, nothing to convert);
    ///   - the file already opens successfully with `key` (already migrated on a prior launch).
    /// Only the one-time "a real pre-SQLCipher file exists" case does any work.
    static func migrateIfNeeded(path: String, key: Data) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if opens(path: path, key: key) { return }
        guard opens(path: path, key: nil) else {
            // Neither the current key nor "no key at all" can read this file's schema. This is
            // not the common case this migration exists for (a real, era-appropriate plaintext
            // file) — it could be a foreign/corrupted file, or a file encrypted with some OTHER
            // key. Per the "no data loss, never destroy on a failed conversion" requirement: touch
            // NOTHING and fail loudly rather than guessing.
            throw SensitiveDatabaseMigrationError.sourceUnreadable(path: path)
        }
        try convert(path: path, key: key)
    }

    /// True only if `path` both opens AND its schema is actually readable with `key` (or with no
    /// key at all, when `key` is `nil`) — a bare `sqlite3_open_v2` succeeding proves nothing here
    /// (see `SQLiteConnection.applyKey`'s own comment), so this always forces a real page read.
    private static func opens(path: String, key: Data?) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return false
        }
        defer { sqlite3_close_v2(handle) }
        if let key {
            let keySpec = SQLCipherKeySpec.string(for: key)
            guard sqlite3_key(handle, keySpec, Int32(keySpec.utf8CString.count)) == SQLITE_OK else { return false }
        }
        return sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK
    }

    /// The actual ATTACH + `sqlcipher_export()` + verify + atomic-replace sequence. Writes ONLY to
    /// a freshly-named temp file next to `path` until every verification step below has passed;
    /// `path` itself is never opened for writing and is touched only by the final atomic replace.
    private static func convert(path: String, key: Data) throws {
        let tempPath = path + ".sqlcipher-migrate-\(UUID().uuidString).tmp"
        // `tempPath` is disposable scratch space ONLY up until it has been verified correct AND
        // handed to `replaceItemAt` below — cleared to `false` right before that call. This is
        // deliberately NOT a blanket "always delete on any exit": once `replaceItemAt` has been
        // attempted, `tempPath` may be the ONLY remaining copy of the fully-converted, verified
        // data (if the replace itself throws — disk full, sandbox/file-protection denial — the
        // original `path` may already be mid-swap, or a background process may have raced it).
        // Deleting the one artifact known-good at that point, unconditionally, is exactly the
        // "unconditionally discards the good copy on any later failure" defect this guards
        // against; leaving it in place costs only disk space and gives a future launch (or a
        // human) something to recover from instead of nothing.
        var shouldCleanUpTempPathOnExit = true
        defer {
            if shouldCleanUpTempPathOnExit {
                try? FileManager.default.removeItem(atPath: tempPath)
                for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tempPath + suffix) }
            }
        }

        // Snapshot per-table row counts from the ORIGINAL file, before touching anything, so the
        // verification step below has an independent baseline — not a count derived from the very
        // copy it's supposed to be checking.
        let beforeCounts = try tableRowCounts(path: path, key: nil)

        // This whole block's connection (`source`) MUST be fully closed before anything below
        // touches `path` or `tempPath` via `FileManager` — `replaceItemAt` needs both the
        // destination (`path`) and the replacement (`tempPath`) to be unheld files. Scoping the
        // open/attach/export/detach/close sequence inside its own block (rather than a `defer`
        // that would only fire when the whole function returns, i.e. AFTER the replace below)
        // is what guarantees that ordering on every exit path, success or failure.
        try {
            var source: OpaquePointer?
            // SQLITE_OPEN_CREATE here is NOT about `path` itself — `migrateIfNeeded` already
            // confirmed that file exists before ever calling `convert()`. It's required because
            // SQLite's `ATTACH` inherits its own "may create a new file" permission from the
            // CALLING connection's open flags: without `SQLITE_OPEN_CREATE` on `source`, the
            // `ATTACH ... AS sqlcipher_migration_target` below fails with "unable to open
            // database" even though `tempPath` legitimately doesn't exist yet and SHOULD be
            // creatable.
            guard sqlite3_open_v2(path, &source, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let source else {
                if let source { sqlite3_close_v2(source) }
                throw SensitiveDatabaseMigrationError.sourceUnreadable(path: path)
            }
            // Attach the target WITHOUT an inline `KEY` clause, then key it with `sqlite3_key_v2`
            // (the multi-database form of the exact same call `SQLiteConnection.applyKey` uses for
            // the primary connection) instead of embedding the key spec as SQL text. `sqlite3_key`/
            // `sqlite3_key_v2`'s raw-key recognition is a pattern match on the literal bytes handed
            // to the C API — it is NOT reproduced by SQLite's own SQL-expression evaluation, so
            // embedding `keySpec` inside `ATTACH ... KEY <expr>;` statement text does not reliably
            // reach the same raw-key-bypass code path `sqlite3_key()` does: an unquoted `x'...'`
            // evaluates to a raw decoded BLOB (no leading `x`/`'` bytes left for the pattern to
            // match at all), and a quoted string-literal form fails the identical way — both embed
            // a database that opens and reads correctly through the SAME session that just wrote it
            // (whatever key material SQL-level ATTACH actually derived was at least self-consistent
            // within that session) but fails an HMAC check on every fresh reopen with the real key,
            // proving the SQL-text path derives a genuinely different effective key than the direct
            // C API does from identical input. Calling the C API directly, scoped to this one
            // attached alias, sidesteps SQL text/type ambiguity entirely and is SQLCipher's own
            // documented mechanism for keying an attached database independently of the main
            // connection's key.
            var errPtr: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(source, "ATTACH DATABASE '\(tempPath.sqlSingleQuoteEscaped)' AS sqlcipher_migration_target;", nil, nil, &errPtr) == SQLITE_OK else {
                let message = errPtr.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errPtr)
                sqlite3_close_v2(source)
                throw SensitiveDatabaseMigrationError.attachFailed(message: message)
            }
            // Must run before any read/write touches the newly-attached (still-unkeyed) database —
            // same ordering requirement `SQLiteConnection.applyKey` documents for the main handle.
            let keySpec = SQLCipherKeySpec.string(for: key)
            let keyResult = sqlite3_key_v2(source, "sqlcipher_migration_target", keySpec, Int32(keySpec.utf8CString.count))
            guard keyResult == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(source))
                sqlite3_exec(source, "DETACH DATABASE sqlcipher_migration_target;", nil, nil, nil)
                sqlite3_close_v2(source)
                throw SensitiveDatabaseMigrationError.attachFailed(message: message)
            }
            guard sqlite3_exec(source, "SELECT sqlcipher_export('sqlcipher_migration_target');", nil, nil, &errPtr) == SQLITE_OK else {
                let message = errPtr.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errPtr)
                sqlite3_exec(source, "DETACH DATABASE sqlcipher_migration_target;", nil, nil, nil)
                sqlite3_close_v2(source)
                throw SensitiveDatabaseMigrationError.exportFailed(message: message)
            }
            // Force the newly-written attached database to fully checkpoint back into `tempPath`
            // itself before detaching, so `tempPath` is immediately a complete, self-contained
            // file on disk with no dependency on a `-wal`/`-shm` sidecar that a later, separately-
            // opened connection (the verification below, or `Database`'s real open after this
            // function returns) might not associate with it the same way.
            sqlite3_exec(source, "PRAGMA sqlcipher_migration_target.wal_checkpoint(TRUNCATE);", nil, nil, nil)
            sqlite3_exec(source, "DETACH DATABASE sqlcipher_migration_target;", nil, nil, nil)
            sqlite3_close_v2(source)
        }()
        // Whatever `-wal`/`-shm` sidecars `tempPath` picked up during export must not survive
        // into the verification/replace steps below — same reasoning as the checkpoint above.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempPath + suffix)
        }

        // Verify the CONVERTED COPY independently, from fresh connections, before the original is
        // touched at all: (a) it must be genuinely encrypted now — opening it with NO key must NOT
        // be able to read its schema — and (b) it must open and read correctly WITH the key, with
        // row counts matching the pre-conversion snapshot, table for table.
        guard !opens(path: tempPath, key: nil) else {
            throw SensitiveDatabaseMigrationError.convertedFileStillPlaintext
        }
        guard opens(path: tempPath, key: key) else {
            throw SensitiveDatabaseMigrationError.verificationOpenFailed
        }
        let afterCounts = try tableRowCounts(path: tempPath, key: key)
        for (table, before) in beforeCounts {
            let after = afterCounts[table] ?? -1
            guard after == before else {
                throw SensitiveDatabaseMigrationError.rowCountMismatch(table: table, before: before, after: after)
            }
        }

        // Past this point `tempPath` is the verified, fully-converted copy and the ONLY remaining
        // step is the atomic replace immediately below — stop unconditionally discarding it on
        // function exit (see the `shouldCleanUpTempPathOnExit` comment above): if `replaceItemAt`
        // itself throws, the caller — or the next launch's `migrateIfNeeded` — still has this
        // exact copy to recover from, rather than nothing at all.
        shouldCleanUpTempPathOnExit = false

        // Deliberately NOT touching `path`'s own `-wal`/`-shm` siblings (if any) before this call:
        // doing so used to be a separate, non-atomic step ahead of the swap below, which meant a
        // process kill or a thrown error landing in the gap between that deletion and this replace
        // could permanently and silently drop whatever committed-but-not-yet-checkpointed data was
        // sitting only in `path`'s WAL at that moment — the exact corruption window "touched only
        // by the final atomic replace" (this file's own header comment) promises can't happen. It
        // isn't needed for correctness either: SQLite validates a WAL file's salt against its main
        // database file's header before ever trusting it, so a stale plaintext-era WAL sitting next
        // to the brand-new encrypted `path` this call is about to produce simply won't match and is
        // safely ignored/discarded by SQLite itself on next open, exactly like any foreign WAL.
        //
        // `replaceItemAt` is atomic on the same volume (same directory here, so always true). Both
        // `source` (above) and every verification connection are closed by this point, so neither
        // `path` nor `tempPath` is held open.
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tempPath))

        // Only now, after the swap has atomically landed and `path` unambiguously refers to the new
        // encrypted file, sweep away whatever stale sidecars the OLD plaintext file left lying
        // around next to it. This is pure best-effort disk hygiene (per the previous paragraph,
        // SQLite would ignore them safely even if this never ran) — not a correctness-critical step
        // — so failures here are swallowed exactly as before.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Table-by-table row counts for every user table (`sqlite_%` catalog tables excluded) — the
    /// data-integrity check the conversion above is verified against.
    private static func tableRowCounts(path: String, key: Data?) throws -> [String: Int64] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw SensitiveDatabaseMigrationError.sourceUnreadable(path: path)
        }
        defer { sqlite3_close_v2(handle) }
        if let key {
            let keySpec = SQLCipherKeySpec.string(for: key)
            guard sqlite3_key(handle, keySpec, Int32(keySpec.utf8CString.count)) == SQLITE_OK else {
                throw SensitiveDatabaseMigrationError.sourceUnreadable(path: path)
            }
        }
        var tables: [String] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';", -1, &stmt, nil) == SQLITE_OK else {
            throw SensitiveDatabaseMigrationError.sourceUnreadable(path: path)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 0) { tables.append(String(cString: name)) }
        }
        sqlite3_finalize(stmt)

        var counts: [String: Int64] = [:]
        for table in tables {
            var countStmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \"\(table)\";", -1, &countStmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(countStmt) }
            if sqlite3_step(countStmt) == SQLITE_ROW {
                counts[table] = sqlite3_column_int64(countStmt, 0)
            }
        }
        return counts
    }
}

enum SensitiveDatabaseMigrationError: Error, Equatable {
    /// Neither the current key nor "no key" could read `path`'s schema — see
    /// `SensitiveDatabaseMigrator.migrateIfNeeded`'s own comment for why this deliberately does
    /// NOT attempt any destructive recovery.
    case sourceUnreadable(path: String)
    case attachFailed(message: String)
    case exportFailed(message: String)
    /// The converted copy opened with NO key — i.e. `sqlcipher_export()` produced a file that
    /// isn't actually encrypted. Should be unreachable (the ATTACH above always specifies a KEY),
    /// kept as a typed, checked failure rather than trusting that invariant silently.
    case convertedFileStillPlaintext
    case verificationOpenFailed
    case rowCountMismatch(table: String, before: Int64, after: Int64)
}

private extension String {
    /// Escapes embedded single quotes for safe interpolation into a single-quoted SQL string
    /// literal (SQL's own doubling convention: `'` → `''`). `tempPath` is built entirely from this
    /// process's own temp-directory path plus a `UUID` this code generates itself, so in practice
    /// it never contains a quote — this exists purely as defense in depth, not because any known
    /// input triggers it.
    var sqlSingleQuoteEscaped: String { replacingOccurrences(of: "'", with: "''") }
}
