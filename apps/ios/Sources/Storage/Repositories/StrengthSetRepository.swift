import Foundation

/// Storage for the strength-set ledger (`strength_sets`, migration 9; EPIC-42/EPIC-28's absorbed
/// strength-logging half). Append-first, exactly like `HydrationRepository` over
/// `hydration_entries`: `insertSet` only ever inserts a row, a correction is a NEW row built by
/// `StrengthSetLedger.makeRevision` — never an UPDATE of a logged set (I2) — and `liveSets`/
/// `liveSet` derive the visible view from the tombstone + supersedes links, never from a mutated
/// flag.
///
/// Unlike `hydration_entries`, `strength_sets` carries no embedded provenance columns — see
/// `StrengthSet`'s own doc for why (the parent `sessions` row already carries the one provenance
/// that matters; a lifted weight has no separate upstream source to preserve lineage for).
final class StrengthSetRepository {
    private let main: SQLiteConnection

    init(main: SQLiteConnection) {
        self.main = main
    }

    private static let columns = """
        id, session_id, original_id, supersedes, revision, movement_id, custom_label, set_kind, \
        superset_group, seq, reps, weight_value, weight_unit, is_warm_up, recorded_at
        """
    private static let placeholders = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"

    /// Appends one row (an original or a revision — both are inserts). `INSERT OR REPLACE` is
    /// idempotent on the ULID PK, so re-inserting the identical row is a no-op; it never
    /// overwrites a *different* logical version, because a revision always mints a fresh id
    /// (mirrors `HydrationRepository.insertEntry`). `is_warm_up` is written from
    /// `StrengthSet.isWarmUp`, which is computed from `setKind` — never accepted as an
    /// independent value — so the denormalized column can never drift from the kind that defines it.
    func insertSet(_ s: StrengthSet) throws {
        try main.run("""
            INSERT OR REPLACE INTO strength_sets
              (\(Self.columns), \(Rows.convColumns))
            VALUES (\(Self.placeholders), \(Rows.convPlaceholders));
            """,
            [.text(s.id), .text(s.sessionId), .text(s.originalId), .string(s.supersedes), .int(s.revision),
             .string(s.movementId), .string(s.customLabel), .text(s.setKind.rawValue), .string(s.supersetGroup),
             .int(s.seq), .int(s.reps), .double(s.weightValue), .string(s.weightUnit?.rawValue),
             .bool(s.isWarmUp), .date(s.recordedAt)]
            + Rows.convParams(updatedAt: s.updatedAt, originDeviceId: s.originDeviceId, deletedAt: s.deletedAt))
    }

    /// Every row logged for a session — every revision, tombstoned or not — ordered by seq then
    /// revision. This is the shape `StrengthSetLedger.liveSets` expects as input, and also what
    /// `StrengthSessionRunner.recordSet` reads to resolve the next `seq`.
    func sets(sessionId: String) throws -> [StrengthSet] {
        try main.query("SELECT * FROM strength_sets WHERE session_id = ? ORDER BY seq ASC, revision ASC;",
                       [.text(sessionId)]).map(Self.readSet)
    }

    /// The LIVE sets for a session, in logged order — the repository-level mirror of
    /// `StrengthSetLedger.liveSets`, kept in sync with it the same way
    /// `HydrationRepository.liveEntries` mirrors `HydrationLedger.liveEntries`. A divergence
    /// between this SQL and the pure Swift rule is a bug on one side, not an acceptable difference.
    func liveSets(sessionId: String) throws -> [StrengthSet] {
        try main.query("""
            SELECT * FROM strength_sets
            WHERE session_id = ? AND deleted_at IS NULL
              AND id NOT IN (SELECT supersedes FROM strength_sets WHERE supersedes IS NOT NULL AND deleted_at IS NULL)
            ORDER BY seq ASC;
            """, [.text(sessionId)]).map(Self.readSet)
    }

    /// The full audit chain of one logical set — every revision, tombstoned or superseded rows
    /// included — oldest first.
    func history(originalId: String) throws -> [StrengthSet] {
        try main.query("SELECT * FROM strength_sets WHERE original_id = ? ORDER BY revision ASC;",
                       [.text(originalId)]).map(Self.readSet)
    }

    /// The current live head of a chain (what a revision edits), or nil if the chain is fully
    /// deleted or unknown. Reuses the pure live-set logic so the SQL and the in-memory rule cannot
    /// drift.
    func liveSet(originalId: String) throws -> StrengthSet? {
        StrengthSetLedger.liveSets(try history(originalId: originalId)).first
    }

    /// Any single row by id, tombstone or not.
    func set(id: String) throws -> StrengthSet? {
        try main.query("SELECT * FROM strength_sets WHERE id = ?;", [.text(id)]).first.map(Self.readSet)
    }

    /// Tombstones ONE row — reverting a revision (its prior version becomes live again, because it
    /// is no longer superseded by a non-deleted row). Not a hard delete: the row stays for the
    /// audit chain (I3-flavored).
    func undoSet(id: String, at date: Date) throws {
        try main.run("UPDATE strength_sets SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                     [.date(date), .date(date), .text(id)])
    }

    /// Tombstones a WHOLE chain — "remove this set" — so no revision of it stays live. Every row
    /// with this `original_id` is marked deleted; `history` still returns them.
    func deleteChain(originalId: String, at date: Date) throws {
        try main.run("UPDATE strength_sets SET deleted_at = ?, updated_at = ? WHERE original_id = ? AND deleted_at IS NULL;",
                     [.date(date), .date(date), .text(originalId)])
    }

    // MARK: - Readers

    static func readSet(_ r: SQLiteRow) -> StrengthSet {
        StrengthSet(
            id: r.requireString("id"), sessionId: r.requireString("session_id"),
            originalId: r.requireString("original_id"), supersedes: r.string("supersedes"),
            revision: r.intValue("revision") ?? 1, movementId: r.string("movement_id"),
            customLabel: r.string("custom_label"),
            setKind: StrengthSetKind(rawValue: r.requireString("set_kind")) ?? .working,
            supersetGroup: r.string("superset_group"), seq: r.intValue("seq") ?? 0,
            reps: r.intValue("reps"), weightValue: r.double("weight_value"),
            weightUnit: r.string("weight_unit").flatMap(WeightUnit.init(rawValue:)),
            recordedAt: r.requireDate("recorded_at"), updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }
}
