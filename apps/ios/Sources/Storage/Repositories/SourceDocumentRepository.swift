import Foundation

/// Metadata CRUD for the lab-notebook document vault (LAB-02), over a `source_documents` table.
///
/// **This repository holds the sensitive connection and nothing else.** That is the I7
/// enforcement, structural rather than a rule someone has to remember — there is no `main`
/// connection in scope here, so no statement in this file can address `badan.db` even by accident.
/// Mirrors `JournalRepository`'s own header exactly, for the same reason: a `SourceDocument` row
/// landing in the main database would silently downgrade `Database.purgeSensitiveNamespace()` — a
/// literal file deletion — to a best-effort row sweep for rows that can carry a patient's name,
/// date of birth, or diagnoses.
///
/// The `source_documents` table (sensitive migration version 5, alongside `lab_reports`/
/// `lab_results`/`reference_ranges`/`derived_trends`) is defined in
/// `Migrations.swift`'s `sensitiveMigrations`; this repository's SQL is written against that exact
/// DDL. It was reconstructed here verbatim ahead of the migration landing during this slice's
/// parallel build (three lanes: domain/schema, document-vault/OCR, UI) and reconciled against the
/// real migration once all three lanes' work was integrated.
final class SourceDocumentRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    private static let columns = """
        id, sha256, mime_type, original_file_name, page_count, ocr_status, vault_file_ref, \
        sensitivity_tier, imported_at, updated_at, origin_device_id, deleted_at
        """
    private static let placeholders = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"

    /// Plain `INSERT`, never `INSERT OR REPLACE` — deliberately, unlike `JournalRepository
    /// .insertEntry`'s idempotent upsert. A `SourceDocument`'s identity is its content (`sha256`),
    /// not a client-retried write of the same logical row, so a second insert of an unchanged file
    /// SHOULD fail the unique index above loudly rather than silently overwrite the first row's
    /// `id` — every `OCRExtraction`/`LabReport.documentRef` elsewhere in the app would still be
    /// pointing at that original id.
    func insert(_ doc: SourceDocument) throws {
        try sensitive.run(
            "INSERT INTO source_documents (\(Self.columns)) VALUES (\(Self.placeholders));",
            [
                .text(doc.id), .text(doc.sha256), .text(doc.mimeType), .string(doc.originalFileName),
                .int(doc.pageCount), .text(doc.ocrStatus.rawValue), .text(doc.vaultFileRef),
                .text(doc.sensitivityTier.rawValue), .date(doc.importedAt), .date(doc.updatedAt),
                .text(doc.originDeviceId), .date(doc.deletedAt),
            ])
    }

    /// Advances OCR status only (`.pending` -> `.inProgress` -> `.completed`/`.failed`) — the one
    /// field `LabDocumentOCR`'s caller updates in place, since OCR status is a processing-pipeline
    /// state machine, not a user-authored fact with a revision history worth preserving.
    func updateOCRStatus(id: String, status: SourceDocumentOCRStatus, updatedAt: Date) throws {
        try sensitive.run(
            "UPDATE source_documents SET ocr_status = ?, updated_at = ? WHERE id = ?;",
            [.text(status.rawValue), .date(updatedAt), .text(id)])
    }

    func document(id: String) throws -> SourceDocument? {
        try sensitive.query("SELECT * FROM source_documents WHERE id = ?;", [.text(id)])
            .first.map(Self.read)
    }

    /// The live document already vaulted under this hash, if any — the LAB-02 duplicate-import
    /// check. A caller sees the EXISTING document rather than the unique-index violation `insert`
    /// would otherwise throw, so "you already added this report" can be an ordinary message
    /// instead of a crash.
    func document(sha256: String) throws -> SourceDocument? {
        try sensitive.query(
            "SELECT * FROM source_documents WHERE sha256 = ? AND deleted_at IS NULL;",
            [.text(sha256)]
        ).first.map(Self.read)
    }

    /// Every live document, most recently imported first. Unbounded, matching
    /// `JournalRepository.allEntries()`'s own reasoning — a personal lab notebook is dozens to a
    /// few hundred documents even over many years, not a table that needs pagination to read whole.
    func allDocuments() throws -> [SourceDocument] {
        try sensitive.query(
            "SELECT * FROM source_documents WHERE deleted_at IS NULL ORDER BY imported_at DESC;"
        ).map(Self.read)
    }

    /// Tombstones the metadata row. Deleting the VAULTED FILE itself is `DocumentVault.delete
    /// (vaultFileRef:)`'s job, called separately by whatever caller orchestrates "delete this
    /// document" — this repository only ever touches the sensitive connection (I7's structural
    /// point), never the filesystem.
    func delete(id: String, at date: Date) throws {
        try sensitive.run(
            "UPDATE source_documents SET deleted_at = ?, updated_at = ? WHERE id = ?;",
            [.date(date), .date(date), .text(id)])
    }

    private static func read(_ r: SQLiteRow) -> SourceDocument {
        SourceDocument(
            id: r.requireString("id"),
            sha256: r.requireString("sha256"),
            mimeType: r.requireString("mime_type"),
            originalFileName: r.string("original_file_name"),
            pageCount: r.intValue("page_count") ?? 0,
            ocrStatus: SourceDocumentOCRStatus(rawValue: r.requireString("ocr_status")) ?? .pending,
            vaultFileRef: r.requireString("vault_file_ref"),
            sensitivityTier: LabSensitivityTier(rawValue: r.requireString("sensitivity_tier")) ?? .high,
            importedAt: r.requireDate("imported_at"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
