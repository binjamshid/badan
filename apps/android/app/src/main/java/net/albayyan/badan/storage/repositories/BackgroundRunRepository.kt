package net.albayyan.badan.storage.repositories

import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * §9.8 `BackgroundRun` — the substrate-level wakeup log, wider than `export_runs` because it also
 * covers ingest wakeups. It exists so "why is my data stale?" is answered from recorded wakeup
 * history instead of guesswork.
 *
 * **Not a health entity, and deliberately carries no provenance.** I1 governs *measurements,
 * derived values and logged entries* — things that assert something about a body. A background run
 * asserts something about the operating system's scheduler. It has no `sourceId` to stamp and no
 * `measuredAt` that means anything, so `background_runs` has neither the provenance columns nor
 * the D-7 convention columns (see the `Schema.kt` v4 comment). Do not "fix" that by adding them.
 *
 * **`work_done` holds counts only.** Never a value, never a metric id, never a source name — see
 * [BackgroundWorkDone]. `BackgroundSubstrateTest.workDoneCarriesNoValues` enforces it structurally.
 *
 * The domain types live in this file rather than under `domain/` on purpose: nothing in the domain
 * layer reads them, no engine derives from them, and they are not part of the canonical model the
 * two platforms mirror entity-for-entity. Putting them in `domain/` would imply all three.
 */
class BackgroundRunRepository(private val db: SqliteConnection) {

    // MARK: - Writes

