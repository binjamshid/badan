import XCTest
@testable import BADAN

/// Focused regression tests for the panel-review-2026-07 labeling/honesty fixes: the sample-data
/// lifecycle flag that drives `SampleDataBanner` (STUB-01/COMP-06), and the tolerant-decode
/// default flip for the three previously pre-consented notification preferences (STUB-12).
/// Driven against a throwaway on-disk `Database`, mirroring `LifecycleFixTests`' setup.
final class LabelingFixTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-labeling-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
        // Process-global UserDefaults keys — start clean and clean up after (see `LifecycleFixTests`).
        UserDefaults.standard.removeObject(forKey: SeedController.seedCompletedKey)
        UserDefaults.standard.removeObject(forKey: SeedController.demoSeedActiveKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: SeedController.seedCompletedKey)
        UserDefaults.standard.removeObject(forKey: SeedController.demoSeedActiveKey)
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers (mirrors `LifecycleFixTests`' wiring)

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

    // MARK: - STUB-01/COMP-06 — demoSeedActive lifecycle

    func testSeedSetsDemoSeedActiveAndIsDemoDataActiveReflectsIt() throws {
        XCTAssertFalse(SeedController.isDemoDataActive, "should start clean per setUp")

        let seed = makeSeedController()
        try seed.seed(asOf: clock.now())

        XCTAssertTrue(UserDefaults.standard.bool(forKey: SeedController.demoSeedActiveKey))
        XCTAssertTrue(SeedController.isDemoDataActive,
                     "the static helper RootView reads must reflect the flag `seed()` just set")
    }

    func testMarkStartEmptyClearsDemoSeedActiveAndLeavesZeroDemoRows() throws {
        let seed = makeSeedController()
        try seed.seed(asOf: clock.now())

        // Sanity: seeding actually produced rows across every table `markStartEmpty` must clear.
        XCTAssertGreaterThan(try count("sources", in: db.main), 0)
        XCTAssertGreaterThan(try count("workout_entries", in: db.main), 0)
        XCTAssertGreaterThan(try count("nutrition_entries", in: db.main), 0)
        XCTAssertGreaterThan(try count("note_entries", in: db.main), 0)
        XCTAssertGreaterThan(try count("medication_regimens", in: db.sensitive), 0)
        XCTAssertGreaterThan(try count("symptom_entries", in: db.sensitive), 0)
        XCTAssertTrue(SeedController.isDemoDataActive)

        try SeedController.markStartEmpty(database: db)

        // The flag the banner reads must flip immediately.
        XCTAssertFalse(SeedController.isDemoDataActive)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: SeedController.demoSeedActiveKey))
        // "Start empty" means done-and-empty, not "not yet seeded" — `seedIfNeeded` must not
        // later demo-seed on top of a deliberately empty start.
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SeedController.seedCompletedKey))

        // Zero demo rows left anywhere — ingested/derived (main), manual logs (main), and
        // sensitive (medications/symptoms) — mirrors `LifecycleFixTests`' table-by-table style.
        for table in ["sources", "source_devices", "raw_samples", "interval_records", "sessions",
                      "derived_values", "baselines", "insights", "dedup_decisions", "read_anchors",
                      "workout_entries", "nutrition_entries", "note_entries"] {
            XCTAssertEqual(try count(table, in: db.main), 0, "\(table) should be empty after markStartEmpty")
        }
        for table in ["medication_regimens", "adherence_events", "symptom_entries"] {
            XCTAssertEqual(try count(table, in: db.sensitive), 0, "\(table) should be empty after markStartEmpty")
        }
    }

    func testMarkStartEmptyPreventsSeedIfNeededFromLaterDemoSeeding() throws {
        let seed = makeSeedController()
        try seed.seed(asOf: clock.now())
        try SeedController.markStartEmpty(database: db)

        // A subsequent bootstrap-style call (e.g. next cold launch) must not re-seed fake data
        // over a deliberately-empty start.
        try seed.seedIfNeeded(asOf: clock.now())

        XCTAssertTrue(try CatalogRepository(db.main).sources().isEmpty)
        XCTAssertFalse(SeedController.isDemoDataActive)
    }

    // MARK: - STUB-12 — NotificationPreference defaults & tolerant decode

    func testNotificationPreferenceDefaultsAllFalse() {
        let prefs = NotificationPreference()
        XCTAssertFalse(prefs.morningNarrative)
        XCTAssertFalse(prefs.weeklyDigest)
        XCTAssertFalse(prefs.medicationReminders)
        XCTAssertFalse(prefs.dataPausedAlerts)
    }

    func testNotificationPreferenceDecodesMissingFieldsAsFalse() throws {
        // An empty JSON object — every field absent — must decode to the all-false default
        // rather than throwing (which would fail the enclosing `CustomizationProfile` decode and
        // silently reset every other preference too — see `ProfileRepository.load()`).
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(NotificationPreference.self, from: data)
        XCTAssertFalse(decoded.morningNarrative)
        XCTAssertFalse(decoded.weeklyDigest)
        XCTAssertFalse(decoded.medicationReminders)
        XCTAssertFalse(decoded.dataPausedAlerts)
    }

    func testNotificationPreferenceDecodePreservesExplicitTrueValues() throws {
        // Tolerant decode must still round-trip an explicit `true` faithfully — this isn't a
        // blanket "always false" override, only a default for *missing* keys.
        let data = Data(#"{"morningNarrative": true, "medicationReminders": true}"#.utf8)
        let decoded = try JSONDecoder().decode(NotificationPreference.self, from: data)
        XCTAssertTrue(decoded.morningNarrative)
        XCTAssertTrue(decoded.medicationReminders)
        // Absent keys still decode false, even alongside sibling keys that were present.
        XCTAssertFalse(decoded.weeklyDigest)
        XCTAssertFalse(decoded.dataPausedAlerts)
    }

    func testCustomizationProfileDefaultNotificationsAllFalse() {
        let profile = CustomizationProfile()
        XCTAssertFalse(profile.notifications.morningNarrative)
        XCTAssertFalse(profile.notifications.weeklyDigest)
        XCTAssertFalse(profile.notifications.medicationReminders)
        XCTAssertFalse(profile.notifications.dataPausedAlerts)
    }
}
