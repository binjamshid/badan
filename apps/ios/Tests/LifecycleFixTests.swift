import XCTest
import UserNotifications
@testable import BADAN

/// Focused regression tests for the panel-review-2026-07 lifecycle fixes: the demo/real data
/// boundary (BUG-01), the profile-survives-a-reset guarantee (BUG-04/BUG-09), the interrupted-
/// first-run-seed resume (BUG-16), and the stale-reminder cleanup (BUG-05). Driven against a
/// throwaway on-disk `Database`, mirroring `PipelineTests`' setup.
final class LifecycleFixTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-lifecycle-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
        // These two UserDefaults keys are process-global; every test that touches them starts
        // from a known-clean slate and cleans up after itself (see `tearDownWithError`).
        UserDefaults.standard.removeObject(forKey: SeedController.seedCompletedKey)
        UserDefaults.standard.removeObject(forKey: SeedController.demoSeedActiveKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: SeedController.seedCompletedKey)
        UserDefaults.standard.removeObject(forKey: SeedController.demoSeedActiveKey)
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers (mirrors `AppEnvironment.init`'s wiring)

    private func makeSeedController() -> SeedController {
        let catalog = CatalogRepository(db.main)
        let measurements = MeasurementRepository(db.main)
        let reconciliation = ReconciliationRepository(db.main)
        let ingestion = IngestionPipeline(measurements: measurements, catalog: catalog,
                                         reconciliation: reconciliation, registry: MetricRegistry.shared,
                                         clock: clock, deviceId: deviceId)
        let derivation = DerivationRepository(db.main)
        let baselines = BaselineEngine(derivation: derivation, measurements: measurements,
                                       registry: MetricRegistry.shared, clock: clock, deviceId: deviceId)
        let insightEngine = InsightEngine(insights: InsightRepository(db.main), derivation: derivation,
                                          measurements: measurements, templates: InsightTemplateStore.shared,
                                          registry: MetricRegistry.shared, clock: clock, deviceId: deviceId)
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        return SeedController(catalog: catalog, ingestion: ingestion, logging: logging,
                              measurements: measurements, baselines: baselines, insightEngine: insightEngine,
                              registry: MetricRegistry.shared, clock: clock, deviceId: deviceId)
    }

    private func count(_ table: String, in conn: SQLiteConnection) throws -> Int {
        Int(try conn.query("SELECT COUNT(*) AS c FROM \(table);").first?.int("c") ?? 0)
    }

    /// Rows in a measurement table that did NOT come from the user's own typing — the set
    /// `purgeIngestedData` is allowed to delete (F2).
    private func countIngested(_ table: String, in conn: SQLiteConnection) throws -> Int {
        Int(try conn.query(
            "SELECT COUNT(*) AS c FROM \(table) WHERE ingestion_path != '\(IngestionPath.manual.rawValue)';"
        ).first?.int("c") ?? 0)
    }

    @MainActor
    private func makeEnvironment() -> AppEnvironment {
        AppEnvironment(database: db, clock: clock)
    }

    // MARK: - BUG-01 / Database.purgeIngestedData

    func testPurgeIngestedDataPreservesManualLogsAndProfile() throws {
        let seed = makeSeedController()
        try seed.seed(asOf: clock.now())

        // Sanity: seeding actually produced ingested rows and manual logs before the purge.
        XCTAssertGreaterThan(try count("sources", in: db.main), 0)
        XCTAssertGreaterThan(try count("raw_samples", in: db.main), 0)
        XCTAssertGreaterThan(try count("workout_entries", in: db.main), 0)
        XCTAssertGreaterThan(try count("nutrition_entries", in: db.main), 0)
        XCTAssertGreaterThan(try count("note_entries", in: db.main), 0)
        XCTAssertGreaterThan(try count("medication_regimens", in: db.sensitive), 0)

        // seed() doesn't write a profile row — create one so the preservation assert below
        // actually exercises purgeIngestedData leaving customization_profile alone.
        try ProfileRepository(db.main).save(CustomizationProfile())
        XCTAssertGreaterThan(try count("customization_profile", in: db.main), 0)

        try db.purgeIngestedData()

        // Ingested/derived data is gone. (F2) `raw_samples`/`interval_records`/`sessions` are
        // deliberately NOT in this list: they mix ingested rows with the user's own manual ones,
        // so "empty afterwards" is the wrong assertion for them — see the F2 test below. The
        // seed writes no manual rows, so their ingested contents still go to zero here; that's
        // asserted per-path rather than per-table.
        for table in ["sources", "source_devices", "derived_values", "baselines", "insights",
                      "dedup_decisions", "read_anchors"] {
            XCTAssertEqual(try count(table, in: db.main), 0, "\(table) should be empty after purgeIngestedData")
        }
        for table in ["raw_samples", "interval_records", "sessions"] {
            XCTAssertEqual(try countIngested(table, in: db.main), 0,
                           "\(table)'s ingested rows should be gone after purgeIngestedData")
        }
        // Manual logs, the profile, and the sensitive DB are untouched (BUG-01's whole point).
        XCTAssertGreaterThan(try count("workout_entries", in: db.main), 0)
        XCTAssertGreaterThan(try count("nutrition_entries", in: db.main), 0)
        XCTAssertGreaterThan(try count("note_entries", in: db.main), 0)
        XCTAssertGreaterThan(try count("customization_profile", in: db.main), 0)
        XCTAssertGreaterThan(try count("medication_regimens", in: db.sensitive), 0)
    }

    // MARK: - F2: a manually logged weight must survive connecting Apple Health

    /// Builds the row `LogHubScreen.logWeight` writes: a `raw_samples` row whose only marker of
    /// being the user's own is `ingestion_path = 'manual'`.
    private func manualWeightSample(at measuredAt: Date) -> RawSample {
        RawSample(id: ULID.newID(), metricId: MetricID.weight, value: 80, unit: "kg",
                  originalValue: 80, originalUnit: "kg", startAt: measuredAt, tzId: "UTC",
                  provenance: Provenance(sourceId: deviceId, deviceId: deviceId,
                                         ingestionPath: .manual, measuredAt: measuredAt,
                                         measuredTimezone: "UTC", recordedAt: measuredAt,
                                         ingestedAt: measuredAt),
                  updatedAt: measuredAt, originDeviceId: deviceId)
    }

    func testPurgeIngestedDataPreservesManuallyLoggedWeight() throws {
        let seed = makeSeedController()
        try seed.seed(asOf: clock.now())
        _ = try MeasurementRepository(db.main).upsertRawSample(manualWeightSample(at: clock.now()))

        XCTAssertGreaterThan(try countIngested("raw_samples", in: db.main), 0,
                             "sanity: the seed wrote ingested samples for the purge to remove")

        try db.purgeIngestedData()

        let weights = try MeasurementRepository(db.main).rawSamples(metricId: MetricID.weight)
        XCTAssertEqual(weights.count, 1,
                       "F2: quick-logged weight is a raw_sample with ingestion_path 'manual' — "
                           + "connecting Apple Health must not delete the user's own log")
        XCTAssertEqual(weights.first?.provenance.ingestionPath, .manual)
        XCTAssertEqual(try countIngested("raw_samples", in: db.main), 0,
                       "F2: ingested samples must still be purged — the predicate narrows the "
                           + "delete, it doesn't skip it")
    }

    /// The "Start empty" onboarding fork shares this primitive, and its contract is that the demo
    /// seed is gone. Nothing the seed writes is `.manual` (it goes through `FakeHealthStore` ->
    /// `IngestionPipeline` as `.platformStore`), so F2's predicate must not leave demo rows behind.
    func testMarkStartEmptyStillRemovesEveryDemoSeededMeasurement() throws {
        let seed = makeSeedController()
        try seed.seed(asOf: clock.now())

        try SeedController.markStartEmpty(database: db)

        for table in ["raw_samples", "interval_records", "sessions"] {
            XCTAssertEqual(try count(table, in: db.main), 0,
                           "\(table): no demo-seeded row is manual, so 'start empty' must be "
                               + "literally empty")
        }
    }

    func testPurgeDemoManualLogsClearsOnlyMainDBManualLogTables() throws {
        let seed = makeSeedController()
        try seed.seed(asOf: clock.now())

        try db.purgeDemoManualLogs()

        XCTAssertEqual(try count("workout_entries", in: db.main), 0)
        XCTAssertEqual(try count("nutrition_entries", in: db.main), 0)
        XCTAssertEqual(try count("note_entries", in: db.main), 0)
        // Sensitive-DB medications/symptoms are a separate purge (`purgeSensitiveNamespace`) —
        // this method must not touch them.
        XCTAssertGreaterThan(try count("medication_regimens", in: db.sensitive), 0)
    }

    // MARK: - BUG-03 / resetAll ordering

    func testResetAllRecreatesUsableSchemaWithConsistentUserVersion() throws {
        let seed = makeSeedController()
        try seed.seed(asOf: clock.now())

        try db.resetAll()

        // A fresh CatalogRepository against the recreated schema must work immediately — this
        // would throw ("no such table") if `resetAll` left `user_version` stamped but the
        // schema not actually recreated (the BUG-03 failure mode).
        XCTAssertNoThrow(try CatalogRepository(db.main).sources())
        let version = try db.main.query("PRAGMA user_version;").first?.int("user_version")
        let expected = Schema.mainMigrations.map(\.version).max().map(Int64.init)
        XCTAssertEqual(version, expected, "user_version should reflect the fully re-applied schema")
    }

    // MARK: - BUG-04 / profile survives a reset

    func testProfileIsRePersistedAfterResetAll() throws {
        let profiles = ProfileRepository(db.main)
        var customized = CustomizationProfile()
        customized.language = .ar
        customized.theme = .dark
        try profiles.save(customized)

        // Mirrors `AppEnvironment.resetDemoData`: capture the live profile, wipe, then
        // explicitly re-save it (the fix) rather than relying on `load()`'s in-memory cache.
        let live = customized
        try db.resetAll()
        try profiles.save(live)

        // A brand-new repository (no in-memory cache — simulates the next cold launch) must
        // read the re-saved profile back from disk, not silently-reset defaults.
        let reloaded = try ProfileRepository(db.main).load()
        XCTAssertEqual(reloaded.language, .ar)
        XCTAssertEqual(reloaded.theme, .dark)
    }

    func testProfileIsLostAfterResetAllWithoutReSave() throws {
        // Documents the bug BUG-04 fixes: without the explicit re-save, a fresh repository
        // reads defaults back, not what was live before the reset.
        let profiles = ProfileRepository(db.main)
        var customized = CustomizationProfile()
        customized.language = .ar
        try profiles.save(customized)

        try db.resetAll()

        let reloaded = try ProfileRepository(db.main).load()
        XCTAssertEqual(reloaded.language, .en, "a bare resetAll with no re-save reverts to defaults")
    }

    // MARK: - BUG-09 / ProfileRepository.cached thread safety

    func testProfileRepositoryConcurrentLoadAndSaveDoesNotCrash() throws {
        let profiles = ProfileRepository(db.main)
        try profiles.save(CustomizationProfile())

        let iterations = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            var p = CustomizationProfile()
            p.arabicDigits = i.isMultiple(of: 2)
            try? profiles.save(p)
            _ = try? profiles.load()
        }
        // No crash / no assertion failure from the concurrent access above is the test; a final
        // load should still succeed and return *some* valid profile.
        XCTAssertNoThrow(try profiles.load())
    }

    // MARK: - BUG-16 / interrupted first-run seed resume

    func testSeedIfNeededSeedsAndSetsCompletionMarkersWhenAbsent() throws {
        let seed = makeSeedController()
        try seed.seedIfNeeded(asOf: clock.now())

        XCTAssertTrue(UserDefaults.standard.bool(forKey: SeedController.seedCompletedKey))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SeedController.demoSeedActiveKey))
        XCTAssertFalse(try CatalogRepository(db.main).sources().isEmpty)
    }

    func testSeedIfNeededSkipsEntirelyWhenCompletedMarkerSet() throws {
        UserDefaults.standard.set(true, forKey: SeedController.seedCompletedKey)
        let seed = makeSeedController()
        try seed.seedIfNeeded(asOf: clock.now())

        // Marker set, nothing else ever seeded in this test — `seedIfNeeded` must not seed.
        XCTAssertTrue(try CatalogRepository(db.main).sources().isEmpty)
    }

    func testReRunningSeedAfterInterruptionDoesNotDuplicateManualLogs() throws {
        // Simulates a first `seed()` being interrupted right after completion and resumed by a
        // second full `seed()` call (what `seedIfNeeded` does when the marker is absent but
        // `sources` is already non-empty) — every manual-log write must use a deterministic id
        // so this lands on the same rows instead of duplicating them (BUG-16).
        let seed = makeSeedController()
        try seed.seed(asOf: clock.now())
        let workoutsAfterFirst = try count("workout_entries", in: db.main)
        let nutritionAfterFirst = try count("nutrition_entries", in: db.main)
        let notesAfterFirst = try count("note_entries", in: db.main)
        let regimensAfterFirst = try count("medication_regimens", in: db.sensitive)
        let adherenceAfterFirst = try count("adherence_events", in: db.sensitive)
        let symptomsAfterFirst = try count("symptom_entries", in: db.sensitive)
        XCTAssertGreaterThan(workoutsAfterFirst, 0)

        try seed.seed(asOf: clock.now())

        XCTAssertEqual(try count("workout_entries", in: db.main), workoutsAfterFirst)
        XCTAssertEqual(try count("nutrition_entries", in: db.main), nutritionAfterFirst)
        XCTAssertEqual(try count("note_entries", in: db.main), notesAfterFirst)
        XCTAssertEqual(try count("medication_regimens", in: db.sensitive), regimensAfterFirst)
        XCTAssertEqual(try count("adherence_events", in: db.sensitive), adherenceAfterFirst)
        XCTAssertEqual(try count("symptom_entries", in: db.sensitive), symptomsAfterFirst)
    }

    // MARK: - BUG-05 / stale medication reminders

    @MainActor
    func testRefreshMedicationRemindersCancelsWhenPreferenceOff() async throws {
        // Local scheduling doesn't require notification *authorization* (only presentation
        // does), so a fake pending request can be added directly without granting anything —
        // real, deterministic proof that `refreshMedicationReminders()` cancels rather than
        // merely no-oping when the preference is off.
        let center = UNUserNotificationCenter.current()
        let identifier = "med-reminder.lifecycle-test.0900"
        let content = UNMutableNotificationContent()
        content.title = "test"
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 9, minute: 0), repeats: true)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))

        // Confirm the fake request actually landed before asserting anything about it being
        // cancelled — if this test host can't schedule local notifications at all, skip rather
        // than pass vacuously or fail on an environment limitation unrelated to the fix.
        let baseline = await center.pendingNotificationRequests()
        try XCTSkipUnless(baseline.contains { $0.identifier == identifier },
                          "local notification scheduling unavailable in this test environment")

        let env = makeEnvironment()
        env.update { $0.notifications.medicationReminders = false }
        await env.refreshMedicationReminders()

        let pending = await center.pendingNotificationRequests()
        XCTAssertFalse(pending.contains { $0.identifier == identifier },
                       "turning the preference off must cancel any already-scheduled reminder")
    }
}
