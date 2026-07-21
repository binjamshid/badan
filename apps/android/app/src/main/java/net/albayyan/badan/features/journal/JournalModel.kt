package net.albayyan.badan.features.journal

import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.journal.BehaviorValueKind
import net.albayyan.badan.domain.journal.ContextStatus
import net.albayyan.badan.domain.journal.JournalEntry
import net.albayyan.badan.domain.journal.JournalLog
import net.albayyan.badan.ontology.BehaviorDefinition

/**
 * EPIC-29 — the journal and context-status surfaces' Compose-free presentation core, and the Android
 * half of the iOS `JournalStrings` / `JournalCategory` / `JournalDayBuilder` / `ContextStatusList`
 * set. Same pure/UI split `HealthMonitorModel` uses; `JournalSurfacePresentationTest` asserts it on
 * the JVM without the Compose runtime.
 *
 * Nothing here restates a domain rule. The interval semantics live on `ContextStatus`, the recall
 * arithmetic on `JournalLog`, and the storage rules on `JournalRepository` — a second copy of a rule
 * is a second place for it to be wrong.
 */

// MARK: - Strings
//
// The register is the one `behaviors.json` is curated in: **records what happened, never grades
// it**. Nothing here says "too much", "should", "avoid" or "better", and no day is a "miss".

internal object JournalStrings {
    val title = LocalizedString(en = "Daily journal", ar = "المفكرة اليومية")
    val logTile = LocalizedString(en = "Journal", ar = "المفكرة")

    /** Plan §16's locked trust line for this surface. */
    val trust = LocalizedString(
        en = "Used only on your device to find your patterns.",
        ar = "تُستخدم على جهازك فقط لاكتشاف أنماطك.",
    )

    val today = LocalizedString(en = "Today", ar = "اليوم")
    val yesterday = LocalizedString(en = "Yesterday", ar = "أمس")
    val dayPickerLabel = LocalizedString(en = "Day being logged", ar = "اليوم الذي تسجّله")

    /**
     * The arm rule, said plainly. `CorrelationEngine` treats a behaviour with no tag on a day the
     * user journaled as a day it did NOT happen, so what the user leaves untapped is evidence too —
     * that has to be visible on the screen where the tapping happens, not only in a doc.
     */
    val untappedNote = LocalizedString(
        en = "Tap what happened. On a day you log, anything you leave untapped counts as “didn’t happen”.",
        ar = "اضغط ما حدث فعلاً. وفي أي يوم تسجّل فيه، يُحتسب ما تتركه دون ضغط أنه لم يحدث.",
    )

    /**
     * Shown while the day selector sits on Yesterday. Names both instants rather than hiding the
     * backdating — `JournalEntry.isRecalled` is disclosure, never a discount.
     */
    val recallNote = LocalizedString(
        en = "Logging for yesterday. BADAN records both when it happened and when you entered it.",
        ar = "أنت تسجّل ليوم أمس. يحفظ بدن وقت حدوث الأمر ووقت إدخالك له معاً.",
    )

    val taggedCount = LocalizedString(en = "Tagged: {n}", ar = "عدد العلامات: {n}")
    val nothingTaggedYet = LocalizedString(en = "Nothing tagged yet", ar = "لا توجد علامات بعد")

    val amount = LocalizedString(en = "Amount", ar = "المقدار")
    val minutes = LocalizedString(en = "min", ar = "دقيقة")
    val times = LocalizedString(en = "times", ar = "مرات")
    val decreaseAmount = LocalizedString(en = "Decrease", ar = "إنقاص")
    val increaseAmount = LocalizedString(en = "Increase", ar = "زيادة")

    val ownTagsTitle = LocalizedString(en = "Your own tags", ar = "علاماتك الخاصة")
    val ownTagPlaceholder = LocalizedString(en = "Add your own tag", ar = "أضف علامة خاصة بك")

    /**
     * Says out loud what the engine does with free text, so a power user is never surprised that
     * their own tags produced no findings.
     */
    val ownTagsNote = LocalizedString(
        en = "Saved and exported with everything else. Your own tags aren’t compared against your scores — two spellings of one habit would split the evidence in half.",
        ar = "تُحفظ وتُصدَّر مع بقية بياناتك. لكن علاماتك الخاصة لا تُقارَن بمؤشراتك، لأن كتابة العادة نفسها بصيغتين تقسّم الأدلة إلى نصفين.",
    )

