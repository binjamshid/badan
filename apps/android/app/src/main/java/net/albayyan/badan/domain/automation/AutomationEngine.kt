package net.albayyan.badan.domain.automation

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Clock
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.ExportTrigger
import net.albayyan.badan.export.ExportRunner
import net.albayyan.badan.storage.repositories.AutomationScheduleRepository
import net.albayyan.badan.storage.repositories.ExportTemplateRepository
import java.io.File
import java.time.ZoneId

// -- Seams --
//
// The engine's own logic is the due-gate and the failure budget, both pure (see
// AutomationSchedule.kt). Everything with a side effect goes behind one of these three interfaces so
// AutomationEngineTest can exercise the loop against fakes, and so the engine never has to touch
// WorkManager or the notification framework to be reasoned about.

/**
 * Whether new measurement data has arrived on the ingested axis since a watermark — the
 * `onNewData` cadence's gate. Deliberately the ingested axis (`ingested_at`), the SAME axis the
 * export cursor advances on, so "there is new data to export" here and "the cursor moved" there
 * can never disagree.
 */
interface AutomationDataFreshnessProbing {
    /** True when any raw/interval/session row has `ingested_at` strictly greater than [afterWatermark]
     *  (or any such row exists at all when it is null — a never-run schedule). */
    fun hasDataIngested(afterWatermark: Long?): Boolean
}

/**
 * Fires the "an automation was paused" notification. Best-effort by contract: the load-bearing
 * honesty guarantee is the VISIBLE pause (stored state the UI shows), which holds with no
 * notification permission at all; this is the nudge on top. On Android the notification is delivered
 * only when `POST_NOTIFICATIONS` is granted (EPIC-32 owns that request flow); the pause is not.
 */
interface AutomationPauseNotifier {
    fun automationPaused(scheduleId: String, language: AppLanguage)
}

/**
 * Runs one saved template through the EXISTING Phase-1 runner, unattended. A seam so the engine can
 * be tested against a fake; the real conformance ([ExportRunnerAutomationRunner]) calls
 * `ExportRunner.runTemplate` verbatim — the engine composes that path, it does not reimplement it.
 */
interface AutomationTemplateRunning {
    /**
     * Runs [template] unattended and returns only the terminal outcome. Unattended means NO
     * sensitive consent and NO passphrase are available, so `runTemplate` refuses a sensitive scope
     * — a scheduled automation must never carry standing permission to export meds/symptoms.
     */
    suspend fun runScheduledTemplate(template: ExportTemplate, trigger: ExportTrigger): ExportOutcome
}

/**
 * The real [AutomationTemplateRunning] over Phase-1's [ExportRunner]. [baseDir] is the scratch
 * directory `runTemplate` generates into (the worker passes the app cache dir), the Android
 * counterpart of iOS keeping its temp folder inside the runner.
 */
class ExportRunnerAutomationRunner(
    private val runner: ExportRunner,
    private val baseDir: File,
) : AutomationTemplateRunning {
    override suspend fun runScheduledTemplate(template: ExportTemplate, trigger: ExportTrigger): ExportOutcome =
        // consent/passphrase left at their defaults (null) — an unattended run cannot collect either,
        // so a sensitive template is refused inside runTemplate rather than silently narrowed.
        runner.runTemplate(template, trigger, baseDir).run.outcome
}

// -- Engine --

/** What one [AutomationEngine.evaluateDue] pass did, for the substrate's diagnostics and for tests. */
data class AutomationEvaluationSummary(
    /** Enabled `opportunisticBackground` schedules examined this wake. */
    val considered: Int = 0,
    /** Schedules that passed every due gate and were actually run through the template runner. */
    val ran: Int = 0,
    /** Schedules that transitioned INTO the paused state this wake (each fired one notification). */
    val pausedThisRun: Int = 0,
)

