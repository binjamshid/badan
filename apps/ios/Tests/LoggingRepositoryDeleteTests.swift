import XCTest
@testable import BADAN

/// The tombstone-delete path (ledger #34 / dossier "No manual log can be edited or deleted
/// anywhere in the app"). `deleteRegimen`/`deleteSymptom` already existed with zero callers and
/// zero tests; `deleteAdherence`/`deleteNutrition`/`deleteNote` are new, added to back the three
/// `TimelineEvent` kinds `TimelineAssembler` already marks `deletable: true` (medication ==
/// adherence event, meal == nutrition entry, note). Every case here asserts the ADR-0003
/// tombstone contract: `deleted_at` is set, `updated_at` moves with it, and every reader query
/// (which already filters `WHERE deleted_at IS NULL`) stops returning the row — a soft delete
/// that behaves like a delete from every existing call site's point of view.
final class LoggingRepositoryDeleteTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    var repo: LoggingRepository!
    let now = Date(timeIntervalSince1970: 1_783_000_000)
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-logging-delete-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
        repo = LoggingRepository(main: db.main, sensitive: db.sensitive)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Medication regimen (pre-existing, previously untested)

    func testDeleteRegimenTombstonesAndHidesFromReads() throws {
        let regimen = MedicationRegimen(id: ULID.newID(), name: "Vitamin D", schedule: .daily(times: ["08:00"]),
                                        startedAt: now, updatedAt: now, originDeviceId: deviceId)
        try repo.upsertRegimen(regimen)
        XCTAssertEqual(try repo.regimens().count, 1)

        try repo.deleteRegimen(id: regimen.id, at: now.addingTimeInterval(60))

        XCTAssertTrue(try repo.regimens().isEmpty, "a deleted regimen must not appear in the active list")
        XCTAssertNil(try repo.regimen(id: regimen.id), "a deleted regimen must not be individually readable either")
    }

    // MARK: - Symptom entry (pre-existing, previously untested)

    func testDeleteSymptomTombstonesAndHidesFromReads() throws {
        let symptom = SymptomEntry(id: ULID.newID(), symptomId: "headache", severity: 4,
                                   occurredAt: now, tzId: "UTC", updatedAt: now, originDeviceId: deviceId)
        try repo.insertSymptom(symptom)
        XCTAssertEqual(try repo.allSymptoms().count, 1)

        try repo.deleteSymptom(id: symptom.id, at: now.addingTimeInterval(60))

        XCTAssertTrue(try repo.allSymptoms().isEmpty)
        XCTAssertTrue(try repo.symptoms(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600)).isEmpty)
    }

    // MARK: - Adherence event (new — backs the Timeline `.medication` row)

    func testDeleteAdherenceTombstonesAndHidesFromReads() throws {
        let regimen = MedicationRegimen(id: ULID.newID(), name: "Metformin", schedule: .daily(times: ["08:00"]),
                                        startedAt: now, updatedAt: now, originDeviceId: deviceId)
        try repo.upsertRegimen(regimen)
        let event = AdherenceEvent(id: ULID.newID(), regimenId: regimen.id, kind: .taken,
                                   occurredAt: now, tzId: "UTC", updatedAt: now, originDeviceId: deviceId)
        try repo.insertAdherence(event)
        XCTAssertEqual(try repo.adherence(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60)).count, 1)

        try repo.deleteAdherence(id: event.id, at: now.addingTimeInterval(60))

        XCTAssertTrue(try repo.adherence(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(120)).isEmpty)
        XCTAssertTrue(try repo.adherence(regimenId: regimen.id, from: now.addingTimeInterval(-60), to: now.addingTimeInterval(120)).isEmpty)
    }

    /// The updated_at column must actually move with the tombstone — a stale `updated_at` on a
    /// soft-deleted row would be indistinguishable from "never touched" to a future sync
    /// consumer reading ADR-0003's columns.
    func testDeleteAdherenceUpdatesTheUpdatedAtColumn() throws {
        let regimen = MedicationRegimen(id: ULID.newID(), name: "Metformin", schedule: .daily(times: ["08:00"]),
                                        startedAt: now, updatedAt: now, originDeviceId: deviceId)
        try repo.upsertRegimen(regimen)
        let event = AdherenceEvent(id: ULID.newID(), regimenId: regimen.id, kind: .taken,
                                   occurredAt: now, tzId: "UTC", updatedAt: now, originDeviceId: deviceId)
        try repo.insertAdherence(event)

        let deletedAt = now.addingTimeInterval(3_600)
        try repo.deleteAdherence(id: event.id, at: deletedAt)

        let row = try db.sensitive.query("SELECT deleted_at, updated_at FROM adherence_events WHERE id = ?;", [.text(event.id)]).first
        XCTAssertEqual(row?.date("deleted_at"), deletedAt)
        XCTAssertEqual(row?.date("updated_at"), deletedAt)
    }

    // MARK: - Nutrition entry (new — backs the Timeline `.meal` row)

    func testDeleteNutritionTombstonesAndHidesFromReads() throws {
        let entry = NutritionEntry(id: ULID.newID(), description: "Oatmeal", mealType: .breakfast,
                                   energyKcal: 300, occurredAt: now, tzId: "UTC", updatedAt: now, originDeviceId: deviceId)
        try repo.upsertNutrition(entry)
        XCTAssertEqual(try repo.nutrition(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60)).count, 1)

        try repo.deleteNutrition(id: entry.id, at: now.addingTimeInterval(60))

        XCTAssertTrue(try repo.nutrition(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(120)).isEmpty)
    }

    // MARK: - Note entry (new — backs the Timeline `.note` row)

    func testDeleteNoteTombstonesAndHidesFromReads() throws {
        let note = NoteEntry(id: ULID.newID(), text: "Felt better after a walk", occurredAt: now,
                             tzId: "UTC", updatedAt: now, originDeviceId: deviceId)
        try repo.upsertNote(note)
        XCTAssertEqual(try repo.notes(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60)).count, 1)

        try repo.deleteNote(id: note.id, at: now.addingTimeInterval(60))

        XCTAssertTrue(try repo.notes(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(120)).isEmpty)
    }

    /// Deleting one row must never touch a sibling row — the exact bug a `WHERE id = ?`-less
    /// tombstone statement would produce.
    func testDeleteOnlyAffectsTheTargetedRow() throws {
        let keep = NoteEntry(id: ULID.newID(), text: "Keep me", occurredAt: now, tzId: "UTC",
                             updatedAt: now, originDeviceId: deviceId)
        let remove = NoteEntry(id: ULID.newID(), text: "Remove me", occurredAt: now, tzId: "UTC",
                               updatedAt: now, originDeviceId: deviceId)
        try repo.upsertNote(keep)
        try repo.upsertNote(remove)

        try repo.deleteNote(id: remove.id, at: now.addingTimeInterval(60))

        let remaining = try repo.notes(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(120))
        XCTAssertEqual(remaining.map(\.id), [keep.id])
    }
}
