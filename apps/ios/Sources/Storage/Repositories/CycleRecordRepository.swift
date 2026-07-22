import Foundation

/// Storage for the cycle module's period ledger (`cycle_records`, sensitive migration v6).
/// Append-first, exactly like `LabResultRepository`/`StrengthSetRepository`: `insertRecord` only
/// ever inserts a row, a correction is a NEW row (a fresh id, `supersedes` pointing at the row it
/// replaces) — never an UPDATE of a logged period (I2) — and `liveRecords`/`liveRecord` derive the
/// visible view from the tombstone + supersedes links, never from a mutated flag.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `LabResultRepository`/`JournalRepository` use. Per
/// `docs/legal/reproductive-threat-model.md` §1, this is the single highest-sensitivity data family
/// this app handles, so there is no `main` connection in scope here for a statement to reach even
/// by accident.
final class CycleRecordRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    private static let columns = "id, start_at, end_at, ongoing, note, original_id, supersedes, revision"
    private static let placeholders = "?, ?, ?, ?, ?, ?, ?, ?"

    /// Appends one row (an original or a revision — both are inserts). `INSERT OR REPLACE` is
    /// idempotent on the ULID PK, so a retried write is a no-op; it never overwrites a DIFFERENT
    /// logical version, because a revision always mints a fresh id (mirrors
    /// `LabResultRepository.insertResult` exactly).
    func insertRecord(_ record: CycleRecord) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO cycle_records
              (\(Self.columns), \(Rows.provColumns), \(Rows.convColumns))
            VALUES (\(Self.placeholders), \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(record.id), .date(record.startAt), .date(record.endAt), .bool(record.ongoing),
             .string(record.note), .text(record.originalId), .string(record.supersedes),
             .int(record.revision)]
            + Rows.provParams(record.provenance)
            + Rows.convParams(updatedAt: record.updatedAt, originDeviceId: record.originDeviceId,
                              deletedAt: record.deletedAt))
    }

    /// The LIVE periods, most recently started first — the repository-level mirror of
    /// `CycleRecordLedger.liveRecords`, kept in sync with it the same way
    /// `LabResultRepository.allLiveResults` mirrors `LabResultLedger.liveResults`. A divergence
    /// between this SQL and the pure Swift rule is a bug on one side, not an acceptable difference.
    func liveRecords() throws -> [CycleRecord] {
        try sensitive.query("""
            SELECT * FROM cycle_records
            WHERE deleted_at IS NULL
              AND id NOT IN (SELECT supersedes FROM cycle_records WHERE supersedes IS NOT NULL AND deleted_at IS NULL)
            ORDER BY start_at DESC;
            """).map(Self.readRecord)
    }

    /// The full audit chain of one logical period — every revision, tombstoned or superseded rows
    /// included — oldest first.
    func history(originalId: String) throws -> [CycleRecord] {
        try sensitive.query("SELECT * FROM cycle_records WHERE original_id = ? ORDER BY revision ASC;",
                            [.text(originalId)]).map(Self.readRecord)
    }

    /// The current live head of a chain (what a revision edits), or nil if the chain is fully
    /// deleted or unknown. Reuses the pure live-set logic so the SQL and the in-memory rule cannot
    /// drift.
    func liveRecord(originalId: String) throws -> CycleRecord? {
        CycleRecordLedger.liveRecords(try history(originalId: originalId)).first
    }

    /// Any single row by id, tombstone or not — for inspecting what a revision superseded.
    func record(id: String) throws -> CycleRecord? {
        try sensitive.query("SELECT * FROM cycle_records WHERE id = ?;", [.text(id)]).first.map(Self.readRecord)
    }

    /// Tombstones a WHOLE chain — "remove this period" — so no revision of it stays live. Mirrors
    /// `LabResultRepository.deleteChain` exactly: every row with this `original_id` is marked
    /// deleted, and `history` still returns them for the audit trail.
    func deleteChain(originalId: String, at date: Date) throws {
        try sensitive.run("""
            UPDATE cycle_records SET deleted_at = ?, updated_at = ? WHERE original_id = ? AND deleted_at IS NULL;
            """, [.date(date), .date(date), .text(originalId)])
    }

    // MARK: - Readers

    static func readRecord(_ r: SQLiteRow) -> CycleRecord {
        CycleRecord(
            id: r.requireString("id"),
            startAt: r.requireDate("start_at"),
            endAt: r.date("end_at"),
            ongoing: r.bool("ongoing"),
            note: r.string("note"),
            originalId: r.requireString("original_id"),
            supersedes: r.string("supersedes"),
            revision: r.intValue("revision") ?? 1,
            provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