    /** The chip's spoken state — the two halves of the switch a screen reader announces. */
    val logged = LocalizedString(en = "Logged", ar = "مُسجَّل")
    val notLogged = LocalizedString(en = "Not logged", ar = "غير مُسجَّل")

    val saveFailed = LocalizedString(
        en = "Couldn’t save that — try again.",
        ar = "تعذّر الحفظ — حاول مرة أخرى.",
    )
    val loadFailed = LocalizedString(
        en = "Couldn’t load today’s tags — try again.",
        ar = "تعذّر تحميل علامات اليوم — حاول مرة أخرى.",
    )

    /**
     * The journal is sensitive-plus (I7): when sensitive records are off it is not shown at all, and
     * the reason is named rather than left as a missing tile.
     */
    val sensitiveOffTitle = LocalizedString(
        en = "The journal is part of sensitive records",
        ar = "المفكرة ضمن السجلات الحساسة",
    )
    val sensitiveOffMessage = LocalizedString(
        en = "Behaviour tags stay in the separate, purgeable store with medications and symptoms. Turn on Sensitive records in Settings to log them.",
        ar = "تبقى علامات السلوك في المخزن المنفصل القابل للحذف مع الأدوية والأعراض. فعّل السجلات الحساسة من الإعدادات لتسجيلها.",
    )

    // MARK: - Context statuses

    val contextTitle = LocalizedString(en = "Periods you’ve marked", ar = "فترات وصفتها")

    /**
     * The whole behavioural contract of `ContextStatus`, in one sentence: it conditions how a value
     * is READ and never what the value is.
     */
    val contextExplainer = LocalizedString(
        en = "Marking a period changes no number. It tells BADAN to read those days less confidently and adds a note beside them.",
        ar = "وصف فترة لا يغيّر أي رقم. فهو يجعل بدن يقرأ تلك الأيام بثقة أقل ويضيف ملاحظة بجانبها.",
    )
    val contextStart = LocalizedString(en = "Start a period", ar = "ابدأ فترة")
    val contextOngoing = LocalizedString(en = "Ongoing", ar = "مستمرة")
    val contextEndNow = LocalizedString(en = "End now", ar = "أنهِ الآن")
    val contextStarted = LocalizedString(en = "Started {date}", ar = "بدأت في {date}")
    val contextRange = LocalizedString(en = "{start} to {end}", ar = "من {start} إلى {end}")
    val contextEarlier = LocalizedString(en = "Earlier", ar = "سابقة")
    val contextNoneTitle = LocalizedString(en = "Nothing marked", ar = "لا توجد فترات موصوفة")
    val contextNoneMessage = LocalizedString(
        en = "That’s the normal state. Mark a period only when a stretch of days genuinely didn’t look like your usual ones.",
        ar = "وهذه هي الحالة المعتادة. صِف فترة فقط حين تكون أيامٌ متتالية مختلفة فعلاً عن أيامك المعتادة.",
    )
    val contextCustomPlaceholder = LocalizedString(
        en = "Describe it in your own words",
        ar = "صِفها بكلماتك",
    )
    val contextDelete = LocalizedString(en = "Remove", ar = "إزالة")
}

/**
 * Display names for the behaviour dictionary's category keys — the chip-group headings.
 *
 * A table rather than a `nameEn`/`nameAr` pair on each dictionary row: a category is a UI grouping,
 * not a piece of the shared contract, and adding two localized fields per behaviour to
 * `behaviors.json` would put ten strings in the contract twenty-eight times over.
 * `JournalSurfacePresentationTest` asserts every category the shipped dictionary uses resolves HERE
 * rather than falling back, so a new category in the contract fails the suite instead of shipping as
 * a raw key.
 */
internal object JournalCategory {

