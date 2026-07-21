import Foundation
import Observation

/// The one view model behind both hydration surfaces — LogHub's Today card and the full Hydration
/// screen. Reads and writes go through `env.hydration` (the Stage-1 append-first ledger); this type
/// owns none of that logic, it only orchestrates the UI-facing operations: load today, quick-log a
/// favorite or a custom drink, undo the last log, revise/delete a drink, manage favorites and goals,
/// and record the user's chosen day type.
///
/// Every write follows the same shape the domain layer established: append (never mutate), then
/// recompute the affected day's summary, then bump `dataGeneration` so sibling surfaces reload. A
/// backdated drink recomputes the day it *occurred* on (its frozen goal snapshot is preserved), and
/// a revision that moves a drink across the day boundary recomputes both days.
@Observable
@MainActor
final class HydrationViewModel {
    // Loaded state
    var todayEntries: [HydrationEntry] = []       // live, today only, newest-first
    var todayTotalMl: Double = 0
    var favorites: [HydrationFavorite] = []
    var beverages: [HydrationBeverage] = []
    var customBeverages: [BeverageDefinition] = []
    var containers: [ContainerPreset] = []
    var activeGoals: [HydrationGoal] = []         // default (dayType nil) + any day-type goals
    var resolvedGoal: HydrationGoal?              // the goal applied to today after the day-type pick
    var todayDayType: String?                     // user-selected; nil = default. Never inferred.
    var weekSummaries: [HydrationDailySummary] = []
    var loadFailed = false

    /// A transient "Added 500 mL — Undo" affordance for the most recent quick-log. Cleared on undo,
    /// on the next log, or after a short window.
    struct PendingUndo: Equatable {
        let entryId: String
        let message: String
    }
    var pendingUndo: PendingUndo?
    var saveFailed = false

    private let catalog: HydrationBeverageCatalog
    private var undoToken = UUID()
    private var tz: String { TimeZone.current.identifier }

    init(catalog: HydrationBeverageCatalog = .shared) {
        self.catalog = catalog
    }

    // MARK: - Derived

    var progress: HydrationProgress {
        HydrationProgress(totalMl: todayTotalMl,
                          goalTargetMl: (resolvedGoal?.hasTarget == true) ? resolvedGoal?.targetMl : nil)
    }

    var loggedDayCountThisWeek: Int { HydrationWeek.loggedDayCount(weekSummaries) }

    /// The default goal (the one with no day type), if the user has set one.
    var defaultGoal: HydrationGoal? { activeGoals.first { $0.dayType == nil } }

    /// The user-authored day-type goals, oldest-first for a stable list.
    var dayTypeGoals: [HydrationGoal] {
        activeGoals.filter { $0.dayType != nil }.sorted { $0.createdAt < $1.createdAt }
    }

    func beverage(for entry: HydrationEntry) -> HydrationBeverage {
        catalog.resolve(id: entry.beverageId, custom: customBeverages)
    }

    // MARK: - Load

