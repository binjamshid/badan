import Foundation

enum SQLiteError: Error, CustomStringConvertible {
    case openFailed(path: String, message: String)
    case prepareFailed(sql: String, message: String)
    case bindFailed(index: Int, message: String)
    case stepFailed(sql: String, message: String)
    case execFailed(sql: String, message: String)
    case decodeFailed(entity: String, reason: String)
    case encodeFailed(entity: String)
    /// D-23/A16: `sqlite3_key()` itself accepted the key (it always reports success, even for a
    /// wrong key on an already-encrypted file), but the mandatory follow-up read
    /// (`SELECT count(*) FROM sqlite_master`) that actually proves the key works failed — either
    /// the key is wrong for this file, or the file isn't a SQLCipher database at all.
    case keyFailed(path: String, message: String)

    var description: String {
        switch self {
        case .openFailed(let path, let m): return "SQLite open failed (\(path)): \(m)"
        case .prepareFailed(let sql, let m): return "SQLite prepare failed: \(m)\n\(sql)"
        case .bindFailed(let i, let m): return "SQLite bind failed at \(i): \(m)"
        case .stepFailed(let sql, let m): return "SQLite step failed: \(m)\n\(sql)"
        case .execFailed(let sql, let m): return "SQLite exec failed: \(m)\n\(sql)"
        case .decodeFailed(let e, let r): return "Decode failed for \(e): \(r)"
        case .encodeFailed(let e): return "Encode failed for \(e)"
        case .keyFailed(let path, let m): return "SQLite key verification failed (\(path)): \(m)"
        }
    }
}

/// Minimal centralized error-logging seam (OPT-187) so `SQLiteError`'s typed diagnostic detail
/// isn't silently discarded by call sites that swallow it via `try?`. Callers converting a
/// swallowed error should route it through here first rather than dropping it with zero trace.
enum StorageErrorLog {
    static func record(_ error: Error, context: StaticString) {
        #if DEBUG
        print("[Storage] \(context): \(error)")
        #endif
    }
}

/// Shared JSON coding for entities and JSON columns (Provenance, SessionDetail, scope,
/// manifest, input manifests). Deterministic key ordering so exported/serialized bytes are
/// stable and cross-platform-comparable.
enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    static func encode<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Throwing variant of `encode` (OPT-192) for call sites where a genuine encode failure
    /// should fail the surrounding write rather than silently persisting the literal string
    /// `"null"`, which would otherwise commit a corrupted row with no error at write time.
    static func encodeOrThrow<T: Encodable>(_ value: T) throws -> String {
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            throw SQLiteError.encodeFailed(entity: String(describing: T.self))
        }
        return text
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
