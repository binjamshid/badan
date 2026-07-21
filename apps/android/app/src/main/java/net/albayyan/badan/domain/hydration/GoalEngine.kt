package net.albayyan.badan.domain.hydration

import java.time.Instant
import java.time.ZoneId

// MARK: - Goal

/**
 * Which kind of hydration goal is in effect. `NONE` is a **first-class, equal-status value**, not the
 * absence of a goal: §7A.1 is explicit that no-goal must never be nagged and never treated as
 * "unset". A summary snapshotted under `NONE` records that the user was tracking *without* a target —
 * a legitimate, complete state, distinct from "we don't know". Mirror of iOS `HydrationGoalKind`.
 */
enum class HydrationGoalKind(val code: String) {
    NONE("none"),       // tracking without a target — never nagged, never "0% of nothing"
    MANUAL("manual");   // a user-entered daily target

    companion object {
        fun fromCode(code: String?): HydrationGoalKind = entries.firstOrNull { it.code == code } ?: NONE
    }
}

/**
 * A hydration goal. [targetMl] is null exactly when `kind == NONE`. [dayType] is a **user-authored**
 * label (e.g. "training", "rest") for day-type goal schedules (§7A.1, Phase 2); a null [dayType] is
 * the default goal that applies when no day-type override matches. Nothing here infers a day type or
 * a target. Mirror of iOS `HydrationGoal`.
 */
data class HydrationGoal(
    val id: String,
    val kind: HydrationGoalKind,
    val targetMl: Double? = null,
    val dayType: String? = null,
    val active: Boolean = true,
    val createdAt: Long,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    /** True only when a real, positive target exists — the guard every progress computation uses. */
    val hasTarget: Boolean get() = kind != HydrationGoalKind.NONE && (targetMl ?: 0.0) > 0.0

    companion object {
        /** The canonical no-goal value — say what you mean rather than pass a bare null target. */
        fun noGoal(id: String, dayType: String? = null, createdAt: Long, updatedAt: Long, originDeviceId: String): HydrationGoal =
            HydrationGoal(id = id, kind = HydrationGoalKind.NONE, targetMl = null, dayType = dayType,
                active = true, createdAt = createdAt, updatedAt = updatedAt, originDeviceId = originDeviceId)
    }
}

// MARK: - Daily summary

/**
 * A day's hydration rollup with a **frozen goal snapshot**. Manual / imported / estimated totals are
 * kept separate (I5) — only [manualMl] is populated this phase, but the other two exist so an
 * imported/estimated volume can never be silently blended into the number the user actually logged.
 * The `goal*` fields record the goal that was in effect when this day was first summarized, so raising
 * a goal next month does not retroactively mark last month's met days as missed. Mirror of iOS
 * `HydrationDailySummary`.
 */
data class HydrationDailySummary(
    val dayKey: String,        // local calendar day, "yyyy-MM-dd"
    val tzId: String,          // the tz the day boundary was computed in
    val manualMl: Double,
    val importedMl: Double = 0.0,
    val estimatedMl: Double = 0.0,
    val entryCount: Int,
    val goalKind: HydrationGoalKind,   // snapshot
    val goalTargetMl: Double? = null,  // snapshot; null for a no-goal day
    val goalId: String? = null,        // snapshot; which goal produced it
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    val totalMl: Double get() = manualMl + importedMl + estimatedMl

    /**
     * Progress against the snapshotted target — **only** when a real target was in effect. A no-goal
     * day returns null, never 0: a percentage-of-nothing is exactly the streak-guilt framing §7A.1
     * rejects ("Missing logs do not mean the user did not drink").
     */
    val goalProgressPct: Double?
        get() {
            val target = goalTargetMl
            return if (goalKind != HydrationGoalKind.NONE && target != null && target > 0.0) totalMl / target * 100.0 else null
        }
}

// MARK: - Goal engine

/**
 * Pure logic for resolving goals and rolling up daily summaries. Storage-free and total, so the
 * no-goal-is-equal-status rule and the snapshot-survives-a-goal-change rule are testable without a
 * database. The engine never *infers* — day types and targets are always supplied by the caller.
 * Mirror of iOS `GoalEngine`.
 */
object GoalEngine {

    /**
     * Resolves the goal for a (caller-supplied, never inferred) [dayType]. A day-type override wins;
     * otherwise the default goal (`dayType == null`) applies; otherwise there is no active goal, which
     * callers treat as equal-status no-goal. Tombstoned and inactive goals are ignored.
     */
    fun resolveGoal(dayType: String?, goals: List<HydrationGoal>): HydrationGoal? {
        val active = goals.filter { it.active && it.deletedAt == null }
        if (dayType != null) {
            active.firstOrNull { it.dayType == dayType }?.let { return it }
        }
        return active.firstOrNull { it.dayType == null }
    }

    /** The local calendar day key ("yyyy-MM-dd") an instant falls in, computed in [tzId]. */
    fun dayKey(dateMillis: Long, tzId: String): String {
        val zone = runCatching { ZoneId.of(tzId) }.getOrElse { ZoneId.of("UTC") }
        val d = Instant.ofEpochMilli(dateMillis).atZone(zone).toLocalDate()
        return "%04d-%02d-%02d".format(d.year, d.monthValue, d.dayOfMonth)
    }

    /** Sum of the (already-live) manual entries handed in. */
    fun manualTotalMl(liveEntries: List<HydrationEntry>): Double = liveEntries.sumOf { it.volumeMl }

    /**
     * Builds or refreshes a day's summary. Totals are always recomputed from [liveEntries]; the goal
     * snapshot is **frozen** — if [existing] already carries one it is preserved verbatim, and only a
     * first-ever summary captures [resolvedGoal]. That is what keeps history honest across a later
     * goal change; the caller re-snapshots the current day explicitly (`existing = null`) when the
     * user edits today's goal.
     */
    fun makeSummary(
        dayKey: String, tzId: String, liveEntries: List<HydrationEntry>,
        resolvedGoal: HydrationGoal?, existing: HydrationDailySummary?, now: Long, originDeviceId: String,
    ): HydrationDailySummary {
        val manual = manualTotalMl(liveEntries)
        val kind: HydrationGoalKind
        val target: Double?
        val goalId: String?
        when {
            existing != null -> {
                kind = existing.goalKind; target = existing.goalTargetMl; goalId = existing.goalId
            }
            resolvedGoal != null && resolvedGoal.hasTarget -> {
                kind = resolvedGoal.kind; target = resolvedGoal.targetMl; goalId = resolvedGoal.id
            }
            else -> {
                kind = HydrationGoalKind.NONE; target = null; goalId = resolvedGoal?.id
            }
        }
        return HydrationDailySummary(
            dayKey = dayKey, tzId = tzId, manualMl = manual, importedMl = 0.0, estimatedMl = 0.0,
            entryCount = liveEntries.size, goalKind = kind, goalTargetMl = target, goalId = goalId,
            updatedAt = now, originDeviceId = originDeviceId,
        )
    }
}
