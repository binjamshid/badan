package net.albayyan.badan.features.hydration

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.MILLIS_PER_DAY
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.hydration.GoalEngine
import net.albayyan.badan.domain.hydration.HydrationEntry
import net.albayyan.badan.domain.hydration.HydrationFluidType
import net.albayyan.badan.domain.hydration.HydrationGoal
import net.albayyan.badan.domain.hydration.HydrationGoalKind
import net.albayyan.badan.domain.hydration.HydrationLedger
import java.time.Instant
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale
import java.util.TimeZone

// MARK: - Bilingual strings (feature-scoped)
//
// Everything the hydration surface says, in both languages, in one place. Shared vocabulary
// (Add / Save / Cancel / Edit / Delete / Today / Close) still comes from `Loc`; only the
// hydration-specific copy lives here. The register is the anti-nag register §7A.1 mandates: no
// dehydration claims, no urgency, no streaks, no percentage-of-nothing. No-goal is described as a
// legitimate way to track, never as an unset or missing target.

object HydrationStrings {
    val waterToday = LocalizedString(en = "Water today", ar = "الماء اليوم")
    val loggedToday = LocalizedString(en = "logged today", ar = "مُسجَّل اليوم")

    /** The no-goal progress line — a fact, never a shortfall. */
    fun totalLine(amount: String, unit: String): LocalizedString = LocalizedString(
        en = "$amount $unit logged today",
        ar = "$amount $unit مُسجَّل اليوم",
    )

    /** The with-goal progress line: logged over the user's own tracking target. */
    fun goalLine(amount: String, target: String, unit: String): LocalizedString = LocalizedString(
        en = "$amount / $target $unit",
        ar = "$amount / $target $unit",
    )

    val customAmount = LocalizedString(en = "Custom amount", ar = "كمية مخصصة")
    val addADrink = LocalizedString(en = "Add a drink", ar = "إضافة مشروب")
    val ml = LocalizedString(en = "mL", ar = "مل")
    val drink = LocalizedString(en = "Drink", ar = "المشروب")
    val whenLogged = LocalizedString(en = "Time", ar = "الوقت")
    val noteOptional = LocalizedString(en = "Note (optional)", ar = "ملاحظة (اختياري)")
    val undo = LocalizedString(en = "Undo", ar = "تراجع")
    val nothingYet = LocalizedString(
        en = "No drinks logged yet today.",
        ar = "لم تُسجَّل مشروبات اليوم بعد.",
    )
    val logsHint = LocalizedString(
        en = "Tap an amount to log a drink in one tap.",
        ar = "اضغط على كمية لتسجيل مشروب بضغطة واحدة.",
    )

    // Favorites (curated in-memory defaults; a user's own containers appear beside them).
    val glass = LocalizedString(en = "Glass", ar = "كوب")
    val bottle = LocalizedString(en = "Bottle", ar = "زجاجة")

    // Overflow / module controls.
    val goalSettings = LocalizedString(en = "Tracking goal", ar = "هدف التتبّع")
    val hideModule = LocalizedString(en = "Hide hydration", ar = "إخفاء الترطيب")
    val hiddenNotice = LocalizedString(en = "Hydration is hidden", ar = "الترطيب مخفي")
    val showModule = LocalizedString(en = "Show", ar = "إظهار")
    val hiddenExplainer = LocalizedString(
        en = "Your logged drinks are kept — showing hydration again brings them back.",
        ar = "تبقى مشروباتك المُسجَّلة محفوظة — إظهار الترطيب مجددًا يعيدها.",
    )

    // Goal sheet.
    val goalTitle = LocalizedString(en = "Tracking goal", ar = "هدف التتبّع")
    val noGoalOption = LocalizedString(en = "Track without a goal", ar = "التتبّع دون هدف")
    val noGoalDetail = LocalizedString(
        en = "Log your drinks and see your day — no target, no reminders to hit a number.",
        ar = "سجّل مشروباتك وشاهد يومك — دون هدف ودون تذكيرات ببلوغ رقم.",
    )
    val manualGoalOption = LocalizedString(en = "Set a daily amount", ar = "تحديد كمية يومية")
    val manualGoalDetail = LocalizedString(
        en = "A number you chose to aim for. You can change or clear it anytime.",
        ar = "رقم اخترته لتسعى إليه. يمكنك تغييره أو إزالته في أي وقت.",
    )
    val dailyTarget = LocalizedString(en = "Daily amount", ar = "الكمية اليومية")

