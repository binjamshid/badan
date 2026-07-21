package net.albayyan.badan.storage.repositories

import java.time.Instant
import java.time.ZoneId
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.platform.notifications.NotificationClass
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

// MARK: - Domain (EPIC-32 `notification_deliveries`, migration v8)
//
// These types live beside their repository rather than under `domain/`, for the same reason
// [BackgroundRun] does: a notification-delivery row is not a health entity. It carries no
// provenance, no measured value and no metric id (I1 has nothing to say about it) — it is
// operational metadata about a scheduling decision. Putting it in `domain/` would imply it is part
// of the canonical health model the two platforms mirror entity-for-entity; it is not.

/**
 * The state of one queued/delivered notification. These are the `outcome` values the v8 migration
 * documents (`scheduled|delivered|suppressed|cancelled`); the schema deliberately does not pin the
 * enum, so it is owned here. Mirror of iOS `NotificationOutcome`.
 */
enum class NotificationOutcome(val code: String) {
    /**
     * Queued but not yet fired. A scheduled row STILL counts toward the day's budget: the engine has
     * committed the slot even though the notification hasn't been posted.
     */
    SCHEDULED("scheduled"),

    /** The notification was posted. */
    DELIVERED("delivered"),

    /**
     * The engine decided against sending — over budget, in quiet hours, or capped. Recorded for
     * diagnostics by `AppEnvironment.evaluateAndSchedule` on every non-`SCHEDULED` verdict (the same
     * as iOS), and also the outcome a reserved row is moved to when the system refuses an immediate
     * post. A suppressed row does NOT consume budget (see
     * [NotificationDeliveryRepository.countBudgeted]).
     */
    SUPPRESSED("suppressed"),

    /**
     * A previously-scheduled notification was cancelled before it fired (e.g. the class was turned
     * off). Does not consume budget.
     */
    CANCELLED("cancelled"),
    ;

    companion object {
        fun fromCode(code: String?): NotificationOutcome = entries.firstOrNull { it.code == code } ?: SCHEDULED
    }
}

/**
 * One row of the notification budget ledger (plan §9.12 / EPIC-32). VALUE-FREE by contract: it
 * records that a notification of some CLASS was scheduled/delivered, never the health value the
 * notification was about — "a readiness summary was scheduled for 07:00" is metadata; the readiness
 * score itself is nowhere in this type. Instants are epoch millis, as everywhere on Android.
 */
data class NotificationDelivery(
    val id: String,
    val notificationClass: NotificationClass,
    val scheduledFor: Long,
    val deliveredAt: Long?,
    val outcome: NotificationOutcome,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long?,
)

/**
 * The local-day window the ≤2/day budget is measured over, as a pure function of an instant and a
 * zone. Extracted from the repository so the boundary arithmetic — the part a DST transition or an
 * off-by-one can quietly break — is testable on the JVM, where this module can open no SQLite
 * database. `[start, end)`: start inclusive, end exclusive.
 */
object NotificationDayWindow {
    fun bounds(instant: Long, zone: ZoneId): Pair<Long, Long> {
        val date = Instant.ofEpochMilli(instant).atZone(zone).toLocalDate()
        val start = date.atStartOfDay(zone).toInstant().toEpochMilli()
        val end = date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        return start to end
    }
}

// MARK: - Repository

/**
 * `notification_deliveries` (migration v8) — the budget ledger EPIC-32's decision engine counts
 * against. It answers exactly one question for the engine ("how many budgeted notifications have I
 * already committed for this day?") and records what it decides, so the ≤2/day invariant survives
 * process death, backgrounding, and multiple evaluations in a day.
 *
 * Device-local and pruned like `background_runs`/`export_runs`: this is a record of BADAN's own
 * scheduling, not user data, so it neither needs to accumulate forever nor to merge across devices
 * (a delivery describes what happened on THIS phone). Byte-equivalent behaviour to iOS
 * `NotificationDeliveryRepository`.
 */
class NotificationDeliveryRepository(private val db: SqliteConnection) {

    // MARK: - Writes

    /**
     * Record one delivery decision. Plain INSERT (ids are fresh ULIDs), so a collision is an
     * id-generation bug worth surfacing rather than silently overwriting an earlier row.
     */
    fun insert(row: NotificationDelivery) {
        db.run(
            """
            INSERT INTO notification_deliveries
              (id, notification_class, scheduled_for, delivered_at, outcome, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ${Rows.convPlaceholders});
            """,
            listOf(
                row.id, row.notificationClass.code, row.scheduledFor, row.deliveredAt, row.outcome.code,
                row.updatedAt, row.originDeviceId, row.deletedAt,
            ),
        )
    }

