import Foundation

/// A bound/returned SQLite value. BADAN stores instants as INTEGER epoch-millis, booleans
/// as 0/1, JSON as TEXT.
enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func date(_ date: Date?) -> SQLValue { date.map { .integer($0.epochMillis) } ?? .null }
    static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    static func string(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    static func double(_ value: Double?) -> SQLValue { value.map { .real($0) } ?? .null }
    static func int(_ value: Int?) -> SQLValue { value.map { .integer(Int64($0)) } ?? .null }
}

/// A materialized result row with typed, name-based accessors.
struct SQLiteRow {
    let values: [String: SQLValue]

    func string(_ column: String) -> String? {
        if case .text(let v)? = values[column] { return v }
        return nil
    }
    func requireString(_ column: String) -> String { string(column) ?? "" }

    func int(_ column: String) -> Int64? {
        switch values[column] {
        case .integer(let v): return v
        case .real(let v): return Int64(v)
        default: return nil
        }
    }
    func intValue(_ column: String) -> Int? { int(column).map { Int($0) } }

    func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }
    func requireDouble(_ column: String) -> Double { double(column) ?? 0 }

    func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }

    func date(_ column: String) -> Date? { int(column).map { Date(epochMillis: $0) } }
    func requireDate(_ column: String) -> Date { date(column) ?? Date(epochMillis: 0) }

    func data(_ column: String) -> Data? {
        if case .blob(let d)? = values[column] { return d }
        return nil
    }
}
