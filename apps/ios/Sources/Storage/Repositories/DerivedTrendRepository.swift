import Foundation

/// Storage for the lab notebook's personal-baseline findings (`DerivedTrend` — concept 3 of the
/// four-concept reference-range law; `derived_trends`, sensitive migration v5).
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CorrelationRepository` uses for its own `derived_values` copy, for the same reason:
/// an analyte id (`hiv_viral_load`, `beta_hcg`…) can itself disclose, so this cannot live in
/// `badan.db` even for a "normal"-tier analyte's trend, since the identifier space is shared.
///
/// Append-only (I2), identical in shape to `CorrelationRepository`'s `derived_values` half and to
/// `DerivationRepository`'s `baselines` half: a recompute INSERTs a fresh row with a new
/// `computed_at`/`valid_from`, and the latest one wins on read. Nothing here updates or deletes a
/// trend, so "what BADAN believed about this analyte's personal normal last month" stays
/// answerable — which for a lab marker, sampled a handful of times a year, is often the only
/// evidence a "why does it say that" question can point to.
final class DerivedTrendRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    /// Plain INSERT (never `OR REPLACE`) — the append-only contract this table's lack of a unique
    /// natural-key index exists to make hold structurally, not just by writer convention (mirrors
    /// migration 6's fix to `idx_baseline_lookup`).
    func appendTrend(_ trend: DerivedTrend) throws {
        try sensitive.run("""
            INSERT INTO derived_trends
              (id, analyte_id, window_days, method, center, spread, band_low, band_high, n_points,
               provisional, algorithm_version, unit, valid_from, computed_at, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(trend.id), .text(trend.analyteId), .int(trend.windowDays), .text(trend.method.rawValue),
             .real(trend.center), .real(trend.spread), .real(trend.bandLow), .real(trend.bandHigh),
             .int(trend.nPoints), .bool(trend.provisional), .text(trend.algorithmVersion),
             .text(trend.unit), .date(trend.validFrom), .date(trend.computedAt)]
            + Rows.convParams(updatedAt: trend.updatedAt, originDeviceId: trend.originDeviceId,
                              deletedAt: trend.deletedAt))
    }

    /// Latest row for an analyte (latest-read over the append-only log) — concept 3 for
    /// `ReferenceRangeEngine.render`'s call site.
    func latestTrend(analyteId: String) throws -> DerivedTrend? {
        try sensitive.query("""
            SELECT * FROM derived_trends WHERE analyte_id = ? AND deleted_at IS NULL
            ORDER BY valid_from DESC, computed_at DESC LIMIT 1;
            """, [.text(analyteId)]).first.map(Self.readTrend)
    }

    /// Every appended row for one analyte, oldest first — the audit trail I2 exists to preserve.
    func allTrends(analyteId: String) throws -> [DerivedTrend] {
        try sensitive.query("SELECT * FROM derived_trends WHERE analyte_id = ? ORDER BY computed_at ASC;",
                            [.text(analyteId)]).map(Self.readTrend)
    }

    static func readTrend(_ r: SQLiteRow) -> DerivedTrend {
        DerivedTrend(
            id: r.requireString("id"),
            analyteId: r.requireString("analyte_id"),
            windowDays: r.intValue("window_days") ?? 0,
            method: BaselineMethod(rawValue: r.requireString("method")) ?? .medianMAD,
            center: r.requireDouble("center"),
            spread: r.requireDouble("spread"),
            bandLow: r.requireDouble("band_low"),
            bandHigh: r.requireDouble("band_high"),
            nPoints: r.intValue("n_points") ?? 0,
            provisional: r.bool("provisional"),
            algorithmVersion: r.requireString("algorithm_version"),
            unit: r.requireString("unit"),
            validFrom: r.requireDate("valid_from"),
            computedAt: r.requireDate("computed_at"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
