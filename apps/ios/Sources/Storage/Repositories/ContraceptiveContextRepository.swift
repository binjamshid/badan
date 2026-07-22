import Foundation

/// Storage for declared contraceptive-method intervals (`contraceptive_context_logs`, sensitive
/// migration v6) — the CYCLE-07 input that lets `CyclePrediction` pause/broaden a forecast instead
/// of confidently predicting through an active hormonal context (see `ContraceptiveContextLog`'s
/// own doc, and `docs/legal/reproductive-threat-model.md` §5).
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository`/`FlowLogRepository` use.
final class ContraceptiveContextRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    private static let columns = "id, method_type, start_at, end_at, adherence_note"
    private static let placeholders = "?, ?, ?, ?, ?"

    /// Inserts or updates one declared context. Unlike `CycleRecord`, a context legitimately
    /// CHANGES in place — closing an active method (setting `endAt`) re-inserts the SAME id with
    /// `end_at` now populated, rather than appending a chained revision, because the interval is
    /// one fact whose end was simply not known yet. This mirrors `JournalRepository.upsertStatus`'s
    /// exact reasoning for `context_statuses`, applied here to a contraceptive-method interval
    /// instead of a travel/illness one. `INSERT OR REPLACE` is idempotent on the ULID PK.
    func insert(_ context: ContraceptiveContextLog) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO contraceptive_context_logs
              (\(Self.columns), \(Rows.provColumns), \(Rows.convColumns))
            VALUES (\(Self.placeholders), \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(context.id), .text(context.methodType.rawValue), .date(context.startAt),
             .date(context.endAt), .string(context.adherenceNote)]
            + Rows.provParams(context.provenance)
            + Rows.convParams(updatedAt: context.updatedAt, originDeviceId: context.originDeviceId,
                              deletedAt: context.deletedAt))
    }

    /// Every live context, most recently started first.
    func liveContexts() throws -> [ContraceptiveContextLog] {
        try sensitive.query("""
            SELECT * FROM contraceptive_context_logs WHERE deleted_at IS NULL ORDER BY start_at DESC;
            """).map(Self.readContext)
    }

    /// The context with `endAt == nil AND deletedAt == nil`, if any. There should only ever be
    /// zero or one such row at a time (a person is not usually declared on two methods
    /// simultaneously), but this deliberately does not crash or throw if that invariant is ever
    /// violated by malformed/corrupted data — it returns the most recently STARTED matching row,
    /// the same "degrade gracefully, never trap on untrusted persisted data" posture
    /// `DataConflictRepository.read`'s doc explains for its own malformed-row case.
    func activeContext() throws -> ContraceptiveContextLog? {
        try sensitive.query("""
            SELECT * FROM contraceptive_context_logs
            WHERE end_at IS NULL AND deleted_at IS NULL
            ORDER BY start_at DESC LIMIT 1;
            """).first.map(Self.readContext)
    }

    // MARK: - Readers

    static func readContext(_ r: SQLiteRow) -> ContraceptiveContextLog {
        ContraceptiveContextLog(
            id: r.requireString("id"),
            methodType: ContraceptiveMethodType(rawValue: r.requireString("method_type")) ?? .pill,
            startAt: r.requireDate("start_at"),
            endAt: r.date("end_at"),
            adherenceNote: r.string("adherence_note"),
            provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
