import Foundation

/// Storage for the lab notebook's per-observation ledger (`lab_results`, sensitive migration v5).
/// Append-first, exactly like `HydrationRepository`/`StrengthSetRepository`: `insertResult` only
/// ever inserts a row, a correction or a LAB-16 amendment is a NEW row built by
/// `DuplicateConflictResolver.makeAmendment` — never an UPDATE of a logged result (I2) — and
/// `liveResults`/`liveResult` derive the visible view from the tombstone + supersedes links, never
/// from a mutated flag.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `JournalRepository`/`LabReportRepository` use.
final class LabResultRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    private static let columns = """
        id, report_id, panel_id, analyte_id, custom_label, raw_value_text, comparator, numeric_value, \
        raw_unit, canonical_value, canonical_unit, result_type, review_state, sensitivity_tier, \
        original_id, supersedes, revision
        """
    private static let placeholders = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"

    /// Appends one row (an original or a revision — both are inserts). `INSERT OR REPLACE` is
    /// idempotent on the ULID PK, so a retried write is a no-op; it never overwrites a DIFFERENT
    /// logical version, because a revision always mints a fresh id (mirrors
    /// `StrengthSetRepository.insertSet`).
    func insertResult(_ result: LabResult) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO lab_results
              (\(Self.columns), \(Rows.provColumns), \(Rows.convColumns))
            VALUES (\(Self.placeholders), \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(result.id), .text(result.reportId), .string(result.panelId), .string(result.analyteId),
             .string(result.customLabel), .text(result.rawValueText),
             .string(result.comparator?.rawValue), .double(result.numericValue), .string(result.rawUnit),
             .double(result.canonicalValue), .string(result.canonicalUnit),
             .text(result.resultType.rawValue), .text(result.reviewState.rawValue),
             .text(result.sensitivityTier.rawValue), .text(result.originalId), .string(result.supersedes),
             .int(result.revision)]
            + Rows.provParams(result.provenance)
            + Rows.convParams(updatedAt: result.updatedAt, originDeviceId: result.originDeviceId,
                              deletedAt: result.deletedAt))
    }

    /// Every row logged for a report — every revision, tombstoned or not — ordered for stable
    /// chronological display.
    func results(reportId: String) throws -> [LabResult] {
        try sensitive.query("SELECT * FROM lab_results WHERE report_id = ? ORDER BY measured_at ASC, revision ASC;",
                            [.text(reportId)]).map(Self.readResult)
    }

    /// The LIVE results for a report, in measured order — the repository-level mirror of
    /// `LabResultLedger.liveResults`, kept in sync with it the same way
    /// `HydrationRepository.liveEntries` mirrors `HydrationLedger.liveEntries`. A divergence between
    /// this SQL and the pure Swift rule is a bug on one side, not an acceptable difference.
    ///
    /// `includeSuppressed` mirrors `MeasurementRepository.rawSamples`'s own parameter/clause exactly
    /// (`suppressed_by IS NULL`) — a LAB-16 `.merge` decision marks the losing duplicate suppressed
    /// without deleting it, and that row must stay invisible to every ordinary "live" read.
    func liveResults(reportId: String, includeSuppressed: Bool = false) throws -> [LabResult] {
        var sql = """
            SELECT * FROM lab_results
            WHERE report_id = ? AND deleted_at IS NULL
              AND id NOT IN (SELECT supersedes FROM lab_results WHERE supersedes IS NOT NULL AND deleted_at IS NULL)
            """
        if !includeSuppressed { sql += " AND suppressed_by IS NULL" }
        sql += " ORDER BY measured_at ASC;"
        return try sensitive.query(sql, [.text(reportId)]).map(Self.readResult)
    }

    /// Every live result for one DICTIONARY analyte across all reports, oldest first — the
    /// marker-browser/trend read (LAB-04/LAB-12), backed by `idx_lab_results_analyte_measured`.
    ///
    /// Filters on the `analyte_id` column specifically, so a purely custom-labeled marker
    /// (`analyte_id IS NULL`) is invisible to this query by construction — callers building a history
    /// for a custom-labeled analyte should use `allLiveResults()` and group by `LabResult.analyteKey`
    /// in memory instead (the reason `analyteKey` exists at all: it is the ONE identity that covers
    /// both dictionary and custom markers).
    func liveResults(analyteId: String, includeSuppressed: Bool = false) throws -> [LabResult] {
        var sql = """
            SELECT * FROM lab_results
            WHERE analyte_id = ? AND deleted_at IS NULL
              AND id NOT IN (SELECT supersedes FROM lab_results WHERE supersedes IS NOT NULL AND deleted_at IS NULL)
            """
        if !includeSuppressed { sql += " AND suppressed_by IS NULL" }
        sql += " ORDER BY measured_at ASC;"
        return try sensitive.query(sql, [.text(analyteId)]).map(Self.readResult)
    }

    /// Every live result in the whole notebook, oldest first — the base for any in-memory grouping
    /// by `analyteKey` (the read `computePersonalBaseline` and `ManualEntryScreen.save()`'s
    /// `LabDuplicateCheck.apply` both need, since both cover custom-labeled markers
    /// `liveResults(analyteId:)` cannot see).
    func allLiveResults(includeSuppressed: Bool = false) throws -> [LabResult] {
        var sql = """
            SELECT * FROM lab_results
            WHERE deleted_at IS NULL
              AND id NOT IN (SELECT supersedes FROM lab_results WHERE supersedes IS NOT NULL AND deleted_at IS NULL)
            """
        if !includeSuppressed { sql += " AND suppressed_by IS NULL" }
        sql += " ORDER BY measured_at ASC;"
        return try sensitive.query(sql).map(Self.readResult)
    }

    /// The full audit chain of one logical result — every revision, tombstoned or superseded rows
    /// included — oldest first.
    func history(originalId: String) throws -> [LabResult] {
        try sensitive.query("SELECT * FROM lab_results WHERE original_id = ? ORDER BY revision ASC;",
                            [.text(originalId)]).map(Self.readResult)
    }

    /// The current live head of a chain (what a revision edits), or nil if the chain is fully deleted
    /// or unknown. Reuses the pure live-set logic so the SQL and the in-memory rule cannot drift.
    func liveResult(originalId: String) throws -> LabResult? {
        LabResultLedger.liveResults(try history(originalId: originalId)).first
    }

    /// Any single row by id, tombstone or not — for inspecting what a revision superseded.
    func result(id: String) throws -> LabResult? {
        try sensitive.query("SELECT * FROM lab_results WHERE id = ?;", [.text(id)]).first.map(Self.readResult)
    }

    /// Tombstones ONE row — reverting a revision (its prior version becomes live again, since it is
    /// no longer superseded by a non-deleted row). Not a hard delete: the row stays for the audit
    /// chain (I3-flavored).
    func undoRevision(id: String, at date: Date) throws {
        try sensitive.run("UPDATE lab_results SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                          [.date(date), .date(date), .text(id)])
    }

    /// Tombstones a WHOLE chain — "remove this result" — so no revision of it stays live.
    func deleteChain(originalId: String, at date: Date) throws {
        try sensitive.run("""
            UPDATE lab_results SET deleted_at = ?, updated_at = ? WHERE original_id = ? AND deleted_at IS NULL;
            """, [.date(date), .date(date), .text(originalId)])
    }

    /// I3: marks `id` a dedup-suppressed twin of `winnerId` — an UPDATE of the `suppressed_by`
    /// provenance column only, NEVER a delete. This is the storage-side mechanism
    /// `DuplicateConflictResolver`'s `.merge` decision resolves to, and mirrors
    /// `MeasurementRepository.setSuppressed`'s exact contract (same field, same never-delete rule),
    /// applied here to the sensitive lab table rather than a wearable-reading one. Called from
    /// `ManualEntryScreen.save()` immediately after inserting a result the resolver scored `.merge`
    /// against an existing live result (LAB-16) — see that call site for the actual wiring.
    func suppress(id: String, by winnerId: String, at date: Date) throws {
        try sensitive.run("UPDATE lab_results SET suppressed_by = ?, updated_at = ? WHERE id = ?;",
                          [.text(winnerId), .date(date), .text(id)])
    }

    // MARK: - Readers

    static func readResult(_ r: SQLiteRow) -> LabResult {
        LabResult(
            id: r.requireString("id"),
            reportId: r.requireString("report_id"),
            panelId: r.string("panel_id"),
            analyteId: r.string("analyte_id"),
            customLabel: r.string("custom_label"),
            rawValueText: r.requireString("raw_value_text"),
            comparator: r.string("comparator").flatMap(LabComparator.init(rawValue:)),
            numericValue: r.double("numeric_value"),
            rawUnit: r.string("raw_unit"),
            canonicalValue: r.double("canonical_value"),
            canonicalUnit: r.string("canonical_unit"),
            resultType: LabResultType(rawValue: r.requireString("result_type")) ?? .textual,
            reviewState: LabReviewState(rawValue: r.requireString("review_state")) ?? .needsReview,
            sensitivityTier: LabSensitivityTier(rawValue: r.requireString("sensitivity_tier")) ?? .standard,
            originalId: r.requireString("original_id"),
            supersedes: r.string("supersedes"),
            revision: r.intValue("revision") ?? 1,
            provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
