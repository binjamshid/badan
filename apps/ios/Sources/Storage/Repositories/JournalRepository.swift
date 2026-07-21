import Foundation

/// Storage for the behavior journal and the context statuses (EPIC-29, plan §9.9/§9.10), over the
/// `journal_entries` and `context_statuses` tables created by sensitive migration v3.
///
/// **This repository holds the sensitive connection and nothing else.** That is the I7 enforcement,
/// and it is structural rather than a rule someone has to remember: there is no `main` connection
/// in scope here, so no statement in this file can address `badan.db` even by accident. A journal
/// row landing in the main database would silently downgrade `Database.purgeSensitiveNamespace()`
/// — a literal file deletion — to a best-effort row sweep for the two most lifestyle-revealing
/// tables BADAN has. `JournalTests.testJournalTablesExistOnlyInTheSensitiveDatabase` asserts the
/// tables are absent from the main schema, and `testSensitivePurgeRemovesJournalAndContextRows`
/// asserts the purge actually clears them.
///
/// The purge itself needs no extension for these families: it deletes and recreates
/// `badan_sensitive.db` wholesale, so every table in `Schema.sensitiveMigrations` — v1's
/// meds/symptoms/conditions and v3's journal/context/cycle alike — is covered by construction.
/// That is the property the tests here pin, so a future "purge only these tables" optimization
/// cannot quietly leave the journal behind.
///
/// Deletes are tombstones (`deleted_at`), matching `LoggingRepository`: the ADR-0003 sync columns
/// only mean something if a removal is a recorded event, and a correction to yesterday's journal
/// should not erase what the user first said.
final class JournalRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    /// Batch several journal writes (a day's worth of chips tapped at once) into one transaction
    /// instead of one implicit commit+fsync per row. Same rationale as
    /// `LoggingRepository.transactionSensitive`; named without a suffix because this repository
    /// has only one connection to begin with.
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    // MARK: - Journal entries

    private static let entryColumns =
        "id, behavior_id, custom_label, value_kind, value, unit, occurred_at, tz_id, note"
    private static let entryPlaceholders = "?, ?, ?, ?, ?, ?, ?, ?, ?"

    /// Inserts one behavior tag. `INSERT OR REPLACE` is idempotent on the ULID primary key, so a
    /// retried write is a no-op rather than a duplicate — and since a correction is a NEW row plus
    /// a tombstone on the old one (never an in-place edit), it can never overwrite a different
    /// logical entry.
    func insertEntry(_ e: JournalEntry) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO journal_entries
              (\(Self.entryColumns), \(Rows.provColumns), \(Rows.convColumns))
            VALUES (\(Self.entryPlaceholders), \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(e.id), .string(e.behaviorId), .string(e.customLabel), .text(e.valueKind.rawValue),
             .double(e.value), .string(e.unit), .date(e.occurredAt), .text(e.tzId), .string(e.note)]
            + Rows.provParams(e.provenance)
            + Rows.convParams(updatedAt: e.updatedAt, originDeviceId: e.originDeviceId, deletedAt: e.deletedAt))
    }

    /// Live entries whose `occurred_at` falls in the window, newest first.
    ///
    /// The window is on `occurred_at`, never on `recorded_at`: an entry the user backdated to
    /// yesterday belongs to yesterday, which is the whole point of yesterday-recall. Filtering on
    /// when it was typed would file it under today and quietly poison the day arms every
    /// correlation is built from.
    func entries(from: Date, to: Date) throws -> [JournalEntry] {
        try sensitive.query("""
            SELECT * FROM journal_entries
            WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL
            ORDER BY occurred_at DESC;
            """, [.date(from), .date(to)]).map(Self.readEntry)
    }

    /// Live entries for one behavior across a window — the read the correlation engine's per-
    /// behavior arms are built from. Backed by `idx_journal_behavior_occurred`.
    func entries(behaviorId: String, from: Date, to: Date) throws -> [JournalEntry] {
        try sensitive.query("""
            SELECT * FROM journal_entries
            WHERE behavior_id = ? AND occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL
            ORDER BY occurred_at DESC;
            """, [.text(behaviorId), .date(from), .date(to)]).map(Self.readEntry)
    }

    /// Every live entry, newest first. Unbounded on purpose, matching
    /// `LoggingRepository.allSymptoms()`: a hand-tapped journal is tens of rows per week, and both
    /// the export and the correlation engine need the whole history rather than a page of it.
    func allEntries() throws -> [JournalEntry] {
        try sensitive.query("SELECT * FROM journal_entries WHERE deleted_at IS NULL ORDER BY occurred_at DESC;")
            .map(Self.readEntry)
    }

    /// One row by id, tombstone or not — for inspecting what was superseded by a correction.
    func entry(id: String) throws -> JournalEntry? {
        try sensitive.query("SELECT * FROM journal_entries WHERE id = ?;", [.text(id)]).first.map(Self.readEntry)
    }

    /// Tombstones one entry. Not a hard delete: the row stays so "the user logged this, then took
    /// it back" is recoverable and so a synced peer learns the entry went away rather than
    /// inferring it from absence.
    func deleteEntry(id: String, at date: Date) throws {
        try sensitive.run("UPDATE journal_entries SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                          [.date(date), .date(date), .text(id)])
    }

    // MARK: - Context statuses

    private static let statusColumns = "id, status_id, custom_label, start_at, end_at, tz_id, note"
    private static let statusPlaceholders = "?, ?, ?, ?, ?, ?, ?"

    /// Inserts or updates one declared interval.
    ///
    /// Unlike journal entries, a status legitimately CHANGES in place — closing an open-ended
    /// status ("I'm back") sets `end_at` on the same row rather than appending a second one,
    /// because the interval is one fact whose end was simply not known yet. That is not an I2
    /// concern: I2 governs derived values, and a status is a raw user assertion, not a computation.
    func upsertStatus(_ s: ContextStatus) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO context_statuses
              (\(Self.statusColumns), \(Rows.provColumns), \(Rows.convColumns))
            VALUES (\(Self.statusPlaceholders), \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(s.id), .string(s.statusId), .string(s.customLabel), .date(s.startAt), .date(s.endAt),
             .text(s.tzId), .string(s.note)]
            + Rows.provParams(s.provenance)
            + Rows.convParams(updatedAt: s.updatedAt, originDeviceId: s.originDeviceId, deletedAt: s.deletedAt))
    }

    /// Closes an open-ended status at `endAt`. A separate method from `upsertStatus` so the common
    /// "I'm back from the trip" action can't accidentally rewrite `start_at` or the note.
    func closeStatus(id: String, endAt: Date, updatedAt: Date) throws {
        try sensitive.run("UPDATE context_statuses SET end_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
                          [.date(endAt), .date(updatedAt), .text(id)])
    }

    /// Every live status, most recently started first.
    func allStatuses() throws -> [ContextStatus] {
        try sensitive.query("SELECT * FROM context_statuses WHERE deleted_at IS NULL ORDER BY start_at DESC;")
            .map(Self.readStatus)
    }

    /// Statuses open at `instant`.
    ///
    /// `end_at IS NULL` is matched explicitly rather than relying on a comparison, because SQL
    /// comparisons against NULL are NULL (not true) — an open-ended status is the NORMAL case
    /// here, and a plain `end_at > ?` would silently return none of them, which is the failure
    /// mode where "I'm travelling right now" annotates nothing at all.
    func activeStatuses(at instant: Date) throws -> [ContextStatus] {
        try sensitive.query("""
            SELECT * FROM context_statuses
            WHERE deleted_at IS NULL AND start_at <= ? AND (end_at IS NULL OR end_at > ?)
            ORDER BY start_at DESC;
            """, [.date(instant), .date(instant)]).map(Self.readStatus)
    }

    /// Statuses overlapping `[from, to)` — the window query a nightly score asks. Same NULL-aware
    /// end handling as `activeStatuses`.
    func statuses(overlapping from: Date, to: Date) throws -> [ContextStatus] {
        try sensitive.query("""
            SELECT * FROM context_statuses
            WHERE deleted_at IS NULL AND start_at < ? AND (end_at IS NULL OR end_at > ?)
            ORDER BY start_at DESC;
            """, [.date(to), .date(from)]).map(Self.readStatus)
    }

    /// Statuses that STARTED inside the window — the export's range read. Distinct from
    /// `statuses(overlapping:to:)` on purpose: an export window asks "what did the user declare in
    /// this period", not "what was in force during it", so a year-long open status does not get
    /// dragged into every month's file.
    func statuses(from: Date, to: Date) throws -> [ContextStatus] {
        try sensitive.query("""
            SELECT * FROM context_statuses
            WHERE start_at >= ? AND start_at <= ? AND deleted_at IS NULL
            ORDER BY start_at DESC;
            """, [.date(from), .date(to)]).map(Self.readStatus)
    }

    func status(id: String) throws -> ContextStatus? {
        try sensitive.query("SELECT * FROM context_statuses WHERE id = ?;", [.text(id)]).first.map(Self.readStatus)
    }

    func deleteStatus(id: String, at date: Date) throws {
        try sensitive.run("UPDATE context_statuses SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                          [.date(date), .date(date), .text(id)])
    }

    // MARK: - Readers

    static func readEntry(_ r: SQLiteRow) -> JournalEntry {
        JournalEntry(
            id: r.requireString("id"),
            behaviorId: r.string("behavior_id"),
            customLabel: r.string("custom_label"),
            // An unrecognized stored kind falls back to `.boolean` — the shape that claims the
            // least (it carries no value at all), so a row written by a newer build reads as
            // "this happened" rather than as a number in an unknown unit.
            valueKind: BehaviorValueKind(rawValue: r.requireString("value_kind")) ?? .boolean,
            value: r.double("value"),
            unit: r.string("unit"),
            occurredAt: r.requireDate("occurred_at"),
            tzId: r.requireString("tz_id"),
            note: r.string("note"),
            provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }

    static func readStatus(_ r: SQLiteRow) -> ContextStatus {
        ContextStatus(
            id: r.requireString("id"),
            statusId: r.string("status_id"),
            customLabel: r.string("custom_label"),
            startAt: r.requireDate("start_at"),
            // `r.date` returns nil for a NULL column, which is exactly the open-ended case — kept
            // as nil rather than defaulted to anything, since "still active" and "ended at the
            // epoch" are opposite claims.
            endAt: r.date("end_at"),
            tzId: r.requireString("tz_id"),
            note: r.string("note"),
            provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
