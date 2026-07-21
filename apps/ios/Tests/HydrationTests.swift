import XCTest
@testable import BADAN

/// EPIC-38 hydration DATA + LOGIC core. Covers the four acceptance criteria: an append-first ledger
/// with auditable revisions; no-goal as an equal-status default; a goal snapshot that survives a goal
/// change; and a default export that structurally redacts notes and contexts. Plus Arabic volume
/// parsing (§7A.1) and the v7 schema shape.
final class HydrationTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-hydration-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func repo() -> HydrationRepository { HydrationRepository(main: db.main) }

    /// Manual provenance for a logged drink — `ingestion_path=manual`, as every user-entered fact is.
    private func manualProvenance(at date: Date, tz: String = "Asia/Riyadh") -> Provenance {
        Provenance(sourceId: "badan.manual", ingestionPath: .manual, measuredAt: date,
                   measuredTimezone: tz, recordedAt: date, ingestedAt: date)
    }

    private func makeEntry(id: String, ml: Double, at date: Date, tz: String = "Asia/Riyadh",
                           fluid: String = "water", note: String? = nil) -> HydrationEntry {
        HydrationLedger.makeEntry(id: id, volumeMl: ml, fluidType: fluid, occurredAt: date, tzId: tz,
                                  note: note, provenance: manualProvenance(at: date, tz: tz),
                                  updatedAt: date, originDeviceId: device)
    }

    // MARK: - Arabic volume parsing (§7A.1, mL canonical)

    func testVolumeParsingFoldsArabicNumeralsToCanonicalMl() {
        XCTAssertEqual(HydrationLedger.parseVolumeMl("500"), 500)
        XCTAssertEqual(HydrationLedger.parseVolumeMl("٥٠٠"), 500, "Eastern Arabic-Indic digits must parse")
        XCTAssertEqual(HydrationLedger.parseVolumeMl("۵۰۰"), 500, "Extended Arabic-Indic digits must parse")
        XCTAssertEqual(HydrationLedger.parseVolumeMl("1٫5"), 1.5, "Arabic decimal separator must parse")
        XCTAssertEqual(HydrationLedger.parseVolumeMl("2,5"), 2.5, "comma decimal must parse")
    }

    func testVolumeParsingRejectsNonPositiveAndJunk() {
        XCTAssertNil(HydrationLedger.parseVolumeMl("0"), "a drink with no volume is a mistake, not a log")
        XCTAssertNil(HydrationLedger.parseVolumeMl("-250"))
        XCTAssertNil(HydrationLedger.parseVolumeMl("abc"))
        XCTAssertNil(HydrationLedger.parseVolumeMl(""))
    }

    // MARK: - Append-first ledger with auditable revisions (pure)

    func testLiveEntriesRevisionSupersedesOriginal() {
        let t = clock.now()
        let a = makeEntry(id: "A", ml: 250, at: t)
        let b = makeEntry(id: "B", ml: 500, at: t)
        // Revise A -> A2 (500 mL). Append-only: A stays, A2 supersedes it.
        let a2 = HydrationLedger.makeRevision(of: a, id: "A2", volumeMl: 500,
                                              provenance: manualProvenance(at: t), updatedAt: t, originDeviceId: device)
        XCTAssertEqual(a2.originalId, "A", "a revision keeps the chain's stable identity")
        XCTAssertEqual(a2.supersedes, "A")
        XCTAssertEqual(a2.revision, 2)

        let live = HydrationLedger.liveEntries([a, a2, b])
        XCTAssertEqual(Set(live.map(\.id)), ["A2", "B"], "the revision is live, the original is superseded")
    }

    func testUndoOfARevisionRevertsToThePriorVersion() {
        let t = clock.now()
        let a = makeEntry(id: "A", ml: 250, at: t)
        let a2 = HydrationLedger.makeRevision(of: a, id: "A2", volumeMl: 500,
                                              provenance: manualProvenance(at: t), updatedAt: t, originDeviceId: device)
        // Undo the revision: tombstone A2. A is no longer superseded by a *non-deleted* row -> live again.
        var deletedA2 = a2; deletedA2.deletedAt = t
        let live = HydrationLedger.liveEntries([a, deletedA2])
        XCTAssertEqual(live.map(\.id), ["A"], "undoing a revision reverts to the prior version")
        XCTAssertEqual(live.first?.volumeMl, 250)
    }

    func testDeletingAWholeChainLeavesNothingLive() {
        let t = clock.now()
        let a = makeEntry(id: "A", ml: 250, at: t)
        let a2 = HydrationLedger.makeRevision(of: a, id: "A2", volumeMl: 500,
                                              provenance: manualProvenance(at: t), updatedAt: t, originDeviceId: device)
        // Delete = tombstone every row in the chain.
        var da = a; da.deletedAt = t
        var da2 = a2; da2.deletedAt = t
        XCTAssertTrue(HydrationLedger.liveEntries([da, da2]).isEmpty, "deleting the chain removes the entry")
    }

    // MARK: - Ledger through the repository (revise/undo/backdate/delete)

    func testRepositoryReviseUndoDeleteRoundTrip() throws {
        let r = repo()
        let now = clock.now()
        let day = GoalEngine.dayKey(for: now, tzId: "Asia/Riyadh")

        let a = makeEntry(id: "A", ml: 250, at: now)
        try r.insertEntry(a)
        XCTAssertEqual(try r.liveEntries(from: .distantPast, to: .distantFuture).map(\.id), ["A"])

        // Revise A -> A2 via the live head.
        let head = try XCTUnwrap(r.liveEntry(originalId: "A"))
        let a2 = HydrationLedger.makeRevision(of: head, id: "A2", volumeMl: 750,
                                              provenance: manualProvenance(at: now), updatedAt: now, originDeviceId: device)
        try r.insertEntry(a2)
        XCTAssertEqual(try r.liveEntries(from: .distantPast, to: .distantFuture).map(\.volumeMl), [750],
                       "the live head is the revision")
        XCTAssertEqual(try r.history(originalId: "A").count, 2, "the full audit chain is preserved")

        // Undo the revision -> reverts to the original.
        try r.undoEntry(id: "A2", at: now)
        XCTAssertEqual(try r.liveEntries(from: .distantPast, to: .distantFuture).map(\.volumeMl), [250])

        // Delete the whole chain -> nothing live, history still intact (tombstoned, not removed).
        try r.deleteEntry(originalId: "A", at: now)
        XCTAssertTrue(try r.liveEntries(from: .distantPast, to: .distantFuture).isEmpty)
        let chain = try r.history(originalId: "A")
        XCTAssertEqual(chain.count, 2, "delete tombstones the existing rows; it never hard-deletes them")
        XCTAssertTrue(chain.allSatisfy { $0.deletedAt != nil }, "every row in a deleted chain carries a tombstone")
        _ = day
    }

    func testBackdatedEntryLandsInThePastDaySummary() throws {
        let r = repo()
        let now = clock.now()
        let yesterday = now.addingTimeInterval(-86_400)
        let yKey = GoalEngine.dayKey(for: yesterday, tzId: "Asia/Riyadh")

        try r.insertEntry(makeEntry(id: "Y", ml: 400, at: yesterday))
        let summary = try r.recomputeSummary(dayKey: yKey, tzId: "Asia/Riyadh", now: now, originDeviceId: device)
        XCTAssertEqual(summary.manualMl, 400, "a backdated drink counts on the day it occurred")
        XCTAssertEqual(summary.entryCount, 1)
    }

    // MARK: - No-goal is an equal-status default

    func testNoGoalSummaryHasNoProgressPercentage() {
        let s = HydrationDailySummary(dayKey: "2026-07-21", tzId: "Asia/Riyadh", manualMl: 1200,
                                      entryCount: 3, goalKind: .none, updatedAt: clock.now(), originDeviceId: device)
        XCTAssertNil(s.goalProgressPct, "a no-goal day must never render a percentage of nothing")
        XCTAssertEqual(s.totalMl, 1200)
    }

    func testResolveGoalTreatsNoActiveGoalAsNoGoal() {
        XCTAssertNil(GoalEngine.resolveGoal(dayType: nil, from: []), "no active goal resolves to no-goal")
        let none = HydrationGoal.noGoal(id: "G", createdAt: clock.now(), updatedAt: clock.now(), originDeviceId: device)
        XCTAssertFalse(none.hasTarget, "an explicit no-goal has no target and is equal-status, not unset")
    }

    // MARK: - Goal snapshot survives a goal change

    func testGoalSnapshotIsFrozenAcrossAGoalChange_engine() {
        let day = "2026-06-01"
        let live = [makeEntry(id: "X", ml: 500, at: clock.now())]
        let goal2000 = HydrationGoal(id: "g1", kind: .manual, targetMl: 2000, createdAt: clock.now(),
                                     updatedAt: clock.now(), originDeviceId: device)
        let first = GoalEngine.makeSummary(dayKey: day, tzId: "Asia/Riyadh", liveEntries: live,
                                           resolvedGoal: goal2000, existing: nil, at: clock.now(), originDeviceId: device)
        XCTAssertEqual(first.goalTargetMl, 2000)

        // Goal later raised to 2500; recomputing the SAME already-summarized day must keep 2000.
        let goal2500 = HydrationGoal(id: "g2", kind: .manual, targetMl: 2500, createdAt: clock.now(),
                                     updatedAt: clock.now(), originDeviceId: device)
        let recomputed = GoalEngine.makeSummary(dayKey: day, tzId: "Asia/Riyadh", liveEntries: live,
                                                resolvedGoal: goal2500, existing: first, at: clock.now(), originDeviceId: device)
        XCTAssertEqual(recomputed.goalTargetMl, 2000, "the snapshot is frozen — history stays honest after a goal change")
    }

    func testGoalSnapshotIsFrozenAcrossAGoalChange_repository() throws {
        let r = repo()
        let now = clock.now()
        let key = GoalEngine.dayKey(for: now, tzId: "Asia/Riyadh")
        try r.insertEntry(makeEntry(id: "A", ml: 500, at: now))

        try r.upsertGoal(HydrationGoal(id: "g1", kind: .manual, targetMl: 2000, createdAt: now, updatedAt: now, originDeviceId: device))
        let first = try r.recomputeSummary(dayKey: key, tzId: "Asia/Riyadh", now: now, originDeviceId: device)
        XCTAssertEqual(first.goalTargetMl, 2000)

        // Change the goal, then recompute WITHOUT forcing a re-snapshot -> frozen at 2000.
        try r.deactivateGoals(dayType: nil, at: now)
        try r.upsertGoal(HydrationGoal(id: "g2", kind: .manual, targetMl: 2500, createdAt: now, updatedAt: now, originDeviceId: device))
        let frozen = try r.recomputeSummary(dayKey: key, tzId: "Asia/Riyadh", now: now, originDeviceId: device)
        XCTAssertEqual(frozen.goalTargetMl, 2000, "an ordinary recompute preserves the frozen snapshot")

        // Only an explicit force (the user edited today's goal) re-snapshots.
        let refreshed = try r.recomputeSummary(dayKey: key, tzId: "Asia/Riyadh", now: now, originDeviceId: device, forceGoalResnapshot: true)
        XCTAssertEqual(refreshed.goalTargetMl, 2500, "a forced re-snapshot adopts the current goal")
    }

    // MARK: - Export redaction proven

    private func bundleString(_ payload: HydrationExportPayload, policy: HydrationRedactionPolicy) throws -> String {
        let manifest = ExportManifest(
            exportId: "exp", schemaVersion: "0.1.0", appVersion: "1.0", platform: "iOS",
            generatedAt: clock.now(), scope: ExportScope(includeRaw: true, includeDerived: true,
                                                         includeSuppressed: false, includeSensitive: false),
            dateRange: "all", displayLanguage: "en", unitProfile: "canonical",
            timezonePolicy: "x", dedupPolicy: "y", perMetricRowCounts: [:], checksums: [:],
            dataQualityNote: "z", sampleDataRowCount: 0)
        let data = try JSONBundleWriter().data(
            manifest: manifest, rawSamples: [], intervalRecords: [], sessions: [], derivedValues: [],
            baselines: [], symptoms: [], adherence: [], workouts: [], nutrition: [],
            hydration: payload, hydrationRedaction: policy)
        return String(decoding: data, as: UTF8.self)
    }

    func testDefaultExportRedactsNotesStructurally() throws {
        let entry = makeEntry(id: "A", ml: 500, at: clock.now(), note: "SECRET-NOTE-TEXT")
        let payload = HydrationExportPayload(entries: [entry])

        let redacted = try bundleString(payload, policy: .default)
        XCTAssertFalse(redacted.contains("SECRET-NOTE-TEXT"), "the note text must never appear in a default export")
        // The `"note"` STRING legitimately appears once — inside the redaction manifest's
        // excluded_by_default list. What must be absent is the note KEY on an entry (`"note":…`).
        XCTAssertFalse(redacted.contains("\"note\":"), "the note key is absent, not blanked (structural redaction)")
        XCTAssertTrue(redacted.contains("\"notes_included\":false"))

        let opted = try bundleString(payload, policy: HydrationRedactionPolicy(includeNotes: true))
        XCTAssertTrue(opted.contains("SECRET-NOTE-TEXT"), "opting in surfaces the note")
        XCTAssertTrue(opted.contains("\"note\":"))
    }

    func testRedactionManifestNamesEveryDefaultExclusion() throws {
        let redacted = try bundleString(HydrationExportPayload(entries: [makeEntry(id: "A", ml: 500, at: clock.now())]), policy: .default)
        for field in ["note", "fasting_context", "cycle_context", "pregnancy_context", "location", "reminder_history"] {
            XCTAssertTrue(redacted.contains("\"\(field)\""), "the redaction manifest must disclose that '\(field)' is excluded")
        }
    }

    func testBundleOmitsHydrationEntirelyWhenPayloadEmpty() throws {
        // The golden-safety guarantee: no hydration payload -> no `hydration` anywhere in the bundle.
        let empty = try bundleString(HydrationExportPayload(), policy: .default)
        XCTAssertFalse(empty.contains("hydration"), "an empty payload adds nothing to the envelope")
    }

    func testHydrationCSVRedactsNotesByDefaultAndOptsIn() {
        let entry = makeEntry(id: "A", ml: 500, at: clock.now(), note: "SECRET-NOTE-TEXT")
        let defaultCSV = HydrationCSVWriter().entriesCSV([entry])
        XCTAssertFalse(defaultCSV.contains("SECRET-NOTE-TEXT"))
        XCTAssertFalse(defaultCSV.contains("note"), "the note column is absent from a default CSV")

        let optedCSV = HydrationCSVWriter(policy: HydrationRedactionPolicy(includeNotes: true)).entriesCSV([entry])
        XCTAssertTrue(optedCSV.contains("SECRET-NOTE-TEXT"))
    }

    func testHydrationSummaryCSVKeepsTotalsSeparateAndNoGoalBlank() {
        let s = HydrationDailySummary(dayKey: "2026-07-21", tzId: "Asia/Riyadh", manualMl: 1000,
                                      entryCount: 2, goalKind: .none, updatedAt: clock.now(), originDeviceId: device)
        let csv = HydrationCSVWriter().summariesCSV([s])
        XCTAssertTrue(csv.contains("manual_ml,imported_ml,estimated_ml,total_ml"), "manual/imported/estimated stay separate")
        // no-goal row leaves goal_target_ml and goal_progress_pct blank (never a fabricated 0)
        let dataLine = csv.components(separatedBy: CSVWriter.newline)[1]
        XCTAssertTrue(dataLine.hasSuffix("none,,"), "a no-goal day leaves target and progress blank, not 0")
    }

    // MARK: - Schema v7 shape

    func testMigrationV7CreatesHydrationTablesWithExpectedColumns() throws {
        func columns(_ table: String) throws -> [String] {
            try db.main.query("PRAGMA table_info(\(table));").map { $0.requireString("name") }
        }
        XCTAssertEqual(try columns("hydration_entries"), [
            "id", "volume_ml", "fluid_type", "beverage_id", "container_id", "occurred_at", "tz_id",
            "note", "original_id", "supersedes", "revision",
            "source_id", "device_id", "ingestion_path", "external_id", "batch_id", "measured_at",
            "measured_tz", "recorded_at", "ingested_at", "algorithm_version_id", "quality_flags", "suppressed_by",
            "updated_at", "origin_device_id", "deleted_at"])
        XCTAssertEqual(try columns("beverage_definitions"), [
            "id", "name_en", "name_ar", "fluid_type", "default_volume_ml", "caffeine_mg_per_100ml",
            "alcohol_pct", "electrolyte_note", "is_builtin", "updated_at", "origin_device_id", "deleted_at"])
        XCTAssertEqual(try columns("container_presets"), [
            "id", "name_en", "name_ar", "volume_ml", "beverage_id", "sort_order", "updated_at", "origin_device_id", "deleted_at"])
        XCTAssertEqual(try columns("hydration_goals"), [
            "id", "kind", "target_ml", "day_type", "active", "created_at", "updated_at", "origin_device_id", "deleted_at"])
        XCTAssertEqual(try columns("hydration_daily_summaries"), [
            "day_key", "tz_id", "manual_ml", "imported_ml", "estimated_ml", "entry_count", "goal_kind",
            "goal_target_ml", "goal_id", "updated_at", "origin_device_id", "deleted_at"])
    }

    // MARK: - Beverage dictionary

    func testBeverageDictionaryIsBilingualAndMetadataOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("packages/contracts/dictionaries/beverages.json")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let note = try XCTUnwrap(json?["note"] as? String)
        XCTAssertTrue(note.contains("DISPLAY METADATA ONLY"), "the dictionary must state the metadata-only rule")
        XCTAssertTrue(note.lowercased().contains("net hydration"), "the dictionary must name the net-hydration reject rule")
        let beverages = try XCTUnwrap(json?["beverages"] as? [[String: Any]])
        XCTAssertTrue(beverages.contains { ($0["id"] as? String) == "water" })
        for b in beverages {
            XCTAssertFalse((b["nameEn"] as? String ?? "").isEmpty, "every beverage carries English")
            XCTAssertFalse((b["nameAr"] as? String ?? "").isEmpty, "every beverage carries Arabic")
        }
    }
}
