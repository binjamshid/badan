package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Sql
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * Storage for the journal correlation engine's findings (EPIC-29), over the `derived_values` and
 * `input_manifests` tables created by **sensitive** migration v4. Mirror of iOS
 * `CorrelationRepository`, same queries and same semantics.
 *
 * **This repository holds the sensitive connection and nothing else** — the same structural I7
 * enforcement [JournalRepository] uses, for the same reason and one step further along the chain.
 * A journal row says "the user logged alcohol on the 12th". A correlation finding says the same
 * thing in its *identifier*: `journal.correlation.alcohol.readiness.score` discloses the habit
 * before any value is read, in a column, in plain text. If that row lived in `badan.db` it would
 * survive `Database.purgeSensitiveNamespace()` — a literal file deletion — and keep disclosing it
 * after the user had turned sensitive records off. There is no `main` connection in scope in this
 * file, so no statement here can address `badan.db` even by accident.
 *
 * This is deliberately NOT how `stress.day_trend` works, and the difference is principled rather
 * than inconsistent: that metric is sensitive-plus too, but its ID names no behaviour, so only its
 * VALUE is revealing and the registry's `sensitiveClass` gate on the export path is enough. Here
 * the identifier itself is the disclosure, so placement has to carry the guarantee.
 *
 * Append-only (I2): a recompute INSERTs a fresh row with a new `computed_at` and the latest one
 * wins on read. Nothing here updates or deletes a finding, so "what BADAN believed about this
 * behaviour last month" stays answerable — which for a statistical claim is the whole point of
 * keeping the history.
 */
class CorrelationRepository(
    private val sensitive: SqliteConnection,
) {

    /** Batch a finding's manifest + row into one transaction instead of two implicit commits. */
    fun <T> transaction(block: () -> T): T = sensitive.transaction(block)

    // MARK: - Input manifests

    fun insertManifest(m: InputManifest) {
        sensitive.run(
            "INSERT OR REPLACE INTO input_manifests (id, inputs) VALUES (?, ?);",
            listOf(m.id, JsonCoding.encode(m.inputs)),
        )
    }

    fun manifest(id: String): InputManifest? {
        val row = sensitive.query("SELECT * FROM input_manifests WHERE id = ?;", listOf(id)).firstOrNull()
            ?: return null
        val inputs = JsonCoding.decodeOrNull<List<InputManifest.Input>>(row.getString("inputs")) ?: return null
        return InputManifest(id = id, inputs = inputs)
    }

    // MARK: - Findings (append-only)

    fun appendDerived(v: DerivedValue) {
        sensitive.run(
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

    /** Latest row for a metric + window (latest-read over the append-only log). */
    fun latestDerived(metricId: String, periodKey: String): DerivedValue? =
        sensitive.query(
            """
            SELECT * FROM derived_values WHERE metric_id = ? AND period_key = ? AND deleted_at IS NULL
            ORDER BY computed_at DESC LIMIT 1;
            """,
            listOf(metricId, periodKey),
        ).firstOrNull()?.let { DerivationRepository.readDerived(it) }

    /**
     * The current finding per metric id — one row per behaviour x score pair, newest belief each.
     *
     * The read a stored-findings surface would make, kept in parity with the iOS repository. It has
     * **no caller on this platform yet**: the correlations screen renders the outcomes
     * `CorrelationEngine.recompute` has just returned, because a suppressed pair is never persisted
     * and the "not yet, about N more days" rows can only come from a live evaluation — so the
     * findings and the shortfalls arrive together, from one pass.
     *
     * Grouped on `metric_id` alone rather than on (metric_id, period_key): a finding's window slides
     * forward every day, so grouping by both would return the whole history of windows instead of
     * the current view.
     */
    fun latestFindings(): List<DerivedValue> =
        sensitive.query(
            """
            SELECT d.* FROM derived_values d
            JOIN (SELECT metric_id, MAX(computed_at) AS mc FROM derived_values
                  WHERE deleted_at IS NULL GROUP BY metric_id) latest
            ON d.metric_id = latest.metric_id AND d.computed_at = latest.mc
            WHERE d.deleted_at IS NULL
            ORDER BY d.metric_id ASC;
            """,
        ).map { DerivationRepository.readDerived(it) }

    /** Every appended row for one pair, oldest first — the audit trail I2 exists to preserve. */
    fun allDerived(metricId: String): List<DerivedValue> =
        sensitive.query(
            "SELECT * FROM derived_values WHERE metric_id = ? ORDER BY computed_at ASC;",
            listOf(metricId),
        ).map { DerivationRepository.readDerived(it) }
}
