import Foundation

/// Storage for loss declarations (`LossDeclarationRecord` — `loss_declaration_records`, sensitive
/// migration v8). Append-only AT CREATION (I2): a loss is declared once via `insertDeclaration`.
/// `updateDataDisposition` is the one deliberate exception — a plain UPDATE of `data_disposition`/
/// `updated_at` only, mirroring `CycleAnomalyEventRepository.updateState`'s exact shape (research
/// doc §9 line 132: the disposition choice is "revisitable later, not a one-time forced decision").
/// `deleteRecord` tombstones the row independently of the `PregnancyRecord` chain it references
/// (research doc §9 lines 150, 161-162, 178: "independently deletable").
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository`/`PregnancyRecordRepository` use.
final class LossDeclarationRecordRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    /// Plain INSERT (never `OR REPLACE`) — a loss declaration is created once.
    func insertDeclaration(_ declaration: LossDeclarationRecord) throws {
        try sensitive.run("""
            INSERT INTO loss_declaration_records
              (id, pregnancy_record_original_id, declared_at, approximate_date, gestational_stage,
               free_text_note, data_disposition, fertility_treatment_context, \(Rows.provColumns), \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(declaration.id), .text(declaration.pregnancyRecordOriginalId), .date(declaration.declaredAt),
             .date(declaration.approximateDate), .string(declaration.gestationalStage?.rawValue),
             .string(declaration.freeTextNote), .text(declaration.dataDisposition.rawValue),
             .bool(declaration.fertilityTreatmentContext)]
            + Rows.provParams(declaration.provenance)
            + Rows.convParams(updatedAt: declaration.updatedAt, originDeviceId: declaration.originDeviceId,
                              deletedAt: declaration.deletedAt))
    }

    /// Every live loss declaration for one journey (ordinarily zero or one — a journey is declared
    /// lost once — but this deliberately does not assume that, the same "degrade gracefully on
    /// malformed data" posture `ContraceptiveContextRepository.activeContext` documents for its own
    /// at-most-one case).
    func liveDeclarations(pregnancyRecordOriginalId: String) throws -> [LossDeclarationRecord] {
        try sensitive.query("""
            SELECT * FROM loss_declaration_records
            WHERE pregnancy_record_original_id = ? AND deleted_at IS NULL
            ORDER BY declared_at DESC;
            """, [.text(pregnancyRecordOriginalId)]).map(Self.readDeclaration)
    }

    /// Every live loss declaration across every journey — used by purge/count paths.
    func allLiveDeclarations() throws -> [LossDeclarationRecord] {
        try sensitive.query("SELECT * FROM loss_declaration_records WHERE deleted_at IS NULL ORDER BY declared_at DESC;")
            .map(Self.readDeclaration)
    }

    /// Transitions `data_disposition` only — never touches `approximate_date`/`gestational_stage`/
    /// `free_text_note`/the declaration's other facts, mirroring
    /// `CycleAnomalyEventRepository.updateState`'s one-column-transition shape exactly.
    func updateDataDisposition(id: String, disposition: LossDataDisposition, at date: Date) throws {
        try sensitive.run("UPDATE loss_declaration_records SET data_disposition = ?, updated_at = ? WHERE id = ?;",
                          [.text(disposition.rawValue), .date(date), .text(id)])
    }

    /// Independent deletion — tombstones this ONE declaration without touching the `PregnancyRecord`
    /// chain it references (research doc §9: independently deletable).
    func deleteRecord(id: String, at date: Date) throws {
        try sensitive.run("UPDATE loss_declaration_records SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
                          [.date(date), .date(date), .text(id)])
    }

    /// Single-row lookup by id (tombstone or not) — used by the composition layer to resolve a
    /// declaration's `pregnancyRecordOriginalId` before a disposition change that needs it (turning
    /// `.delete` into a real scoped purge — `PregnancyModuleServices.updateLossDataDisposition`).
    func declaration(id: String) throws -> LossDeclarationRecord? {
        try sensitive.query("SELECT * FROM loss_declaration_records WHERE id = ?;", [.text(id)])
            .first.map(Self.readDeclaration)
    }

    /// Real, hard deletion of every declaration (live or already tombstoned) belonging to ONE
    /// journey — the "Delete" data-disposition's actual erasure, scoped by
    /// `pregnancyRecordOriginalId`. Distinct from `deleteRecord`, which only tombstones ONE
    /// declaration by its own `id`. Used by `PregnancyModuleServices.purgeJourneyData(originalId:)`
    /// (general audit finding 1). A DIFFERENT journey's declarations are untouched.
    func purgeChain(pregnancyRecordOriginalId: String) throws {
        try sensitive.run("DELETE FROM loss_declaration_records WHERE pregnancy_record_original_id = ?;",
                          [.text(pregnancyRecordOriginalId)])
    }

    static func readDeclaration(_ r: SQLiteRow) -> LossDeclarationRecord {
        LossDeclarationRecord(
            id: r.requireString("id"),
            pregnancyRecordOriginalId: r.requireString("pregnancy_record_original_id"),
            declaredAt: r.requireDate("declared_at"),
            approximateDate: r.requireDate("approximate_date"),
            gestationalStage: r.string("gestational_stage").flatMap(LossGestationalStage.init(rawValue:)),
            freeTextNote: r.string("free_text_note"),
            dataDisposition: LossDataDisposition(rawValue: r.requireString("data_disposition")) ?? .keep,
            fertilityTreatmentContext: r.bool("fertility_treatment_context"),
            provenance: Rows.readProvenance(r),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
