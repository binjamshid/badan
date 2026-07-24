import Foundation

/// Storage for user-entered due-date inputs (`DueDateSourceEntry` — `due_date_source_entries`,
/// sensitive migration v8). Append-only per `(pregnancyRecordOriginalId, sourceType)` pair — see
/// that type's own doc for why a full revision chain isn't needed here.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository`/`PregnancyRecordRepository` use.
final class DueDateSourceEntryRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    /// Plain INSERT (never `OR REPLACE`) — append-only per pair, mirrors
    /// `CyclePredictionRepository.appendPrediction`'s "no natural-key unique index" posture: a
    /// correction always inserts a fresh row rather than overwriting a prior one.
    func insertEntry(_ entry: DueDateSourceEntry) throws {
        try sensitive.run("""
            INSERT INTO due_date_source_entries
              (id, pregnancy_record_original_id, source_type, entered_date, \(Rows.provColumns), \(Rows.convColumns))
            VALUES (?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(entry.id), .text(entry.pregnancyRecordOriginalId), .text(entry.sourceType.rawValue),
             .date(entry.enteredDate)]
            + Rows.provParams(entry.provenance)
            + Rows.convParams(updatedAt: entry.updatedAt, originDeviceId: entry.originDeviceId,
                              deletedAt: entry.deletedAt))
    }

    /// Every LIVE source entry for one journey, resolved to at most one row per `DueDateSourceType`
    /// — the most recently recorded (`updated_at DESC`) live row per type wins, per
    /// `DueDateSourceEntry`'s own doc. `DueDateEstimator.estimate` consumes this dictionary directly.
    func currentEntriesByType(pregnancyRecordOriginalId: String) throws -> [DueDateSourceType: DueDateSourceEntry] {
        let rows = try sensitive.query("""
            SELECT * FROM due_date_source_entries
            WHERE pregnancy_record_original_id = ? AND deleted_at IS NULL
            ORDER BY updated_at DESC;
            """, [.text(pregnancyRecordOriginalId)]).map(Self.readEntry)
        var result: [DueDateSourceType: DueDateSourceEntry] = [:]
        for row in rows where result[row.sourceType] == nil {
            result[row.sourceType] = row
        }
        return result
    }

    /// The full input history for one journey (every entry, every type, in recorded order) — for
    /// audit/history UI and tests. Not filtered by live status.
    func history(pregnancyRecordOriginalId: String) throws -> [DueDateSourceEntry] {
        try sensitive.query("""
            SELECT * FROM due_date_source_entries WHERE pregnancy_record_original_id = ? ORDER BY updated_at ASC;
            """, [.text(pregnancyRecordOriginalId)]).map(Self.readEntry)
    }

    /// Real, hard deletion of every entry belonging to ONE journey — the scoped counterpart to
    /// `Database.purgeSensitiveNamespace()`'s whole-file wipe, used by
    /// `PregnancyModuleServices.purgeJourneyData(originalId:)` (general audit finding 1). A
    /// DIFFERENT journey's `pregnancyRecordOriginalId` is untouched.
    func purgeChain(pregnancyRecordOriginalId: String) throws {
        try sensitive.run("DELETE FROM due_date_source_entries WHERE pregnancy_record_original_id = ?;",
                          [.text(pregnancyRecordOriginalId)])
    }

    static func readEntry(_ r: SQLiteRow) -> DueDateSourceEntry {
        DueDateSourceEntry(
            id: r.requireString("id"),
            pregnancyRecordOriginalId: r.requireString("pregnancy_record_original_id"),
            sourceType: DueDateSourceType(rawValue: r.requireString("source_type")) ?? .lmpBased,
            enteredDate: r.requireDate("entered_date"),
            provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