    /**
     * Append one run row. Plain `INSERT` (not `INSERT OR REPLACE`) because a run is written exactly
     * once, at the end, and is never revised afterwards — an id collision would be a ULID bug worth
     * surfacing rather than silently absorbing.
     *
     * Consequence worth knowing before "improving" this: a wakeup whose *process* is killed
     * mid-flight (the Samsung/Xiaomi case) writes no row at all, so the throttled rows in this table
     * undercount throttling by construction. That is why [cadence] measures observed gaps between
     * rows rather than counting throttled outcomes — the missing rows are the signal.
     */
    fun insert(run: BackgroundRun) {
        db.run(
            """
            INSERT INTO background_runs
              (id, kind, started_at, duration_ms, outcome, work_done, completion_handler_called_in_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                run.id, run.kind.code, run.startedAt, run.durationMs, run.outcome.code,
                run.workDone?.let { JsonCoding.encode(it) }, run.completionHandlerCalledInMs,
            ),
        )
    }

    /**
     * Drop rows older than the §9.8 retention window. Called opportunistically from the sync worker
     * rather than from a dedicated periodic job: this table grows at ~24 rows/day, so a bounded
     * `DELETE` on a `(started_at DESC)` index is cheaper than a second scheduled wakeup would be.
     */
    fun prune(now: Long) {
        db.run(PRUNE_SQL, listOf(retentionCutoff(now)))
    }

    // MARK: - Reads

    fun recent(limit: Int = 50): List<BackgroundRun> =
        db.query(
            "SELECT * FROM background_runs ORDER BY started_at DESC LIMIT ?;",
            listOf(limit.toLong()),
        ).map { read(it) }

    fun lastRun(kind: BackgroundRunKind): BackgroundRun? =
        db.query(
            "SELECT * FROM background_runs WHERE kind = ? ORDER BY started_at DESC LIMIT 1;",
            listOf(kind.code),
        ).firstOrNull()?.let { read(it) }

    /**
     * The honest-guidance input: how the periodic worker has *actually* behaved over [windowMs],
     * measured from the rows that exist plus the gaps between them.
     *
     * Reads only the two columns the summary needs — this runs on the path that decides whether to
     * show a settings banner, not on a detail screen, so decoding `work_done` JSON for every row in
     * a 24-hour window would be waste.
     */
    fun cadence(
        kind: BackgroundRunKind = BackgroundRunKind.WORK_MANAGER_PERIODIC,
        now: Long,
        windowMs: Long = DEFAULT_CADENCE_WINDOW_MS,
    ): CadenceSummary {
        val since = now - windowMs
        val rows = db.query(
            "SELECT started_at, outcome FROM background_runs WHERE kind = ? AND started_at >= ? " +
                "ORDER BY started_at ASC;",
            listOf(kind.code, since),
        )
        val startedAts = rows.map { it.requireDate("started_at") }
        val outcomes = rows.map { BackgroundRunOutcome.fromCode(it.getString("outcome")) }

        // Gaps are measured against the window edges too, not just between rows: a device that ran
        // the worker eight times this morning and nothing since noon has a large *trailing* gap,
        // which is precisely the throttling shape a between-rows-only measure would miss.
        var longestGap = 0L
        var previous = since
        for (t in startedAts) {
            longestGap = maxOf(longestGap, t - previous)
            previous = t
        }
        longestGap = maxOf(longestGap, now - previous)

        return CadenceSummary(
            windowMs = windowMs,
            runs = startedAts.size,
            throttled = outcomes.count { it == BackgroundRunOutcome.THROTTLED },
            errors = outcomes.count { it == BackgroundRunOutcome.ERROR },
            longestGapMs = longestGap,
            oldestRunAt = startedAts.firstOrNull(),
        )
    }

    companion object {
        /** §9.8: "90-day pruning job". */
        const val RETENTION_DAYS = 90
        private const val MILLIS_PER_DAY = 86_400_000L
        private const val DEFAULT_CADENCE_WINDOW_MS = MILLIS_PER_DAY

        /**
         * Parameterized and bounded on the indexed column. Kept as a named constant so the pruning
         * test can assert the shape (`started_at <`, one bind arg) without a database — this module
         * has no instrumented test source set, so an unbounded `DELETE FROM background_runs` would
         * otherwise be caught by nobody.
         */
        const val PRUNE_SQL = "DELETE FROM background_runs WHERE started_at < ?;"

        fun retentionCutoff(now: Long, retentionDays: Int = RETENTION_DAYS): Long =
            now - retentionDays * MILLIS_PER_DAY

        fun read(r: Row): BackgroundRun =
            BackgroundRun(
                id = r.requireString("id"),
                kind = BackgroundRunKind.fromCode(r.getString("kind")),
                startedAt = r.requireDate("started_at"),
                durationMs = r.getLong("duration_ms"),
                outcome = BackgroundRunOutcome.fromCode(r.getString("outcome")),
                workDone = JsonCoding.decodeOrNull<BackgroundWorkDone>(r.getString("work_done")),
                completionHandlerCalledInMs = r.getLong("completion_handler_called_in_ms"),
            )
    }
}

// MARK: - Row model

/**
 * §9.8 kinds, shared verbatim with iOS so the two platforms' `background_runs` tables stay
 * diffable by a cross-platform fixture. Android emits only [WORK_MANAGER_PERIODIC] and
 * [FOREGROUND_SYNC]; the three `hk*`/`bg*` kinds are iOS's. Do not prune them from this enum to
 * "clean up" — `fromCode` would then silently rewrite an imported iOS diagnostics row.
 */
enum class BackgroundRunKind(val code: String) {
    HK_OBSERVER_WAKE("hkObserverWake"),
    BG_APP_REFRESH("bgAppRefresh"),
    BG_PROCESSING("bgProcessing"),
    WORK_MANAGER_PERIODIC("workManagerPeriodic"),

    /**
     * A user-triggered "sync now". Reused for Android's expedited one-off rather than minting a
     * `workManagerExpedited` kind, because §9.8 fixes this enum across both platforms and the
     * distinction that matters in diagnostics — *the user asked for this, the scheduler did not* —
     * is exactly what `foregroundSync` already means.
     */
    FOREGROUND_SYNC("foregroundSync");

    companion object {
        fun fromCode(code: String?): BackgroundRunKind =
            entries.firstOrNull { it.code == code } ?: WORK_MANAGER_PERIODIC
    }
}

/**
 * §9.8 outcomes.
 *
 * **[THROTTLED] is not an error and must never be presented as one.** Doze, App Standby, and the
 * OEM battery managers on Samsung/Xiaomi/Huawei devices routinely defer or kill periodic work.
 * That is the platform working as designed, not BADAN failing, and telling a user their health app
 * is "broken" every time their phone saved battery would be both alarming and false. The honest
 * response is the guidance copy in `BackgroundCopy.throttleGuidanceBody` plus a link to the
 * battery settings — see plan §14 and §12 EPIC-05 task 5.
 */
enum class BackgroundRunOutcome(val code: String) {
    COMPLETED("completed"),

    /**
     * The OS took the execution window back. On iOS this is `BGTask` expiration; on Android it is
     * `STOP_REASON_TIMEOUT` — WorkManager's ten-minute ceiling. Distinct from [THROTTLED]: the work
     * *started* and ran out of time, rather than being deferred or never allowed to start.
     */
    EXPIRED("expired"),

    /**
     * Credential-encrypted storage was unavailable. Present for iOS parity; see the comment in
     * `SyncWorker` for why Android cannot currently write a row with this outcome.
     */
    STORE_LOCKED("storeLocked"),
    THROTTLED("throttled"),
    ERROR("error");

    /**
     * The single predicate any UI must consult before styling a run row as a problem. Only [ERROR]
     * qualifies: everything else is the scheduler behaving normally under constraint.
     */
    val isFailure: Boolean get() = this == ERROR

    /** Wellness-safe, non-alarmist, and never the word "failed" for a scheduler decision. */
    val displayLabel: LocalizedString
        get() = when (this) {
            COMPLETED -> LocalizedString(en = "Completed", ar = "اكتمل")
            EXPIRED -> LocalizedString(en = "Ran out of time", ar = "انتهى الوقت المتاح")
            STORE_LOCKED -> LocalizedString(en = "Device was locked", ar = "كان الجهاز مقفلاً")
            THROTTLED -> LocalizedString(en = "Delayed by the system", ar = "أخّره النظام")
            ERROR -> LocalizedString(en = "Didn't finish", ar = "لم يكتمل")
        }

    companion object {
        fun fromCode(code: String?): BackgroundRunOutcome =
            entries.firstOrNull { it.code == code } ?: ERROR
    }
}

/**
 * The `work_done` JSON column. **Every field is an Int or a Boolean.** That is not a coincidence
 * and not a style preference — it is the mechanism that makes "no health values in logs" checkable
 * rather than merely intended, and `BackgroundSubstrateTest.workDoneCarriesNoValues` asserts the
 * serialized form contains no strings and no floating-point numbers.
 *
 * Notably absent: `IngestSummary.unmappedMetricIds`. It would be genuinely useful for debugging a
 * registry/adapter mismatch, and it holds identifiers rather than readings — but §9.8 says counts
 * only, and *which metrics this person's devices report* is itself a small disclosure sitting in a
 * table that Diagnostics can display and export. Debug that mismatch from a debug build's ingest
 * path, not from a shipped user's telemetry.
 */
@Serializable
data class BackgroundWorkDone(
    val samples: Int = 0,
    val intervals: Int = 0,
    val sessions: Int = 0,
    val suppressed: Int = 0,
    val unmapped: Int = 0,
    /** WorkManager's `runAttemptCount` — 0 on the first attempt, >0 after a backoff retry. */
    val runAttempt: Int = 0,
    /**
     * The raw `WorkInfo.STOP_REASON_*` int when the system stopped this run, else null.
     * Stored numerically rather than as a label so a future WorkManager release adding a reason
     * BADAN does not know about is still recorded faithfully instead of collapsing to "unknown".
     */
    val stopReason: Int? = null,
    /** False below API 31, where `getStopReason()` does not exist — see `SyncWorker`. */
    val stopReasonKnown: Boolean = true,
    /**
     * True when every record type this run covered was read from a changes token rather than
     * re-read over a window (EPIC-02).
     *
     * Assigned by `SyncWorker` from the run's backfill windows — see `IncrementalClassification`,
     * which owns the "every type, not any type" rule and why a mixed run reports false. It is
     * called out here because for the whole of Phase 0 nothing in the tree ever assigned it, so
     * this field's default *was* its value and Diagnostics claimed every Android background sync
     * was a full-window read. If a future caller constructs `BackgroundWorkDone` for a real sync
     * and leaves this to its default, that claim comes back.
     */
    val incremental: Boolean = false,
)

data class BackgroundRun(
    val id: String,
    val kind: BackgroundRunKind,
    val startedAt: Long,
    val durationMs: Long? = null,
    val outcome: BackgroundRunOutcome,
    val workDone: BackgroundWorkDone? = null,
    /**
     * iOS-only: milliseconds from wake to calling the HealthKit/BGTask completion handler, which
     * guards the three-strikes budget. Android writes null — WorkManager has no equivalent cliff.
     */
    val completionHandlerCalledInMs: Long? = null,
)

/**
 * Observed background behaviour over a window. The input to the "should we show OEM battery
 * guidance?" decision, kept separate from the decision itself so the heuristic is a pure function.
 */
data class CadenceSummary(
    val windowMs: Long,
    val runs: Int,
    val throttled: Int,
    val errors: Int,
    val longestGapMs: Long,
    val oldestRunAt: Long?,
) {
    /**
     * Whether this device looks like it is deferring background work — the trigger for honest
     * guidance, never for an error state.
     *
     * Requires [MIN_OBSERVED_RUNS] before answering true at all: a freshly-installed or
     * freshly-connected app has one run and a window-sized gap, which is indistinguishable from
     * aggressive throttling and would greet every new user with a battery-settings banner.
     *
     * Two independent signals, either sufficient:
     *  - any run we recorded as throttled, or
     *  - fewer than half the runs the period predicts (the killed-mid-flight case, which leaves no
     *    row behind and is therefore only visible as absence).
     */
    fun suggestsThrottling(expectedPeriodMs: Long): Boolean {
        if (expectedPeriodMs <= 0L) return false
        if (runs < MIN_OBSERVED_RUNS) return false
        if (throttled > 0) return true
        val expected = windowMs / expectedPeriodMs
        return runs * 2 < expected
    }

    companion object {
        const val MIN_OBSERVED_RUNS = 3
    }
}