    func load(_ env: AppEnvironment) {
        let now = env.now()
        let day = GoalEngine.dayKey(for: now, tzId: tz)
        do {
            customBeverages = try env.hydration.beverages()
            beverages = catalog.all(custom: customBeverages)
            containers = try env.hydration.containers()
            favorites = HydrationFavorite.list(containers: containers)
            activeGoals = try env.hydration.activeGoals()
            todayDayType = HydrationDayTypeStore.selected(forDayKey: day)
            resolvedGoal = GoalEngine.resolveGoal(dayType: todayDayType, from: activeGoals)

            let (start, end) = HydrationRepository.dayBounds(dayKey: day, tzId: tz)
            let live = try env.hydration.liveEntries(from: start, to: end)
                .filter { GoalEngine.dayKey(for: $0.occurredAt, tzId: tz) == day }
            todayEntries = live
            todayTotalMl = GoalEngine.manualTotalMl(live)

            let weekStart = GoalEngine.dayKey(for: now.addingTimeInterval(-6 * 86_400), tzId: tz)
            weekSummaries = try env.hydration.summaries(from: weekStart, to: day)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    // MARK: - Logging

    /// Log a favorite (a saved container or a built-in default amount). ≤1 action from the surface;
    /// sets the "Added … — Undo" affordance and names the favorite in its confirmation when it has one.
    @discardableResult
    func log(favorite: HydrationFavorite, env: AppEnvironment) -> Bool {
        let fluidType = fluidType(forBeverageId: favorite.beverageId)
        return log(volumeMl: favorite.volumeMl, fluidType: fluidType, beverageId: favorite.beverageId,
                   containerId: favorite.containerId, occurredAt: env.now(), note: nil,
                   favoriteName: favorite.name.map { env.s($0) }, env: env)
    }

    /// Log an arbitrary drink (the custom sheet). `occurredAt` may be backdated.
    @discardableResult
    func log(volumeMl: Double, fluidType: String, beverageId: String?, containerId: String?,
             occurredAt: Date, note: String?, favoriteName: String?, env: AppEnvironment) -> Bool {
        let now = env.now()
        let provenance = manualProvenance(measuredAt: occurredAt, at: now, env: env)
        let entry = HydrationLedger.makeEntry(
            id: ULID.newID(), volumeMl: volumeMl, fluidType: fluidType, beverageId: beverageId,
            containerId: containerId, occurredAt: occurredAt, tzId: tz, note: note,
            provenance: provenance, updatedAt: now, originDeviceId: env.deviceId)
        do {
            try env.hydration.transaction {
                try env.hydration.insertEntry(entry)
                let dayKey = GoalEngine.dayKey(for: occurredAt, tzId: tz)
                try env.hydration.recomputeSummary(dayKey: dayKey, tzId: tz, dayType: dayTypeApplied(to: dayKey, env: env),
                                                   now: now, originDeviceId: env.deviceId)
            }
        } catch {
            saveFailed = true
            return false
        }
        env.bumpDataGeneration()
        let message = HydrationStrings.confirmation(
            volume: HydrationStrings.volume(volumeMl, formatter: env.format, language: env.language),
            favoriteName: favoriteName, language: env.language)
        setPendingUndo(entryId: entry.id, message: message)
        Announce.status(message)
        load(env)
        return true
    }

    /// Undo the most recent quick-log — tombstone that single row (append-first: nothing is
    /// hard-deleted) and recompute its day.
    func undoLastLog(env: AppEnvironment) {
        guard let pending = pendingUndo else { return }
        let now = env.now()
        do {
            if let entry = try env.hydration.entry(id: pending.entryId) {
                try env.hydration.transaction {
                    try env.hydration.undoEntry(id: pending.entryId, at: now)
                    let dayKey = GoalEngine.dayKey(for: entry.occurredAt, tzId: tz)
                    try env.hydration.recomputeSummary(dayKey: dayKey, tzId: tz, dayType: dayTypeApplied(to: dayKey, env: env),
                                                       now: now, originDeviceId: env.deviceId)
                }
                env.bumpDataGeneration()
            }
        } catch {
            // A failed undo leaves the drink logged (the safe direction) rather than pretending.
        }
        clearPendingUndo()
        load(env)
    }

    // MARK: - Edit / delete

    /// Revise a logged drink — an APPEND that supersedes the live head, never a mutation. Recomputes
    /// the old day, and the new day too when the edit moved the drink across a day boundary.
    @discardableResult
    func revise(originalId: String, volumeMl: Double, fluidType: String, beverageId: String?,
                occurredAt: Date, note: String?, env: AppEnvironment) -> Bool {
        let now = env.now()
        do {
            guard let head = try env.hydration.liveEntry(originalId: originalId) else { return false }
            let oldDay = GoalEngine.dayKey(for: head.occurredAt, tzId: tz)
            let newDay = GoalEngine.dayKey(for: occurredAt, tzId: tz)
            let revision = HydrationLedger.makeRevision(
                of: head, id: ULID.newID(), volumeMl: volumeMl, fluidType: fluidType,
                beverageId: .some(beverageId), occurredAt: occurredAt, note: .some(note),
                provenance: manualProvenance(measuredAt: occurredAt, at: now, env: env),
                updatedAt: now, originDeviceId: env.deviceId)
            try env.hydration.transaction {
                try env.hydration.insertEntry(revision)
                try env.hydration.recomputeSummary(dayKey: oldDay, tzId: tz, dayType: dayTypeApplied(to: oldDay, env: env),
                                                   now: now, originDeviceId: env.deviceId)
                if newDay != oldDay {
                    try env.hydration.recomputeSummary(dayKey: newDay, tzId: tz, dayType: dayTypeApplied(to: newDay, env: env),
                                                       now: now, originDeviceId: env.deviceId)
                }
            }
        } catch {
            return false
        }
        env.bumpDataGeneration()
        load(env)
        return true
    }

    /// Delete a drink — tombstone the whole chain (history stays, I3-flavored) and recompute its day.
    @discardableResult
    func delete(entry: HydrationEntry, env: AppEnvironment) -> Bool {
        let now = env.now()
        do {
            let dayKey = GoalEngine.dayKey(for: entry.occurredAt, tzId: tz)
            try env.hydration.transaction {
                try env.hydration.deleteEntry(originalId: entry.originalId, at: now)
                try env.hydration.recomputeSummary(dayKey: dayKey, tzId: tz, dayType: dayTypeApplied(to: dayKey, env: env),
                                                   now: now, originDeviceId: env.deviceId)
            }
        } catch {
            return false
        }
        env.bumpDataGeneration()
        load(env)
        return true
    }

    // MARK: - Favorites (containers)

    @discardableResult
    func saveFavorite(name: String, volumeMl: Double, beverageId: String?, env: AppEnvironment) -> Bool {
        let now = env.now()
        // A user-named favorite sets both language fields to their own text (same as a custom symptom
        // label) — the name is theirs, not a translatable dictionary term.
        let container = ContainerPreset(
            id: ULID.newID(), nameEn: name, nameAr: name, volumeMl: volumeMl, beverageId: beverageId,
            sortOrder: containers.filter { $0.deletedAt == nil }.count,
            updatedAt: now, originDeviceId: env.deviceId)
        do { try env.hydration.upsertContainer(container) } catch { return false }
        env.bumpDataGeneration()
        load(env)
        return true
    }

    @discardableResult
    func deleteFavorite(_ favorite: HydrationFavorite, env: AppEnvironment) -> Bool {
        guard let containerId = favorite.containerId else { return false }  // built-in defaults aren't deletable
        do { try env.hydration.deleteContainer(id: containerId, at: env.now()) } catch { return false }
        env.bumpDataGeneration()
        load(env)
        return true
    }

    // MARK: - Goals

    /// Set (or replace) the default goal — a manual daily amount, or an explicit no-goal. Both
    /// deactivate the current default first, then upsert; today is re-snapshotted so the change shows
    /// immediately (past days keep the goal they were actually tracked against).
    @discardableResult
    func setDefaultGoal(manualTargetMl: Double?, env: AppEnvironment) -> Bool {
        let now = env.now()
        let id = ULID.newID()
        let goal: HydrationGoal = manualTargetMl.map {
            HydrationGoal(id: id, kind: .manual, targetMl: $0, dayType: nil, active: true,
                          createdAt: now, updatedAt: now, originDeviceId: env.deviceId)
        } ?? HydrationGoal.noGoal(id: id, dayType: nil, createdAt: now, updatedAt: now, originDeviceId: env.deviceId)
        return upsertGoalResnapshotting(goal, dayType: nil, env: env)
    }

    /// Add or replace a user-authored day-type goal (a named daily amount, e.g. "Training" → 3000 mL).
    @discardableResult
    func setDayTypeGoal(name: String, targetMl: Double, env: AppEnvironment) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let now = env.now()
        let goal = HydrationGoal(id: ULID.newID(), kind: .manual, targetMl: targetMl, dayType: trimmed,
                                 active: true, createdAt: now, updatedAt: now, originDeviceId: env.deviceId)
        return upsertGoalResnapshotting(goal, dayType: trimmed, env: env)
    }

    /// Remove a day-type goal (deactivate its rows — the history stays, never hard-deleted). If today
    /// was set to that day type, today falls back to the default goal.
    @discardableResult
    func removeDayTypeGoal(_ goal: HydrationGoal, env: AppEnvironment) -> Bool {
        guard let dayType = goal.dayType else { return false }
        do { try env.hydration.deactivateGoals(dayType: dayType, at: env.now()) } catch { return false }
        if todayDayType == dayType { selectTodayDayType(nil, env: env); return true }
        env.bumpDataGeneration()
        load(env)
        return true
    }

    /// Record which user-authored day type today is (nil = the default goal). Never inferred — the
    /// user picks. Re-snapshots today so the applied goal changes immediately.
    func selectTodayDayType(_ dayType: String?, env: AppEnvironment) {
        let day = GoalEngine.dayKey(for: env.now(), tzId: tz)
        HydrationDayTypeStore.set(dayType, forDayKey: day)
        do {
            try env.hydration.recomputeSummary(dayKey: day, tzId: tz, dayType: dayType,
                                               now: env.now(), originDeviceId: env.deviceId,
                                               forceGoalResnapshot: true)
        } catch {
            // Non-fatal: the selection still applies to the live progress readout below on reload.
        }
        env.bumpDataGeneration()
        load(env)
    }

    // MARK: - Internals

    private func upsertGoalResnapshotting(_ goal: HydrationGoal, dayType: String?, env: AppEnvironment) -> Bool {
        let now = env.now()
        do {
            try env.hydration.transaction {
                try env.hydration.deactivateGoals(dayType: dayType, at: now)
                try env.hydration.upsertGoal(goal)
                // Re-snapshot today only when the changed goal is the one applied to today (the
                // default, or the day type today is set to) — otherwise past/other days keep their
                // frozen snapshot untouched.
                let day = GoalEngine.dayKey(for: now, tzId: tz)
                if dayType == todayDayType {
                    try env.hydration.recomputeSummary(dayKey: day, tzId: tz, dayType: todayDayType,
                                                       now: now, originDeviceId: env.deviceId,
                                                       forceGoalResnapshot: true)
                }
            }
        } catch {
            return false
        }
        env.bumpDataGeneration()
        load(env)
        return true
    }

    /// The day type that applies to `dayKey`: the user's today-selection for the current day, else the
    /// default (nil). A backdated drink or a past day never adopts today's day type — the goal engine
    /// resolves those against the default, never an inferred one.
    private func dayTypeApplied(to dayKey: String, env: AppEnvironment) -> String? {
        let today = GoalEngine.dayKey(for: env.now(), tzId: tz)
        return dayKey == today ? todayDayType : nil
    }

    private func fluidType(forBeverageId beverageId: String?) -> String {
        guard let beverageId,
              let match = beverages.first(where: { $0.id == beverageId }) else {
            return HydrationFluidType.water.rawValue
        }
        return match.fluidType
    }

    private func manualProvenance(measuredAt: Date, at now: Date, env: AppEnvironment) -> Provenance {
        Provenance(sourceId: env.deviceId, deviceId: env.deviceId, ingestionPath: .manual,
                   measuredAt: measuredAt, measuredTimezone: tz, recordedAt: now, ingestedAt: now)
    }

    private func setPendingUndo(entryId: String, message: String) {
        let token = UUID()
        undoToken = token
        pendingUndo = PendingUndo(entryId: entryId, message: message)
        // Auto-dismiss the affordance after a short window unless a newer log replaced it.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.undoToken == token else { return }
            self.pendingUndo = nil
        }
    }

    private func clearPendingUndo() {
        undoToken = UUID()
        pendingUndo = nil
    }
}
