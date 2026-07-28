import Foundation

/// Storage for structured-session segments (`workout_intervals`, migration 9; EPIC-42's
/// interval/HIIT engine). Mirrors `StrengthSetRepository`'s shape — same table family, same parent
/// `sessions` row, same main-DB connection.
///
/// Unlike `strength_sets` there is no revision chain here: a strength set is a claim the person
/// makes and may correct, while an interval segment is an observation of a clock that already ran.
/// Correcting one would mean claiming the timer ran differently than it did. Segments are therefore
/// insert-once and tombstone-only, which is also why this type has no `update`.
final class WorkoutIntervalRepository {
    private let main: SQLiteConnection

    init(main: SQLiteConnection) {
        self.main = main
    }

    private static let columns = "id, session_id, seq, kind, start_at, end_at, target, result, " +
        "updated_at, origin_device_id, deleted_at"
    private static let placeholders = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try main.transaction(body) }

    /// Appends one segment. `INSERT OR REPLACE` on the ULID primary key makes re-recording the
    /// identical segment a no-op, which matters because `IntervalEngine.completedSegments`
    /// recomputes the whole completed prefix on every call — writing round 3 does not depend on
    /// rounds 1 and 2 not being written again.
    func insert(_ interval: WorkoutInterval) throws {
        try main.run("""
            INSERT OR REPLACE INTO workout_intervals (\(Self.columns)) VALUES (\(Self.placeholders));
            """,
            [.text(interval.id), .text(interval.sessionId), .int(interval.seq), .text(interval.kind.rawValue),
             .date(interval.startAt), .date(interval.endAt), .string(interval.target), .string(interval.result),
             .date(interval.updatedAt), .text(interval.originDeviceId), .date(interval.deletedAt)])
    }

    /// Appends many in one transaction — one commit per session finalize rather than one per lap.
    func insertAll(_ intervals: [WorkoutInterval]) throws {
        guard !intervals.isEmpty else { return }
        try main.transaction {
            for interval in intervals { try insert(interval) }
        }
    }

    /// A session's live segments, in order. Filters tombstones, matching the convention every other
    /// repository here follows (`MeasurementRepository`, `StrengthSetRepository`).
    func intervals(sessionId: String) throws -> [WorkoutInterval] {
        try main.query("""
            SELECT \(Self.columns) FROM workout_intervals
            WHERE session_id = ? AND deleted_at IS NULL ORDER BY seq ASC;
            """, [.text(sessionId)]).map(Self.read)
    }

    /// Soft-delete every segment of a session (I3: never a hard delete) — used when a session is
    /// discarded, so its segments go with it rather than outliving their parent.
    func tombstoneAll(sessionId: String, at date: Date) throws {
        try main.run("""
            UPDATE workout_intervals SET deleted_at = ?, updated_at = ?
            WHERE session_id = ? AND deleted_at IS NULL;
            """, [.date(date), .date(date), .text(sessionId)])
    }

    static func read(_ r: SQLiteRow) -> WorkoutInterval {
        WorkoutInterval(
            id: r.requireString("id"), sessionId: r.requireString("session_id"),
            seq: r.intValue("seq") ?? 0,
            kind: IntervalSegmentKind(rawValue: r.requireString("kind")) ?? .work,
            startAt: r.requireDate("start_at"), endAt: r.date("end_at"),
            target: r.string("target"), result: r.string("result"),
            updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
