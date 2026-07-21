package net.albayyan.badan.domain.journal

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.ingestion.DayAttribution

/**
 * The curated set of circumstances a user can declare (plan §9.10). Mirror of iOS
 * `ContextStatusKind`; `code` equals the iOS rawValue so a status declared on one platform reads
 * the same on the other.
 *
 * Small and closed on purpose: these are the circumstances an engine has a defensible reason to
 * caveat around. Anything else is a custom label — recorded and displayed, but annotating the same
 * way, because BADAN has no basis for treating one user-invented circumstance differently.
 *
 * Deliberately NOT diagnostic: [ILLNESS] means "the user said they were unwell", nothing more. No
 * code anywhere may read it as a condition, a severity, or a reason to change a number.
 */
@Serializable
enum class ContextStatusKind(val code: String) {
    @SerialName("travel") TRAVEL("travel"),
    @SerialName("illness") ILLNESS("illness"),
    @SerialName("fasting") FASTING("fasting"),
    @SerialName("altitude") ALTITUDE("altitude"),
    @SerialName("injury") INJURY("injury");

    val displayLabel: LocalizedString
        get() = when (this) {
            TRAVEL -> LocalizedString(en = "Travelling", ar = "سفر")
            ILLNESS -> LocalizedString(en = "Feeling unwell", ar = "توعّك")
            FASTING -> LocalizedString(en = "Fasting", ar = "صيام")
            ALTITUDE -> LocalizedString(en = "At altitude", ar = "على ارتفاع عالٍ")
            INJURY -> LocalizedString(en = "Injury", ar = "إصابة")
        }

    /**
     * The caveat an engine attaches to a value computed while this status was open. Phrased as
     * "your usual pattern may not apply", never as an instruction and never as an explanation of
     * the number — the value is what it is; this says only that the personal baseline it is read
     * against was built from days that didn't look like this one.
     */
    val caveat: LocalizedString
        get() = when (this) {
            TRAVEL -> LocalizedString(
                en = "Computed while you were travelling — your usual pattern may not apply.",
                ar = "حُسب أثناء سفرك — قد لا ينطبق نمطك المعتاد.",
            )
            ILLNESS -> LocalizedString(
                en = "Computed while you noted feeling unwell — your usual pattern may not apply.",
                ar = "حُسب أثناء تسجيلك شعورًا بالتوعّك — قد لا ينطبق نمطك المعتاد.",
            )
            FASTING -> LocalizedString(
                en = "Computed during a fasting period you noted — your usual pattern may not apply.",
                ar = "حُسب خلال فترة صيام سجّلتها — قد لا ينطبق نمطك المعتاد.",
            )
            ALTITUDE -> LocalizedString(
                en = "Computed while you noted being at altitude — your usual pattern may not apply.",
                ar = "حُسب أثناء وجودك على ارتفاع عالٍ سجّلته — قد لا ينطبق نمطك المعتاد.",
            )
            INJURY -> LocalizedString(
                en = "Computed while you noted an injury — your usual pattern may not apply.",
                ar = "حُسب أثناء تسجيلك إصابة — قد لا ينطبق نمطك المعتاد.",
            )
        }

    companion object {
        fun fromCode(code: String?): ContextStatusKind? = entries.firstOrNull { it.code == code }
    }
}

/**
 * A user-declared interval that conditions how a value should be READ — never what it is (§9.10).
 * Mirror of iOS `ContextStatus`.
 *
 * Sensitive-plus (I7), same as [JournalEntry]: travel, illness and injury intervals disclose
 * circumstance. Rows live only in `badan_sensitive.db`.
 *
 * **Interval semantics.** [endAt] `== null` is the normal case, not a malformed row: a status is
 * declared when it starts ("I'm travelling") and closed later, so an open-ended row means "still
 * active as of now". Every reader must treat null as ongoing. Membership is half-open
 * (`startAt <= t < endAt`) so two back-to-back statuses that share an instant don't both claim it.
 *
 * **The behavioural rule this type enforces structurally.** Engines read active statuses to
 * annotate CONFIDENCE and COPY, and never to alter a stored value. That is not a convention here,
 * it is the surface area: this type exposes no metric id, no value, no offset, no multiplier and no
 * adjustment of any kind, and its only output is [ContextAnnotation] — a confidence ceiling and
 * caveat sentences, nothing else. There is deliberately no `applyTo(measurement)`, so "a status
 * quietly changed my number" is not a bug misuse can introduce; it would require adding new API, in
 * a review that would have to argue against this paragraph.
 */
