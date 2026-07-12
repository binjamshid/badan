import Foundation

/// Persists platform read-query cursors (e.g. `HKQueryAnchor`) so a real platform adapter can
/// resume an incremental sync instead of re-scanning full history on every launch. Storage-only
/// and platform-agnostic by design (opaque `Data` in/out) — the specific encoding (currently
/// NSKeyedArchiver secure-coded `HKQueryAnchor`) is the adapter's concern, not this repo's
/// (FEAT-01). Backs the `read_anchors` table reserved since migration v1.
final class ReadAnchorRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    func anchor(store: String, platformType: String) throws -> Data? {
        try db.query("SELECT anchor FROM read_anchors WHERE store = ? AND platform_type = ?;",
                     [.text(store), .text(platformType)]).first?.data("anchor")
    }

    func setAnchor(store: String, platformType: String, data: Data, updatedAt: Date) throws {
        try db.run("""
            INSERT OR REPLACE INTO read_anchors (store, platform_type, anchor, updated_at)
            VALUES (?, ?, ?, ?);
            """,
            [.text(store), .text(platformType), .blob(data), .date(updatedAt)])
    }
}
