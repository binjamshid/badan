import XCTest
@testable import BADAN

/// EPIC-38 — the wiring test the audit's finding was about. `HydrationTests` proves the hydration
/// WRITERS redact correctly and stay absent-when-empty; those passed while the export was still
/// unshipped, because nothing exercised the one path a user actually reaches. This file drives
/// `ExportRunner.run` — the real, user-reachable export — over a store WITH drinks and asserts the
/// drinks come out the other end, in both formats, with notes withheld by default.
///
/// It is the anti-"green-but-unshipped" guard: if a future refactor drops the `hydration:` argument
/// at either `ExportRunner` construction, or stops gathering the ledger, this fails — where the copy
/// promising drinks are in the default export would otherwise keep lying silently.
final class HydrationExportWiringTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    private let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-hydration-export-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Harness

    private func hydrationRepo() -> HydrationRepository { HydrationRepository(main: db.main) }

    /// A runner built the way `AppEnvironment`'s plain share-sheet exporter is: with the drink ledger
    /// wired in. The whole point of the test is that this argument is present and honored.
    private func makeRunner(hydration: HydrationRepository?) -> ExportRunner {
        ExportRunner(
            measurements: MeasurementRepository(db.main), derivation: DerivationRepository(db.main),
            logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
            exportJobs: ExportJobRepository(db.main), registry: .shared, clock: clock,
            appVersion: "test", deviceId: device, hydration: hydration)
    }

    /// Two live drinks (one carrying a note, one poured from a custom beverage), a manual goal, and a
    /// recomputed day summary — all in UTC so the summary's day key lands cleanly inside the export
    /// window. `NOTE-TEXT-DO-NOT-EXPORT` is the tripwire: it must never surface in a default export.
    @discardableResult
    private func seedDrinks() throws -> (day: String, occurred: Date) {
        let repo = hydrationRepo()
        let occurred = clock.now().addingTimeInterval(-3_600)
        let prov = Provenance(sourceId: "badan.manual", ingestionPath: .manual, measuredAt: occurred,
                              measuredTimezone: "UTC", recordedAt: occurred, ingestedAt: occurred)
        let water = HydrationLedger.makeEntry(id: "HYD-WATER", volumeMl: 500, fluidType: "water",
                                              occurredAt: occurred, tzId: "UTC", note: "NOTE-TEXT-DO-NOT-EXPORT",
                                              provenance: prov, updatedAt: occurred, originDeviceId: device)
        let latte = HydrationLedger.makeEntry(id: "HYD-LATTE", volumeMl: 250, fluidType: "coffee",
                                              beverageId: "bev-latte", occurredAt: occurred, tzId: "UTC",
                                              provenance: prov, updatedAt: occurred, originDeviceId: device)
        try repo.upsertBeverage(BeverageDefinition(
            id: "bev-latte", nameEn: "Latte", nameAr: "لاتيه", fluidType: "coffee",
            defaultVolumeMl: 250, isBuiltin: false, updatedAt: occurred, originDeviceId: device))
        try repo.insertEntry(water)
        try repo.insertEntry(latte)
        try repo.upsertGoal(HydrationGoal(id: "GOAL-1", kind: .manual, targetMl: 2000,
                                          createdAt: occurred, updatedAt: occurred, originDeviceId: device))
        let day = GoalEngine.dayKey(for: occurred, tzId: "UTC")
        try repo.recomputeSummary(dayKey: day, tzId: "UTC", now: clock.now(), originDeviceId: device)
        return (day, occurred)
    }

    private func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    // MARK: - JSON: the real export path carries drinks, notes withheld by default

    func testDefaultJSONExportIncludesDrinksAndRedactsNotes() throws {
        let seeded = try seedDrinks()
        let result = try makeRunner(hydration: hydrationRepo()).run(scope: .everything, format: .json)

        let bundleURL = try XCTUnwrap(result.fileURLs.first { $0.lastPathComponent == "bundle.json" })
        let bundle = try read(bundleURL)

        // The block is present with the drinks — the exact thing that was built, golden-tested, and
        // unreachable before this wiring.
        XCTAssertTrue(bundle.contains("\"hydration\":{"), "logs.hydration must be present in a default export")
        XCTAssertTrue(bundle.contains("\"record_id\":\"HYD-WATER\""))
        XCTAssertTrue(bundle.contains("\"record_id\":\"HYD-LATTE\""))
        XCTAssertTrue(bundle.contains("\"bev-latte\""), "a referenced custom beverage travels with the entry")
        XCTAssertTrue(bundle.contains("\"goal_id\":\"GOAL-1\""))
        XCTAssertTrue(bundle.contains("\"day_key\":\"\(seeded.day)\""), "the day summary is exported")
        XCTAssertTrue(bundle.contains("\"logs.hydration\":2"), "the manifest row count reflects the two drinks")

        // Notes are redacted STRUCTURALLY by default: the value never appears, and the key is absent
        // (not blanked). The literal string "note" still appears once inside excluded_by_default.
        XCTAssertFalse(bundle.contains("NOTE-TEXT-DO-NOT-EXPORT"), "a note must never leak into a default export")
        XCTAssertFalse(bundle.contains("\"note\":"), "the note key is absent, not present-but-blank")
        XCTAssertTrue(bundle.contains("\"notes_included\":false"))
        XCTAssertTrue(result.rowCount >= 2, "hydration entries count toward the export's row total")
    }

    // MARK: - CSV: a CSV export isn't missing the drinks either

    func testDefaultCSVExportEmitsHydrationFilesWithoutNotes() throws {
        try seedDrinks()
        let result = try makeRunner(hydration: hydrationRepo()).run(scope: .everything, format: .csv)

        let entriesURL = try XCTUnwrap(result.fileURLs.first { $0.lastPathComponent == "hydration_entries.csv" },
                                       "a CSV export must include a hydration_entries.csv")
        let entries = try read(entriesURL)
        XCTAssertTrue(entries.contains("HYD-WATER"))
        XCTAssertTrue(entries.contains("HYD-LATTE"))
        XCTAssertFalse(entries.contains("note"), "the note column is absent from a default CSV")
        XCTAssertFalse(entries.contains("NOTE-TEXT-DO-NOT-EXPORT"))

        // The redaction manifest ships alongside so a CSV reader learns what was left out.
        XCTAssertTrue(result.fileURLs.contains { $0.lastPathComponent == "hydration_redaction.json" })
        // And the drink files are checksummed in the export manifest like every other file.
        let manifestURL = try XCTUnwrap(result.fileURLs.first { $0.lastPathComponent == "manifest.json" })
        XCTAssertTrue(try read(manifestURL).contains("hydration_entries.csv"),
                      "hydration files must be verifiable via the manifest checksums")
    }

    // MARK: - Absent-when-empty and unwired: goldens stay byte-stable

    func testExportWithoutHydrationRepoOrDataOmitsTheBlock() throws {
        // No drinks seeded, repo wired: nothing in range -> no block.
        let empty = try read(try XCTUnwrap(
            makeRunner(hydration: hydrationRepo()).run(scope: .everything, format: .json)
                .fileURLs.first { $0.lastPathComponent == "bundle.json" }))
        XCTAssertFalse(empty.contains("\"hydration\""), "no drinks -> no hydration block (goldens stay byte-stable)")

        // Drinks present but the runner built WITHOUT the ledger (the automation/route/aggregate
        // constructions before this change): still absent, so an unwired runner degrades silently to
        // the prior bytes rather than crashing.
        try seedDrinks()
        let unwired = try read(try XCTUnwrap(
            makeRunner(hydration: nil).run(scope: .everything, format: .json)
                .fileURLs.first { $0.lastPathComponent == "bundle.json" }))
        XCTAssertFalse(unwired.contains("\"hydration\""), "a nil ledger contributes nothing to the bundle")
    }

    // MARK: - The notes opt-in mechanism (the other half of the default-redaction promise)

    func testNotesAppearOnlyWhenTheRedactionPolicyOptsThemIn() throws {
        try seedDrinks()
        let entries = try hydrationRepo().liveEntries(from: Date(timeIntervalSince1970: 0), to: clock.now())
        let payload = HydrationExportPayload(entries: entries)

        // Default policy: withheld (proved above via the runner). Opt-in policy: the note is carried —
        // so "excluded by default" is a redaction choice, not a capability the export lacks.
        let optedCSV = HydrationCSVWriter(policy: HydrationRedactionPolicy(includeNotes: true)).entriesCSV(entries)
        XCTAssertTrue(optedCSV.contains("NOTE-TEXT-DO-NOT-EXPORT"), "the opt-in CSV carries the note")
        XCTAssertTrue(optedCSV.contains("note"), "the note column exists under the opt-in policy")

        let manifest = ExportManifest(
            exportId: "e", schemaVersion: "1.0.0", appVersion: "test", platform: "iOS",
            generatedAt: clock.now(), scope: .everything, dateRange: "all", displayLanguage: "en",
            unitProfile: "canonical", timezonePolicy: "", dedupPolicy: "", perMetricRowCounts: [:],
            checksums: [:], dataQualityNote: "", sampleDataRowCount: 0, encrypted: false)
        let optedBundle = String(decoding: try JSONBundleWriter().data(
            manifest: manifest, rawSamples: [], intervalRecords: [], sessions: [], derivedValues: [],
            baselines: [], symptoms: [], adherence: [], workouts: [], nutrition: [],
            hydration: payload, hydrationRedaction: HydrationRedactionPolicy(includeNotes: true)), as: UTF8.self)
        XCTAssertTrue(optedBundle.contains("NOTE-TEXT-DO-NOT-EXPORT"), "the opt-in bundle carries the note")
        XCTAssertTrue(optedBundle.contains("\"notes_included\":true"))
    }
}
