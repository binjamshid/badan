import Foundation

/// Storage for `data_conflicts` (migration 10, main db — device/source disagreement is not
/// sensitive-plus, I7 does not apply). Each row is a detected-but-not-yet-resolved disagreement;
/// `markResolved` is the ONLY transition a conflict makes (unresolved -> resolved), and it never
/// deletes or rewrites `candidate_record_ids` — the original candidate set stays exactly as
/// detected, auditable, even after resolution (mirrors I3's "suppress, never delete" spirit for a
/// row that isn't itself a measurement).
final class DataConflictRepository {
    private let main: SQLiteConnection

    init(main: SQLiteConnection) {
        self.main = main
    }

    private static let columns = """
        id, scope_key, window_start, window_end, candidate_record_ids, status, resolved_by_decision_id, detected_at
        """
    private static let placeholders = "?, ?, ?, ?, ?, ?, ?, ?"

    func insert(_ c: DataConflict) throws {
        try main.run("""
            INSERT OR REPLACE INTO data_conflicts
              (\(Self.columns), \(Rows.convColumns))
            VALUES (\(Self.placeholders), \(Rows.convPlaceholders));
            """,
            [.text(c.id), .text(c.scopeKey), .date(c.windowStart), .date(c.windowEnd),
             .text(JSONCoding.encode(c.candidateRecordIds)), .text(c.status.rawValue),
             .string(c.resolvedByDecisionId), .date(c.detectedAt)]
            + Rows.convParams(updatedAt: c.updatedAt, originDeviceId: c.originDeviceId, deletedAt: c.deletedAt))
    }

    /// Any single conflict by id, resolved or not. `nil` both for "no such row" AND for a row
    /// whose `candidate_record_ids` is malformed/under-count (see `read`) — callers already treat
    /// both as "not available," so this never needs to distinguish the two.
    func conflict(id: String) throws -> DataConflict? {
        try main.query("SELECT * FROM data_conflicts WHERE id = ?;", [.text(id)]).first.flatMap(Self.read)
    }

    /// The queue a Device Hub "conflicts to review" surface reads — unresolved, live rows, freshest
    /// first. `compactMap` rather than `map`: a single corrupted historical row (malformed/under-
    /// count `candidate_record_ids`) is silently skipped from the list rather than crashing every
    /// caller — see `read`'s doc comment.
    func unresolved(limit: Int = 50) throws -> [DataConflict] {
        try main.query("""
            SELECT * FROM data_conflicts WHERE status = 'unresolved' AND deleted_at IS NULL
            ORDER BY detected_at DESC LIMIT ?;
            """, [.int(limit)]).compactMap(Self.read)
    }

    /// Every live conflict (any status) touching `scopeKey`, most recent first — backs a metric
    /// detail's "why am I seeing this value?" lookup. `compactMap` for the same reason as
    /// `unresolved()` above: skip a corrupted row rather than crash the whole lookup.
    func conflicts(scopeKey: String) throws -> [DataConflict] {
        try main.query("""
            SELECT * FROM data_conflicts WHERE scope_key = ? AND deleted_at IS NULL
            ORDER BY detected_at DESC;
            """, [.text(scopeKey)]).compactMap(Self.read)
    }

    /// Marks a conflict resolved and records which `ReconciliationDecision` resolved it. The only
    /// state transition this table supports — `candidate_record_ids`/`scope_key`/`detected_at` are
    /// never touched, so the row still tells the full "what was detected" story after resolution.
    func markResolved(id: String, decisionId: String, at date: Date) throws {
        try main.run("""
            UPDATE data_conflicts SET status = 'resolved', resolved_by_decision_id = ?, updated_at = ?
            WHERE id = ?;
            """, [.text(decisionId), .date(date), .text(id)])
    }

    /// `nil` for a row whose `candidate_record_ids` fails to decode at all, or decodes to fewer
    /// than 2 elements. `DataConflict.init` guards that same "2+ candidates" invariant with a
    /// `precondition` — appropriate for TRUSTED, in-memory construction (the reconciliation
    /// engine's own decision logic), where violating it really would be a programmer bug worth
    /// trapping on. Persisted data is external, untrusted input, though: a corrupted row, a future
    /// writer bug, or a botched sync-merge must never crash the app just because Device Hub or the
    /// Data Conflicts screen happened to read it — the same "every parser returns nil rather than
    /// trapping on malformed input" principle `GattServiceAdapters.swift` documents for BLE
    /// notifications applies equally here. Skipping the row (never guessing/truncating it into a
    /// fake 2-element set) keeps this honest: a row this build can't trust is surfaced as "not
    /// available," not silently reinterpreted.
    static func read(_ r: SQLiteRow) -> DataConflict? {
        guard let candidateRecordIds = JSONCoding.decode([String].self, from: r.string("candidate_record_ids")),
              candidateRecordIds.count >= 2
        else { return nil }
        // `scope:` below is only a construction placeholder — `scopeKey` is overwritten immediately
        // after with the EXACT raw stored string, so a row whose scope_key doesn't parse (a future
        // scope kind this build doesn't know about) still round-trips its real key unchanged rather
        // than silently rewriting it to "workout_duplicate" on the next save.
        var conflict = DataConflict(id: r.requireString("id"), scope: .workoutDuplicate,
                     windowStart: r.requireDate("window_start"), windowEnd: r.requireDate("window_end"),
                     candidateRecordIds: candidateRecordIds,
                     status: DataConflictStatus(rawValue: r.requireString("status")) ?? .unresolved,
                     resolvedByDecisionId: r.string("resolved_by_decision_id"),
                     detectedAt: r.requireDate("detected_at"), updatedAt: r.requireDate("updated_at"),
                     originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
        conflict.scopeKey = r.requireString("scope_key")
        return conflict
    }
}
