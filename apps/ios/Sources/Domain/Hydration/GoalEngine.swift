import Foundation

// MARK: - Goal

/// Which kind of hydration goal is in effect. `none` is a **first-class, equal-status value**, not
/// the absence of a goal: §7A.1 is explicit that no-goal must never be nagged and never treated as
/// "unset". A summary snapshotted under `none` records that the user was tracking *without* a target
/// — a legitimate, complete state, distinct from "we don't know".
public enum HydrationGoalKind: String, Codable, Hashable, Sendable {
    case none      // tracking without a target — never nagged, never "0% of nothing"
    case manual    // a user-entered daily target
    // `estimated` (body-weight/activity/climate models) is Phase 3, opt-in, off by default (§7A.1).
}

/// A hydration goal. `targetMl` is nil exactly when `kind == .none`. `dayType` is a **user-authored**
/// label (e.g. "training", "rest") for day-type goal schedules (§7A.1, Phase 2); a nil `dayType` is
/// the default goal that applies when no day-type override matches. Nothing here infers a day type or
/// a target — that is the whole point of "user-authored only".
public struct HydrationGoal: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: HydrationGoalKind
    public var targetMl: Double?
    public var dayType: String?
    public var active: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    /// True only when a real, positive target exists — the guard every progress computation uses so
    /// a no-goal day can never render a percentage.
    public var hasTarget: Bool {
        guard kind != .none, let targetMl, targetMl > 0 else { return false }
        return true
    }

    public init(id: String, kind: HydrationGoalKind, targetMl: Double? = nil, dayType: String? = nil,
                active: Bool = true, createdAt: Date, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.targetMl = targetMl; self.dayType = dayType
        self.active = active; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }

    /// The canonical no-goal value. Exposed as a constructor so callers say what they mean ("set no
    /// goal") rather than passing a nil target and hoping the reader infers equal status.
    public static func noGoal(id: String, dayType: String? = nil, createdAt: Date, updatedAt: Date,
                              originDeviceId: String) -> HydrationGoal {
        HydrationGoal(id: id, kind: .none, targetMl: nil, dayType: dayType, active: true,
                      createdAt: createdAt, updatedAt: updatedAt, originDeviceId: originDeviceId)
    }
}

// MARK: - Daily summary

/// A day's hydration rollup with a **frozen goal snapshot**. Manual / imported / estimated totals are
/// kept separate (I5) — only `manualMl` is populated this phase, but the other two exist so an
/// imported or estimated volume can never be silently blended into the number the user actually
/// logged. The `goal*` fields record the goal that was in effect when this day was first summarized,
/// so raising a goal next month does not retroactively mark last month's met days as missed (§9.14).
public struct HydrationDailySummary: Codable, Hashable, Sendable, Identifiable {
    public var dayKey: String        // local calendar day, "yyyy-MM-dd"
    public var tzId: String          // the tz the day boundary was computed in
    public var manualMl: Double
    public var importedMl: Double
    public var estimatedMl: Double
    public var entryCount: Int
    public var goalKind: HydrationGoalKind   // snapshot
    public var goalTargetMl: Double?         // snapshot; nil for a no-goal day
    public var goalId: String?               // snapshot; which goal produced it
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var id: String { dayKey }
    public var totalMl: Double { manualMl + importedMl + estimatedMl }

    /// Progress against the snapshotted target — **only** when a real target was in effect. A no-goal
    /// day returns nil, never 0%: a percentage-of-nothing is exactly the streak-guilt framing §7A.1
    /// rejects ("Missing logs do not mean the user did not drink").
    public var goalProgressPct: Double? {
        guard goalKind != .none, let target = goalTargetMl, target > 0 else { return nil }
        return totalMl / target * 100.0
    }

    public init(dayKey: String, tzId: String, manualMl: Double, importedMl: Double = 0,
                estimatedMl: Double = 0, entryCount: Int, goalKind: HydrationGoalKind,
                goalTargetMl: Double? = nil, goalId: String? = nil, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.dayKey = dayKey; self.tzId = tzId; self.manualMl = manualMl; self.importedMl = importedMl
        self.estimatedMl = estimatedMl; self.entryCount = entryCount; self.goalKind = goalKind
        self.goalTargetMl = goalTargetMl; self.goalId = goalId; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - Goal engine

/// Pure logic for resolving goals and rolling up daily summaries. Storage-free and total, so the
/// no-goal-is-equal-status rule and the snapshot-survives-a-goal-change rule are testable without a
/// database. The engine never *infers* — day types and targets are always supplied by the caller.
public enum GoalEngine {

    /// Resolves the goal for a (caller-supplied, never inferred) `dayType`. A day-type override wins;
    /// otherwise the default goal (`dayType == nil`) applies; otherwise there is no active goal, which
    /// callers treat as equal-status no-goal. Tombstoned and inactive goals are ignored.
    public static func resolveGoal(dayType: String?, from goals: [HydrationGoal]) -> HydrationGoal? {
        let active = goals.filter { $0.active && $0.deletedAt == nil }
        if let dayType, let override = active.first(where: { $0.dayType == dayType }) { return override }
        return active.first(where: { $0.dayType == nil })
    }

    /// The local calendar day key ("yyyy-MM-dd") an instant falls in, computed in `tzId`. Unknown tz
    /// ids fall back to UTC — the same posture the export timestamp formatter takes.
    public static func dayKey(for date: Date, tzId: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tzId) ?? TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    /// Sum of the (already-live) manual entries handed in. Callers pass `HydrationLedger.liveEntries`
    /// for one day; this never re-derives the live set, so the two rules stay in one place.
    public static func manualTotalMl(_ liveEntries: [HydrationEntry]) -> Double {
        liveEntries.reduce(0) { $0 + $1.volumeMl }
    }

    /// Builds or refreshes a day's summary.
    ///
    /// Totals are always recomputed from `liveEntries` (a backdated drink can legitimately change a
    /// past day's total). The **goal snapshot is frozen**: if `existing` already carries one, it is
    /// preserved verbatim; only a first-ever summary for the day captures `resolvedGoal`. That is what
    /// keeps history honest across a later goal change — and it means the caller re-snapshots the
    /// *current* day explicitly (via `existing: nil`) when the user edits their goal today, rather than
    /// every recompute silently adopting the newest target.
    public static func makeSummary(dayKey: String, tzId: String, liveEntries: [HydrationEntry],
                                   resolvedGoal: HydrationGoal?, existing: HydrationDailySummary?,
                                   at now: Date, originDeviceId: String) -> HydrationDailySummary {
        let manual = manualTotalMl(liveEntries)
        let kind: HydrationGoalKind
        let target: Double?
        let goalId: String?
        if let existing {
            // Frozen: the goal that was in effect when this day was first summarized stays put.
            kind = existing.goalKind; target = existing.goalTargetMl; goalId = existing.goalId
        } else if let goal = resolvedGoal, goal.hasTarget {
            kind = goal.kind; target = goal.targetMl; goalId = goal.id
        } else {
            // No active target → an equal-status no-goal snapshot, never a missing/0% one.
            kind = .none; target = nil; goalId = resolvedGoal?.id
        }
        return HydrationDailySummary(
            dayKey: dayKey, tzId: tzId, manualMl: manual, importedMl: 0, estimatedMl: 0,
            entryCount: liveEntries.count, goalKind: kind, goalTargetMl: target, goalId: goalId,
            updatedAt: now, originDeviceId: originDeviceId
        )
    }
}
