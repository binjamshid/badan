package net.albayyan.badan.domain.journal

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance

/**
 * The shape of the answer a behavior tag carries (plan §9.9). Mirror of iOS `BehaviorValueKind`;
 * `code`/`@SerialName` equal the iOS rawValue so the stored column and the dictionary asset are
 * read identically on both platforms.
 *
 * Storing the KIND alongside the value is what lets one table hold "did it happen", "how many" and
 * "how long" without a reader guessing from a nullable column: a [BOOLEAN] row has no value at all,
 * and a [COUNT] row's 3 means three servings, not three minutes.
 */
@Serializable
enum class BehaviorValueKind(val code: String) {
    /** Did it happen at all. Carries no value and no unit — the row's existence is the fact. */
    @SerialName("boolean") BOOLEAN("boolean"),

    /** How many times/servings. Counts the behavior itself, so it carries no physical unit. */
    @SerialName("count") COUNT("count"),

    /** A measured amount in `unit` (`min` for a nap, etc.). */
    @SerialName("quantity") QUANTITY("quantity");

    val displayLabel: LocalizedString
        get() = when (this) {
            BOOLEAN -> LocalizedString(en = "Happened", ar = "حدث")
            COUNT -> LocalizedString(en = "Count", ar = "العدد")
            QUANTITY -> LocalizedString(en = "Amount", ar = "المقدار")
        }

    companion object {
        /**
         * An unrecognized stored kind folds to [BOOLEAN] — the shape that claims the least (it
         * carries no value at all), so a row written by a newer build reads as "this happened"
         * rather than as a number in an unknown unit.
         */
        fun fromCode(code: String?): BehaviorValueKind = entries.firstOrNull { it.code == code } ?: BOOLEAN
    }
}

/**
 * One logged behavior tag — the raw user assertion the correlation engine later reads (§9.9).
 * Mirror of iOS `JournalEntry`.
 *
 * Sensitive-plus (I7). These rows live ONLY in `badan_sensitive.db`: a caffeine / alcohol /
 * screen-in-bed pattern is lifestyle-revealing in a way a step count is not, so it must be
 * removable by the file-deletion purge rather than a best-effort row sweep, and must never appear
 * in an export that did not explicitly ask for sensitive data.
 *
 * [behaviorId] (a `behaviors.json` key) and [customLabel] (the user's own words) are mutually
 * exclusive: exactly one is set. Storing the KEY rather than a rendered label is what keeps
 * Arabic/RTL first-order — a journal written in Arabic exports readably in English and back.
 *
 * Carries full embedded provenance (I1) with `ingestionPath = MANUAL`. The provenance is what makes
 * backdating honest: [occurredAt] is when the behavior happened, `provenance.recordedAt` is when the
 * user said so, and the gap between them is [isRecalled] rather than an invisible fudge.
 */
@Serializable
data class JournalEntry(
    val id: String,
    /** Dictionary key from `behaviors.json`. Null exactly when [customLabel] is set. */
    val behaviorId: String? = null,
    /** Free text, for a behavior the dictionary doesn't list. Null exactly when [behaviorId] is set. */
    val customLabel: String? = null,
    val valueKind: BehaviorValueKind,
    /** Null for [BehaviorValueKind.BOOLEAN]; the count/amount otherwise. */
    val value: Double? = null,
    /** Canonical unit for [BehaviorValueKind.QUANTITY] only. */
    val unit: String? = null,
    /** When the behavior happened — the axis every correlation and day-bucketing reads. */
    val occurredAt: Long,
    val tzId: String,
    val note: String? = null,
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    /**
     * Whether this tag asserts the behavior happened. The one definition of the with/without split:
     * a boolean row's existence IS the assertion, while a count/quantity row with an explicit 0 is
     * an assertion that it did NOT — "I had no coffee today" is real information a user can enter,
     * and silently counting it in the "with" arm would poison every finding built on top of it.
     */
    val isPresent: Boolean
        get() = when (valueKind) {
            BehaviorValueKind.BOOLEAN -> true
            BehaviorValueKind.COUNT, BehaviorValueKind.QUANTITY -> (value ?: 0.0) > 0.0
        }

    /**
     * True when the user logged this after the fact — the yesterday-recall path, a first-class way
     * to use the journal and not an edge case.
     *
     * Derived from provenance rather than stored as a column: `recordedAt` already records when the
     * user said it and [occurredAt] when it happened, so a stored flag would be a second copy of a
     * fact the row already carries. The one-hour threshold keeps "logged it a few minutes later"
     * out of the recall bucket; anything beyond that reads as recalled.
     *
     * Disclosure, not a discount: a recalled entry counts exactly like a live one.
     */
    val isRecalled: Boolean get() = provenance.recordedAt - occurredAt > 3_600_000L

    /**
     * The local calendar day this entry belongs to, in its own recorded time zone — the bucket key
     * the correlation engine's day arms are built from. An unresolvable [tzId] falls back to UTC,
     * matching how timestamps for such a row are rendered, so the key and the printed timestamp
     * never disagree about which day it was.
     */
    fun dayKey(): String =
        LocalDate.ofInstant(Instant.ofEpochMilli(occurredAt), zone()).toString()

    private fun zone(): ZoneId = runCatching { ZoneId.of(tzId) }.getOrDefault(ZoneId.of("UTC"))
}

