import Foundation

/// Append-only derived values, their input manifests, and materialized baselines. Recompute
/// APPENDS rows; reads take the latest `computed_at` (INVARIANT I2). Nothing is overwritten.
///
/// "Nothing is overwritten" was, until migration 6, false for baselines specifically — a claim
/// this header made while `upsertBaseline` wrote with `INSERT OR REPLACE` against a UNIQUE natural
/// key, so a second write at the same (metric_id, covariate_context, window_days, valid_from) did
/// a DELETE-then-INSERT and lost the prior row. That surfaced only on the score-backfill RETRY
/// (fixed `window.to` → same `valid_from`, recomputed band), never the nightly path. Migration 6
/// drops that unique index for a non-unique lookup index, and `upsertBaseline` below is now a plain
/// `INSERT` — every row carries a unique ULID `id`, so an append can no longer collide, and two
/// rows sharing a `valid_from` both survive with `computed_at` deciding the latest read. The method
/// keeps its `upsert` name because the baseline engine calls it; the semantics are now pure append.
final class DerivationRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    /// Run a batch of writes as a single transaction instead of one implicit commit+fsync per
    /// row (PERF-02 (audit 2026-07-12)).
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.transaction(body)
    }

    // MARK: - InputManifest

    func insertManifest(_ m: InputManifest) throws {
        try db.run("INSERT OR REPLACE INTO input_manifests (id, inputs) VALUES (?, ?);",
                   [.text(m.id), .text(JSONCoding.encode(m.inputs))])
    }

    func manifest(id: String) throws -> InputManifest? {
        guard let row = try db.query("SELECT * FROM input_manifests WHERE id = ?;", [.text(id)]).first,
              let inputs = JSONCoding.decode([InputManifest.Input].self, from: row.string("inputs")) else { return nil }
        return InputManifest(id: id, inputs: inputs)
    }

    // MARK: - DerivedValue (append-only)

    func appendDerived(_ v: DerivedValue) throws {
        try db.run("""
            INSERT INTO derived_values
              (id, metric_id, value, unit, period_key, confidence, provisional, algorithm_id,
               algorithm_version, input_manifest_id, computed_at, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(v.id), .text(v.metricId), .real(v.value), .text(v.unit), .text(v.periodKey),
             .double(v.confidence), .bool(v.provisional), .text(v.algorithmId), .text(v.algorithmVersion),
             .string(v.inputManifestId), .date(v.computedAt), .date(v.updatedAt),
             .text(v.originDeviceId), .date(v.deletedAt)])
    }

    /// Latest derived value for a metric+period (latest-read over the append-only log).
    func latestDerived(metricId: String, periodKey: String) throws -> DerivedValue? {
        try db.query("SELECT * FROM derived_values WHERE metric_id = ? AND period_key = ? AND deleted_at IS NULL ORDER BY computed_at DESC LIMIT 1;",
                     [.text(metricId), .text(periodKey)]).first.map(Self.readDerived)
    }

    /// Latest derived value per period for a metric, over a set of period keys — used by the
    /// detail chart's derived series (e.g. daily RHR).
    func latestDerivedSeries(metricId: String) throws -> [DerivedValue] {
        // Group by period_key, take max computed_at.
        let rows = try db.query("""
            SELECT d.* FROM derived_values d
            JOIN (SELECT period_key, MAX(computed_at) AS mc FROM derived_values
                  WHERE metric_id = ? AND deleted_at IS NULL GROUP BY period_key) latest
            ON d.period_key = latest.period_key AND d.computed_at = latest.mc
            WHERE d.metric_id = ? AND d.deleted_at IS NULL
            ORDER BY d.period_key ASC;
            """, [.text(metricId), .text(metricId)])
        return rows.map(Self.readDerived)
    }

    /// All appended rows for a metric, oldest first. `limit` is optional (defaults to
    /// unbounded, preserving existing callers' behavior) so future history/power-mode UI isn't
    /// forced into an all-or-nothing read of this append-only table (PERF-130).
    func allDerived(metricId: String, limit: Int? = nil) throws -> [DerivedValue] {
        var sql = "SELECT * FROM derived_values WHERE metric_id = ? ORDER BY computed_at ASC"
        var params: [SQLValue] = [.text(metricId)]
        if let limit {
            sql += " LIMIT ?"
            params.append(.int(limit))
        }
        sql += ";"
        return try db.query(sql, params).map(Self.readDerived)
    }

    // MARK: - Baseline

    /// Appends a baseline. Named `upsert` for the engine that calls it, but a pure `INSERT` since
    /// migration 6 (I2): the natural key is no longer UNIQUE, so this can never overwrite a prior
    /// row — the earlier `INSERT OR REPLACE` deleted history whenever a retried backfill recomputed
    /// a different band at an already-used `valid_from`. Every row's ULID `id` keeps inserts unique;
    /// `latestBaseline` resolves which row is current on read.
    func upsertBaseline(_ b: Baseline) throws {
        try db.run("""
            INSERT INTO baselines
              (id, metric_id, covariate_context, window_days, method, center, spread, band_low, band_high,
               n_points, provisional, algorithm_version, valid_from, computed_at, unit)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(b.id), .text(b.metricId), .text(b.covariateContext), .int(b.windowDays),
             .text(b.method.rawValue), .real(b.center), .real(b.spread), .real(b.bandLow), .real(b.bandHigh),
             .int(b.nPoints), .bool(b.provisional), .text(b.algorithmVersion), .date(b.validFrom),
             .date(b.computedAt), .text(b.unit)])
    }

    /// The current baseline for a metric+context: newest `valid_from`, and — now that migration 6
    /// lets two appended rows share a `valid_from` (the retry case) — newest `computed_at` among
    /// those, so the freshest belief wins and the older row is RETAINED as auditable history rather
    /// than deleted. Served by `idx_baseline_lookup` (metric_id, covariate_context, valid_from DESC).
    func latestBaseline(metricId: String, context: String = "default") throws -> Baseline? {
        try db.query("SELECT * FROM baselines WHERE metric_id = ? AND covariate_context = ? ORDER BY valid_from DESC, computed_at DESC LIMIT 1;",
                     [.text(metricId), .text(context)]).first.map(Self.readBaseline)
    }

    // MARK: - Readers

    static func readDerived(_ r: SQLiteRow) -> DerivedValue {
        DerivedValue(id: r.requireString("id"), metricId: r.requireString("metric_id"),
                     value: r.requireDouble("value"), unit: r.requireString("unit"),
                     periodKey: r.requireString("period_key"), confidence: r.double("confidence"),
                     provisional: r.bool("provisional"), algorithmId: r.requireString("algorithm_id"),
                     algorithmVersion: r.requireString("algorithm_version"), inputManifestId: r.string("input_manifest_id"),
                     computedAt: r.requireDate("computed_at"), updatedAt: r.requireDate("updated_at"),
                     originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }

    static func readBaseline(_ r: SQLiteRow) -> Baseline {
        Baseline(id: r.requireString("id"), metricId: r.requireString("metric_id"),
                 covariateContext: r.requireString("covariate_context"), windowDays: r.intValue("window_days") ?? 14,
                 method: BaselineMethod(rawValue: r.requireString("method")) ?? .medianMAD,
                 center: r.requireDouble("center"), spread: r.requireDouble("spread"),
                 bandLow: r.requireDouble("band_low"), bandHigh: r.requireDouble("band_high"),
                 nPoints: r.intValue("n_points") ?? 0, provisional: r.bool("provisional"),
                 algorithmVersion: r.requireString("algorithm_version"), validFrom: r.requireDate("valid_from"),
                 computedAt: r.requireDate("computed_at"), unit: r.requireString("unit"))
    }
}
