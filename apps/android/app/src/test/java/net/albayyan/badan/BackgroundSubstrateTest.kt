package net.albayyan.badan

import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkInfo
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.platform.background.BackgroundCopy
import net.albayyan.badan.platform.background.BackgroundScheduler
import net.albayyan.badan.platform.background.StopReasonMapping
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.repositories.BackgroundRunKind
import net.albayyan.badan.storage.repositories.BackgroundRunOutcome
import net.albayyan.badan.storage.repositories.BackgroundRunRepository
import net.albayyan.badan.storage.repositories.BackgroundWorkDone
import net.albayyan.badan.storage.repositories.CadenceSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.TimeUnit

/**
 * EPIC-05 — the Android background substrate's decisions, tested where they can be tested.
 *
 * Scope, stated honestly because `FoundationTest`'s doc had to be corrected for claiming coverage
 * it did not have: this module still has no `androidTest` source set and no Robolectric, so
 * nothing here touches a real database or a live `WorkManager`. What *is* covered is every decision
 * that was extracted into a pure function precisely so it could be — outcome classification, the
 * value-freeness of the run row, the unique-work policies, the pruning bound, and the honest-label
 * copy. `BackgroundRunRepository`'s SQL and `SyncWorker.doWork`'s control flow remain uncovered and
 * are verified by the device-lab soak in the EPIC-05 acceptance criteria.
 */
class BackgroundSubstrateTest {

    // MARK: - Outcome mapping

    @Test fun timeoutIsExpiredNotThrottled() {
        // The one stop reason where the work genuinely started and ran out of runway — the direct
        // analogue of an iOS BGTask expiration. Collapsing it into `throttled` would lose the
        // distinction that tells us whether ingest needs chunking.
        assertEquals(
            BackgroundRunOutcome.EXPIRED,
            StopReasonMapping.outcomeFor(WorkInfo.STOP_REASON_TIMEOUT),
        )
    }

    @Test fun everyDeferralReasonMapsToThrottled() {
        val deferrals = listOf(
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
            WorkInfo.STOP_REASON_USER,
        )
        for (reason in deferrals) {
            assertEquals(
                "stop reason $reason must be throttled, not an error",
                BackgroundRunOutcome.THROTTLED,
                StopReasonMapping.outcomeFor(reason),
            )
        }
    }

    /**
     * The load-bearing assertion of EPIC-05 task 5. If this ever fails, a Samsung or Xiaomi user
     * whose phone deferred a sync is being told their health app failed.
     */
    @Test fun throttlingIsNeverAFailure() {
        assertFalse(BackgroundRunOutcome.THROTTLED.isFailure)
        assertFalse(BackgroundRunOutcome.EXPIRED.isFailure)
        assertFalse(BackgroundRunOutcome.STORE_LOCKED.isFailure)
        assertFalse(BackgroundRunOutcome.COMPLETED.isFailure)
        assertTrue(BackgroundRunOutcome.ERROR.isFailure)
    }

    @Test fun unknownStopReasonBiasesToThrottled() {
        // Covers API 26-30, where getStopReason() does not exist, and any reason a future
        // WorkManager release adds.
        assertEquals(BackgroundRunOutcome.THROTTLED, StopReasonMapping.outcomeForUnknownReason())
        assertEquals(
            BackgroundRunOutcome.THROTTLED,
            StopReasonMapping.outcomeFor(WorkInfo.STOP_REASON_UNKNOWN),
        )
        assertEquals(BackgroundRunOutcome.THROTTLED, StopReasonMapping.outcomeFor(-9999))
    }

    @Test fun selfCancellationIsNotCountedAsThrottling() {
        // BADAN cancelling its own work must not feed the OEM-guidance heuristic, or turning
        // background sync off would make the app claim the phone is throttling it.
        assertEquals(
            BackgroundRunOutcome.COMPLETED,
            StopReasonMapping.outcomeFor(WorkInfo.STOP_REASON_CANCELLED_BY_APP),
        )
    }

    @Test fun outcomeCodesRoundTripThroughStorage() {
        for (outcome in BackgroundRunOutcome.entries) {
            assertEquals(outcome, BackgroundRunOutcome.fromCode(outcome.code))
        }
        for (kind in BackgroundRunKind.entries) {
            assertEquals(kind, BackgroundRunKind.fromCode(kind.code))
        }
    }

    // MARK: - Run-row value-freeness