    // Weekly card.
    val thisWeek = LocalizedString(en = "This week", ar = "هذا الأسبوع")
    val weeklyReassurance = LocalizedString(
        en = "Days without a log aren't days you didn't drink — just days without an entry.",
        ar = "الأيام بلا تسجيل ليست أيامًا لم تشرب فيها — بل أيام دون إدخال فقط.",
    )

    /** Observational weekly sentence — a count, never a streak or a shortfall. */
    fun daysLogged(days: String, of: String): LocalizedString = LocalizedString(
        en = "You logged drinks on $days of the last $of days.",
        ar = "سجّلت مشروبات في $days من آخر $of أيام.",
    )

    /** The confirmation after a one-tap log: names the container/drink when there is one. */
    fun addedFrom(amount: String, unit: String, container: String?, beverage: String?): LocalizedString = when {
        container != null -> LocalizedString(
            en = "Added $amount $unit from $container",
            ar = "أُضيف $amount $unit من $container",
        )
        beverage != null -> LocalizedString(
            en = "Added $amount $unit of $beverage",
            ar = "أُضيف $amount $unit من $beverage",
        )
        else -> LocalizedString(en = "Added $amount $unit", ar = "أُضيف $amount $unit")
    }
}

// MARK: - Progress (pure)

/**
 * The calm progress model for a day. `NoGoal` is a first-class, equal-status state — it carries the
 * logged total and NO fraction, so the card can render "1,250 mL logged today" without ever
 * computing a percentage-of-nothing (the exact streak-guilt framing §7A.1 rejects). `WithGoal`
 * carries a fraction only for the gentle bar; the bar is capped at 1.0 for drawing but the raw
 * fraction is preserved so an over-target day reads as "more than your amount", never an alarm.
 */
sealed interface HydrationProgress {
    val totalMl: Double

    data class NoGoal(override val totalMl: Double) : HydrationProgress
    data class WithGoal(override val totalMl: Double, val targetMl: Double) : HydrationProgress {
        /** Uncapped fraction (may exceed 1.0). */
        val fraction: Double get() = if (targetMl > 0.0) totalMl / targetMl else 0.0
        /** Fraction clamped to [0,1] for the progress bar's width — never a >100% bar. */
        val barFraction: Float get() = fraction.coerceIn(0.0, 1.0).toFloat()
    }

    companion object {
        /**
         * Resolve the day's progress from the live total and the currently-active goal. A `NONE`
         * goal, a null goal, or a non-positive target all collapse to [NoGoal] — the honest default,
         * never a fabricated 0%.
         */
        fun of(totalMl: Double, goal: HydrationGoal?): HydrationProgress =
            if (goal != null && goal.hasTarget) WithGoal(totalMl, goal.targetMl!!) else NoGoal(totalMl)
    }
}

// MARK: - Favorites (pure)

/**
 * A one-tap logging affordance on the Today card. Either a curated in-memory default (Glass /
 * Bottle, plain water) or one of the user's own `container_presets` rows. Logging one is ≤2 actions
 * and yields the "Added 500 mL from Bottle" confirmation its [name] supplies.
 */
data class HydrationFavorite(
    val id: String,
    val name: LocalizedString,
    val volumeMl: Double,
    val beverageId: String? = null,
    val fluidType: String = HydrationFluidType.WATER.code,
    /** True for the built-in Glass/Bottle defaults, so they can be styled/ordered distinctly. */
    val isBuiltin: Boolean = false,
) {
    companion object {
        /**
         * The curated defaults shown when the user has authored no containers yet. Kept in memory
         * (not seeded rows) so the module needs no extra migration or seed and a "Delete all data"
         * never strands the card without a way to log. Two calm sizes cover a glass and a bottle.
         */
        val defaults: List<HydrationFavorite> = listOf(
            HydrationFavorite("builtin.glass", HydrationStrings.glass, 250.0, isBuiltin = true),
            HydrationFavorite("builtin.bottle", HydrationStrings.bottle, 500.0, isBuiltin = true),
        )
    }
}

