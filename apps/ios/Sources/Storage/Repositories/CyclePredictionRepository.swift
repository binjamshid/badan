import Foundation

/// Storage for the cycle module's next-period forecast (`CyclePrediction` — `cycle_predictions`,
/// sensitive migration v6). Append-only (I2), identical in shape to `DerivedTrendRepository` over
/// `derived_trends`: a recompute INSERTs a fresh row with a new `generatedAt`, and the latest one
/// wins on read. Nothing here updates or deletes a forecast, so "what BADAN predicted last time,
/// and with what confidence/method" stays answerable — which matters here specifically because
/// `docs/legal/reproductive-threat-model.md` requires every prediction surface to be a range with a
/// stated method and confidence, never a bare date, and that claim is only auditable if the
/// forecast history itself is never silently overwritten.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository` uses.
final class CyclePredictionRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    /// Plain INSERT (never `OR REPLACE`) — the append-only contract this table's lack of a unique
    /// natural-key index exists to make hold structurally, not just by writer convention (mirrors
    /// `DerivedTrendRepository.appendTrend`).
    func appendPrediction(_ prediction: CyclePrediction) throws {
        try sensitive.run("""
            INSERT INTO cycle_predictions
              (id, generated_at, predicted_next_start_low, predicted_next_start_center,
               predicted_next_start_high, confidence, method, status, suppression_reason,
               algorithm_version, input_cycle_ids, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(prediction.id), .date(prediction.generatedAt), .date(prediction.predictedNextStartLow),
             .date(prediction.predictedNextStartCenter), .date(prediction.predictedNextStartHigh),
             .real(prediction.confidence), .text(prediction.method.rawValue),
             .text(prediction.status.rawValue), .string(prediction.suppressionReason),
             .text(prediction.algorithmVersion), .text(JSONCoding.encode(prediction.inputCycleIds))]
            + Rows.convParams(updatedAt: prediction.updatedAt, originDeviceId: prediction.originDeviceId,
                              deletedAt: prediction.deletedAt))
    }

    /// The most recent live forecast (latest-read over the append-only log) — what any surface
    /// asking "when is my next period expected" reads.
    func latestPrediction() throws -> CyclePrediction? {
        try sensitive.query("""
            SELECT * FROM cycle_predictions WHERE deleted_at IS NULL ORDER BY generated_at DESC LIMIT 1;
            """).first.map(Self.readPrediction)
    }

    static func readPrediction(_ r: SQLiteRow) -> CyclePrediction {
        CyclePrediction(
            id: r.requireString("id"),
            generatedAt: r.requireDate("generated_at"),
            predictedNextStartLow: r.date("predicted_next_start_low"),
            predictedNextStartCenter: r.date("predicted_next_start_center"),
            predictedNextStartHigh: r.date("predicted_next_start_high"),
            confidence: r.requireDouble("confidence"),
            method: CyclePredictionMethod(rawValue: r.requireString("method")) ?? .coldStart,
            status: CyclePredictionStatus(rawValue: r.requireString("status")) ?? .active,
            suppressionReason: r.string("suppression_reason"),
            algorithmVersion: r.requireString("algorithm_version"),
            inputCycleIds: JSONCoding.decode([String].self, from: r.string("input_cycle_ids")) ?? [],
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