@Serializable
data class ContextStatus(
    val id: String,
    /** Taxonomy key ([ContextStatusKind.code]). Null exactly when [customLabel] is set. */
    val statusId: String? = null,
    /** The user's own words for a circumstance the taxonomy doesn't name. */
    val customLabel: String? = null,
    val startAt: Long,
    /** Null = still active. See the interval-semantics note above. */
    val endAt: Long? = null,
    val tzId: String,
    val note: String? = null,
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    /** The taxonomy kind, or null for a custom status — a normal, displayable state. */
    val kind: ContextStatusKind? get() = ContextStatusKind.fromCode(statusId)

    /** Still running (no declared end). */
    val isOpenEnded: Boolean get() = endAt == null

    /** Whether [instant] falls inside this interval. Half-open: start is inside, end is not. */
    fun isActive(instant: Long): Boolean {
        if (instant < startAt) return false
        val end = endAt ?: return true
        return instant < end
    }

    /**
     * Whether this interval touches `[from, to)` at all — the query a day- or window-scoped engine
     * asks ("was anything declared during the night I just scored?").
     */
    fun overlaps(from: Long, to: Long): Boolean {
        if (to <= from) return isActive(from)
        val end = endAt
        if (end != null && end <= from) return false
        return startAt < to
    }

    /**
     * Display name: the taxonomy label, or the user's own words. Never empty — a status with
     * neither (a corrupt row) reads as the generic word rather than blank.
     */
    val displayLabel: LocalizedString
        get() = kind?.displayLabel
            ?: customLabel?.let { LocalizedString(en = it, ar = it) }
            ?: LocalizedString(en = "Context", ar = "سياق")

    /**
     * The caveat sentence for this status. A custom status gets the same generic sentence naming
     * the user's own label — BADAN has no basis for a bespoke caveat about a circumstance it has
     * never heard of, and inventing one would be false precision.
     */
    val caveat: LocalizedString
        get() = kind?.caveat ?: LocalizedString(
            en = "Computed during “{label}”, which you noted — your usual pattern may not apply.",
            ar = "حُسب خلال “{label}” الذي سجّلته — قد لا ينطبق نمطك المعتاد.",
        ).filling(mapOf("label" to (customLabel ?: "")))
}

/**
 * Everything a [ContextStatus] is allowed to do to a derived result: cap its confidence and add
 * sentences explaining why. There is no value field here, by construction.
 *
 * [confidenceCeiling] is a CEILING, not a multiplier and not a replacement: [applyingTo] returns
 * `min(confidence, ceiling)`, so an already-low confidence is never raised by a context being
 * active, and a high one is capped rather than rescaled by a made-up factor.
 */
class ContextAnnotation(
    confidenceCeiling: Double,
    val caveats: List<LocalizedString>,
) {
    /** The most confidence a value computed inside these intervals may claim. 1.0 = no cap. */
    val confidenceCeiling: Double = confidenceCeiling.coerceIn(0.0, 1.0)

    val isEmpty: Boolean get() = caveats.isEmpty()

    /**
     * The confidence a consumer should publish instead of [confidence]. Monotonic and
     * non-increasing: a context can only ever make BADAN less sure, never more.
     */
    fun applyingTo(confidence: Double?): Double? =
        confidence?.let { minOf(it, confidenceCeiling) }

    companion object {
        val NONE = ContextAnnotation(1.0, emptyList())
    }
}

/**
 * Reads active statuses and produces the annotation for a moment or a window. An object rather than
 * a method on [ContextStatus], because the answer depends on the whole SET of open intervals.
 */
object ContextAnnotator {

    /**
     * The confidence ceiling applied whenever any status is open.
     *
     * Deliberately UNIFORM across kinds, and deliberately not a table of per-kind numbers. BADAN has
     * no evidence base for claiming travel disturbs a personal baseline more (or less) than illness
     * or altitude, and a ranked table would be exactly the false precision §4.9 rules out — a
     * published number implies a study behind it. One honest statement ("a day you told us was
     * unusual should not be read as confidently as an ordinary one") is what this encodes.
     *
     * 0.7 rather than something lower because the value is still fully valid and fully shown; the
     * cap governs how strongly it is presented, not whether it is trusted. Must equal the iOS
     * constant: `JournalTest` and `CorrelationEngineGoldenTest` pin 0.7 here as a literal, and
     * `JournalTests.testTheActiveContextConfidenceCeilingMatchesTheAndroidConstant` pins the same
     * literal on iOS. Both halves are required — a symbolic assertion on either side would let the
     * two drift apart while staying green.
     */
    const val ACTIVE_CONTEXT_CONFIDENCE_CEILING: Double = 0.7

