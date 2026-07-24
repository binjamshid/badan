import Foundation

/// Storage for the cycle module's fertile-window estimate (`CycleFertileWindowEstimate` —
/// `cycle_fertile_window_estimates`, sensitive migration v7, EPIC-39 CYCLE-12). Append-only (I2),
/// identical in shape to `CyclePredictionRepository` over `cycle_predictions`: a recompute INSERTs a
/// fresh row with a new `generatedAt`, and the latest one wins on read — nothing here updates or
/// deletes an estimate, so "what BADAN estimated last time, under which mode, with what confidence"
/// stays fully auditable.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository`/`CyclePredictionRepository` use.
final class CycleFertileWindowEstimateRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    /// Plain INSERT (never `OR REPLACE`) — append-only, mirrors `CyclePredictionRepository.appendPrediction`.
    func appendEstimate(_ estimate: CycleFertileWindowEstimate) throws {
        try sensitive.run("""
            INSERT INTO cycle_fertile_window_estimates
              (id, generated_at, window_start, window_end, confidence, mode, evidence_basis, status,
               suppression_reason, algorithm_version, input_cycle_ids, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(estimate.id), .date(estimate.generatedAt), .date(estimate.windowStart),
             .date(estimate.windowEnd), .real(estimate.confidence), .text(estimate.mode.rawValue),
             .text(estimate.evidenceBasis.rawValue), .text(estimate.status.rawValue),
             .string(estimate.suppressionReason), .text(estimate.algorithmVersion),
             .text(JSONCoding.encode(estimate.inputCycleIds))]
            + Rows.convParams(updatedAt: estimate.updatedAt, originDeviceId: estimate.originDeviceId,
                              deletedAt: estimate.deletedAt))
    }

    /// The most recent live estimate (latest-read over the append-only log) — what any surface
    /// asking "what's the current fertile-window estimate" reads. `nil` when `refreshAll` has never
    /// appended one yet (e.g. `fertileWindowMode` was `.suppressed` at every past recompute — see
    /// `CycleModuleServices.refreshAll`'s own gate, which never even calls the engine in that case).
    func latestEstimate() throws -> CycleFertileWindowEstimate? {
        try sensitive.query("""
            SELECT * FROM cycle_fertile_window_estimates WHERE deleted_at IS NULL
            ORDER BY generated_at DESC LIMIT 1;
            """).first.map(Self.readEstimate)
    }

    static func readEstimate(_ r: SQLiteRow) -> CycleFertileWindowEstimate {
        CycleFertileWindowEstimate(
            id: r.requireString("id"),
            generatedAt: r.requireDate("generated_at"),
            windowStart: r.date("window_start"),
            windowEnd: r.date("window_end"),
            confidence: r.requireDouble("confidence"),
            mode: FertileWindowMode(rawValue: r.requireString("mode")) ?? .suppressed,
            evidenceBasis: FertileWindowEvidenceBasis(rawValue: r.requireString("evidence_basis")) ?? .insufficientHistory,
            status: FertileWindowStatus(rawValue: r.requireString("status")) ?? .suppressed,
            suppressionReason: r.string("suppression_reason"),
            algorithmVersion: r.requireString("algorithm_version"),
            inputCycleIds: JSONCoding.decode([String].self, from: r.string("input_cycle_ids")) ?? [],
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