    fun displayName(category: String): LocalizedString? = when (category) {
        "stimulants" -> LocalizedString(en = "Stimulants", ar = "منبّهات")
        "alcohol" -> LocalizedString(en = "Alcohol", ar = "الكحول")
        "food" -> LocalizedString(en = "Food", ar = "الطعام")
        "hydration" -> LocalizedString(en = "Water", ar = "الماء")
        "evening" -> LocalizedString(en = "Evening", ar = "المساء")
        "sleep" -> LocalizedString(en = "Sleep", ar = "النوم")
        "movement" -> LocalizedString(en = "Movement", ar = "الحركة")
        "recovery" -> LocalizedString(en = "Recovery", ar = "الاستشفاء")
        "supplements" -> LocalizedString(en = "Supplements", ar = "المكمّلات")
        "circumstance" -> LocalizedString(en = "The day itself", ar = "طبيعة اليوم")
        else -> null
    }

    /**
     * The heading actually rendered. An unknown category (a dictionary row added ahead of this
     * table) falls back to its raw key rather than disappearing — a chip with no group would be a
     * behaviour the user can never tap.
     */
    fun heading(category: String): LocalizedString =
        displayName(category) ?: LocalizedString(en = category, ar = category)
}

// MARK: - Which day is being logged

/**
 * The two days the journal offers. Deliberately two and not a date picker: plan §11 names chore
 * fatigue as this epic's main risk, and "today" plus "the day I forgot" is the whole realistic range
 * of a ten-second flow. Anything older is a correction, not journaling, and belongs on the entry
 * itself (a tombstone plus a fresh row) rather than in the daily surface.
 */
internal enum class JournalDayChoice {
    TODAY,
    YESTERDAY;

    val displayName: LocalizedString
        get() = when (this) {
            TODAY -> JournalStrings.today
            YESTERDAY -> JournalStrings.yesterday
        }

    /**
     * The instant an entry logged on this screen carries as `occurredAt`.
     *
     * Yesterday goes through `JournalLog.yesterday`, which does calendar arithmetic rather than
     * subtracting 86 400 000 millis — across a DST boundary the fixed-millis form lands an hour off
     * and files the entry under the wrong local day, and the local day IS the bucket every
     * correlation arm is built from.
     */
    fun occurredAt(now: Long, tzId: String): Long = when (this) {
        TODAY -> now
        YESTERDAY -> JournalLog.yesterday(now, tzId)
    }

    /**
     * True for the recall path, which routes through `JournalLog.recalledEntry` so the stored row
     * reports `isRecalled` instead of pretending it was typed as it happened.
     */
    val isRecall: Boolean get() = this == YESTERDAY
}

// MARK: - One chip

/**
 * A behaviour chip's state for the day on screen: the dictionary row, and the live entry for it if
 * the user has tagged it.
 *
 * [entry] is the ONLY source of "is this on" — there is no separate selected-set the view keeps in
 * parallel, so the chips cannot drift from what is actually stored. A toggle writes, reloads, and
 * the chips re-derive.
 */
internal data class JournalChip(
    val behavior: BehaviorDefinition,
    val entry: JournalEntry?,
) {
    val id: String get() = behavior.id
    val isOn: Boolean get() = entry != null

    /**
     * The amount the user recorded, when they recorded one. Null for a plain tap — a tap stores a
     * boolean row and no number at all, because a tapped "Nap" chip does not tell BADAN the nap was
     * twenty minutes.
     */
    val amount: Double?
        get() = entry?.takeIf { it.valueKind != BehaviorValueKind.BOOLEAN }?.value

    /**
     * Whether power depth may offer a count/duration for this behaviour. Read from the DICTIONARY
     * (the shape the contract says this behaviour has), never from the stored row.
     */
    val offersAmount: Boolean get() = behavior.valueKind != BehaviorValueKind.BOOLEAN

    /**
     * The step a `+`/`−` tap moves by: minutes go in fives (a nap is not timed to the minute), counts
     * in ones.
     */
    val amountStep: Double get() = if (behavior.valueKind == BehaviorValueKind.QUANTITY) 5.0 else 1.0

    /**
     * The unit label beside a power-depth amount, or null for a count — which counts the behaviour
     * itself and so has no physical unit (2 coffees is 2, not 2 of anything convertible).
     */
    val amountUnit: LocalizedString?
        get() = if (behavior.valueKind == BehaviorValueKind.QUANTITY && behavior.unit == "min") {
            JournalStrings.minutes
        } else {
            null
        }
}

/** One category's chips, in dictionary order. */
internal data class JournalChipGroup(
    val category: String,
    val chips: List<JournalChip>,
) {
    val heading: LocalizedString get() = JournalCategory.heading(category)
}