// MARK: - Today / week state

/** A resolved snapshot of the Today card's data, loaded off-thread and handed to the composable. */
data class HydrationTodayState(
    val entries: List<HydrationEntry>,   // today's LIVE entries, newest first
    val totalMl: Double,
    val goal: HydrationGoal?,            // the currently-active default goal (may be NONE / null)
    val favorites: List<HydrationFavorite>,
) {
    val progress: HydrationProgress get() = HydrationProgress.of(totalMl, goal)

    companion object {
        val empty = HydrationTodayState(emptyList(), 0.0, null, HydrationFavorite.defaults)
    }
}

/** One bar in the observational weekly card: a local day, its short label, and the day's logged mL. */
data class HydrationWeekDay(
    val dayKey: String,
    val label: String,
    val totalMl: Double,
    val isToday: Boolean,
) {
    val hasLog: Boolean get() = totalMl > 0.0
}

/** The weekly card's resolved data: seven day-bars (oldest → newest) plus the observational count. */
data class HydrationWeek(
    val days: List<HydrationWeekDay>,
) {
    val daysWithLogs: Int get() = days.count { it.hasLog }
    val span: Int get() = days.size
    val maxMl: Double get() = days.maxOfOrNull { it.totalMl } ?: 0.0
    val anyLogs: Boolean get() = daysWithLogs > 0
}

// MARK: - Data + mutation layer (repository-backed; callers wrap in withContext(IO))
//
// Every function here is a thin, honest use of the already-built `HydrationRepository` +
// `HydrationLedger` + `GoalEngine`. Nothing infers a goal, a day type, or a hydration weight; a
// logged mL is stored as exactly that mL (no net-hydration multiplier — §7A.1). Mutations recompute
// the affected day's summary so the summary table (which export reads) stays honest.

object HydrationData {

    /** The IANA tz id used to attribute an entry to a local day. */
    private fun tz(): String = TimeZone.getDefault().id

    /** Manual provenance for a UI-entered drink — this device asserted it (I1). */
    private fun manualProvenance(env: AppEnvironment, occurredAt: Long, now: Long, tzId: String): Provenance =
        Provenance(
            sourceId = env.deviceId,
            deviceId = env.deviceId,
            ingestionPath = IngestionPath.MANUAL,
            measuredAt = occurredAt,
            measuredTimezone = tzId,
            recordedAt = now,
            ingestedAt = now,
        )

    /**
     * The favorites row: the user's own container presets (named, ordered) followed by the curated
     * defaults. User containers come first because they are the ones a person deliberately made;
     * the defaults are the always-there fallback so the card can never be favorite-less.
     */
    fun favorites(env: AppEnvironment): List<HydrationFavorite> {
        val user = runCatching { env.hydration.containers() }.getOrDefault(emptyList()).map { c ->
            HydrationFavorite(
                id = c.id,
                name = c.displayName,
                volumeMl = c.volumeMl,
                beverageId = c.beverageId,
                fluidType = env.beverages.beverage(c.beverageId)?.fluidType ?: HydrationFluidType.WATER.code,
            )
        }
        return user + HydrationFavorite.defaults
    }

    /** Load the Today card's full state: live entries for the local day, total, active goal, favorites. */
    fun loadToday(env: AppEnvironment): HydrationTodayState {
        val now = env.now()
        val tzId = tz()
        val dayKey = GoalEngine.dayKey(now, tzId)
        val (start, end) = net.albayyan.badan.storage.repositories.HydrationRepository.dayBounds(dayKey, tzId)
        val entries = runCatching { env.hydration.liveEntries(start, end) }.getOrDefault(emptyList())
            .filter { GoalEngine.dayKey(it.occurredAt, tzId) == dayKey }
        val total = entries.sumOf { it.volumeMl }
        val goal = runCatching { GoalEngine.resolveGoal(null, env.hydration.activeGoals()) }.getOrNull()
        return HydrationTodayState(
            entries = entries,
            totalMl = total,
            goal = goal,
            favorites = favorites(env),
        )
    }