    /** The annotation for a single instant. */
    fun annotation(instant: Long, statuses: List<ContextStatus>): ContextAnnotation =
        make(statuses.filter { it.deletedAt == null && it.isActive(instant) })

    /**
     * The annotation for a window — what a nightly score or day rollup asks, since it describes a
     * span rather than a moment. Any overlap counts: a status that covered half the night is still
     * a reason the night wasn't ordinary.
     */
    fun annotation(from: Long, to: Long, statuses: List<ContextStatus>): ContextAnnotation =
        make(statuses.filter { it.deletedAt == null && it.overlaps(from, to) })

    /**
     * Ceilings do NOT compound across statuses: travel + illness is capped once, not squared. Two
     * reasons to read a day carefully are not twice the uncertainty, and multiplying them would
     * invent a number nothing supports.
     */
    private fun make(active: List<ContextStatus>): ContextAnnotation =
        if (active.isEmpty()) {
            ContextAnnotation.NONE
        } else {
            ContextAnnotation(ACTIVE_CONTEXT_CONFIDENCE_CEILING, active.map { it.caveat })
        }
}

// MARK: - The I7 seam

/**
 * How a declared context reaches a score engine **without that engine touching the sensitive
 * database**. Mirror of the iOS `ContextAnnotationResolver`; the full rationale lives there and is
 * summarized here.
 *
 * `context_statuses` live in `badan_sensitive.db` (I7); every score engine holds a connection to
 * `badan.db` and only that. Handing an engine a `JournalRepository` would put a sensitive connection
 * in scope inside the derivation pipeline — the exact structural property that makes I7 enforceable
 * rather than remembered. So the boundary is crossed by a FUNCTION, resolved once in the composition
 * root (which holds both connections legitimately) and injected into each engine. An engine asks
 * "what was declared over `[from, to)`?" and receives a ceiling plus some sentences; it cannot ask
 * which status, enumerate rows, or write one.
 *
 * Only the CEILING is persisted, onto a `confidence` column in the main database — a bare number
 * naming no circumstance. The caveat sentences are never stored: a surface renders them by reading
 * the sensitive store at display time (see [ContextCaveats]), so no word like "travelling" reaches
 * `badan.db` and the sensitive purge still takes the disclosure with it.
 */
typealias ContextAnnotationResolver = (from: Long, to: Long) -> ContextAnnotation

/** The resolver an engine gets when nobody wired one: no context, ever. */
val NO_CONTEXT_ANNOTATIONS: ContextAnnotationResolver = { _, _ -> ContextAnnotation.NONE }

// MARK: - Caveat read model (display side)

/**
 * The display half of the seam: what a surface calls to show "computed while you were travelling"
 * beside a score, in the reader's language. Mirror of the iOS `ContextCaveats`.
 *
 * Fed by the SAME [ContextAnnotationResolver] the engines take, rather than by the sensitive
 * repository directly: a caveat is sensitive-plus TEXT, and the fewer places that hold a sensitive
 * connection, the less there is to get wrong. The two halves cannot disagree, because both read the
 * annotation for the same day window through [ContextAnnotator].
 */
object ContextCaveats {

    /**
     * The caveat sentences for the local day a derived value is attributed to, or an empty list when
     * the day sat inside no declared interval — the ordinary case, which renders as nothing.
     *
     * The window is the local day itself, matching the day attribution every engine scores by: a
     * status the user declared for yesterday annotates yesterday's rows, not today's.
     */
    fun forDay(day: Long, tz: String, annotations: ContextAnnotationResolver): List<LocalizedString> {
        val from = DayAttribution.startOfDay(day, tz)
        return annotations(from, DayAttribution.addingDays(1, from, tz)).caveats
    }

    /**
     * Same, for a `"day:YYYY-MM-DD"` period key — the shape every per-day score row carries. A key in
     * any other shape (a session key, a week rollup) resolves to no caveats rather than to a guessed
     * day.
     */
    fun forPeriodKey(periodKey: String, tz: String, annotations: ContextAnnotationResolver): List<LocalizedString> {
        if (!periodKey.startsWith("day:")) return emptyList()
        val day = DayAttribution.dateFromDayKey(periodKey.removePrefix("day:"), tz) ?: return emptyList()
        return forDay(day, tz, annotations)
    }
}
