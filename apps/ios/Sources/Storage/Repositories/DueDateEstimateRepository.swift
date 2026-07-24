import Foundation

/// Storage for the pregnancy module's computed due-date estimate (`DueDateEstimate` —
/// `due_date_estimates`, sensitive migration v8). Append-only (I2), identical in shape to
/// `CyclePredictionRepository`: a recompute INSERTs a fresh row with a new `generatedAt`, and the
/// latest one wins on read.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository`/`PregnancyRecordRepository` use.
final class DueDateEstimateRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    /// Plain INSERT (never `OR REPLACE`) — the append-only contract this table's lack of a unique
    /// natural-key index exists to make hold structurally, mirroring
    /// `CyclePredictionRepository.appendPrediction`.
    func appendEstimate(_ estimate: DueDateEstimate) throws {
        try sensitive.run("""
            INSERT INTO due_date_estimates
              (id, pregnancy_record_original_id, generated_at, range_low, range_center, range_high,
               resolved_source_type, confidence, algorithm_version, input_source_entry_ids, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(estimate.id), .text(estimate.pregnancyRecordOriginalId), .date(estimate.generatedAt),
             .date(estimate.rangeLow), .date(estimate.rangeCenter), .date(estimate.rangeHigh),
             .string(estimate.resolvedSourceType?.rawValue), .real(estimate.confidence),
             .text(estimate.algorithmVersion), .text(JSONCoding.encode(estimate.inputSourceEntryIds))]
            + Rows.convParams(updatedAt: estimate.updatedAt, originDeviceId: estimate.originDeviceId,
                              deletedAt: estimate.deletedAt))
    }

    /// The most recent live estimate for one journey — what any surface asking "what's the due date"
    /// reads.
    func latestEstimate(pregnancyRecordOriginalId: String) throws -> DueDateEstimate? {
        try sensitive.query("""
            SELECT * FROM due_date_estimates
            WHERE pregnancy_record_original_id = ? AND deleted_at IS NULL
            ORDER BY generated_at DESC LIMIT 1;
            """, [.text(pregnancyRecordOriginalId)]).first.map(Self.readEstimate)
    }

    /// Real, hard deletion of every estimate belonging to ONE journey — the scoped counterpart to
    /// `Database.purgeSensitiveNamespace()`'s whole-file wipe, used by
    /// `PregnancyModuleServices.purgeJourneyData(originalId:)` (general audit finding 1). A
    /// DIFFERENT journey's `pregnancyRecordOriginalId` is untouched.
    func purgeChain(pregnancyRecordOriginalId: String) throws {
        try sensitive.run("DELETE FROM due_date_estimates WHERE pregnancy_record_original_id = ?;",
                          [.text(pregnancyRecordOriginalId)])
    }

    static func readEstimate(_ r: SQLiteRow) -> DueDateEstimate {
        DueDateEstimate(
            id: r.requireString("id"),
            pregnancyRecordOriginalId: r.requireString("pregnancy_record_original_id"),
            generatedAt: r.requireDate("generated_at"),
            rangeLow: r.date("range_low"),
            rangeCenter: r.date("range_center"),
            rangeHigh: r.date("range_high"),
            resolvedSourceType: r.string("resolved_source_type").flatMap(DueDateSourceType.init(rawValue:)),
            confidence: r.requireDouble("confidence"),
            algorithmVersion: r.requireString("algorithm_version"),
            inputSourceEntryIds: JSONCoding.decode([String].self, from: r.string("input_source_entry_ids")) ?? [],
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
