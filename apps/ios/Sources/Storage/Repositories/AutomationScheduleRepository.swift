import Foundation

/// Why an automation-schedule write was refused. A user-facing condition, not a programming error.
enum AutomationScheduleError: Error, Equatable {
    case notFound(id: String)
}

/// `automation_schedules` (migration v4, plan §9.7) — the user's declared automation intent.
///
/// Soft-delete only (`deleted_at`), like every other convention-column table: a deleted schedule's
/// `templateId` may still be referenced by `export_runs` rows the schedule produced, and the run
/// ledger is a record of what happened, not a view over what currently exists.
///
/// The two mutating helpers `recordSuccess`/`recordFailure` are the ONLY writers of the failure
/// budget, called by `AutomationEngine` after a run. They update in place (this is scheduler
/// bookkeeping, not a derived health value — I2 does not apply): the append-only audit of what an
/// automation actually did lives in `export_runs`.
final class AutomationScheduleRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // MARK: - Writes

    /// Insert or replace a schedule. `OR REPLACE` because the id is a caller-held ULID, so a
    /// replace is an update of the same row (matches `ExportTemplateRepository.write`).
    func upsert(_ schedule: AutomationSchedule) throws {
        try write(schedule)
    }

    /// Full update of a configuration row (tier/cadence/quiet-hours/enabled). The UI's editor path
    /// (stage 2). Refuses a row that does not exist rather than silently inserting one.
    func update(_ schedule: AutomationSchedule) throws {
        try db.transaction {
            guard try self.schedule(id: schedule.id) != nil else {
                throw AutomationScheduleError.notFound(id: schedule.id)
            }
            try write(schedule)
        }
    }

    @discardableResult
    private func write(_ s: AutomationSchedule) throws -> Int {
        try db.run("""
            INSERT OR REPLACE INTO automation_schedules
              (id, template_id, tier, desired_cadence, quiet_hours, enabled, consecutive_failures,
               last_success_at, next_expected_window, created_at, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(s.id), .text(s.templateId), .text(s.tier.rawValue),
             .text(s.desiredCadence.rawValue), .string(s.quietHours?.storageString),
             .bool(s.enabled), .int(s.consecutiveFailures), .date(s.lastSuccessAt),
             .date(s.nextExpectedWindow), .date(s.createdAt)]
            + Rows.convParams(updatedAt: s.updatedAt, originDeviceId: s.originDeviceId,
                              deletedAt: s.deletedAt))
    }

    /// Record a clean run (success or `skippedNoData`): reset the strike counter and stamp the
    /// success clock. `nextExpectedWindow` is the DISPLAY-ONLY estimate — persisted so a surface can
    /// show it, never read back by the engine as a fire time.
    func recordSuccess(id: String, at successInstant: Date, nextExpectedWindow: Date?, now: Date) throws {
        let changed = try db.run("""
            UPDATE automation_schedules
               SET consecutive_failures = 0, last_success_at = ?, next_expected_window = ?, updated_at = ?
             WHERE id = ? AND deleted_at IS NULL;
            """,
            [.date(successInstant), .date(nextExpectedWindow), .date(now), .text(id)])
        guard changed > 0 else { throw AutomationScheduleError.notFound(id: id) }
    }

    /// Record a failed run: set the new strike count (computed by `AutomationBudget`, so the pause
    /// threshold lives in one place). At `failureBudget` the derived `isPaused` flips true and the
    /// engine stops considering this schedule until a resume.
    func recordFailure(id: String, consecutiveFailures: Int, now: Date) throws {
        let changed = try db.run("""
            UPDATE automation_schedules SET consecutive_failures = ?, updated_at = ?
             WHERE id = ? AND deleted_at IS NULL;
            """,
            [.int(consecutiveFailures), .date(now), .text(id)])
        guard changed > 0 else { throw AutomationScheduleError.notFound(id: id) }
    }

    /// Un-pause a schedule the user chose to resume: reset the strike counter to 0 (which flips the
    /// derived `isPaused` back to false). The engine will reconsider it on the next wake.
    func resume(id: String, now: Date) throws {
        try recordFailure(id: id, consecutiveFailures: 0, now: now)
    }

    /// Enable/disable without deleting — the module is hideable-without-deletion.
    func setEnabled(id: String, enabled: Bool, now: Date) throws {
        let changed = try db.run("""
            UPDATE automation_schedules SET enabled = ?, updated_at = ?
             WHERE id = ? AND deleted_at IS NULL;
            """,
            [.bool(enabled), .date(now), .text(id)])
        guard changed > 0 else { throw AutomationScheduleError.notFound(id: id) }
    }

    func softDelete(id: String, at date: Date) throws {
        let changed = try db.run(
            "UPDATE automation_schedules SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
            [.date(date), .date(date), .text(id)])
        guard changed > 0 else { throw AutomationScheduleError.notFound(id: id) }
    }

    // MARK: - Reads

    /// Every live schedule (for the UI). Includes paused and disabled ones — the UI must show a
    /// paused schedule so the pause is never invisible.
    func all() throws -> [AutomationSchedule] {
        try db.query("SELECT * FROM automation_schedules WHERE deleted_at IS NULL ORDER BY created_at ASC;")
            .map(Self.read)
    }

    func schedule(id: String) throws -> AutomationSchedule? {
        try db.query("SELECT * FROM automation_schedules WHERE id = ? AND deleted_at IS NULL;", [.text(id)])
            .first.map(Self.read)
    }

    /// The candidates a background wake evaluates: enabled, background-tier, not deleted. Matches
    /// the `(enabled, tier)` index (migration v4). Paused schedules are RETURNED (not filtered in
    /// SQL) so the pause decision stays in the one pure place that owns it
    /// (`AutomationDueEvaluator`, which skips them) — a handful of extra rows read is cheaper than
    /// forking the pause rule across SQL and Swift.
    func dueCandidates() throws -> [AutomationSchedule] {
        try db.query("""
            SELECT * FROM automation_schedules
             WHERE enabled = 1 AND tier = ? AND deleted_at IS NULL
             ORDER BY created_at ASC;
            """, [.text(AutomationTier.opportunisticBackground.rawValue)])
            .map(Self.read)
    }

    static func read(_ r: SQLiteRow) -> AutomationSchedule {
        AutomationSchedule(
            id: r.requireString("id"),
            templateId: r.requireString("template_id"),
            // An unparseable tier falls back to `manualOnly` — the tier that makes NO promise and is
            // never auto-run, so a corrupt row can only ever become MORE conservative, never
            // silently start firing in the background.
            tier: AutomationTier(rawValue: r.requireString("tier")) ?? .manualOnly,
            desiredCadence: AutomationCadence(rawValue: r.requireString("desired_cadence")) ?? .onNewData,
            quietHours: r.string("quiet_hours").flatMap { QuietHours(storageString: $0) },
            enabled: r.bool("enabled"),
            consecutiveFailures: r.intValue("consecutive_failures") ?? 0,
            lastSuccessAt: r.date("last_success_at"),
            nextExpectedWindow: r.date("next_expected_window"),
            createdAt: r.requireDate("created_at"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}

// MARK: - Data-freshness probe

/// The real `AutomationDataFreshnessProbing`, over the main DB. Asks the one question the
/// `onNewData` cadence needs: has anything been ingested since a watermark? Scans the three
/// measurement tables on the `ingested_at` axis — the SAME axis the export cursor advances on — so
/// the engine's "there is new data" agrees with `runTemplate`'s "the cursor moved".
///
/// Lives in the storage layer (not the engine) because it is a raw query; the engine sees only the
/// `AutomationDataFreshnessProbing` seam.
struct AutomationDataFreshnessProbe: AutomationDataFreshnessProbing {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    func hasDataIngested(after watermark: Date?) -> Bool {
        // nil watermark (never-run schedule) ⇒ "any row at all": epoch 0 makes `ingested_at > 0`
        // true for every real row without a separate query path.
        let ref = (watermark ?? Date(timeIntervalSince1970: 0)).epochMillis
        // One `EXISTS` per table, `LIMIT 1` overall — index-free but bounded: it stops at the first
        // qualifying row rather than counting. `ingested_at` is an INTEGER epoch-millis column on
        // all three (embedded provenance, D-3).
        let sql = """
            SELECT 1 AS present FROM raw_samples WHERE ingested_at > ? \
            UNION ALL SELECT 1 FROM interval_records WHERE ingested_at > ? \
            UNION ALL SELECT 1 FROM sessions WHERE ingested_at > ? \
            LIMIT 1;
            """
        let rows = (try? db.query(sql, [.integer(ref), .integer(ref), .integer(ref)])) ?? []
        return !rows.isEmpty
    }
}