    /**
     * Convenience: record a freshly-decided delivery for [cls], returning the row so a caller can
     * hold its id (e.g. to mark it delivered later). The ledger stores state transitions, so
     * `updated_at` is set to [now] on every write.
     */
    fun record(
        cls: NotificationClass,
        scheduledFor: Long,
        outcome: NotificationOutcome,
        now: Long,
        deviceId: String,
    ): NotificationDelivery {
        val row = NotificationDelivery(
            id = Ulid.newId(),
            notificationClass = cls,
            scheduledFor = scheduledFor,
            deliveredAt = if (outcome == NotificationOutcome.DELIVERED) now else null,
            outcome = outcome,
            updatedAt = now,
            originDeviceId = deviceId,
            deletedAt = null,
        )
        insert(row)
        return row
    }

    /**
     * Transition the row with [id] to [outcome] — how a slot reserved at decision time is closed out
     * once the system has told us what actually happened to it. `delivered_at` is stamped only for a
     * real delivery; any other outcome clears it, because a row that never fired must not carry a
     * delivery timestamp. Idempotent: updating a missing id is a no-op.
     *
     * Mirror of iOS `NotificationDeliveryRepository.transition(id:to:at:)`.
     */
    fun transition(id: String, outcome: NotificationOutcome, at: Long) {
        db.run(
            """
            UPDATE notification_deliveries SET outcome = ?, delivered_at = ?, updated_at = ?
            WHERE id = ? AND deleted_at IS NULL;
            """,
            listOf(
                outcome.code,
                if (outcome == NotificationOutcome.DELIVERED) at else null,
                at, id,
            ),
        )
    }

    /**
     * Transition an existing row to `delivered` — called by `AppEnvironment.evaluateAndSchedule`
     * with the id of the row it just reserved, once `AndroidNotificationScheduler.post` confirms the
     * system accepted an immediate post. Idempotent: updating a missing id is a no-op.
     */
    fun markDelivered(id: String, at: Long) = transition(id, NotificationOutcome.DELIVERED, at)

    /**
     * Transition [cls]'s most recent still-scheduled row to `delivered`. This is what the delivery
     * worker calls after the system actually accepted the post: the row was written at schedule
     * time (that is what reserved the budget slot), and this closes it out honestly. A no-op when
     * nothing is scheduled — a delivery with no reservation is not a row worth inventing.
     */
    fun markDeliveredForClass(cls: NotificationClass, at: Long) {
        db.run(
            """
            UPDATE notification_deliveries SET outcome = ?, delivered_at = ?, updated_at = ?
            WHERE id IN (
              SELECT id FROM notification_deliveries
              WHERE notification_class = ? AND outcome = ? AND deleted_at IS NULL
              ORDER BY scheduled_for DESC LIMIT 1
            );
            """,
            listOf(
                NotificationOutcome.DELIVERED.code, at, at,
                cls.code, NotificationOutcome.SCHEDULED.code,
            ),
        )
    }

    /**
     * Tombstone every live scheduled row for [cls] — the ledger half of "the user turned this class
     * off". Recorded as `cancelled` rather than deleted so the day's history stays inspectable, and
     * so the freed budget slot is explicit rather than inferred from a missing row.
     */
    fun cancelScheduled(cls: NotificationClass, at: Long) {
        db.run(
            """
            UPDATE notification_deliveries SET outcome = ?, updated_at = ?
            WHERE notification_class = ? AND outcome = ? AND deleted_at IS NULL;
            """,
            listOf(NotificationOutcome.CANCELLED.code, at, cls.code, NotificationOutcome.SCHEDULED.code),
        )
    }

    // MARK: - Reads (the budget count)

    /**
     * How many BUDGETED (non-med) notifications are already committed for the local day containing
     * [day]. This is the number the ≤2/day invariant is checked against, so it counts only rows that
     * consumed a slot — `scheduled` and `delivered` — and never `suppressed`/`cancelled` ones. Meds
     * are excluded structurally (`notification_class <> 'meds'`): a med reminder is exempt from the
     * budget by design.
     */
    fun countBudgeted(day: Long, zone: ZoneId): Int {
        val (start, end) = NotificationDayWindow.bounds(day, zone)
        val rows = runCatching {
            db.query(
                """
                SELECT COUNT(*) AS c FROM notification_deliveries
                WHERE notification_class <> ?
                  AND outcome IN (?, ?)
                  AND scheduled_for >= ? AND scheduled_for < ?
                  AND deleted_at IS NULL;
                """,
                listOf(
                    NotificationClass.MEDS.code,
                    NotificationOutcome.SCHEDULED.code, NotificationOutcome.DELIVERED.code,
                    start, end,
                ),
            )
        }.getOrDefault(emptyList())
        return rows.firstOrNull()?.getInt("c") ?: 0
    }

