import Foundation

/// Storage for one period's flow-intensity log (`flow_logs`, sensitive migration v6). No revision
/// chain — see `FlowLog`'s own doc for why a flow-intensity correction is a plain tombstone-and-
/// relog rather than a chained revision. Tombstones (`deleted_at`) still apply, matching
/// `JournalRepository`'s discipline: a correction to a logged flow moment should not erase what the
/// user first tapped.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository`/`JournalRepository` use.
final class FlowLogRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    private static let columns = "id, cycle_id, occurred_at, original_label, normalized_intensity, note"
    private static let placeholders = "?, ?, ?, ?, ?, ?"

    /// `INSERT OR REPLACE` is idempotent on the ULID PK, so a retried write is a no-op.
    func insert(_ log: FlowLog) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO flow_logs
              (\(Self.columns), \(Rows.provColumns), \(Rows.convColumns))
            VALUES (\(Self.placeholders), \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(log.id), .text(log.cycleId), .date(log.occurredAt), .text(log.originalLabel),
             .double(log.normalizedIntensity), .string(log.note)]
            + Rows.provParams(log.provenance)
            + Rows.convParams(updatedAt: log.updatedAt, originDeviceId: log.originDeviceId,
                              deletedAt: log.deletedAt))
    }

    /// Every live flow log for one period, in logged order — the one real read shape this table
    /// serves (a period's own flow history), backed by `idx_flow_logs_cycle_occurred`.
    func liveLogs(cycleId: String) throws -> [FlowLog] {
        try sensitive.query("""
            SELECT * FROM flow_logs WHERE cycle_id = ? AND deleted_at IS NULL ORDER BY occurred_at ASC;
            """, [.text(cycleId)]).map(Self.readLog)
    }

    // MARK: - Readers

    static func readLog(_ r: SQLiteRow) -> FlowLog {
        FlowLog(
            id: r.requireString("id"),
            cycleId: r.requireString("cycle_id"),
            occurredAt: r.requireDate("occurred_at"),
            originalLabel: r.requireString("original_label"),
            normalizedIntensity: r.requireDouble("normalized_intensity"),
            note: r.string("note"),
            provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
