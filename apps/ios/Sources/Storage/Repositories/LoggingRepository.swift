import Foundation

/// All structured logging. Meds / symptoms / conditions live in the **sensitive** DB so
/// disabling those modules is a file deletion (D-9). Workouts / nutrition / notes are normal
/// sensitivity and live in the main DB.
final class LoggingRepository {
    private let main: SQLiteConnection
    private let sensitive: SQLiteConnection

    init(main: SQLiteConnection, sensitive: SQLiteConnection) {
        self.main = main
        self.sensitive = sensitive
    }

    /// Run a batch of main-DB writes (this repo's workouts/nutrition/notes, or any other
    /// main-DB repo called from inside `body`) as a single transaction instead of one implicit
    /// commit+fsync per row. Kept separate from `transactionSensitive` because main and
    /// sensitive are different physical database files/connections — a transaction on one
    /// never covers writes to the other (PERF-02 (audit 2026-07-12)).
    @discardableResult
    func transactionMain<T>(_ body: () throws -> T) throws -> T {
        try main.transaction(body)
    }

    /// Run a batch of sensitive-DB writes (medications/symptoms) as a single transaction.
    /// See `transactionMain` for why this is a distinct method (PERF-02 (audit 2026-07-12)).
    @discardableResult
    func transactionSensitive<T>(_ body: () throws -> T) throws -> T {
        try sensitive.transaction(body)
    }

    // MARK: - Medications (sensitive)