/**
 * Builders for the two ways a journal entry is created. Both return a value — there is deliberately
 * no mutating "edit": a correction is a new row plus a tombstone on the old one
 * (`JournalRepository.deleteEntry`), so what the user originally said stays recoverable.
 */
object JournalLog {

    /** A tag logged as it happens. `recordedAt == occurredAt`, so `isRecalled` is false. */
    fun entry(
        id: String,
        behaviorId: String? = null,
        customLabel: String? = null,
        valueKind: BehaviorValueKind,
        value: Double? = null,
        unit: String? = null,
        occurredAt: Long,
        tzId: String,
        note: String? = null,
        sourceId: String,
        deviceId: String? = null,
        now: Long,
        originDeviceId: String,
    ): JournalEntry = JournalEntry(
        id = id,
        behaviorId = behaviorId,
        customLabel = customLabel,
        valueKind = valueKind,
        value = value,
        unit = unit,
        occurredAt = occurredAt,
        tzId = tzId,
        note = note,
        provenance = Provenance(
            sourceId = sourceId,
            deviceId = deviceId,
            ingestionPath = IngestionPath.MANUAL,
            measuredAt = occurredAt,
            measuredTimezone = tzId,
            recordedAt = now,
            ingestedAt = now,
        ),
        updatedAt = now,
        originDeviceId = originDeviceId,
    )

    /**
     * A tag the user is entering for an earlier moment — the yesterday-recall path.
     *
     * Identical to [entry] except that the caller names the past instant explicitly, which is the
     * point: the timestamp the correlation engine buckets on is the one the user says the behavior
     * happened at, while `recordedAt`/`ingestedAt` stay honest about when it was typed. Backdating
     * is therefore recorded, never disguised. A separate entry point so the two intents read
     * differently at the call site; the stored row differs only in its timestamps.
     */
    fun recalledEntry(
        id: String,
        behaviorId: String? = null,
        customLabel: String? = null,
        valueKind: BehaviorValueKind,
        value: Double? = null,
        unit: String? = null,
        occurredAt: Long,
        tzId: String,
        note: String? = null,
        sourceId: String,
        deviceId: String? = null,
        now: Long,
        originDeviceId: String,
    ): JournalEntry = entry(
        id = id, behaviorId = behaviorId, customLabel = customLabel, valueKind = valueKind,
        value = value, unit = unit, occurredAt = occurredAt, tzId = tzId, note = note,
        sourceId = sourceId, deviceId = deviceId, now = now, originDeviceId = originDeviceId,
    )

    /**
     * The same wall-clock time as [reference] on the previous local day, in [tzId] — the instant the
     * "yesterday" chip logs at when the user doesn't pick a time.
     *
     * Calendar arithmetic (`minusDays(1)` on the zoned date-time), never `-86_400_000` millis:
     * across a DST boundary a fixed 24-hour subtraction lands an hour off and silently files the
     * entry under the wrong local day, which is exactly the bucket the correlation arms use.
     */
    fun yesterday(reference: Long, tzId: String): Long {
        val zone = runCatching { ZoneId.of(tzId) }.getOrDefault(ZoneId.of("UTC"))
        return Instant.ofEpochMilli(reference).atZone(zone).minusDays(1).toInstant().toEpochMilli()
    }
}
