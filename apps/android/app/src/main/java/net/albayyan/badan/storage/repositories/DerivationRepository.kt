package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.BaselineMethod
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection
import net.albayyan.badan.storage.sqlite.Sql

/**
 * Append-only derived values, their input manifests, and materialized baselines. Recompute
 * APPENDS rows; reads take the latest `computed_at` (INVARIANT I2). Nothing is overwritten.
 *
 * "Nothing is overwritten" was, until migration 6, false for baselines specifically — a claim
 * this header made while `upsertBaseline` wrote with `INSERT OR REPLACE` against a UNIQUE natural
 * key, so a second write at the same (metric_id, covariate_context, window_days, valid_from) did a
 * DELETE-then-INSERT and lost the prior row. That surfaced only on the score-backfill RETRY (fixed
 * `window.to` → same `valid_from`, recomputed band), never the nightly path. Migration 6 drops that
 * unique index for a non-unique lookup index, and `upsertBaseline` below is now a plain `INSERT` —
 * every row carries a unique ULID `id`, so an append can no longer collide, and two rows sharing a
 * `valid_from` both survive with `computed_at` deciding the latest read. The method keeps its
 * `upsert` name because the baseline engine calls it; the semantics are now pure append.
 */
class DerivationRepository(private val db: SqliteConnection) {

    // MARK: - InputManifest

    fun insertManifest(m: InputManifest) {
        db.run(
            "INSERT OR REPLACE INTO input_manifests (id, inputs) VALUES (?, ?);",
            listOf(m.id, JsonCoding.encode(m.inputs)),
        )
    }

    fun manifest(id: String): InputManifest? {
        val row = db.query("SELECT * FROM input_manifests WHERE id = ?;", listOf(id)).firstOrNull() ?: return null
        val inputs = JsonCoding.decodeOrNull<List<InputManifest.Input>>(row.getString("inputs")) ?: return null
        return InputManifest(id = id, inputs = inputs)
    }

    // MARK: - DerivedValue (append-only)

