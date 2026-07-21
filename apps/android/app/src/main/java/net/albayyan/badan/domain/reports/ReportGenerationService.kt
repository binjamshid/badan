package net.albayyan.badan.domain.reports

import net.albayyan.badan.core.Clock
import net.albayyan.badan.storage.repositories.ReportRecord
import net.albayyan.badan.storage.repositories.ReportRepository

/**
 * Ties the pure [ReportBuilder] to the `reports` store: generate a model for a period, persist its
 * metadata (replacing any prior row for the same period+version), and answer the substrate's "is a
 * weekly report due?" question. Rendering the PDF is deliberately NOT here — the weekly trigger runs
 * on a WorkManager thread where the graphics stack does not belong, so this persists only the model +
 * metadata and the artifact is rendered on demand when the user opens or shares a report. Mirror of
 * iOS `ReportGenerationService.swift`.
 *
 * Thread-safety comes from the same place every other repository caller's does: the single
 * [net.albayyan.badan.storage.sqlite.SqliteConnection] serializes every access through its own lock,
 * and this class keeps no mutable state of its own.
 */
class ReportGenerationService(
    private val builder: ReportBuilder,
    private val reports: ReportRepository,
    private val clock: Clock,
    private val deviceId: String,
    private val timezone: () -> String,
    /**
     * Whether to include the medication-adherence roll-up (counts only). The composition root can
     * turn it off; on by default because a user's own aggregate adherence belongs in their report.
     */
    private val includeAdherence: Boolean = true,
) {

    /**
     * Generate the report for [periodKey] and persist its metadata, replacing any prior row for the
     * same (period, algorithm version). Returns the saved record and the freshly-built model. An
     * empty period is persisted honestly (a `hasSufficientData == false` model), never skipped — so
     * the trigger won't try to regenerate it every wake.
     */
    fun generateAndSave(periodKey: String, now: Long = clock.now()): Pair<ReportRecord, ReportModel> {
        val tz = timezone()
        val model = builder.generate(periodKey, tz, now, includeAdherence)
        val record = reports.save(
            periodKey = model.periodKey,
            algorithmVersionId = model.algorithmVersionId,
            generatedAt = model.generatedAt,
            sectionsIncluded = model.sectionsIncluded,
            artifactPath = null,
            sha256 = model.sha256,
            now = now,
            originDeviceId = deviceId,
        )
        return record to model
    }

    /**
     * The substrate's weekly entry point: generate and persist every weekly report [ReportTrigger]
     * says is due — the last completed ISO week, plus any bounded backfill for weeks a run of missed
     * wakes skipped — and return the period keys actually generated, newest first. Idempotent across
     * repeated opportunistic wakes (dedup is by existing period key).
     *
     * A failure part-way through is NOT swallowed: it throws, and the reports generated before it
     * stay persisted. That is deliberate — each report is an independent row, so a partial backfill
     * is a smaller gap rather than a corrupt state, and the next wake resumes from whatever is still
     * missing.
     */
    fun generateDueWeekly(now: Long = clock.now()): List<String> {
        val tz = timezone()
        val existing = reports.periodKeys(ReportBuilder.algorithm.id)
        val due = ReportTrigger.dueWeeklyPeriodKeys(now, tz, existing)
        for (periodKey in due) generateAndSave(periodKey, now)
        return due
    }
}