    /**
     * The last seven local days as bars, oldest → newest, computed straight from live entries so the
     * observational count never depends on whether a summary row happens to exist. Empty days are
     * present (as zero) on purpose — the card shows the shape of the week, and the reassurance copy
     * makes clear an empty day is "no log", not "no drink".
     */
    fun loadWeek(env: AppEnvironment, spanDays: Int = 7): HydrationWeek {
        val now = env.now()
        val tzId = tz()
        val zone = runCatching { ZoneId.of(tzId) }.getOrElse { ZoneId.of("UTC") }
        val locale = Locale.forLanguageTag(env.language.localeTag)
        val todayKey = GoalEngine.dayKey(now, tzId)

        val from = now - (spanDays - 1).toLong() * MILLIS_PER_DAY
        val fromKey = GoalEngine.dayKey(from, tzId)
        val (start, _) = net.albayyan.badan.storage.repositories.HydrationRepository.dayBounds(fromKey, tzId)
        val entries = runCatching { env.hydration.liveEntries(start, now) }.getOrDefault(emptyList())
        val totals = HashMap<String, Double>()
        for (e in entries) {
            val k = GoalEngine.dayKey(e.occurredAt, tzId)
            totals[k] = (totals[k] ?: 0.0) + e.volumeMl
        }

        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val days = (spanDays - 1 downTo 0).map { back ->
            val date = today.minusDays(back.toLong())
            val key = "%04d-%02d-%02d".format(date.year, date.monthValue, date.dayOfMonth)
            HydrationWeekDay(
                dayKey = key,
                label = date.dayOfWeek.getDisplayName(TextStyle.SHORT, locale),
                totalMl = totals[key] ?: 0.0,
                isToday = key == todayKey,
            )
        }
        return HydrationWeek(days)
    }

    /**
     * Append a drink and refresh the day's summary. Returns the stored entry so the caller can offer
     * "Undo" on exactly that row. [occurredAt] defaults to now (the quick-log path); the custom sheet
     * may pass an earlier time.
     */
    fun log(
        env: AppEnvironment,
        volumeMl: Double,
        fluidType: String = HydrationFluidType.WATER.code,
        beverageId: String? = null,
        containerId: String? = null,
        note: String? = null,
        occurredAt: Long? = null,
    ): HydrationEntry {
        val now = env.now()
        val at = occurredAt ?: now
        val tzId = tz()
        val entry = HydrationLedger.makeEntry(
            id = Ulid.newId(),
            volumeMl = volumeMl,
            fluidType = fluidType,
            beverageId = beverageId,
            containerId = containerId,
            occurredAt = at,
            tzId = tzId,
            note = note,
            provenance = manualProvenance(env, at, now, tzId),
            updatedAt = now,
            originDeviceId = env.deviceId,
        )
        env.hydration.insertEntry(entry)
        resnapshotDay(env, at, now, tzId, forceGoalResnapshot = false)
        return entry
    }

    /** Convenience: log one favorite tap. Returns the entry (for Undo + the "Added … from …" line). */
    fun logFavorite(env: AppEnvironment, favorite: HydrationFavorite): HydrationEntry = log(
        env = env,
        volumeMl = favorite.volumeMl,
        fluidType = favorite.fluidType,
        beverageId = favorite.beverageId,
        containerId = favorite.id.takeUnless { favorite.isBuiltin },
    )

