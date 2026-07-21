import Foundation

/// Storage for the hydration module (EPIC-38): the append-first drink ledger, its beverage/container
/// catalogs, goals, and per-day summaries. All in the **main** DB — a logged drink is normal-class,
/// not sensitive-plus (§9.14). Notes ride along on the row but are the writer's to redact, not this
/// repo's to withhold.
///
/// The ledger is append-first: `insertEntry` only ever adds a row. An edit is a *new* row built by
/// `HydrationLedger.makeRevision` (a fresh id that supersedes the prior), so nothing is overwritten.
/// The two tombstone operations differ only in scope — `undoEntry` tombstones one row (revert / quick-
/// log undo), `deleteEntry` tombstones a whole chain (remove the drink) — and `liveEntries` derives
/// the visible set from those tombstones and the supersedes links, never from a mutated flag.
final class HydrationRepository {
    private let main: SQLiteConnection

    init(main: SQLiteConnection) {
        self.main = main
    }

    /// Batch several hydration writes (append + summary recompute) into one transaction. Same
    /// rationale as `LoggingRepository.transactionMain` (one commit/fsync, not one per row).
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try main.transaction(body) }

    // MARK: - Ledger (hydration_entries)

    private static let entryColumns =
        "id, volume_ml, fluid_type, beverage_id, container_id, occurred_at, tz_id, note, original_id, supersedes, revision"
    private static let entryPlaceholders = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"

    /// Appends one row (an original or a revision — both are inserts; a revision simply carries a
    /// `supersedes` link and a bumped `revision`). `INSERT OR REPLACE` is idempotent on the ULID PK,
    /// so re-inserting the identical row is a no-op; it never overwrites a *different* logical version
    /// because a revision always gets a new id.
    func insertEntry(_ e: HydrationEntry) throws {
        try main.run("""
            INSERT OR REPLACE INTO hydration_entries
              (\(Self.entryColumns), \(Rows.provColumns), \(Rows.convColumns))
            VALUES (\(Self.entryPlaceholders), \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(e.id), .double(e.volumeMl), .text(e.fluidType), .string(e.beverageId), .string(e.containerId),
             .date(e.occurredAt), .text(e.tzId), .string(e.note), .text(e.originalId), .string(e.supersedes), .int(e.revision)]
            + Rows.provParams(e.provenance)
            + Rows.convParams(updatedAt: e.updatedAt, originDeviceId: e.originDeviceId, deletedAt: e.deletedAt))
    }

    /// The LIVE entries in a time window: not tombstoned, and not superseded by a non-deleted
    /// revision. The subquery is global (not range-bounded) on purpose — a revision that moved its
    /// `occurred_at` must still suppress the row it replaced. Mirrors `HydrationLedger.liveEntries`.
    func liveEntries(from: Date, to: Date) throws -> [HydrationEntry] {
        try main.query("""
            SELECT * FROM hydration_entries
            WHERE deleted_at IS NULL AND occurred_at >= ? AND occurred_at <= ?
              AND id NOT IN (SELECT supersedes FROM hydration_entries WHERE supersedes IS NOT NULL AND deleted_at IS NULL)
            ORDER BY occurred_at DESC;
            """, [.date(from), .date(to)]).map(Self.readEntry)
    }

    /// The full audit chain of one logical drink — every revision, tombstoned or superseded rows
    /// included — ordered oldest-first. This is the "auditable revisions" read (I2-flavored history).
    func history(originalId: String) throws -> [HydrationEntry] {
        try main.query("SELECT * FROM hydration_entries WHERE original_id = ? ORDER BY revision ASC, updated_at ASC;",
                       [.text(originalId)]).map(Self.readEntry)
    }

    /// The current live head of a chain (what a revise edits), or nil if the chain is fully deleted.
    /// Reuses the pure live-set logic so the SQL and the in-memory rule cannot drift.
    func liveEntry(originalId: String) throws -> HydrationEntry? {
        HydrationLedger.liveEntries(try history(originalId: originalId)).first
    }

    /// Any single row by id, tombstone or not — for building a revision or inspecting one version.
    func entry(id: String) throws -> HydrationEntry? {
        try main.query("SELECT * FROM hydration_entries WHERE id = ?;", [.text(id)]).first.map(Self.readEntry)
    }

    /// Tombstones ONE row — the quick-log "Undo", and the way to revert a revision (tombstone the
    /// revision → its prior version becomes live again, because it is no longer superseded by a
    /// non-deleted row). Not a hard delete: the row stays for the audit chain (I3-flavored).
    func undoEntry(id: String, at date: Date) throws {
        try main.run("UPDATE hydration_entries SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                     [.date(date), .date(date), .text(id)])
    }

    /// Tombstones a WHOLE chain — "delete this drink" — so no revision of it stays live. Every row
    /// with this `original_id` is marked deleted; the history read still returns them.
    func deleteEntry(originalId: String, at date: Date) throws {
        try main.run("UPDATE hydration_entries SET deleted_at = ?, updated_at = ? WHERE original_id = ? AND deleted_at IS NULL;",
                     [.date(date), .date(date), .text(originalId)])
    }

    // MARK: - Beverage definitions

    func upsertBeverage(_ b: BeverageDefinition) throws {
        try main.run("""
            INSERT OR REPLACE INTO beverage_definitions
              (id, name_en, name_ar, fluid_type, default_volume_ml, caffeine_mg_per_100ml, alcohol_pct, electrolyte_note, is_builtin, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(b.id), .text(b.nameEn), .text(b.nameAr), .text(b.fluidType), .double(b.defaultVolumeMl),
             .double(b.caffeineMgPer100ml), .double(b.alcoholPct), .string(b.electrolyteNote), .bool(b.isBuiltin)]
            + Rows.convParams(updatedAt: b.updatedAt, originDeviceId: b.originDeviceId, deletedAt: b.deletedAt))
    }

    func beverages() throws -> [BeverageDefinition] {
        try main.query("SELECT * FROM beverage_definitions WHERE deleted_at IS NULL ORDER BY name_en ASC;").map(Self.readBeverage)
    }

    func beverage(id: String) throws -> BeverageDefinition? {
        try main.query("SELECT * FROM beverage_definitions WHERE id = ? AND deleted_at IS NULL;", [.text(id)]).first.map(Self.readBeverage)
    }

    func deleteBeverage(id: String, at date: Date) throws {
        try main.run("UPDATE beverage_definitions SET deleted_at = ?, updated_at = ? WHERE id = ?;", [.date(date), .date(date), .text(id)])
    }

    // MARK: - Container presets

    func upsertContainer(_ c: ContainerPreset) throws {
        try main.run("""
            INSERT OR REPLACE INTO container_presets
              (id, name_en, name_ar, volume_ml, beverage_id, sort_order, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(c.id), .text(c.nameEn), .text(c.nameAr), .double(c.volumeMl), .string(c.beverageId), .int(c.sortOrder)]
            + Rows.convParams(updatedAt: c.updatedAt, originDeviceId: c.originDeviceId, deletedAt: c.deletedAt))
    }

    func containers() throws -> [ContainerPreset] {
        try main.query("SELECT * FROM container_presets WHERE deleted_at IS NULL ORDER BY sort_order ASC, name_en ASC;").map(Self.readContainer)
    }

    func deleteContainer(id: String, at date: Date) throws {
        try main.run("UPDATE container_presets SET deleted_at = ?, updated_at = ? WHERE id = ?;", [.date(date), .date(date), .text(id)])
    }

    // MARK: - Goals

    func upsertGoal(_ g: HydrationGoal) throws {
        try main.run("""
            INSERT OR REPLACE INTO hydration_goals
              (id, kind, target_ml, day_type, active, created_at, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(g.id), .text(g.kind.rawValue), .double(g.targetMl), .string(g.dayType), .bool(g.active), .date(g.createdAt)]
            + Rows.convParams(updatedAt: g.updatedAt, originDeviceId: g.originDeviceId, deletedAt: g.deletedAt))
    }

    /// All active, non-tombstoned goals (default + any day-type overrides). No-goal is represented by
    /// an active `kind = none` row *or* by the absence of any active goal — `GoalEngine.resolveGoal`
    /// treats both as equal-status no-goal.
    func activeGoals() throws -> [HydrationGoal] {
        try main.query("SELECT * FROM hydration_goals WHERE active = 1 AND deleted_at IS NULL ORDER BY created_at DESC;").map(Self.readGoal)
    }

    func allGoals() throws -> [HydrationGoal] {
        try main.query("SELECT * FROM hydration_goals WHERE deleted_at IS NULL ORDER BY created_at DESC;").map(Self.readGoal)
    }

    /// Deactivates the currently-active goal(s) for a day type (nil = the default goal) so a newly
    /// set goal replaces the old one without deleting its history. Called before `upsertGoal` when the
    /// user changes their goal.
    func deactivateGoals(dayType: String?, at date: Date) throws {
        if let dayType {
            try main.run("UPDATE hydration_goals SET active = 0, updated_at = ? WHERE active = 1 AND day_type = ?;",
                         [.date(date), .text(dayType)])
        } else {
            try main.run("UPDATE hydration_goals SET active = 0, updated_at = ? WHERE active = 1 AND day_type IS NULL;",
                         [.date(date)])
        }
    }

    // MARK: - Daily summaries

    func upsertSummary(_ s: HydrationDailySummary) throws {
        try main.run("""
            INSERT OR REPLACE INTO hydration_daily_summaries
              (day_key, tz_id, manual_ml, imported_ml, estimated_ml, entry_count, goal_kind, goal_target_ml, goal_id, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(s.dayKey), .text(s.tzId), .double(s.manualMl), .double(s.importedMl), .double(s.estimatedMl),
             .int(s.entryCount), .text(s.goalKind.rawValue), .double(s.goalTargetMl), .string(s.goalId)]
            + Rows.convParams(updatedAt: s.updatedAt, originDeviceId: s.originDeviceId, deletedAt: s.deletedAt))
    }

    func summary(dayKey: String) throws -> HydrationDailySummary? {
        try main.query("SELECT * FROM hydration_daily_summaries WHERE day_key = ? AND deleted_at IS NULL;", [.text(dayKey)]).first.map(Self.readSummary)
    }

    func summaries(from dayKey: String, to: String) throws -> [HydrationDailySummary] {
        try main.query("SELECT * FROM hydration_daily_summaries WHERE day_key >= ? AND day_key <= ? AND deleted_at IS NULL ORDER BY day_key ASC;",
                       [.text(dayKey), .text(to)]).map(Self.readSummary)
    }

    /// Recomputes one local day's summary from its live entries and persists it. Totals are always
    /// refreshed (a backdated drink can change a past day); the goal snapshot is frozen unless
    /// `forceGoalResnapshot` is set — which the caller does only for the current day when the user
    /// edits their goal, so past days keep the goal they were actually tracked against (§9.14).
    ///
    /// `dayType` is caller-supplied (never inferred). `originDeviceId`/`now` are passed in rather than
    /// stored so this repo stays storage-focused like its siblings.
    @discardableResult
    func recomputeSummary(dayKey: String, tzId: String, dayType: String? = nil, now: Date,
                          originDeviceId: String, forceGoalResnapshot: Bool = false) throws -> HydrationDailySummary {
        let (start, end) = Self.dayBounds(dayKey: dayKey, tzId: tzId)
        let live = try liveEntries(from: start, to: end)
            .filter { GoalEngine.dayKey(for: $0.occurredAt, tzId: tzId) == dayKey }
        let resolved = GoalEngine.resolveGoal(dayType: dayType, from: try activeGoals())
        let existing = forceGoalResnapshot ? nil : try summary(dayKey: dayKey)
        let summary = GoalEngine.makeSummary(dayKey: dayKey, tzId: tzId, liveEntries: live,
                                             resolvedGoal: resolved, existing: existing, at: now,
                                             originDeviceId: originDeviceId)
        try upsertSummary(summary)
        return summary
    }

    /// The [start, next-day-start) instants of a local day key, for scoping the entry query. The
    /// caller further filters by `GoalEngine.dayKey` so a boundary row lands on exactly one day.
    static func dayBounds(dayKey: String, tzId: String) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tzId) ?? TimeZone(identifier: "UTC")!
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = parts.count > 0 ? parts[0] : 1970
        comps.month = parts.count > 1 ? parts[1] : 1
        comps.day = parts.count > 2 ? parts[2] : 1
        let start = calendar.date(from: comps) ?? Date(timeIntervalSince1970: 0)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    // MARK: - Readers

    static func readEntry(_ r: SQLiteRow) -> HydrationEntry {
        HydrationEntry(
            id: r.requireString("id"), volumeMl: r.requireDouble("volume_ml"),
            fluidType: r.requireString("fluid_type"), beverageId: r.string("beverage_id"),
            containerId: r.string("container_id"), occurredAt: r.requireDate("occurred_at"),
            tzId: r.requireString("tz_id"), note: r.string("note"),
            originalId: r.requireString("original_id"), supersedes: r.string("supersedes"),
            revision: r.intValue("revision") ?? 1, provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }

    static func readBeverage(_ r: SQLiteRow) -> BeverageDefinition {
        BeverageDefinition(
            id: r.requireString("id"), nameEn: r.requireString("name_en"), nameAr: r.requireString("name_ar"),
            fluidType: r.requireString("fluid_type"), defaultVolumeMl: r.double("default_volume_ml"),
            caffeineMgPer100ml: r.double("caffeine_mg_per_100ml"), alcoholPct: r.double("alcohol_pct"),
            electrolyteNote: r.string("electrolyte_note"), isBuiltin: r.bool("is_builtin"),
            updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }

    static func readContainer(_ r: SQLiteRow) -> ContainerPreset {
        ContainerPreset(
            id: r.requireString("id"), nameEn: r.requireString("name_en"), nameAr: r.requireString("name_ar"),
            volumeMl: r.requireDouble("volume_ml"), beverageId: r.string("beverage_id"),
            sortOrder: r.intValue("sort_order") ?? 0, updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }

    static func readGoal(_ r: SQLiteRow) -> HydrationGoal {
        HydrationGoal(
            id: r.requireString("id"), kind: HydrationGoalKind(rawValue: r.requireString("kind")) ?? .none,
            targetMl: r.double("target_ml"), dayType: r.string("day_type"), active: r.bool("active"),
            createdAt: r.requireDate("created_at"), updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }

    static func readSummary(_ r: SQLiteRow) -> HydrationDailySummary {
        HydrationDailySummary(
            dayKey: r.requireString("day_key"), tzId: r.requireString("tz_id"),
            manualMl: r.requireDouble("manual_ml"), importedMl: r.requireDouble("imported_ml"),
            estimatedMl: r.requireDouble("estimated_ml"), entryCount: r.intValue("entry_count") ?? 0,
            goalKind: HydrationGoalKind(rawValue: r.requireString("goal_kind")) ?? .none,
            goalTargetMl: r.double("goal_target_ml"), goalId: r.string("goal_id"),
            updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