/**
 * EPIC-15 — the scheduling & automation engine (Kotlin mirror of iOS `AutomationEngine`). Invoked by
 * the Phase-0 WorkManager sync worker: it reads the enabled background-tier schedules, decides which
 * are due (cadence / quiet hours / data-newness), runs each due one through the EXISTING
 * `ExportRunner.runTemplate`, then updates the failure budget — pausing and notifying at three
 * consecutive failures.
 *
 * It owns neither generation nor delivery nor the cursor (all `runTemplate`'s), and it advances no
 * cursor itself — doing so would risk the exact Android cursor-advance data-loss class Phase 0's
 * audit caught. Its only writes are to `automation_schedules`.
 */
class AutomationEngine(
    private val schedules: AutomationScheduleRepository,
    private val templates: ExportTemplateRepository,
    private val runner: AutomationTemplateRunning,
    private val freshness: AutomationDataFreshnessProbing,
    private val notifier: AutomationPauseNotifier,
    private val clock: Clock,
    private val zoneId: ZoneId = ZoneId.systemDefault(),
) {
    /**
     * Evaluate every enabled background-tier schedule and run the ones that are due. [trigger] is
     * recorded on each `ExportRun` — [ExportTrigger.SCHEDULED_WORK] for WorkManager. Never throws: a
     * schedule whose template was deleted, or whose read fails, is skipped rather than aborting the
     * batch.
     */
    suspend fun evaluateDue(now: Long, trigger: ExportTrigger): AutomationEvaluationSummary {
        var considered = 0
        var ran = 0
        var pausedThisRun = 0
        val candidates = runCatching { schedules.dueCandidates() }.getOrDefault(emptyList())
        for (schedule in candidates) {
            considered++

            // hasNewData is only meaningful for onNewData; skip the DB read otherwise. The reference
            // watermark is lastSuccessAt (data ingested since we last succeeded) — kept on the
            // schedule so the engine never reaches into the cursor tables, which stay runTemplate's.
            val hasNewData = if (schedule.desiredCadence == AutomationCadence.ON_NEW_DATA) {
                freshness.hasDataIngested(schedule.lastSuccessAt)
            } else {
                false
            }

            if (AutomationDueEvaluator.verdict(schedule, now, hasNewData, zoneId) !is AutomationDueVerdict.Due) continue

            // A due schedule pointing at a since-deleted template can't run. Skip it (no strike — a
            // broken configuration the UI must repair, not a delivery that failed).
            val template = runCatching { templates.template(schedule.templateId) }.getOrNull() ?: continue

            val outcome = runner.runScheduledTemplate(template, trigger)
            ran++
            if (apply(outcome, schedule, now)) pausedThisRun++
        }
        return AutomationEvaluationSummary(considered, ran, pausedThisRun)
    }

    /**
     * Fold one run's outcome into the failure budget and persist it. The pure
     * [AutomationBudget.applyOutcome] decides the numbers; this is only the I/O. Returns true when
     * this run transitioned the schedule into paused (and therefore fired one notification).
     */
    private fun apply(outcome: ExportOutcome, schedule: AutomationSchedule, now: Long): Boolean {
        val update = AutomationBudget.applyOutcome(outcome, schedule, now)
        when (update.kind) {
            AutomationOutcomeKind.SUCCESS -> {
                val estimate = schedule.desiredCadence.estimatedNextWindow(now)
                runCatching { schedules.recordSuccess(schedule.id, now, estimate, now) }
            }
            AutomationOutcomeKind.FAILURE -> {
                runCatching { schedules.recordFailure(schedule.id, update.consecutiveFailures, now) }
                if (update.didJustPause) {
                    // NEVER a silent death: the schedule is now visibly paused (derived from the
                    // count just written) AND the user is told. Language from the template's scope.
                    val language = runCatching { templates.template(schedule.templateId)?.scope?.language }
                        .getOrNull() ?: AppLanguage.EN
                    notifier.automationPaused(schedule.id, language)
                    return true
                }
            }
            AutomationOutcomeKind.NEUTRAL -> Unit
        }
        return false
    }
}
