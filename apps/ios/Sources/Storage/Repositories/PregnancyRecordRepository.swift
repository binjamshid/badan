import Foundation

/// Storage for the pregnancy module's journey ledger (`pregnancy_records`, sensitive migration v8).
/// Append-first, exactly like `CycleRecordRepository`: `insertRecord` only ever inserts a row, a
/// mode transition is a NEW row (a fresh id, `supersedes` pointing at the row it replaces) — never
/// an UPDATE of a logged journey (I2) — and `liveRecords`/`liveRecord` derive the visible view from
/// the tombstone + supersedes links, never from a mutated `mode` column.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository`/`LabResultRepository` use. Per
/// `Domain/Pregnancy/PregnancyModels.swift`'s own header, pregnancy data is in the same
/// highest-sensitivity family as cycle data, with its own sharper loss-suppression edge, so there
/// is no `main` connection in scope here for a statement to reach even by accident.
final class PregnancyRecordRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    private static let columns = "id, mode, multiples_flag, fertility_treatment_context, original_id, supersedes, revision"
    private static let placeholders = "?, ?, ?, ?, ?, ?, ?"

    /// Appends one row (an original or a revision — both are inserts). `INSERT OR REPLACE` is
    /// idempotent on the ULID PK, so a retried write is a no-op; it never overwrites a DIFFERENT
    /// logical version, because a revision always mints a fresh id (mirrors
    /// `CycleRecordRepository.insertRecord` exactly).
    func insertRecord(_ record: PregnancyRecord) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO pregnancy_records
              (\(Self.columns), \(Rows.provColumns), \(Rows.convColumns))
            VALUES (\(Self.placeholders), \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(record.id), .text(record.mode.rawValue), .bool(record.multiplesFlag),
             .bool(record.fertilityTreatmentContext), .text(record.originalId), .string(record.supersedes),
             .int(record.revision)]
            + Rows.provParams(record.provenance)
            + Rows.convParams(updatedAt: record.updatedAt, originDeviceId: record.originDeviceId,
                              deletedAt: record.deletedAt))
    }

    /// The LIVE journeys, most recently updated first — the repository-level mirror of
    /// `PregnancyRecordLedger.liveRecords`, kept in sync with it the same way
    /// `CycleRecordRepository.liveRecords` mirrors `CycleRecordLedger.liveRecords`. A divergence
    /// between this SQL and the pure Swift rule is a bug on one side, not an acceptable difference.
    func liveRecords() throws -> [PregnancyRecord] {
        try sensitive.query("""
            SELECT * FROM pregnancy_records
            WHERE deleted_at IS NULL
              AND id NOT IN (SELECT supersedes FROM pregnancy_records WHERE supersedes IS NOT NULL AND deleted_at IS NULL)
            ORDER BY updated_at DESC;
            """).map(Self.readRecord)
    }

    /// The full audit chain of one logical journey — every revision, tombstoned or superseded rows
    /// included — oldest first.
    func history(originalId: String) throws -> [PregnancyRecord] {
        try sensitive.query("SELECT * FROM pregnancy_records WHERE original_id = ? ORDER BY revision ASC;",
                            [.text(originalId)]).map(Self.readRecord)
    }

    /// The current live head of a chain (what a transition edits), or nil if the chain is fully
    /// deleted, superseded, or unknown. Reuses the pure live-set logic so the SQL and the in-memory
    /// rule cannot drift.
    func liveRecord(originalId: String) throws -> PregnancyRecord? {
        PregnancyRecordLedger.liveRecords(try history(originalId: originalId)).first
    }

    /// Any single row by id, tombstone or not — for inspecting what a revision superseded.
    func record(id: String) throws -> PregnancyRecord? {
        try sensitive.query("SELECT * FROM pregnancy_records WHERE id = ?;", [.text(id)]).first.map(Self.readRecord)
    }

    /// Real, hard deletion of EVERY revision (live, superseded, or already tombstoned) belonging to
    /// ONE journey — the scoped, per-journey counterpart to `Database.purgeSensitiveNamespace()`'s
    /// whole-file wipe, used by `PregnancyModuleServices.purgeJourneyData(originalId:)` to make the
    /// loss-declaration "Delete" data-disposition choice real (general audit finding 1). A DIFFERENT
    /// journey's `originalId` is untouched.
    func purgeChain(originalId: String) throws {
        try sensitive.run("DELETE FROM pregnancy_records WHERE original_id = ?;", [.text(originalId)])
    }

    // MARK: - Readers

    static func readRecord(_ r: SQLiteRow) -> PregnancyRecord {
        PregnancyRecord(
            id: r.requireString("id"),
            mode: PregnancyJourneyMode(rawValue: r.requireString("mode")) ?? .ttc,
            multiplesFlag: r.bool("multiples_flag"),
            fertilityTreatmentContext: r.bool("fertility_treatment_context"),
            originalId: r.requireString("original_id"),
            supersedes: r.string("supersedes"),
            revision: r.intValue("revision") ?? 1,
            provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
