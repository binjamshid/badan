import Foundation

// MARK: - Favorites

/// A one-tap quick-log target on the hydration surfaces. Either a saved `ContainerPreset` (carries a
/// `containerId` and a user-visible name, so its confirmation reads "Added 500 mL from My Bottle") or
/// a built-in default amount (no container id, no name — its confirmation is just "Added 500 mL").
/// Defaults exist so logging is ≤2 actions from the very first launch, before the user has saved any
/// bottle of their own.
struct HydrationFavorite: Identifiable, Hashable {
    let id: String
    /// The favorite's own name, or nil for an anonymous built-in amount.
    let name: LocalizedString?
    let volumeMl: Double
    let beverageId: String?
    let containerId: String?

    var isDefault: Bool { containerId == nil }

    /// The two built-in amounts shown when the user has saved no containers of their own. Plain water,
    /// no name — a fast start that never pretends to be a goal.
    static let builtinDefaults: [HydrationFavorite] = [
        HydrationFavorite(id: "default-250", name: nil, volumeMl: 250, beverageId: nil, containerId: nil),
        HydrationFavorite(id: "default-500", name: nil, volumeMl: 500, beverageId: nil, containerId: nil),
    ]

    /// The favorites row for a set of saved containers: the user's own containers if any, otherwise
    /// the built-in defaults. Never blends the two — once you save a favorite, the row is yours.
    static func list(containers: [ContainerPreset]) -> [HydrationFavorite] {
        let live = containers.filter { $0.deletedAt == nil }
            .sorted { ($0.sortOrder, $0.nameEn) < ($1.sortOrder, $1.nameEn) }
        guard !live.isEmpty else { return builtinDefaults }
        return live.map {
            HydrationFavorite(id: $0.id, name: $0.displayName, volumeMl: $0.volumeMl,
                              beverageId: $0.beverageId, containerId: $0.id)
        }
    }
}

// MARK: - Progress

/// The calm today-progress model. A no-goal day exposes a total and **no** fraction — never a
/// percentage of nothing, never an ahead/behind framing (§7A.1). A goal day exposes a fraction for
/// the ring, capped at 1.0 for display so "over your amount" never renders as an alarming overflow.
struct HydrationProgress: Equatable {
    let totalMl: Double
    /// nil for a no-goal day, or a positive daily amount.
    let goalTargetMl: Double?

    var hasGoal: Bool {
        guard let goalTargetMl else { return false }
        return goalTargetMl > 0
    }

    /// 0...1 for the ring fill, only when a goal exists. nil on a no-goal day (the ring shows a
    /// neutral, un-filled track and the total speaks for itself).
    var fraction: Double? {
        guard let goalTargetMl, goalTargetMl > 0 else { return nil }
        return min(max(totalMl / goalTargetMl, 0), 1)
    }
}

// MARK: - Weekly (observational)

/// Pure weekly rollup for the observational card. Counts the days in the window on which anything was
/// logged — a plain count, never a streak, never "you missed N days". Days with no summary row (never
/// logged) simply don't count, matching "missing logs do not mean the user did not drink".
enum HydrationWeek {
    static func loggedDayCount(_ summaries: [HydrationDailySummary]) -> Int {
        summaries.filter { $0.deletedAt == nil && ($0.entryCount > 0 || $0.totalMl > 0) }.count
    }
}

// MARK: - Today's day type (user-selected, never inferred)

/// Remembers which user-authored day type the user said *today* is, so today's progress tracks the
/// right goal. Persisted in `UserDefaults` keyed by the day it applies to — a stored selection for a
/// past day is ignored (each new day starts back at the default until the user picks again). This is
/// the whole "user-authored only, never inferred" rule made concrete: nothing here guesses a day
/// type, it only records the one the user chose.
enum HydrationDayTypeStore {
    static let defaultsKey = "badan.hydration.todayDayType"

    /// The day type the user selected for `dayKey`, or nil (the default goal) if none was set for
    /// this specific day.
    static func selected(forDayKey dayKey: String, defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: defaultsKey) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == dayKey else { return nil }
        let dayType = String(parts[1])
        return dayType.isEmpty ? nil : dayType
    }

    /// Records `dayType` (nil = back to the default goal) as the choice for `dayKey`.
    static func set(_ dayType: String?, forDayKey dayKey: String, defaults: UserDefaults = .standard) {
        defaults.set("\(dayKey)|\(dayType ?? "")", forKey: defaultsKey)
    }
}

// MARK: - Plausibility

enum HydrationPlausibility {
    /// A single-entry soft ceiling, mirroring `WaterQuickSheet`/`IntentWaterService` (5 L). Only a
    /// non-blocking notice — a >0 volume always saves (§EDGE-15). Never a hard reject beyond ">0".
    static let singleEntryCeilingMl: Double = 5000

    static func isImplausible(_ ml: Double) -> Bool { ml > singleEntryCeilingMl }
}
