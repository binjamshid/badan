import Foundation

/// Why a template write was refused. These are user-facing conditions, not programming errors:
/// the Export Center surfaces them as "that name is taken" / "presets can't be edited".
enum ExportTemplateError: Error, Equatable {
    case nameTaken(String)
    case presetIsReadOnly(id: String)
    case notFound(id: String)
}

/// `export_templates` (migration v4, plan §9.3) — saved export configurations.
///
/// Soft-delete only (`deleted_at`), like every other convention-column table: a deleted template
/// still has `ExportRun` rows pointing at it, and hard-deleting the row would leave the trust
/// ledger unable to say what those runs exported.
final class ExportTemplateRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // MARK: - Writes

    /// Insert a new template.
    ///
    /// The name check and the insert run in one transaction because `idx_export_templates_name`
    /// is the real enforcement and it raises a bare SQLite constraint error — accurate, but not
    /// something a settings screen can turn into a sentence. Checking first lets the caller get
    /// `nameTaken`; doing both in a transaction stops the check from being decorative.
    func insert(_ template: ExportTemplate) throws {
        try db.transaction {
            guard try isNameAvailable(template.name, excludingId: nil) else {
                throw ExportTemplateError.nameTaken(template.name)
            }
            try write(template)
        }
    }

    /// Update an existing template in place.
    ///
    /// Presets are refused here rather than in the UI: §12 EPIC-10 makes them read-only, and a
    /// rule enforced only by a disabled button is a rule that a Shortcut, an intent or a future
    /// screen can walk around.
    func update(_ template: ExportTemplate) throws {
        guard !template.isPreset else { throw ExportTemplateError.presetIsReadOnly(id: template.id) }
        try db.transaction {
            guard try self.template(id: template.id) != nil else {
                throw ExportTemplateError.notFound(id: template.id)
            }
            guard try isNameAvailable(template.name, excludingId: template.id) else {
                throw ExportTemplateError.nameTaken(template.name)
            }
            try write(template)
        }
    }

    /// Tombstone a template. Its `ExportRun` history and `ExportCursor` rows are left alone —
    /// the run log is a record of what happened, not a view over what currently exists.
    func softDelete(id: String, at date: Date) throws {
        guard !QuickExportPreset.presetIds.contains(id) else {
            throw ExportTemplateError.presetIsReadOnly(id: id)
        }
        let changed = try db.run(
            "UPDATE export_templates SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
            [.date(date), .date(date), .text(id)])
        guard changed > 0 else { throw ExportTemplateError.notFound(id: id) }
    }

    /// Seed the Quick Export presets, returning how many rows were actually inserted.
    ///
    /// `INSERT OR IGNORE` makes this idempotent across every launch: the fixed preset ids
    /// (`QuickExportPreset.id`) collide with the primary key on the second call and nothing
    /// happens. Returning the count rather than `Void` is the honest part — `OR IGNORE` also
    /// swallows a *name* collision with a user-created template called "Quick Export — Last 7
    /// days (CSV)", in which case that preset silently does not exist. A caller comparing the
    /// count against `QuickExportPreset.allCases.count` on a first run can notice; a caller
    /// ignoring the return value gets the old behavior of not noticing.
    @discardableResult
    func seedPresets(now: Date, originDeviceId: String) throws -> Int {
        try db.transaction {
            let before = try seededPresetCount()
            for preset in QuickExportPreset.allCases {
                try write(preset.template(now: now, originDeviceId: originDeviceId),
                          conflictPolicy: "OR IGNORE")
            }
            return try seededPresetCount() - before
        }
    }

    /// How many presets currently exist as rows. Counted with a SELECT rather than by summing
    /// `sqlite3_changes` across the inserts: an `INSERT OR IGNORE` that is ignored is not
    /// distinguishable from one that inserted by row-count alone in every SQLite version, and
    /// this count is the number `seedPresets` reports to a caller deciding whether a preset is
    /// missing.
    private func seededPresetCount() throws -> Int {
        let placeholders = Array(repeating: "?", count: QuickExportPreset.allCases.count).joined(separator: ", ")
        return try db.query("SELECT COUNT(*) AS c FROM export_templates WHERE id IN (\(placeholders));",
                            QuickExportPreset.allCases.map { .text($0.id) })
            .first?.intValue("c") ?? 0
    }

    /// The single INSERT. `OR REPLACE` for ordinary writes (id is the ULID the caller already
    /// holds, so a replace is an update of the same row); `OR IGNORE` for seeding.
    @discardableResult
    private func write(_ t: ExportTemplate, conflictPolicy: String = "OR REPLACE") throws -> Int {
        try db.run("""
            INSERT \(conflictPolicy) INTO export_templates
              (id, name, scope, range_rule, format, aggregation, aggregation_method, layout,
               include_schema_docs, destination_id, created_at, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(t.id), .text(t.name), .text(try JSONCoding.encodeOrThrow(t.scope)),
             .text(t.rangeRule.storageValue), .text(t.format.rawValue),
             .text(t.aggregation.storageGranularity), .string(t.aggregation.storageMethod),
             .text(t.layout.rawValue), .bool(t.includeSchemaDocs), .string(t.destinationId),
             .date(t.createdAt)]
            + Rows.convParams(updatedAt: t.updatedAt, originDeviceId: t.originDeviceId,
                              deletedAt: t.deletedAt))
    }

    // MARK: - Reads

    /// Live templates, presets first then by name — Quick Export's row is the one a casual user
    /// is looking for, and burying it under alphabetically-earlier user templates would defeat
    /// the "≤3 taps" goal of §12 EPIC-10.
    func all() throws -> [ExportTemplate] {
        try db.query("SELECT * FROM export_templates WHERE deleted_at IS NULL ORDER BY created_at ASC, name ASC;")
            .map(Self.read)
    }

    func template(id: String) throws -> ExportTemplate? {
        try db.query("SELECT * FROM export_templates WHERE id = ? AND deleted_at IS NULL;", [.text(id)])
            .first.map(Self.read)
    }

    func template(named name: String) throws -> ExportTemplate? {
        try db.query("SELECT * FROM export_templates WHERE name = ? AND deleted_at IS NULL;", [.text(name)])
            .first.map(Self.read)
    }

    /// Mirrors the partial unique index exactly — including `deleted_at IS NULL`, so a name
    /// freed by deleting a template is offered back to the user rather than staying reserved by
    /// a row they can no longer see.
    func isNameAvailable(_ name: String, excludingId: String?) throws -> Bool {
        let rows = try db.query(
            "SELECT id FROM export_templates WHERE name = ? AND deleted_at IS NULL;", [.text(name)])
        guard let existing = rows.first?.string("id") else { return true }
        return existing == excludingId
    }

    static func read(_ r: SQLiteRow) -> ExportTemplate {
        ExportTemplate(
            id: r.requireString("id"),
            name: r.requireString("name"),
            // A scope that fails to decode falls back to `.everything`, matching
            // `ExportJobRepository.read`. Note what "everything" does *not* include: its
            // `includeSensitive` and `includeSuppressed` are both false, so a corrupted row can
            // only ever widen toward raw+derived, never toward the sensitive namespace.
            scope: JSONCoding.decode(ExportScope.self, from: r.string("scope")) ?? .everything,
            rangeRule: ExportRangeRule(storageValue: r.requireString("range_rule")),
            format: ExportFormat(rawValue: r.requireString("format")) ?? .csv,
            aggregation: .from(granularity: r.requireString("aggregation"),
                               method: r.string("aggregation_method")),
            layout: ExportLayout(rawValue: r.requireString("layout")) ?? .tidy,
            includeSchemaDocs: r.bool("include_schema_docs"),
            destinationId: r.string("destination_id"),
            createdAt: r.requireDate("created_at"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