    /**
     * Revise a live entry — an APPEND that supersedes it (never a mutate; I2). Returns the new head.
     * Any field left null falls back to the live value inside `HydrationLedger.makeRevision`, so a
     * "just fix the volume" edit keeps the beverage, time and note.
     */
    fun revise(
        env: AppEnvironment,
        live: HydrationEntry,
        volumeMl: Double = live.volumeMl,
        fluidType: String = live.fluidType,
        beverageId: String? = live.beverageId,
        note: String? = live.note,
        occurredAt: Long = live.occurredAt,
    ): HydrationEntry {
        val now = env.now()
        val tzId = tz()
        val revision = HydrationLedger.makeRevision(
            live = live,
            id = Ulid.newId(),
            volumeMl = volumeMl,
            fluidType = fluidType,
            beverageId = beverageId,
            occurredAt = occurredAt,
            note = note,
            provenance = manualProvenance(env, occurredAt, now, tzId),
            updatedAt = now,
            originDeviceId = env.deviceId,
        )
        env.hydration.insertEntry(revision)
        // Both the old and the new day may need refreshing if the edit moved the drink's time.
        resnapshotDay(env, live.occurredAt, now, tzId, forceGoalResnapshot = false)
        resnapshotDay(env, occurredAt, now, tzId, forceGoalResnapshot = false)
        return revision
    }

    /** Undo one row (the quick-log "Undo", or reverting a single revision). Refreshes its day. */
    fun undo(env: AppEnvironment, entry: HydrationEntry) {
        val now = env.now()
        env.hydration.undoEntry(entry.id, now)
        resnapshotDay(env, entry.occurredAt, now, tz(), forceGoalResnapshot = false)
    }

    /** Delete a whole logical drink (its entire chain). Refreshes its day. */
    fun delete(env: AppEnvironment, entry: HydrationEntry) {
        val now = env.now()
        env.hydration.deleteEntry(entry.originalId, now)
        resnapshotDay(env, entry.occurredAt, now, tz(), forceGoalResnapshot = false)
    }

    /** The currently-active default goal (may be a NONE row, or null when none exists). */
    fun activeGoal(env: AppEnvironment): HydrationGoal? =
        runCatching { GoalEngine.resolveGoal(null, env.hydration.activeGoals()) }.getOrNull()

    /**
     * Set the default goal to no-goal or a manual target and re-snapshot TODAY (only) so today's
     * frozen goal reflects the change while past days keep their honest snapshots. Deactivates any
     * prior default goal first (append-only history; the old row stays, inactive).
     */
    fun setGoal(env: AppEnvironment, kind: HydrationGoalKind, targetMl: Double?) {
        val now = env.now()
        env.hydration.deactivateGoals(dayType = null, at = now)
        val goal = when (kind) {
            HydrationGoalKind.NONE -> HydrationGoal.noGoal(
                id = Ulid.newId(), createdAt = now, updatedAt = now, originDeviceId = env.deviceId,
            )
            HydrationGoalKind.MANUAL -> HydrationGoal(
                id = Ulid.newId(), kind = HydrationGoalKind.MANUAL, targetMl = targetMl,
                dayType = null, active = true, createdAt = now, updatedAt = now, originDeviceId = env.deviceId,
            )
        }
        env.hydration.upsertGoal(goal)
        resnapshotDay(env, now, now, tz(), forceGoalResnapshot = true)
    }

    /** Recompute one day's summary from its live entries (totals always; goal snapshot per the flag). */
    private fun resnapshotDay(env: AppEnvironment, dayMillis: Long, now: Long, tzId: String, forceGoalResnapshot: Boolean) {
        val dayKey = GoalEngine.dayKey(dayMillis, tzId)
        runCatching {
            env.hydration.recomputeSummary(
                dayKey = dayKey, tzId = tzId, dayType = null, now = now,
                originDeviceId = env.deviceId, forceGoalResnapshot = forceGoalResnapshot,
            )
        }
    }
}

// MARK: - Off-thread wrappers
//
// The composables never touch SQLite on the main thread; these suspend wrappers move each op to IO,
// mirroring how the other log surfaces load and mutate.

suspend fun loadTodayAsync(env: AppEnvironment): HydrationTodayState =
    withContext(Dispatchers.IO) { HydrationData.loadToday(env) }

suspend fun loadWeekAsync(env: AppEnvironment): HydrationWeek =
    withContext(Dispatchers.IO) { HydrationData.loadWeek(env) }