    /**
     * Whether a live (scheduled/delivered) row already exists for [cls] on the local day of [day].
     * The engine uses this for idempotency — re-evaluating on a second app open the same day must
     * not schedule a duplicate morning summary.
     */
    fun hasScheduled(cls: NotificationClass, day: Long, zone: ZoneId): Boolean {
        val (start, end) = NotificationDayWindow.bounds(day, zone)
        val rows = runCatching {
            db.query(
                """
                SELECT COUNT(*) AS c FROM notification_deliveries
                WHERE notification_class = ?
                  AND outcome IN (?, ?)
                  AND scheduled_for >= ? AND scheduled_for < ?
                  AND deleted_at IS NULL;
                """,
                listOf(
                    cls.code,
                    NotificationOutcome.SCHEDULED.code, NotificationOutcome.DELIVERED.code,
                    start, end,
                ),
            )
        }.getOrDefault(emptyList())
        return (rows.firstOrNull()?.getInt("c") ?: 0) > 0
    }

    /**
     * How many non-med notifications are queued but not yet fired as of [now] — what the engine
     * reads for `pendingNonMedCount`. Android has no OS-level pending-request queue to interrogate
     * (unlike iOS's `UNUserNotificationCenter.pendingNotificationRequests`), so the ledger's own
     * still-scheduled, still-future rows ARE the pending set. Counted, not assumed.
     */
    fun pendingNonMedCount(now: Long): Int {
        val rows = runCatching {
            db.query(
                """
                SELECT COUNT(*) AS c FROM notification_deliveries
                WHERE notification_class <> ?
                  AND outcome = ?
                  AND scheduled_for >= ?
                  AND deleted_at IS NULL;
                """,
                listOf(NotificationClass.MEDS.code, NotificationOutcome.SCHEDULED.code, now),
            )
        }.getOrDefault(emptyList())
        return rows.firstOrNull()?.getInt("c") ?: 0
    }

    fun recent(limit: Int = 50): List<NotificationDelivery> =
        db.query(
            """
            SELECT * FROM notification_deliveries WHERE deleted_at IS NULL
            ORDER BY scheduled_for DESC LIMIT ?;
            """,
            listOf(limit),
        ).map { read(it) }

    // MARK: - Prune

    /**
     * Drop rows older than [retentionDays]. Hard DELETE, not a soft delete: this is a disposable
     * budget ledger, not user data — there is nothing here worth keeping a tombstone for.
     */
    fun prune(now: Long, retentionDays: Int = RETENTION_DAYS) {
        val cutoff = now - retentionDays.toLong() * MILLIS_PER_DAY
        db.run("DELETE FROM notification_deliveries WHERE scheduled_for < ?;", listOf(cutoff))
    }

    // MARK: - Mapping

    companion object {
        /**
         * The ledger is a rolling budget window, not history to keep — 30 days is far more than the
         * 1-day budget window needs and leaves a short trail for Diagnostics.
         */
        const val RETENTION_DAYS = 30

        private const val MILLIS_PER_DAY = 86_400_000L

        fun read(r: Row): NotificationDelivery = NotificationDelivery(
            id = r.requireString("id"),
            // A row whose class no longer parses can only come from a downgrade or a hand-edited
            // DB. Fall back to the most conservative registered class rather than dropping the row
            // (and skewing the budget count); `meds` is exempt from the budget, so an unrecognized
            // row falling here never wrongly consumes a non-med slot.
            notificationClass = NotificationClass.fromCode(r.requireString("notification_class"))
                ?: NotificationClass.MEDS,
            scheduledFor = r.requireDate("scheduled_for"),
            deliveredAt = r.getDate("delivered_at"),
            outcome = NotificationOutcome.fromCode(r.requireString("outcome")),
            updatedAt = r.requireDate("updated_at"),
            originDeviceId = r.requireString("origin_device_id"),
            deletedAt = r.getDate("deleted_at"),
        )
    }
}
