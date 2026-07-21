package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.automation.AutomationCadence
import net.albayyan.badan.domain.automation.AutomationDataFreshnessProbing
import net.albayyan.badan.domain.automation.AutomationSchedule
import net.albayyan.badan.domain.automation.AutomationTier
import net.albayyan.badan.domain.automation.QuietHours
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.Sql
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * `automation_schedules` (migration v4, plan §9.7) — the user's declared automation intent. Mirror
 * of the iOS `AutomationScheduleRepository`, same SQL.
 *
 * Soft-delete only (`deleted_at`), like every other convention-column table: a deleted schedule's
 * `templateId` may still be referenced by `export_runs` rows it produced, and the run ledger is a
 * record of what happened, not a view over what currently exists.
 *
 * [recordSuccess]/[recordFailure] are the ONLY writers of the failure budget, called by
 * `AutomationEngine` after a run. They update in place (scheduler bookkeeping, not a derived health
 * value — I2 does not apply): the append-only audit of what an automation did lives in `export_runs`.
 */
class AutomationScheduleRepository(private val db: SqliteConnection) {

    // -- Writes --

    /** Insert or replace a schedule (`OR REPLACE`; the id is a caller-held ULID). */
    fun upsert(schedule: AutomationSchedule) = write(schedule)

    private fun write(s: AutomationSchedule) {
        db.run(
            """
            INSERT OR REPLACE INTO automation_schedules
              (id, template_id, tier, desired_cadence, quiet_hours, enabled, consecutive_failures,
               last_success_at, next_expected_window, created_at, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ${Rows.convPlaceholders});
            """,
            listOf(
                s.id, s.templateId, s.tier.code, s.desiredCadence.code, s.quietHours?.storageString,
                Sql.bool(s.enabled), s.consecutiveFailures.toLong(), s.lastSuccessAt,
                s.nextExpectedWindow, s.createdAt,
            ) + Rows.convParams(s.updatedAt, s.originDeviceId, s.deletedAt),
        )
    }

    /**
     * Record a clean run (success or `skippedNoData`): reset the strike counter and stamp the
     * success clock. `nextExpectedWindow` is the DISPLAY-ONLY estimate — persisted so a surface can
     * show it, never read back by the engine as a fire time.
     */
    fun recordSuccess(id: String, at: Long, nextExpectedWindow: Long?, now: Long) {
        db.run(
            """
            UPDATE automation_schedules
               SET consecutive_failures = 0, last_success_at = ?, next_expected_window = ?, updated_at = ?
             WHERE id = ? AND deleted_at IS NULL;
            """,
            listOf(at, nextExpectedWindow, now, id),
        )
    }

    /**
     * Record a failed run: set the new strike count (computed by `AutomationBudget`, so the pause
     * threshold lives in one place). At the budget the derived `isPaused` flips true and the engine
     * stops considering this schedule until a resume.
     */
    fun recordFailure(id: String, consecutiveFailures: Int, now: Long) {
        db.run(
            "UPDATE automation_schedules SET consecutive_failures = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
            listOf(consecutiveFailures.toLong(), now, id),
        )
    }

    /** Un-pause a schedule the user chose to resume: reset the strike counter to 0. */
    fun resume(id: String, now: Long) = recordFailure(id, 0, now)

    /** Enable/disable without deleting — the module is hideable-without-deletion. */
    fun setEnabled(id: String, enabled: Boolean, now: Long) {
        db.run(
            "UPDATE automation_schedules SET enabled = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
            listOf(Sql.bool(enabled), now, id),
        )
    }

    fun softDelete(id: String, at: Long) {
        db.run(
            "UPDATE automation_schedules SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
            listOf(at, at, id),
        )
    }

    // -- Reads --

    /** Every live schedule (for the UI) — including paused and disabled, so the pause is visible. */
    fun all(): List<AutomationSchedule> =
        db.query("SELECT * FROM automation_schedules WHERE deleted_at IS NULL ORDER BY created_at ASC;")
            .map { read(it) }

    fun schedule(id: String): AutomationSchedule? =
        db.query("SELECT * FROM automation_schedules WHERE id = ? AND deleted_at IS NULL;", listOf(id))
            .firstOrNull()?.let { read(it) }

    /**
     * The candidates a background wake evaluates: enabled, background-tier, not deleted. Matches the
     * `(enabled, tier)` index (migration v4). Paused schedules are RETURNED (not filtered in SQL) so
     * the pause decision stays in the one pure place that owns it (`AutomationDueEvaluator`, which
     * skips them).
     */
    fun dueCandidates(): List<AutomationSchedule> =
        db.query(
            "SELECT * FROM automation_schedules WHERE enabled = 1 AND tier = ? AND deleted_at IS NULL ORDER BY created_at ASC;",
            listOf(AutomationTier.OPPORTUNISTIC_BACKGROUND.code),
        ).map { read(it) }

    companion object {
        fun read(r: Row): AutomationSchedule =
            AutomationSchedule(
                id = r.requireString("id"),
                templateId = r.requireString("template_id"),
                // An unparseable tier falls back to MANUAL_ONLY — never auto-run — so a corrupt row
                // can only ever become MORE conservative, never silently fire in the background.
                tier = AutomationTier.fromCode(r.getString("tier")),
                desiredCadence = AutomationCadence.fromCode(r.getString("desired_cadence")),
                quietHours = QuietHours.fromStorage(r.getString("quiet_hours")),
                enabled = r.getBool("enabled"),
                consecutiveFailures = r.getInt("consecutive_failures") ?: 0,
                lastSuccessAt = r.getDate("last_success_at"),
                nextExpectedWindow = r.getDate("next_expected_window"),
                createdAt = r.requireDate("created_at"),
                updatedAt = r.requireDate("updated_at"),
                originDeviceId = r.requireString("origin_device_id"),
                deletedAt = r.getDate("deleted_at"),
            )
    }
}

/**
 * The real [AutomationDataFreshnessProbing], over the main DB. Asks the one question the `onNewData`
 * cadence needs: has anything been ingested since a watermark? Scans the three measurement tables on
 * the `ingested_at` axis — the SAME axis the export cursor advances on — so the engine's "there is
 * new data" agrees with `runTemplate`'s "the cursor moved".
 */
class AutomationDataFreshnessProbe(private val db: SqliteConnection) : AutomationDataFreshnessProbing {
    override fun hasDataIngested(afterWatermark: Long?): Boolean {
        // null watermark (never-run schedule) ⇒ "any row at all": 0 makes `ingested_at > 0` true for
        // every real row without a separate query path.
        val ref = afterWatermark ?: 0L
        // One row per table, LIMIT 1 overall — bounded: it stops at the first qualifying row.
        val rows = db.query(
            "SELECT 1 AS present FROM raw_samples WHERE ingested_at > ? " +
                "UNION ALL SELECT 1 FROM interval_records WHERE ingested_at > ? " +
                "UNION ALL SELECT 1 FROM sessions WHERE ingested_at > ? LIMIT 1;",
            listOf(ref, ref, ref),
        )
        return rows.isNotEmpty()
    }
}