    /**
     * Structural enforcement of "no health values in logs, ever" for the one table that records
     * what a background run did. A count is diagnostics; a measurement is a health value, and this
     * table is displayed in Diagnostics and included in exports.
     *
     * Asserts on the *serialized* form rather than the Kotlin type, because that is what actually
     * lands in the `work_done` column: any field added as a `Double` (a value), a `String` (a
     * source name, a metric id, an exception message) or a nested object fails here.
     */
    @Test fun workDoneCarriesNoValues() {
        val encoded = JsonCoding.encode(
            BackgroundWorkDone(
                samples = 42, intervals = 7, sessions = 1, suppressed = 2, unmapped = 0,
                runAttempt = 1, stopReason = WorkInfo.STOP_REASON_QUOTA, stopReasonKnown = true,
                incremental = true,
            )
        )
        val obj: JsonObject = Json.parseToJsonElement(encoded).jsonObject
        assertTrue("work_done must not be empty", obj.isNotEmpty())

        for ((key, element) in obj) {
            if (element == JsonNull) continue
            val primitive = element as? JsonPrimitive
            assertNotNull("$key must be a scalar — no nested objects or arrays in work_done", primitive)
            primitive!!
            assertFalse("$key must not be a string; strings can carry names and messages", primitive.isString)
            val asBoolean = primitive.content.toBooleanStrictOrNull()
            if (asBoolean != null) continue
            assertNotNull(
                "$key must be an integer count — a fractional number is a measurement, not a count",
                primitive.content.toLongOrNull(),
            )
        }
    }

    @Test fun workDoneOmitsWhichMetricsTheUserHas() {
        // §9.8 is "counts only". `IngestSummary.unmappedMetricIds` is deliberately not carried
        // through: it is a list of identifiers describing what this person's devices report.
        val encoded = JsonCoding.encode(BackgroundWorkDone(unmapped = 3))
        assertFalse(encoded.contains("metricId", ignoreCase = true))
        assertFalse(encoded.contains("unmappedMetricIds", ignoreCase = true))
    }

    // MARK: - Unique-work policy

    /**
     * EPIC-05 task 1: "unique-work policy so re-scheduling does not stack duplicates". The policy
     * is asserted by identity rather than by behaviour because there is no live `WorkManager` here
     * — but the two wrong answers are both silent-failure bugs, so pinning the choice is worth more
     * than the weak form of the test suggests.
     */
    @Test fun periodicWorkUsesUpdateSoReschedulingNeitherStacksNorResets() {
        assertEquals(ExistingPeriodicWorkPolicy.UPDATE, BackgroundScheduler.periodicPolicy)
        // REPLACE would reset the period on every app open and boot, so the hourly sync would never
        // elapse for an active user. KEEP would strand existing installs on an old spec.
        assertFalse(BackgroundScheduler.periodicPolicy == ExistingPeriodicWorkPolicy.REPLACE)
        assertFalse(BackgroundScheduler.periodicPolicy == ExistingPeriodicWorkPolicy.KEEP)
    }

    @Test fun runNowJoinsAnInFlightSyncRatherThanQueueingASecond() {
        assertEquals(ExistingWorkPolicy.KEEP, BackgroundScheduler.oneOffPolicy)
    }

    @Test fun periodIsOneHourAndAboveWorkManagersFloor() {
        assertEquals(TimeUnit.HOURS.toMillis(1), BackgroundScheduler.periodMillis)
        assertTrue(
            "a period below MIN_PERIODIC_INTERVAL_MILLIS is silently raised by WorkManager",
            BackgroundScheduler.periodMillis >= PeriodicWorkRequest.MIN_PERIODIC_INTERVAL_MILLIS,
        )
    }

    @Test fun uniqueNamesAreDistinctConstants() {
        // One name per chain. A computed name would let parallel periodic chains accumulate, each
        // waking the device hourly — exactly the duplicate stacking the policy is meant to prevent.
        assertTrue(BackgroundScheduler.PERIODIC_WORK_NAME != BackgroundScheduler.ONE_OFF_WORK_NAME)
        assertTrue(BackgroundScheduler.PERIODIC_WORK_NAME.isNotBlank())
        assertTrue(BackgroundScheduler.ONE_OFF_WORK_NAME.isNotBlank())
    }

