package net.albayyan.badan.platform.background

import android.content.Context
import android.os.Build
import android.os.UserManager
import androidx.work.CoroutineWorker
import androidx.work.WorkInfo
import androidx.work.WorkerParameters
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.ExportTrigger
import net.albayyan.badan.platform.health.BackfillWindow
import net.albayyan.badan.storage.repositories.BackgroundRun
import net.albayyan.badan.storage.repositories.BackgroundRunKind
import net.albayyan.badan.storage.repositories.BackgroundRunOutcome
import net.albayyan.badan.storage.repositories.BackgroundWorkDone
import kotlin.coroutines.cancellation.CancellationException

/**
 * EPIC-05 — the worker the hourly periodic schedule and the user-triggered "sync now" both run.
 *
 * Contract with the rest of the app: this class is a *driver*, not a second ingest path. It calls
 * `AppEnvironment.syncHealthConnect`, the same entry point the foreground connect flow uses, so
 * dedup, provenance stamping (I1) and baseline recomputation happen exactly once in exactly one
 * place. Anything that looks like reading Health Connect directly from here is a bug.
 *
 * The read underneath is already incremental wherever it can be, and this doc used to say it was
 * not. `HealthConnectAdapter.readType` resumes from a persisted changes token whenever one exists
 * for a record type — EPIC-02 shipped, wired at `AppEnvironment.healthConnect` through
 * `anchors = readAnchors` — so after the first successful sync a wakeup costs what changed, not
 * what the window spans. The stale TODO here (and its twin in `AppEnvironment.syncHealthConnect`)
 * told the next reader to go build something that was already running, and told them to set
 * `BackgroundWorkDone.incremental` that nobody ever set: audit finding #4.
 *
 * [CATCHUP_LOOKBACK_DAYS] is still passed and still earns its place. A changes token expires after
 * roughly 30 days unused and is invalidated when a permission is revoked and re-granted; the
 * fallback for both is a full windowed re-read, and handing that fallback the connect path's 90
 * days would re-walk a quarter of a year on a background wakeup. Upserts are keyed by upstream
 * identity and idempotent, so the short overlapping window is correct on either path.
 */
class SyncWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        // Ordered before anything that touches the database on purpose. BADAN's stores live in
        // credential-encrypted storage, so opening them before first unlock throws — and the run
        // row recording *that* would have to be written to the very store that is unavailable.
        // Hence Android never logs a `storeLocked` outcome even though the enum has one for iOS
        // parity: the honest answer is to retry, not to invent a row we cannot persist.
        //
        // WorkManager already defers non-direct-boot-aware work until first unlock, so this should
        // be unreachable today. It stays because `Result.retry()` is the correct response if it
        // ever is reached, and the alternative is an unexplained SQLiteException at DB-open time.
        if (!isUserUnlocked()) return Result.retry()

        val env = runCatching { AppEnvironment.shared(applicationContext) }.getOrNull()
            ?: return Result.retry()

        // EPIC-26: the score-backfill path is a pure re-derivation over already-ingested data, so it
        // runs BEFORE (and independently of) the Health-Connect eligibility gate below — it needs no
        // connection and must not be skipped for a disconnected user who edited their HR max.
        if (inputData.getBoolean(BackgroundScheduler.KEY_SCORE_BACKFILL, false)) {
            return runScoreBackfill(env)
        }

        val userTriggered = inputData.getBoolean(BackgroundScheduler.KEY_USER_TRIGGERED, false)
        val kind = if (userTriggered) {
            BackgroundRunKind.FOREGROUND_SYNC
        } else {
            BackgroundRunKind.WORK_MANAGER_PERIODIC
        }
        val startedAt = env.clock.now()

        // EPIC-15: evaluate due automations on the periodic wake — the Android counterpart of iOS's
        // BGAppRefresh automation step. Exports read already-stored data, so this runs regardless of
        // Health-Connect eligibility below, and ONLY on the periodic wake, never on a user "sync
        // now" tap (tapping Sync must not silently fire the user's scheduled exports). Each due
        // automation writes its own `ExportRun`; the count here is the substrate-level diagnostic.
        val automationsEvaluated = if (!userTriggered) {
            runCatching {
                env.automationEngine.evaluateDue(env.clock.now(), ExportTrigger.SCHEDULED_WORK).ran
            }.getOrDefault(0)
        } else {
            0
        }

        // EPIC-31: generate every weekly report that is due — the last completed ISO week if it has
        // none yet, plus the bounded gap backfill `ReportTrigger` returns when a run of wakes was
        // missed entirely. Like the
        // automation step above it reads only already-stored data, so it runs before the
        // Health-Connect eligibility gate and ONLY on the periodic wake — a user tapping "sync now"
        // is asking for their data, not for a report to be produced behind them. It is deliberately
        // not allowed to fail the wake: a report is a regenerable rollup and the Reports screen can
        // always build one on demand, so a failure here must not cost the user their sync. Nothing
        // is written to the substrate row for it — no `BackgroundWorkDone` field fits "reports
        // generated" and inventing one would be a schema change for a diagnostic.
        if (!userTriggered) {
            runCatching { env.reportGeneration.generateDueWeekly(env.clock.now()) }
        }

        // EPIC-32: re-arm the budgeted decision notifications. Each enabled class is scheduled as a
        // ONE-SHOT piece of work, so once it fires nothing else would arm the next day's — a user
        // who opted into the morning summary would receive it once and then hear nothing until they
        // happened to relaunch the app. Riding this wake (as EPIC-15's automations and EPIC-31's
        // reports already do) keeps the daily cadence going without a second schedule of its own.
        //
        // Runs on the periodic wake only — a user tapping "sync now" is asking for their data, not
        // for BADAN to re-evaluate what to notify them about. Blocking by design: work handed to a
        // background scope here can be lost when the worker's process is torn down. It is idempotent
        // per class+day (the ledger), needs no Health Connect, is a no-op for a user with every
        // class OFF (the default), and never prompts for permission. Not allowed to fail the wake.
        if (!userTriggered) {
            runCatching { env.reconcileDecisionNotificationsBlocking() }
        }

        // Deliberately writes no run row and reports success. Two reasons, and the first is a data
        // bug rather than tidiness: `syncHealthConnect` purges the demo seed on its first real
        // ingest, so letting this run for a user who has never connected would silently delete the
        // sample data they are still exploring. Second, an unconnected user would otherwise
        // accumulate 24 empty rows a day, burying the wakeups that carry information.
        //
        // A user-triggered run checks only that Health Connect is connected. Turning the
        // background-sync preference off means "stop waking my phone on a schedule", not "ignore me
        // when I tap Sync now" — gating the one-off on the same preference would make the button
        // silently do nothing for precisely the users who turned the schedule off.
        val eligible = if (userTriggered) {
            env.isHealthConnectedPersisted()
        } else {
            env.isBackgroundSyncEligible()
        }
        if (!eligible) {
            // The periodic wake still evaluated automations above (they need no Health Connect), so
            // record a substrate row when any ran rather than dropping the diagnostic — the empty-row
            // suppression is only for wakes that did nothing at all.
            if (automationsEvaluated > 0) {
                record(
                    env, kind, startedAt, BackgroundRunOutcome.COMPLETED,
                    BackgroundWorkDone(runAttempt = runAttemptCount, automationsEvaluated = automationsEvaluated),
                )
            }
            return Result.success()
        }

        return try {
            val summary = env.syncHealthConnect(lookbackDays = CATCHUP_LOOKBACK_DAYS)
            val outcome = if (summary == null) {
                BackgroundRunOutcome.ERROR
            } else {
                BackgroundRunOutcome.COMPLETED
            }
            record(
                env, kind, startedAt, outcome,
                BackgroundWorkDone(
                    samples = summary?.samples ?: 0,
                    intervals = summary?.intervals ?: 0,
                    sessions = summary?.sessions ?: 0,
                    suppressed = summary?.suppressed ?: 0,
                    unmapped = summary?.unmapped ?: 0,
                    runAttempt = runAttemptCount,
                    incremental = IncrementalClassification.wasIncremental(
                        summary?.backfillWindows.orEmpty(),
                    ),
                    automationsEvaluated = automationsEvaluated,
                ),
            )
            // Opportunistic §9.8 pruning: bounded DELETE on an indexed column, cheaper than owning
            // a second scheduled wakeup just to run it.
            runCatching { env.backgroundRuns.prune(env.clock.now()) }
            if (outcome == BackgroundRunOutcome.ERROR) retryWithinBudget() else Result.success()
        } catch (cancellation: CancellationException) {
            // The system stopped us. `CoroutineWorker` cancels the job rather than calling an
            // overridable `onStopped` (it is final), so this catch is the only place a stop can be
            // classified. The repository writes are plain blocking calls, which still execute in a
            // cancelled coroutine — a suspending write here would silently drop the row.
            record(env, kind, startedAt, stoppedOutcome(), stoppedWorkDone())
            throw cancellation
        } catch (t: Throwable) {
            // No `t.message` anywhere near the log or the row: an exception out of the ingest path
            // can carry record contents, and this table is exportable.
            record(
                env, kind, startedAt, BackgroundRunOutcome.ERROR,
                BackgroundWorkDone(runAttempt = runAttemptCount),
            )
            retryWithinBudget()
        }
    }

    /**
     * EPIC-26 — run the queued effort/score backfill (an HR-max/zone edit). A pure re-derivation over
     * already-ingested data through [AppEnvironment.runPendingScoreBackfill], which is append-only
     * (I2) so an interrupted run simply re-runs and skips the days it already wrote. Logged as
     * `bgProcessing` — the parity-correct label for heavy deferrable processing (matching iOS's
     * BGProcessing score-backfill step), not the hourly-sync `workManagerPeriodic`.
     */
    private suspend fun runScoreBackfill(env: AppEnvironment): Result {
        val startedAt = env.clock.now()
        return try {
            env.runPendingScoreBackfill()
            record(
                env, BackgroundRunKind.BG_PROCESSING, startedAt, BackgroundRunOutcome.COMPLETED,
                BackgroundWorkDone(runAttempt = runAttemptCount),
            )
            // Opportunistic §9.8 pruning, matching the sync path.
            runCatching { env.backgroundRuns.prune(env.clock.now()) }
            Result.success()
        } catch (cancellation: CancellationException) {
            record(env, BackgroundRunKind.BG_PROCESSING, startedAt, stoppedOutcome(), stoppedWorkDone())
            throw cancellation
        } catch (t: Throwable) {
            // No `t.message` near the log or row: an exception out of derivation can carry record
            // contents, and this table is exportable. The request marker is left in place (only
            // cleared on success inside `runPendingScoreBackfill`), so the retry re-runs the window.
            record(
                env, BackgroundRunKind.BG_PROCESSING, startedAt, BackgroundRunOutcome.ERROR,
                BackgroundWorkDone(runAttempt = runAttemptCount),
            )
            retryWithinBudget()
        }
    }

    private fun record(
        env: AppEnvironment,
        kind: BackgroundRunKind,
        startedAt: Long,
        outcome: BackgroundRunOutcome,
        workDone: BackgroundWorkDone,
    ) {
        runCatching {
            env.backgroundRuns.insert(
                BackgroundRun(
                    id = Ulid.newId(),
                    kind = kind,
                    startedAt = startedAt,
                    durationMs = env.clock.now() - startedAt,
                    outcome = outcome,
                    workDone = workDone,
                    // Always null on Android — WorkManager has no completion-handler budget.
                    completionHandlerCalledInMs = null,
                ),
            )
        }
    }

    private fun stoppedOutcome(): BackgroundRunOutcome =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            StopReasonMapping.outcomeFor(stopReason)
        } else {
            StopReasonMapping.outcomeForUnknownReason()
        }

    private fun stoppedWorkDone(): BackgroundWorkDone {
        val known = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        return BackgroundWorkDone(
            runAttempt = runAttemptCount,
            stopReason = if (known) stopReason else null,
            stopReasonKnown = known,
        )
    }

    private fun isUserUnlocked(): Boolean =
        applicationContext.getSystemService(UserManager::class.java)?.isUserUnlocked ?: true

    /**
     * Retry, but only while the attempt count is small. An unbounded `Result.retry()` on periodic
     * work turns a persistent condition — Health Connect uninstalled, permission revoked — into an
     * exponential-backoff retry chain that outlives the period it belongs to. Giving up returns
     * success rather than failure because the *next* period will try again in an hour anyway;
     * `Result.failure()` would cancel the periodic chain outright and background sync would stay
     * dead until the user reopened the app.
     */
    private fun retryWithinBudget(): Result =
        if (runAttemptCount < MAX_RETRY_ATTEMPTS) Result.retry() else Result.success()

    private companion object {
        /**
         * Health Connect's own default history window is 30 days; two days is a catch-up overlap
         * generous enough to absorb a device that was throttled overnight, without re-walking
         * history every hour.
         *
         * Not superseded by the changes token, which is what the previous "replaced by the changes
         * token" note implied. This is the width of the *fallback* re-read that runs whenever a
         * token has expired or been invalidated, so it governs the expensive path rather than the
         * cheap one — see the class doc.
         */
        const val CATCHUP_LOOKBACK_DAYS = 2
        const val MAX_RETRY_ATTEMPTS = 3
    }
}

