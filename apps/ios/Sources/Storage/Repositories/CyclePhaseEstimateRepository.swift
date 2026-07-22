import Foundation

/// Storage for the cycle module's phase-as-covariate findings (`CyclePhaseEstimate` —
/// `cycle_phase_estimates`, sensitive migration v6) — the input `BaselineEngine`'s phase-
/// conditioned baselines (EPIC-39's defining feature) read. Append-only (I2), identical in shape to
/// `DerivedTrendRepository`/`CyclePredictionRepository`: a recompute INSERTs a fresh row at a new
/// `computedAt` rather than overwriting the previous belief.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository` uses.
final class CyclePhaseEstimateRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    /// Plain INSERT (never `OR REPLACE`) — append-only, mirrors `DerivedTrendRepository.appendTrend`
    /// and `CyclePredictionRepository.appendPrediction`.
    func appendEstimate(_ estimate: CyclePhaseEstimate) throws {
        try sensitive.run("""
            INSERT INTO cycle_phase_estimates
              (id, date_range_start, date_range_end, phase, confidence, evidence_basis,
               algorithm_version, computed_at, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(estimate.id), .date(estimate.dateRangeStart), .date(estimate.dateRangeEnd),
             .text(estimate.phase.rawValue), .real(estimate.confidence),
             .text(estimate.evidenceBasis.rawValue), .text(estimate.algorithmVersion),
             .date(estimate.computedAt)]
            + Rows.convParams(updatedAt: estimate.updatedAt, originDeviceId: estimate.originDeviceId,
                              deletedAt: estimate.deletedAt))
    }

    /// The most recent estimate whose `[dateRangeStart, dateRangeEnd]` window contains `asOf`, or —
    /// when no row matches exactly (e.g. a gap in computed windows) — the overall most recent live
    /// estimate, so a caller still gets BADAN's latest belief rather than nothing. Ties within
    /// either branch break on `computed_at DESC`.
    func latestEstimate(asOf: Date) throws -> CyclePhaseEstimate? {
        if let containing = try sensitive.query("""
            SELECT * FROM cycle_phase_estimates
            WHERE deleted_at IS NULL AND date_range_start <= ? AND date_range_end >= ?
            ORDER BY computed_at DESC LIMIT 1;
            """, [.date(asOf), .date(asOf)]).first.map(Self.readEstimate) {
            return containing
        }
        return try sensitive.query("""
            SELECT * FROM cycle_phase_estimates WHERE deleted_at IS NULL ORDER BY computed_at DESC LIMIT 1;
            """).first.map(Self.readEstimate)
    }

    static func readEstimate(_ r: SQLiteRow) -> CyclePhaseEstimate {
        CyclePhaseEstimate(
            id: r.requireString("id"),
            dateRangeStart: r.requireDate("date_range_start"),
            dateRangeEnd: r.requireDate("date_range_end"),
            phase: CyclePhase(rawValue: r.requireString("phase")) ?? .unknown,
            confidence: r.requireDouble("confidence"),
            evidenceBasis: CyclePhaseEvidenceBasis(rawValue: r.requireString("evidence_basis")) ?? .insufficientHistory,
            algorithmVersion: r.requireString("algorithm_version"),
            computedAt: r.requireDate("computed_at"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