    func upsertRegimen(_ r: MedicationRegimen) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO medication_regimens
              (id, name, strength, form, schedule, started_at, ended_at, notes, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(r.id), .text(r.name), .string(r.strength), .string(r.form), .text(JSONCoding.encode(r.schedule)),
             .date(r.startedAt), .date(r.endedAt), .string(r.notes), .date(r.updatedAt), .text(r.originDeviceId), .date(r.deletedAt)])
    }

    func regimens(activeOnly: Bool = false) throws -> [MedicationRegimen] {
        var sql = "SELECT * FROM medication_regimens WHERE deleted_at IS NULL"
        if activeOnly { sql += " AND ended_at IS NULL" }
        sql += " ORDER BY name ASC;"
        return try sensitive.query(sql).map(Self.readRegimen)
    }

    func regimen(id: String) throws -> MedicationRegimen? {
        // WHERE deleted_at IS NULL was missing here — `regimens()` (the list read) already
        // filtered tombstones, but this single-row read didn't, so a deleted regimen fetched by
        // id still came back fully populated. Zero existing callers means nothing depended on
        // the old (wrong) behavior; caught by `LoggingRepositoryDeleteTests`, added for ledger
        // #34's tombstone-delete path.
        try sensitive.query("SELECT * FROM medication_regimens WHERE id = ? AND deleted_at IS NULL;", [.text(id)]).first.map(Self.readRegimen)
    }

    func deleteRegimen(id: String, at date: Date) throws {
        try sensitive.run("UPDATE medication_regimens SET deleted_at = ?, updated_at = ? WHERE id = ?;", [.date(date), .date(date), .text(id)])
    }

    func insertAdherence(_ e: AdherenceEvent) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO adherence_events
              (id, regimen_id, kind, scheduled_for, occurred_at, tz_id, skip_reason, skip_note, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(e.id), .text(e.regimenId), .text(e.kind.rawValue), .date(e.scheduledFor), .date(e.occurredAt),
             .text(e.tzId), .string(e.skipReason?.rawValue), .string(e.skipNote), .date(e.updatedAt), .text(e.originDeviceId), .date(e.deletedAt)])
    }

    func adherence(from: Date, to: Date) throws -> [AdherenceEvent] {
        try sensitive.query("SELECT * FROM adherence_events WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
                            [.date(from), .date(to)]).map(Self.readAdherence)
    }

    func adherence(regimenId: String, from: Date, to: Date) throws -> [AdherenceEvent] {
        try sensitive.query("SELECT * FROM adherence_events WHERE regimen_id = ? AND occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
                            [.text(regimenId), .date(from), .date(to)]).map(Self.readAdherence)
    }

    /// Tombstone-deletes one adherence event (a single take/skip record) — the row backing a
    /// Timeline `.medication` event, which `TimelineAssembler` has always marked `deletable:
    /// true` with no repository method to back it (ledger #34 / dossier "No manual log can be
    /// edited or deleted anywhere in the app"). Same shape as `deleteRegimen`/`deleteSymptom`
    /// above — a tombstone, not a hard delete, so the ADR-0003 sync columns keep meaning.
    func deleteAdherence(id: String, at date: Date) throws {
        try sensitive.run("UPDATE adherence_events SET deleted_at = ?, updated_at = ? WHERE id = ?;", [.date(date), .date(date), .text(id)])
    }

    // MARK: - Symptoms (sensitive)

    func insertSymptom(_ s: SymptomEntry) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO symptom_entries
              (id, symptom_id, custom_label, severity, occurred_at, tz_id, duration_s, body_location, triggers, note, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(s.id), .string(s.symptomId), .string(s.customLabel), .int(s.severity), .date(s.occurredAt),
             .text(s.tzId), .double(s.durationSeconds), .string(s.bodyLocation), .text(JSONCoding.encode(s.triggers)),
             .string(s.note), .date(s.updatedAt), .text(s.originDeviceId), .date(s.deletedAt)])
    }

    func symptoms(from: Date, to: Date) throws -> [SymptomEntry] {
        try sensitive.query("SELECT * FROM symptom_entries WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
                            [.date(from), .date(to)]).map(Self.readSymptom)
    }

    func allSymptoms() throws -> [SymptomEntry] {
        try sensitive.query("SELECT * FROM symptom_entries WHERE deleted_at IS NULL ORDER BY occurred_at DESC;").map(Self.readSymptom)
    }

    func deleteSymptom(id: String, at date: Date) throws {
        try sensitive.run("UPDATE symptom_entries SET deleted_at = ?, updated_at = ? WHERE id = ?;", [.date(date), .date(date), .text(id)])
    }

    // MARK: - Conditions (sensitive)

    func upsertCondition(_ c: Condition) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO conditions
              (id, label, status, onset_at, linked_regimen_ids, linked_symptom_ids, notes, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(c.id), .text(c.label), .text(c.status.rawValue), .date(c.onsetAt),
             .text(JSONCoding.encode(c.linkedRegimenIds)), .text(JSONCoding.encode(c.linkedSymptomIds)),
             .string(c.notes), .date(c.updatedAt), .text(c.originDeviceId), .date(c.deletedAt)])
    }

    func conditions() throws -> [Condition] {
        try sensitive.query("SELECT * FROM conditions WHERE deleted_at IS NULL ORDER BY label ASC;").map { r in
            Condition(id: r.requireString("id"), label: r.requireString("label"),
                      status: ConditionStatus(rawValue: r.requireString("status")) ?? .active, onsetAt: r.date("onset_at"),
                      linkedRegimenIds: JSONCoding.decode([String].self, from: r.string("linked_regimen_ids")) ?? [],
                      linkedSymptomIds: JSONCoding.decode([String].self, from: r.string("linked_symptom_ids")) ?? [],
                      notes: r.string("notes"), updatedAt: r.requireDate("updated_at"),
                      originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
        }
    }

    // MARK: - Workouts (main)

    func upsertWorkout(_ w: WorkoutEntry) throws {
        try main.run("""
            INSERT OR REPLACE INTO workout_entries
              (id, activity_type, start_at, end_at, tz_id, energy_kcal, distance_m, avg_hr, max_hr, perceived_effort, note, ingestion_path, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(w.id), .text(w.activityType), .date(w.startAt), .date(w.endAt), .text(w.tzId),
             .double(w.energyKcal), .double(w.distanceM), .double(w.avgHr), .double(w.maxHr), .int(w.perceivedEffort),
             .string(w.note), .text(w.ingestionPath.rawValue), .date(w.updatedAt), .text(w.originDeviceId), .date(w.deletedAt)])
    }

    func workouts(from: Date, to: Date) throws -> [WorkoutEntry] {
        try main.query("SELECT * FROM workout_entries WHERE start_at >= ? AND start_at <= ? AND deleted_at IS NULL ORDER BY start_at DESC;",
                       [.date(from), .date(to)]).map(Self.readWorkout)
    }

    // MARK: - Nutrition (main)

    func upsertNutrition(_ n: NutritionEntry) throws {
        try main.run("""
            INSERT OR REPLACE INTO nutrition_entries
              (id, description, meal_type, energy_kcal, protein_g, carbs_g, fat_g, fiber_g, water_ml, caffeine_mg, low_detail, occurred_at, tz_id, note, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(n.id), .text(n.description), .text(n.mealType.rawValue), .double(n.energyKcal), .double(n.proteinG),
             .double(n.carbsG), .double(n.fatG), .double(n.fiberG), .double(n.waterMl), .double(n.caffeineMg),
             .bool(n.lowDetail), .date(n.occurredAt), .text(n.tzId), .string(n.note), .date(n.updatedAt),
             .text(n.originDeviceId), .date(n.deletedAt)])
    }

    func nutrition(from: Date, to: Date) throws -> [NutritionEntry] {
        try main.query("SELECT * FROM nutrition_entries WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
                       [.date(from), .date(to)]).map(Self.readNutrition)
    }

    /// Tombstone-deletes one nutrition entry — backs the Timeline `.meal` event's `deletable:
    /// true` (ledger #34).
    func deleteNutrition(id: String, at date: Date) throws {
        try main.run("UPDATE nutrition_entries SET deleted_at = ?, updated_at = ? WHERE id = ?;", [.date(date), .date(date), .text(id)])
    }

    // MARK: - Notes (main)

    func upsertNote(_ note: NoteEntry) throws {
        try main.run("INSERT OR REPLACE INTO note_entries (id, text, occurred_at, tz_id, tags, updated_at, origin_device_id, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                     [.text(note.id), .text(note.text), .date(note.occurredAt), .text(note.tzId),
                      .text(JSONCoding.encode(note.tags)), .date(note.updatedAt), .text(note.originDeviceId), .date(note.deletedAt)])
    }

    func notes(from: Date, to: Date) throws -> [NoteEntry] {
        try main.query("SELECT * FROM note_entries WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
                       [.date(from), .date(to)]).map { r in
            NoteEntry(id: r.requireString("id"), text: r.requireString("text"), occurredAt: r.requireDate("occurred_at"),
                      tzId: r.requireString("tz_id"), tags: JSONCoding.decode([String].self, from: r.string("tags")) ?? [],
                      updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
        }
    }

    /// Tombstone-deletes one note — backs the Timeline `.note` event's `deletable: true`
    /// (ledger #34).
    func deleteNote(id: String, at date: Date) throws {
        try main.run("UPDATE note_entries SET deleted_at = ?, updated_at = ? WHERE id = ?;", [.date(date), .date(date), .text(id)])
    }

    // MARK: - Readers

    static func readRegimen(_ r: SQLiteRow) -> MedicationRegimen {
        MedicationRegimen(id: r.requireString("id"), name: r.requireString("name"), strength: r.string("strength"),
                          form: r.string("form"),
                          schedule: JSONCoding.decode(MedicationSchedule.self, from: r.string("schedule")) ?? .asNeeded,
                          startedAt: r.requireDate("started_at"), endedAt: r.date("ended_at"), notes: r.string("notes"),
                          updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
                          deletedAt: r.date("deleted_at"))
    }

    static func readAdherence(_ r: SQLiteRow) -> AdherenceEvent {
        AdherenceEvent(id: r.requireString("id"), regimenId: r.requireString("regimen_id"),
                       kind: AdherenceKind(rawValue: r.requireString("kind")) ?? .taken, scheduledFor: r.date("scheduled_for"),
                       occurredAt: r.requireDate("occurred_at"), tzId: r.requireString("tz_id"),
                       skipReason: r.string("skip_reason").flatMap { SkipReason(rawValue: $0) }, skipNote: r.string("skip_note"),
                       updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }

    static func readSymptom(_ r: SQLiteRow) -> SymptomEntry {
        SymptomEntry(id: r.requireString("id"), symptomId: r.string("symptom_id"), customLabel: r.string("custom_label"),
                     severity: r.intValue("severity") ?? 0, occurredAt: r.requireDate("occurred_at"), tzId: r.requireString("tz_id"),
                     durationSeconds: r.double("duration_s"), bodyLocation: r.string("body_location"),
                     triggers: JSONCoding.decode([String].self, from: r.string("triggers")) ?? [], note: r.string("note"),
                     updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }

    static func readWorkout(_ r: SQLiteRow) -> WorkoutEntry {
        WorkoutEntry(id: r.requireString("id"), activityType: r.requireString("activity_type"),
                     startAt: r.requireDate("start_at"), endAt: r.requireDate("end_at"), tzId: r.requireString("tz_id"),
                     energyKcal: r.double("energy_kcal"), distanceM: r.double("distance_m"), avgHr: r.double("avg_hr"),
                     maxHr: r.double("max_hr"), perceivedEffort: r.intValue("perceived_effort"), note: r.string("note"),
                     ingestionPath: IngestionPath(rawValue: r.requireString("ingestion_path")) ?? .manual,
                     updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }

    static func readNutrition(_ r: SQLiteRow) -> NutritionEntry {
        NutritionEntry(id: r.requireString("id"), description: r.requireString("description"),
                       mealType: MealType(rawValue: r.requireString("meal_type")) ?? .snack, energyKcal: r.double("energy_kcal"),
                       proteinG: r.double("protein_g"), carbsG: r.double("carbs_g"), fatG: r.double("fat_g"), fiberG: r.double("fiber_g"),
                       waterMl: r.double("water_ml"), caffeineMg: r.double("caffeine_mg"), lowDetail: r.bool("low_detail"),
                       occurredAt: r.requireDate("occurred_at"), tzId: r.requireString("tz_id"), note: r.string("note"),
                       updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }
}