/**
 * Whether a completed run read incrementally, for `BackgroundWorkDone.incremental`.
 *
 * The field existed and was never assigned anything but its `false` default, so Diagnostics stated
 * — permanently, on every Android background run — that every sync was a full-window read. After
 * the first successful sync essentially none of them are. That is audit finding #4, and it is the
 * kind of defect that is worse than no field at all: an unset field reads as "not measured", a
 * hardcoded false reads as a measurement.
 *
 * **A run counts as incremental only when every type it covered was.** A mixed run — some types
 * resuming from a token, others falling back to a windowed re-read because their token expired —
 * reports false. One boolean cannot describe a mixed run, and of the two available lies the
 * conservative one is better: over-reporting "incremental" would make a run that re-walked 30 days
 * of history look cheap in exactly the diagnostics someone consults to explain a battery
 * complaint. An empty window list is false for the same reason, not true by vacuity: a run that
 * covered no types measured nothing.
 *
 * A top-level object for the same reason [StopReasonMapping] is one — `BackgroundSubstrateTest`
 * reaches it without loading `CoroutineWorker` and the Android framework into a plain JVM test.
 */
internal object IncrementalClassification {
    fun wasIncremental(windows: List<BackfillWindow>): Boolean =
        windows.isNotEmpty() && windows.all { it.incremental }
}