// MARK: - Building the day

/**
 * The pure day-model builder. Everything the journal screen renders comes from here, so the rules
 * that matter — one chip per dictionary behaviour, newest row wins, custom tags listed separately —
 * are testable without a database or a view.
 */
internal object JournalDayBuilder {

    /**
     * Chips for every dictionary behaviour, paired with the day's live entry where one exists.
     *
     * **Every behaviour always gets a chip**, tagged or not: the vocabulary is the surface, and a
     * disappearing chip would make the screen's shape depend on what was logged.
     *
     * Duplicate rows for one behaviour on one day (possible from a sync peer or an import, never
     * from this screen) resolve to the NEWEST assertion, and the older row stays in the store —
     * readable and exportable. Resolved by comparing timestamps rather than by trusting the query's
     * ordering: the repository does return newest-first today, but a chip silently bound to a
     * superseded row would show the wrong amount and remove the wrong entry, and that failure is
     * invisible in review.
     */
    fun chips(dictionary: List<BehaviorDefinition>, entries: List<JournalEntry>): List<JournalChip> {
        val byBehavior = HashMap<String, JournalEntry>()
        for (entry in entries) {
            if (entry.deletedAt != null) continue
            val behaviorId = entry.behaviorId ?: continue
            val existing = byBehavior[behaviorId]
            if (existing == null ||
                entry.occurredAt > existing.occurredAt ||
                (entry.occurredAt == existing.occurredAt &&
                    entry.provenance.recordedAt > existing.provenance.recordedAt)
            ) {
                byBehavior[behaviorId] = entry
            }
        }
        return dictionary.map { JournalChip(behavior = it, entry = byBehavior[it.id]) }
    }

    /**
     * Group chips by category, preserving the dictionary's own order for both the groups and the
     * chips inside them — the file is authored in a deliberate order (stimulants first, the day
     * itself last) and re-sorting it here would silently override that editorial decision.
     */
    fun groups(chips: List<JournalChip>): List<JournalChipGroup> {
        val order = ArrayList<String>()
        val buckets = HashMap<String, MutableList<JournalChip>>()
        for (chip in chips) {
            val category = chip.behavior.category
            if (buckets[category] == null) {
                order.add(category)
                buckets[category] = ArrayList()
            }
            buckets[category]!!.add(chip)
        }
        return order.map { JournalChipGroup(category = it, chips = buckets[it].orEmpty()) }
    }

    /**
     * The day's free-text tags, newest first. Kept apart from the chips because they behave
     * differently in one visible way — they are not correlated (see [JournalStrings.ownTagsNote]) —
     * and mixing them into the chip grid would imply otherwise.
     */
    fun customEntries(entries: List<JournalEntry>): List<JournalEntry> =
        entries.filter { it.deletedAt == null && it.behaviorId == null && !it.customLabel.isNullOrEmpty() }
            .sortedByDescending { it.occurredAt }

    /**
     * How many things the user tagged on this day — chips plus free-text tags. A plain count with no
     * target and no streak: the journal records, it does not score the journaling.
     */
    fun taggedCount(chips: List<JournalChip>, customEntries: List<JournalEntry>): Int =
        chips.count { it.isOn } + customEntries.size
}

// MARK: - Context statuses

/** The declared-interval list, split the way the manager screen renders it. */
internal data class ContextStatusList(
    /** Open-ended or still running as of `now`, most recently started first. */
    val active: List<ContextStatus>,
    /** Closed intervals, most recently started first. */
    val past: List<ContextStatus>,
) {
    val isEmpty: Boolean get() = active.isEmpty() && past.isEmpty()

    companion object {
        /**
         * Splits live statuses into the two sections. A null `endAt` is the NORMAL case (a status is
         * declared when it starts and closed later), so it must read as active rather than
         * malformed — the same rule `ContextStatus.isActive` encodes, which is why membership is
         * asked of the status rather than re-derived from the column here.
         */
        fun from(statuses: List<ContextStatus>, now: Long): ContextStatusList {
            val live = statuses.filter { it.deletedAt == null }.sortedByDescending { it.startAt }
            return ContextStatusList(
                active = live.filter { it.isActive(now) },
                past = live.filter { !it.isActive(now) },
            )
        }
    }
}
