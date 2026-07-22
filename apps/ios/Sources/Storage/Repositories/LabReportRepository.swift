import Foundation

/// Storage for the lab notebook's report-level entities (EPIC-41, plan §9.17) — `lab_reports` and
/// `lab_panels`, plus the two lightweight overlay logs that can attach to EITHER a report or a
/// result (`user_corrections`, `lab_annotations`; see `LabAttachmentTarget`). Over the tables
/// created by sensitive migration v5.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `JournalRepository`/`CorrelationRepository` use, for the same reason: a lab report's
/// identifier space can itself disclose before any value is read, so there is no `main` connection
/// in scope here for a statement to reach even by accident.
///
/// **Design note on the overlay tables:** `UserCorrection` and `LabAnnotation` both address their
/// target via the SAME generic `(targetType, targetId)` scheme regardless of whether the target is
/// a `LabReport` or a `LabResult`. Splitting "corrections on reports" into this file and
/// "corrections on results" into `LabResultRepository` would duplicate near-identical SQL for one
/// concept; both live here instead, next to the top-of-hierarchy entity, so there is exactly one
/// implementation of each.
final class LabReportRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    /// Batch several writes (a report + its panels, typically) into one transaction instead of one
    /// implicit commit+fsync per row (mirrors `JournalRepository.transaction`).
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    // MARK: - Reports

    private static let reportColumns = """
        id, source_lab_name, collection_at, reported_at, tz_id, document_ref, review_state, \
        ingestion_path, sensitivity_tier
        """
    private static let reportPlaceholders = "?, ?, ?, ?, ?, ?, ?, ?, ?"

    /// `INSERT OR REPLACE` is idempotent on the ULID PK: a retried write is a no-op, and a genuine
    /// metadata edit (e.g. correcting the lab name) is expected to go through `UserCorrection` +
    /// re-insertion of the SAME id — `LabReport` has no revision chain of its own (see the type's
    /// own doc for why).
    func insertReport(_ report: LabReport) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO lab_reports
              (\(Self.reportColumns), \(Rows.convColumns))
            VALUES (\(Self.reportPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(report.id), .string(report.sourceLabName), .date(report.collectionAt),
             .date(report.reportedAt), .text(report.tzId), .string(report.documentRef),
             .text(report.reviewState.rawValue), .text(report.ingestionPath.rawValue),
             .text(report.sensitivityTier.rawValue)]
            + Rows.convParams(updatedAt: report.updatedAt, originDeviceId: report.originDeviceId,
                              deletedAt: report.deletedAt))
    }

    func report(id: String) throws -> LabReport? {
        try sensitive.query("SELECT * FROM lab_reports WHERE id = ?;", [.text(id)]).first.map(Self.readReport)
    }

    /// Every live report, most recently collected first — the notebook's report list/timeline read.
    func liveReports() throws -> [LabReport] {
        try sensitive.query("SELECT * FROM lab_reports WHERE deleted_at IS NULL ORDER BY collection_at DESC;")
            .map(Self.readReport)
    }

    /// Tombstones a report. Not a hard delete: the row (and its panels/results, left untouched here —
    /// callers cascade explicitly) stays for the audit trail.
    func deleteReport(id: String, at date: Date) throws {
        try sensitive.run("UPDATE lab_reports SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                          [.date(date), .date(date), .text(id)])
    }

    // MARK: - Panels

    /// `INSERT OR REPLACE` idempotent on the ULID PK, matching `insertReport`.
    func insertPanel(_ panel: LabPanel) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO lab_panels (id, report_id, name, sort_order, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(panel.id), .text(panel.reportId), .text(panel.name), .int(panel.sortOrder)]
            + Rows.convParams(updatedAt: panel.updatedAt, originDeviceId: panel.originDeviceId,
                              deletedAt: panel.deletedAt))
    }

    /// Every live panel for a report, in source order.
    func panels(reportId: String) throws -> [LabPanel] {
        try sensitive.query("""
            SELECT * FROM lab_panels WHERE report_id = ? AND deleted_at IS NULL ORDER BY sort_order ASC;
            """, [.text(reportId)]).map(Self.readPanel)
    }

    func deletePanel(id: String, at date: Date) throws {
        try sensitive.run("UPDATE lab_panels SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                          [.date(date), .date(date), .text(id)])
    }

    // MARK: - User corrections (append-only; report OR result target)

    /// Corrections are pure inserts — no update/delete method exists against this table anywhere in
    /// this repository, which is the structural half of "append-only, never destructive" (I2-flavored).
    func insertCorrection(_ correction: UserCorrection) throws {
        try sensitive.run("""
            INSERT INTO user_corrections
              (id, target_type, target_id, field_name, previous_value_text, corrected_value_text,
               reason, corrected_at, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(correction.id), .text(correction.targetType.rawValue), .text(correction.targetId),
             .text(correction.fieldName), .string(correction.previousValueText),
             .text(correction.correctedValueText), .string(correction.reason), .date(correction.correctedAt)]
            + Rows.convParams(updatedAt: correction.updatedAt, originDeviceId: correction.originDeviceId,
                              deletedAt: correction.deletedAt))
    }

    /// Every correction recorded against one target, oldest first — the audit trail I2 exists to
    /// preserve.
    func corrections(targetType: LabAttachmentTarget, targetId: String) throws -> [UserCorrection] {
        try sensitive.query("""
            SELECT * FROM user_corrections WHERE target_type = ? AND target_id = ? ORDER BY corrected_at ASC;
            """, [.text(targetType.rawValue), .text(targetId)]).map(Self.readCorrection)
    }

    // MARK: - Annotations

    func insertAnnotation(_ annotation: LabAnnotation) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO lab_annotations
              (id, target_type, target_id, kind, text, resolved, created_at, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(annotation.id), .text(annotation.targetType.rawValue), .text(annotation.targetId),
             .text(annotation.kind.rawValue), .text(annotation.text), .bool(annotation.resolved),
             .date(annotation.createdAt)]
            + Rows.convParams(updatedAt: annotation.updatedAt, originDeviceId: annotation.originDeviceId,
                              deletedAt: annotation.deletedAt))
    }

    /// Every live annotation for one target, in creation order — the visit-prep read.
    func annotations(targetType: LabAttachmentTarget, targetId: String) throws -> [LabAnnotation] {
        try sensitive.query("""
            SELECT * FROM lab_annotations
            WHERE target_type = ? AND target_id = ? AND deleted_at IS NULL ORDER BY created_at ASC;
            """, [.text(targetType.rawValue), .text(targetId)]).map(Self.readAnnotation)
    }

    /// Toggles the "asked/answered at a visit" flag — never a diagnostic state, just a checkbox.
    func setAnnotationResolved(id: String, resolved: Bool, at date: Date) throws {
        try sensitive.run("UPDATE lab_annotations SET resolved = ?, updated_at = ? WHERE id = ?;",
                          [.bool(resolved), .date(date), .text(id)])
    }

    func deleteAnnotation(id: String, at date: Date) throws {
        try sensitive.run("UPDATE lab_annotations SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                          [.date(date), .date(date), .text(id)])
    }

    // MARK: - Readers

    static func readReport(_ r: SQLiteRow) -> LabReport {
        LabReport(
            id: r.requireString("id"),
            sourceLabName: r.string("source_lab_name"),
            collectionAt: r.requireDate("collection_at"),
            reportedAt: r.date("reported_at"),
            tzId: r.requireString("tz_id"),
            documentRef: r.string("document_ref"),
            reviewState: LabReviewState(rawValue: r.requireString("review_state")) ?? .needsReview,
            ingestionPath: IngestionPath(rawValue: r.requireString("ingestion_path")) ?? .manual,
            sensitivityTier: LabSensitivityTier(rawValue: r.requireString("sensitivity_tier")) ?? .standard,
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }

    static func readPanel(_ r: SQLiteRow) -> LabPanel {
        LabPanel(
            id: r.requireString("id"), reportId: r.requireString("report_id"),
            name: r.requireString("name"), sortOrder: r.intValue("sort_order") ?? 0,
            updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }

    static func readCorrection(_ r: SQLiteRow) -> UserCorrection {
        UserCorrection(
            id: r.requireString("id"),
            targetType: LabAttachmentTarget(rawValue: r.requireString("target_type")) ?? .result,
            targetId: r.requireString("target_id"),
            fieldName: r.requireString("field_name"),
            previousValueText: r.string("previous_value_text"),
            correctedValueText: r.requireString("corrected_value_text"),
            reason: r.string("reason"),
            correctedAt: r.requireDate("corrected_at"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }

    static func readAnnotation(_ r: SQLiteRow) -> LabAnnotation {
        LabAnnotation(
            id: r.requireString("id"),
            targetType: LabAttachmentTarget(rawValue: r.requireString("target_type")) ?? .result,
            targetId: r.requireString("target_id"),
            kind: LabAnnotationKind(rawValue: r.requireString("kind")) ?? .note,
            text: r.requireString("text"),
            resolved: r.bool("resolved"),
            createdAt: r.requireDate("created_at"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