    /**
     * EPIC-26: the score-backfill job must have its OWN unique-work name and its OWN input flag. A
     * name shared with the hourly sync would collide the two chains; a flag shared with "sync now"
     * would route a backfill down the Health-Connect read path (or vice versa) — [SyncWorker] picks
     * the path by exactly these constants before any work runs.
     */
    @Test fun scoreBackfillHasItsOwnWorkNameAndFlag() {
        assertTrue(BackgroundScheduler.SCORE_BACKFILL_WORK_NAME.isNotBlank())
        assertTrue(BackgroundScheduler.SCORE_BACKFILL_WORK_NAME != BackgroundScheduler.PERIODIC_WORK_NAME)
        assertTrue(BackgroundScheduler.SCORE_BACKFILL_WORK_NAME != BackgroundScheduler.ONE_OFF_WORK_NAME)
        assertTrue(BackgroundScheduler.KEY_SCORE_BACKFILL.isNotBlank())
        assertTrue(BackgroundScheduler.KEY_SCORE_BACKFILL != BackgroundScheduler.KEY_USER_TRIGGERED)
    }

    /**
     * Marking a request expedited below API 31 makes WorkManager call `getForegroundInfo()`, which
     * `CoroutineWorker` implements by throwing — so every "sync now" tap would fail on API 26-30.
     */
    @Test fun expeditedOnlyRequestedWhereItDoesNotNeedAForegroundNotification() {
        assertFalse(BackgroundScheduler.shouldMarkExpedited(26))
        assertFalse(BackgroundScheduler.shouldMarkExpedited(30))
        assertTrue(BackgroundScheduler.shouldMarkExpedited(31))
        assertTrue(BackgroundScheduler.shouldMarkExpedited(36))
    }

    // MARK: - Pruning

    @Test fun retentionCutoffIsNinetyDays() {
        val now = 1_700_000_000_000L
        val cutoff = BackgroundRunRepository.retentionCutoff(now)
        assertEquals(90, BackgroundRunRepository.RETENTION_DAYS)
        assertEquals(now - 90L * 86_400_000L, cutoff)
        assertTrue(cutoff < now)
    }

    @Test fun retentionCutoffHonoursAnExplicitWindow() {
        val now = 1_700_000_000_000L
        assertEquals(now - 86_400_000L, BackgroundRunRepository.retentionCutoff(now, retentionDays = 1))
    }

    /**
     * The prune statement must be bounded and parameterized. An unbounded `DELETE FROM
     * background_runs` would pass every other test in this file while wiping the whole diagnostics
     * history on the first background run.
     */
    @Test fun pruneStatementIsBoundedAndParameterized() {
        val sql = BackgroundRunRepository.PRUNE_SQL
        assertTrue(sql.contains("DELETE FROM background_runs"))
        assertTrue("prune must be bounded by started_at", sql.contains("started_at <"))
        assertEquals("prune must bind exactly one argument", 1, sql.count { it == '?' })
    }

    // MARK: - Throttle heuristic

    private fun summary(
        runs: Int,
        throttled: Int = 0,
        longestGapMs: Long = 0L,
        windowMs: Long = 86_400_000L,
    ) = CadenceSummary(
        windowMs = windowMs, runs = runs, throttled = throttled, errors = 0,
        longestGapMs = longestGapMs, oldestRunAt = null,
    )

    @Test fun healthyCadenceShowsNoGuidance() {
        // ~20 runs/day is the EPIC-05 acceptance target for a typical device.
        assertFalse(summary(runs = 20).suggestsThrottling(BackgroundScheduler.periodMillis))
    }

    @Test fun missingRunsSuggestThrottling() {
        // Six runs where twenty-four were expected: the process-killed case, which leaves no
        // throttled rows behind and is only visible as absence.
        assertTrue(summary(runs = 6).suggestsThrottling(BackgroundScheduler.periodMillis))
    }

    @Test fun anyThrottledRunSuggestsThrottling() {
        assertTrue(summary(runs = 20, throttled = 1).suggestsThrottling(BackgroundScheduler.periodMillis))
    }

    @Test fun aFreshInstallIsNotAccusedOfThrottling() {
        // One run and a window-sized gap is indistinguishable from aggressive throttling; greeting
        // every new user with a battery-settings banner would be both wrong and off-putting.
        assertFalse(summary(runs = 0).suggestsThrottling(BackgroundScheduler.periodMillis))
        assertFalse(summary(runs = 1, throttled = 1).suggestsThrottling(BackgroundScheduler.periodMillis))
        assertFalse(summary(runs = 2).suggestsThrottling(BackgroundScheduler.periodMillis))
    }