    fun appendDerived(v: DerivedValue) {
        db.run(
            """
            INSERT INTO derived_values
              (id, metric_id, value, unit, period_key, confidence, provisional, algorithm_id,
               algorithm_version, input_manifest_id, computed_at, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                v.id, v.metricId, v.value, v.unit, v.periodKey,
                v.confidence, Sql.bool(v.provisional), v.algorithmId, v.algorithmVersion,
                v.inputManifestId, v.computedAt, v.updatedAt,
                v.originDeviceId, v.deletedAt,
            ),
        )
    }

    /** Latest derived value for a metric+period (latest-read over the append-only log). */
    fun latestDerived(metricId: String, periodKey: String): DerivedValue? =
        db.query(
            "SELECT * FROM derived_values WHERE metric_id = ? AND period_key = ? AND deleted_at IS NULL ORDER BY computed_at DESC LIMIT 1;",
            listOf(metricId, periodKey),
        ).firstOrNull()?.let { readDerived(it) }

    /**
     * Latest derived value per period for a metric, over a set of period keys — used by the
     * detail chart's derived series (e.g. daily RHR). Optional [computedFrom]/[computedTo] bound
     * the append-only scan by `computed_at` so a caller displaying a fixed window doesn't pay for
     * re-aggregating the metric's entire recompute history (PERF-234); omitted, behavior is
     * unchanged (all-time).
     */
    fun latestDerivedSeries(metricId: String, computedFrom: Long? = null, computedTo: Long? = null): List<DerivedValue> {
        // Group by period_key, take max computed_at.
        var subquerySql = "SELECT period_key, MAX(computed_at) AS mc FROM derived_values WHERE metric_id = ? AND deleted_at IS NULL"
        var outerSql = "WHERE d.metric_id = ? AND d.deleted_at IS NULL"
        val params = mutableListOf<Any?>(metricId)
        val outerParams = mutableListOf<Any?>(metricId)
        if (computedFrom != null) { subquerySql += " AND computed_at >= ?"; outerSql += " AND d.computed_at >= ?"; params.add(computedFrom); outerParams.add(computedFrom) }
        if (computedTo != null) { subquerySql += " AND computed_at <= ?"; outerSql += " AND d.computed_at <= ?"; params.add(computedTo); outerParams.add(computedTo) }
        subquerySql += " GROUP BY period_key"
        val rows = db.query(
            """
            SELECT d.* FROM derived_values d
            JOIN ($subquerySql) latest
            ON d.period_key = latest.period_key AND d.computed_at = latest.mc
            $outerSql
            ORDER BY d.period_key ASC;
            """,
            params + outerParams,
        )
        return rows.map { readDerived(it) }
    }

    fun allDerived(metricId: String): List<DerivedValue> =
        db.query("SELECT * FROM derived_values WHERE metric_id = ? AND deleted_at IS NULL ORDER BY computed_at ASC;", listOf(metricId))
            .map { readDerived(it) }

    // MARK: - Baseline

    /**
     * Appends a baseline. Named `upsert` for the engine that calls it, but a pure `INSERT` since
     * migration 6 (I2): the natural key is no longer UNIQUE, so this can never overwrite a prior
     * row — the earlier `INSERT OR REPLACE` deleted history whenever a retried backfill recomputed
     * a different band at an already-used `valid_from`. Every row's ULID `id` keeps inserts unique;
     * `latestBaseline` resolves which row is current on read.
     */
    fun upsertBaseline(b: Baseline) {
        db.run(
            """
            INSERT INTO baselines
              (id, metric_id, covariate_context, window_days, method, center, spread, band_low, band_high,
               n_points, provisional, algorithm_version, valid_from, computed_at, unit)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                b.id, b.metricId, b.covariateContext, b.windowDays.toLong(),
                b.method.code, b.center, b.spread, b.bandLow, b.bandHigh,
                b.nPoints.toLong(), Sql.bool(b.provisional), b.algorithmVersion, b.validFrom,
                b.computedAt, b.unit,
            ),
        )
    }

    /**
     * The current baseline for a metric+context: newest `valid_from`, and — now that migration 6
     * lets two appended rows share a `valid_from` (the retry case) — newest `computed_at` among
     * those, so the freshest belief wins and the older row is RETAINED as auditable history rather
     * than deleted. Served by `idx_baseline_lookup` (metric_id, covariate_context, valid_from DESC).
     */
    fun latestBaseline(metricId: String, context: String = "default"): Baseline? =
        db.query(
            "SELECT * FROM baselines WHERE metric_id = ? AND covariate_context = ? ORDER BY valid_from DESC, computed_at DESC LIMIT 1;",
            listOf(metricId, context),
        ).firstOrNull()?.let { readBaseline(it) }

    // MARK: - Readers

    companion object {
        fun readDerived(r: Row): DerivedValue =
            DerivedValue(
                id = r.requireString("id"), metricId = r.requireString("metric_id"),
                value = r.requireDouble("value"), unit = r.requireString("unit"),
                periodKey = r.requireString("period_key"), confidence = r.getDouble("confidence"),
                provisional = r.getBool("provisional"), algorithmId = r.requireString("algorithm_id"),
                algorithmVersion = r.requireString("algorithm_version"), inputManifestId = r.getString("input_manifest_id"),
                computedAt = r.requireDate("computed_at"), updatedAt = r.requireDate("updated_at"),
                originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
            )

        fun readBaseline(r: Row): Baseline =
            Baseline(
                id = r.requireString("id"), metricId = r.requireString("metric_id"),
                covariateContext = r.requireString("covariate_context"), windowDays = r.getInt("window_days") ?: 14,
                method = BaselineMethod.fromCode(r.requireString("method")),
                center = r.requireDouble("center"), spread = r.requireDouble("spread"),
                bandLow = r.requireDouble("band_low"), bandHigh = r.requireDouble("band_high"),
                nPoints = r.getInt("n_points") ?: 0, provisional = r.getBool("provisional"),
                algorithmVersion = r.requireString("algorithm_version"), validFrom = r.requireDate("valid_from"),
                computedAt = r.requireDate("computed_at"), unit = r.requireString("unit"),
            )
    }
}
