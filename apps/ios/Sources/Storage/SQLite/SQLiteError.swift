import Foundation

enum SQLiteError: Error, CustomStringConvertible {
    case openFailed(path: String, message: String)
    case prepareFailed(sql: String, message: String)
    case bindFailed(index: Int, message: String)
    case stepFailed(sql: String, message: String)
    case execFailed(sql: String, message: String)
    case decodeFailed(entity: String, reason: String)

    var description: String {
        switch self {
        case .openFailed(let path, let m): return "SQLite open failed (\(path)): \(m)"
        case .prepareFailed(let sql, let m): return "SQLite prepare failed: \(m)\n\(sql)"
        case .bindFailed(let i, let m): return "SQLite bind failed at \(i): \(m)"
        case .stepFailed(let sql, let m): return "SQLite step failed: \(m)\n\(sql)"
        case .execFailed(let sql, let m): return "SQLite exec failed: \(m)\n\(sql)"
        case .decodeFailed(let e, let r): return "Decode failed for \(e): \(r)"
        }
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

    static func decode<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