    @Test fun zeroPeriodCannotDivideByZero() {
        assertFalse(summary(runs = 20).suggestsThrottling(0L))
    }

    // MARK: - Copy

    private val allCopy: List<Pair<String, LocalizedString>> = listOf(
        "scheduledLabel" to BackgroundCopy.scheduledLabel,
        "scheduledDetail" to BackgroundCopy.scheduledDetail,
        "runNow" to BackgroundCopy.runNow,
        "backgroundSyncTitle" to BackgroundCopy.backgroundSyncTitle,
        "throttleGuidanceTitle" to BackgroundCopy.throttleGuidanceTitle,
        "throttleGuidanceBody" to BackgroundCopy.throttleGuidanceBody,
        "openBatterySettings" to BackgroundCopy.openBatterySettings,
        "neverSyncedInBackground" to BackgroundCopy.neverSyncedInBackground,
    ) + BackgroundRunOutcome.entries.map { "outcome.${it.code}" to it.displayLabel }

    @Test fun everyStringShipsEnglishAndArabic() {
        for ((name, ls) in allCopy) {
            assertTrue("$name is missing English", ls.en.isNotBlank())
            assertTrue("$name is missing Arabic", ls.ar.isNotBlank())
            assertTrue("$name was not actually translated", ls.en != ls.ar)
        }
    }

    /**
     * §4.10: reliability tiers are labelled honestly, and the words that promise a wall clock never
     * appear un-caveated on-device. Android is allowed the stronger "usually within the hour" that
     * WorkManager earns — but not exactness it does not have.
     */
    @Test fun theParityLabelIsHonestInBothDirections() {
        val label = BackgroundCopy.scheduledLabel.en.lowercase()
        val detail = BackgroundCopy.scheduledDetail.en.lowercase()

        // Not flattened down to iOS's weaker promise.
        assertTrue("Android should claim the reliability WorkManager gives it", label.contains("usually"))
        assertFalse(label.contains("best-effort"))

        // Not overclaimed into a wall-clock promise.
        for (banned in listOf("guaranteed", "every day at", "exactly", "cron")) {
            assertFalse("'$banned' promises precision WorkManager does not have", label.contains(banned))
            assertFalse("'$banned' promises precision WorkManager does not have", detail.contains(banned))
        }
        assertTrue("the caveat must be explicit", detail.contains("not an exact time"))
    }

    @Test fun throttleGuidanceIsGuidanceNotAnAlarm() {
        val body = BackgroundCopy.throttleGuidanceBody.en.lowercase()
        val title = BackgroundCopy.throttleGuidanceTitle.en.lowercase()
        for (banned in listOf("error", "failed", "failure", "broken", "warning", "problem")) {
            assertFalse("throttling copy must not read as a failure ('$banned')", body.contains(banned))
            assertFalse("throttling copy must not read as a failure ('$banned')", title.contains(banned))
        }
        // Names the vendors §14 names, and points somewhere actionable.
        assertTrue(body.contains("samsung"))
        assertTrue(body.contains("xiaomi"))
        assertTrue(body.contains("battery settings"))
    }

    @Test fun noOutcomeLabelReadsAsAFailureExceptTheOneThatIs() {
        for (outcome in BackgroundRunOutcome.entries) {
            if (outcome.isFailure) continue
            val label = outcome.displayLabel.en.lowercase()
            for (banned in listOf("error", "failed", "failure")) {
                assertFalse("${outcome.code} must not read as a failure", label.contains(banned))
            }
        }
        // Even the genuine failure stays wellness-safe and non-alarmist.
        assertEquals("Didn't finish", BackgroundRunOutcome.ERROR.displayLabel.en)
    }

    @Test fun androidNeverRecordsAnIosOnlyCompletionHandlerLatency() {
        // The column exists so the two platforms' schemas stay diffable; WorkManager has no
        // three-strikes budget, so a non-null value here would be fabricated.
        val run = net.albayyan.badan.storage.repositories.BackgroundRun(
            id = "01J0000000000000000000000A",
            kind = BackgroundRunKind.WORK_MANAGER_PERIODIC,
            startedAt = 1_700_000_000_000L,
            durationMs = 1_200L,
            outcome = BackgroundRunOutcome.COMPLETED,
            workDone = BackgroundWorkDone(samples = 3),
        )
        assertNull(run.completionHandlerCalledInMs)
    }
}