/**
 * Classifies a WorkManager stop reason into a §9.8 outcome. A top-level object rather than a
 * companion of [SyncWorker] so `BackgroundSubstrateTest` can exercise it without loading the worker
 * class (and with it `CoroutineWorker` and the Android framework) into a plain JVM test.
 *
 * The governing rule, from §12 EPIC-05 task 5: **throttling is not an error.** Every reason here
 * that means "the platform decided not to let this run now" maps to `throttled`, which
 * `BackgroundRunOutcome.isFailure` reports as false and the UI presents as guidance rather than as
 * a problem. Only a genuine exception out of the ingest path is `error`.
 */
internal object StopReasonMapping {

    fun outcomeFor(stopReason: Int): BackgroundRunOutcome = when (stopReason) {
        // Ran, but hit WorkManager's ten-minute execution ceiling. The direct analogue of an iOS
        // BGTask expiration, and distinct from throttling: the work started and ran out of time.
        WorkInfo.STOP_REASON_TIMEOUT -> BackgroundRunOutcome.EXPIRED

        // Doze, App Standby buckets, background restriction, quota exhaustion, the battery-not-low
        // constraint dropping out mid-run, and the scheduler preempting or rescheduling us. All of
        // this is the platform managing battery, which is exactly what it is supposed to do.
        WorkInfo.STOP_REASON_CONSTRAINT_DEVICE_IDLE,
        WorkInfo.STOP_REASON_CONSTRAINT_BATTERY_NOT_LOW,
        WorkInfo.STOP_REASON_CONSTRAINT_CHARGING,
        WorkInfo.STOP_REASON_CONSTRAINT_CONNECTIVITY,
        WorkInfo.STOP_REASON_CONSTRAINT_STORAGE_NOT_LOW,
        WorkInfo.STOP_REASON_APP_STANDBY,
        WorkInfo.STOP_REASON_BACKGROUND_RESTRICTION,
        WorkInfo.STOP_REASON_QUOTA,
        WorkInfo.STOP_REASON_DEVICE_STATE,
        WorkInfo.STOP_REASON_PREEMPT,
        WorkInfo.STOP_REASON_SYSTEM_PROCESSING,
        WorkInfo.STOP_REASON_ESTIMATED_APP_LAUNCH_TIME_CHANGED,
        // STOP_REASON_USER is the force-stop case — including the "restrict battery usage" button
        // in a Samsung or Xiaomi battery panel, which is the precise scenario the guidance copy
        // addresses. It is a device-management decision, not a BADAN failure.
        WorkInfo.STOP_REASON_USER -> BackgroundRunOutcome.THROTTLED

        // BADAN cancelled its own work (background sync switched off, Health Connect disconnected).
        // Recorded as completed rather than throttled: nothing was deferred and nothing went wrong,
        // and calling our own teardown "throttled" would inflate the OEM-guidance heuristic that
        // `CadenceSummary.suggestsThrottling` computes from throttled counts.
        WorkInfo.STOP_REASON_CANCELLED_BY_APP -> BackgroundRunOutcome.COMPLETED

        else -> outcomeForUnknownReason()
    }

    /**
     * The fallback, used for `STOP_REASON_UNKNOWN`, for any reason a future WorkManager adds, and
     * for every stop on API 26–30 where `getStopReason()` does not exist.
     *
     * Resolving the unknown to `throttled` rather than `error` is a deliberate bias: the population
     * of "we were stopped and cannot say why" is dominated by Doze and OEM battery managers, and
     * the cost of the two mistakes is asymmetric — a throttle mislabelled as an error tells a user
     * their health app is broken when it is not, while an error mislabelled as a throttle shows
     * them battery guidance that is merely unhelpful. `stopReasonKnown = false` is recorded
     * alongside so diagnostics never presents this as a confident classification.
     */
    fun outcomeForUnknownReason(): BackgroundRunOutcome = BackgroundRunOutcome.THROTTLED
}
