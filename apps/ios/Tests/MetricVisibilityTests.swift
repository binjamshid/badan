import XCTest
@testable import BADAN

/// D-35 — per-metric visibility and pins (development priority #2).
///
/// The load-bearing test here is `testHidingAMetricDoesNotStopItBeingIngestedOrDerived`. Everything
/// else in this file protects a preference; that one protects the user's data. If hiding ever
/// starts gating collection, the readings lost are ones HealthKit will not hand over again later,
/// and the user will have chosen that by tidying a list.
final class MetricVisibilityTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"
    let tz = TimeZone.current.identifier

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-visibility-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var range: HealthDateRange {
        HealthDateRange(start: clock.now().addingTimeInterval(-90 * 86_400), end: clock.now())
    }

    // MARK: - The invariant

    /// Hiding is presentation only. Run the real ingestion and derivation pipelines twice over
    /// identical fake data — once with nothing hidden, once with a metric hidden — and assert the
    /// stored rows are identical in both count and content.
    ///
    /// The profile is deliberately *not* passed to either pipeline: that is the design, and this
    /// test is what stops someone "helpfully" threading it in later. If a future change makes
    /// derivation consult `hiddenMetricIds`, these counts diverge and this fails.
    func testHidingAMetricDoesNotStopItBeingIngestedOrDerived() throws {
        let hiddenMetric = MetricID.hrv

        var profile = CustomizationProfile()
        XCTAssertFalse(profile.isMetricHidden(hiddenMetric), "precondition: nothing hidden by default")
        let (visibleMeasurements, visibleDerived) = try runPipelines()

        // Fresh database, same fake data, but the metric is hidden this time.
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-visibility-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)

        profile.hideMetric(hiddenMetric)
        XCTAssertTrue(profile.isMetricHidden(hiddenMetric), "precondition: the metric really is hidden")
        let (hiddenMeasurements, hiddenDerived) = try runPipelines()

        XCTAssertEqual(hiddenMeasurements, visibleMeasurements,
                       "Hiding a metric changed how many measurements were ingested. Hiding is a "
                       + "presentation choice; it must never gate collection. HealthKit will not "
                       + "backfill what BADAN declined to read, so this is unrecoverable data loss.")
        XCTAssertEqual(hiddenDerived, visibleDerived,
                       "Hiding a metric changed how many derived rows were computed. A hidden metric "
                       + "still feeds every score that depends on it.")
        XCTAssertGreaterThan(visibleMeasurements, 0, "precondition: the fixture produced data at all")
        XCTAssertGreaterThan(visibleDerived, 0, "precondition: the fixture produced scores at all")
    }

    /// A hidden metric still has its own rows, not merely the same totals — the counts above could
    /// in principle match while the specific metric was dropped and something else grew.
    func testAHiddenMetricStillHasItsOwnStoredReadings() throws {
        var profile = CustomizationProfile()
        profile.hideMetric(MetricID.hrv)
        _ = try runPipelines()

        let rows = try db.main.query(
            "SELECT COUNT(*) AS n FROM interval_records WHERE metric_id = ?;", [.text(MetricID.hrv)])
        XCTAssertGreaterThan(rows.first?.int("n") ?? 0, 0,
                             "The hidden metric has no stored readings — it was never ingested.")
    }

    // MARK: - The ways back

    /// Hidden metrics drop out of browsing but must remain findable by typing their name, and must
    /// never be filtered out of export. A metric that could not be found by name would be a trap
    /// with no way back; an export that silently dropped it would be data loss by surprise.
    func testHiddenMetricsAreStillReturnedByExplicitNameSearchAndAreNeverFilteredFromExport() throws {
        let registry = MetricRegistry.shared
        let def = try XCTUnwrap(registry.definition(MetricID.hrv))

        var profile = CustomizationProfile()
        profile.hideMetric(def.metricId)

        // Search is registry-level and takes no profile at all — which is exactly the guarantee.
        // Searching the metric's own English name still returns it.
        let hits = registry.search(def.nameEn)
        XCTAssertTrue(hits.contains { $0.metricId == def.metricId },
                      "A hidden metric was not returned by an explicit search for its own name. "
                      + "Search is the way back from hiding; without it, hiding is one-way.")

        // The export picker reads `env.registry.all`, unfiltered. Assert the registry side of that
        // contract: `all` does not consult, and cannot consult, the profile.
        XCTAssertTrue(registry.all.contains { $0.metricId == def.metricId },
                      "The registry's full metric list dropped a hidden metric. The export scope "
                      + "picker is built on this list and must never hide the user's own data.")
    }

    // MARK: - Profile shape and tolerant decode

    func testPinnedAndHiddenDefaultEmpty() {
        let profile = CustomizationProfile()
        XCTAssertTrue(profile.pinnedMetricIds.isEmpty)
        XCTAssertTrue(profile.hiddenMetricIds.isEmpty)
    }

    /// A profile persisted before D-35 has neither key. It must still decode — `ProfileRepository.load()`
    /// treats any whole-profile decode failure as "no saved profile" and silently resets EVERY
    /// preference, so a missing-key throw here would cost the user their language, theme and units.
    /// Built by encoding and stripping, so it cannot drift from whatever fields the profile gains later.
    func testPinnedAndHiddenDecodeEmptyFromAProfileMissingBothKeys() throws {
        var profile = CustomizationProfile()
        profile.pinMetric(MetricID.steps)
        profile.hideMetric(MetricID.hrv)
        let encoded = try JSONEncoder().encode(profile)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["pinnedMetricIds"], "precondition: a fresh encode carries the pin key")
        XCTAssertNotNil(json["hiddenMetricIds"], "precondition: a fresh encode carries the hide key")
        json.removeValue(forKey: "pinnedMetricIds")
        json.removeValue(forKey: "hiddenMetricIds")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(CustomizationProfile.self, from: stripped)
        XCTAssertTrue(decoded.pinnedMetricIds.isEmpty)
        XCTAssertTrue(decoded.hiddenMetricIds.isEmpty)
        XCTAssertEqual(decoded.language, profile.language,
                       "the strip should not have disturbed unrelated preferences")
    }

    /// Array position IS display order, so a round trip that sorted or set-ified would silently
    /// reorder the user's Home.
    func testPinOrderIsArrayOrderAndSurvivesARoundTrip() throws {
        var profile = CustomizationProfile()
        // Deliberately not alphabetical, so a sort would be visible.
        profile.pinMetric(MetricID.steps)
        profile.pinMetric(MetricID.hrv)
        profile.pinMetric(MetricID.activeEnergy)
        let expected = [MetricID.steps, MetricID.hrv, MetricID.activeEnergy]
        XCTAssertEqual(profile.pinnedMetricIds, expected)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CustomizationProfile.self, from: data)
        XCTAssertEqual(decoded.pinnedMetricIds, expected, "pin order changed across a round trip")
    }

    func testPinningIsCappedAtEight() {
        var profile = CustomizationProfile()
        let ids = MetricRegistry.shared.all.prefix(12).map(\.metricId)
        XCTAssertGreaterThan(ids.count, CustomizationProfile.maxPinnedMetrics,
                             "precondition: the fixture offers more metrics than the cap")
        for id in ids { profile.pinMetric(id) }

        XCTAssertEqual(profile.pinnedMetricIds.count, CustomizationProfile.maxPinnedMetrics)
        XCTAssertEqual(profile.pinnedMetricIds, Array(ids.prefix(CustomizationProfile.maxPinnedMetrics)),
                       "the cap should drop the overflow, not the earliest pins")
        XCTAssertFalse(profile.canPinMore)
    }

    /// The clamp also has to hold on direct assignment — callers reach the profile through
    /// `AppEnvironment.update { $0.pinnedMetricIds = ... }`, which writes the property directly and
    /// would bypass a clamp applied only in the initialisers.
    func testDirectAssignmentIsAlsoCappedAndDeduplicated() {
        var profile = CustomizationProfile()
        let ids = MetricRegistry.shared.all.prefix(12).map(\.metricId)
        profile.pinnedMetricIds = ids + ids   // over the cap, and every id twice

        XCTAssertEqual(profile.pinnedMetricIds.count, CustomizationProfile.maxPinnedMetrics)
        XCTAssertEqual(Set(profile.pinnedMetricIds).count, profile.pinnedMetricIds.count,
                       "a duplicated pin would render the same metric twice on Home")
    }

    /// Pinned-and-hidden is contradictory — the pinned card is a browsing surface. Both directions
    /// resolve toward the user's most recent instruction.
    func testPinningAHiddenMetricUnhidesIt() {
        var profile = CustomizationProfile()
        profile.hideMetric(MetricID.hrv)
        profile.pinMetric(MetricID.hrv)

        XCTAssertTrue(profile.isMetricPinned(MetricID.hrv))
        XCTAssertFalse(profile.isMetricHidden(MetricID.hrv),
                       "a metric cannot be pinned to Home and hidden from browsing at once")
    }

    func testHidingAPinnedMetricUnpinsIt() {
        var profile = CustomizationProfile()
        profile.pinMetric(MetricID.hrv)
        profile.hideMetric(MetricID.hrv)

        XCTAssertTrue(profile.isMetricHidden(MetricID.hrv))
        XCTAssertFalse(profile.isMetricPinned(MetricID.hrv))
    }

    // MARK: - Home module parity

    /// Every module id `HomeScreen` gates on must exist in `defaultModules`, or its Settings toggle
    /// never renders and the module can never be switched off — it just falls through
    /// `isHomeModuleVisible`'s `?? true` forever. `"effort"` was in exactly that state before D-35.
    ///
    /// Deliberately asymmetric: `defaultModules` MAY contain an id `HomeScreen` never gates.
    /// `"nutrition"` is that case on purpose — it governs Settings copy and has no Home card — so a
    /// symmetric test would fail on a decision made deliberately and documented in `HomeScreen`.
    func testEveryGatedHomeModuleIdExistsInDefaultModules() {
        let defaults = Set(CustomizationProfile.defaultModules.map(\.id))
        for id in Self.homeModuleIdsGatedByHomeScreen {
            XCTAssertTrue(defaults.contains(id),
                          "\"\(id)\" is gated by HomeScreen but missing from defaultModules, so "
                          + "Settings renders no toggle for it and the user can never hide it.")
        }
    }

    /// The other direction, with its documented exception named rather than assumed.
    func testEveryDefaultModuleIsEitherGatedByHomeScreenOrKnownToHaveNoHomeSurface() {
        let gated = Self.homeModuleIdsGatedByHomeScreen
        for module in CustomizationProfile.defaultModules {
            if gated.contains(module.id) { continue }
            XCTAssertTrue(CustomizationProfile.homeModulesWithoutHomeSurface.contains(module.id),
                          "\"\(module.id)\" is offered as a Settings toggle but no Home card reads "
                          + "it, so switching it off does nothing visible. Either gate a card on it "
                          + "or add it to homeModulesWithoutHomeSurface with a reason.")
        }
    }

    /// Kept as an explicit literal rather than scraped from source: the point is to notice when the
    /// two drift, and a list derived from the same file could not.
    private static let homeModuleIdsGatedByHomeScreen: Set<String> =
        ["pinned", "readiness", "effort", "sleep", "activity", "heart", "meds", "timeline"]

    /// The upgrade path, which is where the `"effort"` bug actually lived. Settings renders one
    /// toggle per entry in the STORED `homeModules`, so a module added to `defaultModules` stays
    /// invisible and unhideable for every profile written before it existed. Decoding a
    /// pre-D-35 profile must therefore surface the new modules, without disturbing what the user
    /// already chose.
    func testDecodingAProfileFromBeforeANewModuleExistedStillOffersThatModule() throws {
        var profile = CustomizationProfile()
        // A stored profile from before "pinned"/"effort" existed, with a deliberate user choice
        // on one of the modules that did exist.
        profile.homeModules = [
            HomeModule(id: "readiness", visible: true, order: 0),
            HomeModule(id: "sleep", visible: false, order: 1),   // the user turned this off
            HomeModule(id: "timeline", visible: true, order: 2),
        ]
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CustomizationProfile.self, from: data)

        for id in ["pinned", "effort"] {
            XCTAssertNotNil(decoded.module(id),
                            "\"\(id)\" is missing after decoding an older profile, so Settings will "
                            + "render no toggle for it and the user can never hide it — the exact "
                            + "state \"effort\" was in before D-35.")
        }
        XCTAssertEqual(decoded.module("sleep")?.visible, false,
                       "merging new modules must not resurrect a module the user switched off")
        XCTAssertEqual(decoded.module("readiness")?.order, 0,
                       "merging new modules must not reorder what the user already had")
        XCTAssertGreaterThan(try XCTUnwrap(decoded.module("pinned")?.order), 2,
                             "new modules belong after the user's existing ones, not in front of them")
    }

    /// Every module needs a translated label, or the Arabic UI shows the capitalized raw id via
    /// `homeModuleLabel`'s `default:` branch. `"effort"` had this bug too.
    func testEveryDefaultModuleHasATranslatedLabel() {
        for module in CustomizationProfile.defaultModules {
            let label = PersonalizationSettingsScreen.homeModuleLabel(module.id)
            XCTAssertNotEqual(label.ar, module.id.capitalized,
                              "\"\(module.id)\" has no Arabic label and falls through to the raw id.")
        }
    }

    // MARK: - The pinned Home card

    /// A pinned metric may keep its value in `derived_values` (`readiness.score` has no interval
    /// record at all) or in a measurement. Both must render.
    ///
    /// This also pins down the dispatch rule, which is subtler than it looks: `loadMetrics` decides
    /// by asking whether a MEASUREMENT exists, not by reading `MetricDefinition.kind`. Kind cannot
    /// be the rule — `heart.rhr` and `heart.hrv` are `kind: derived` in the registry yet have always
    /// been read from HealthKit-ingested interval records, so dispatching on kind empties the key
    /// grid for both. If someone "simplifies" this back to a kind check, the raw half of this test
    /// and `PhaseAwareBaselineConsumptionTests` both fail.
    func testAPinnedDerivedMetricRendersFromDerivedValuesAndAPinnedRawMetricFromIntervals() throws {
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        _ = try runPipelines()   // gives the raw half real interval records and baselines

        // A readiness score for today, written straight in so the assertion is about rendering.
        let today = DayAttribution.startOfDay(clock.now(), tz: tz)
        try derivation.appendDerived(DerivedValue(
            id: "dv-pinned-readiness", metricId: MetricID.readinessScore, value: 72, unit: "score",
            periodKey: DayAttribution.dayPeriodKey(today, tz: tz), confidence: 0.8, provisional: true,
            algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0",
            computedAt: clock.now(), updatedAt: clock.now(), originDeviceId: deviceId))

        var profile = CustomizationProfile()
        profile.pinMetric(MetricID.readinessScore)   // derived
        profile.pinMetric(MetricID.steps)            // raw interval record

        let inputs = HomeFetchInputs(
            measurements: measurements, derivation: derivation, catalog: CatalogRepository(db.main),
            logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
            contextAnnotations: noContextAnnotations, insightsRepo: InsightRepository(db.main),
            registry: .shared, format: ValueFormatter(profile: profile, registry: .shared),
            language: .en, depth: .casual, nutritionEnabled: false, sensitiveModulesEnabled: false,
            now: clock.now(), pinnedMetricIds: profile.pinnedMetricIds)

        guard case .loaded(let data) = HomeViewModel.fetch(inputs) else {
            return XCTFail("expected .loaded")
        }

        let derived = try XCTUnwrap(data.pinnedMetrics.first { $0.metricId == MetricID.readinessScore },
                                    "a pinned derived metric did not reach the Home pinned card")
        XCTAssertTrue(derived.provisional,
                      "provisional must come off the stored row, which said true")
        XCTAssertNil(derived.position,
                     "a derived score has no personal baseline to sit against; inventing a band "
                     + "would be a comparison the number does not have")

        XCTAssertNotNil(data.pinnedMetrics.first { $0.metricId == MetricID.steps },
                        "a pinned raw metric did not reach the Home pinned card")

        // Pins are additional, never a replacement: the four-metric key grid is untouched.
        XCTAssertNotNil(data.metric(MetricID.steps),
                        "pinning a metric removed it from the key grid")
    }

    /// Pin order is the user's, so the card must render in it — not in registry or fetch order.
    func testThePinnedCardRendersInTheUsersChosenOrder() throws {
        _ = try runPipelines()
        var profile = CustomizationProfile()
        profile.pinMetric(MetricID.activeEnergy)
        profile.pinMetric(MetricID.steps)

        let inputs = HomeFetchInputs(
            measurements: MeasurementRepository(db.main), derivation: DerivationRepository(db.main),
            catalog: CatalogRepository(db.main),
            logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
            contextAnnotations: noContextAnnotations, insightsRepo: InsightRepository(db.main),
            registry: .shared, format: ValueFormatter(profile: profile, registry: .shared),
            language: .en, depth: .casual, nutritionEnabled: false, sensitiveModulesEnabled: false,
            now: clock.now(), pinnedMetricIds: profile.pinnedMetricIds)

        guard case .loaded(let data) = HomeViewModel.fetch(inputs) else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(data.pinnedMetrics.map(\.metricId), [MetricID.activeEnergy, MetricID.steps])
    }

    // MARK: - Helpers

    /// Runs the real ingestion and derivation pipelines over the deterministic fake store, exactly
    /// as `DerivationPipelineTests` wires them, and returns (measurement rows, derived rows).
    private func runPipelines() throws -> (measurements: Int, derived: Int) {
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        _ = try IngestionPipeline(measurements: measurements,
                                  catalog: CatalogRepository(db.main),
                                  reconciliation: ReconciliationRepository(db.main),
                                  registry: .shared, clock: clock, deviceId: deviceId)
            .ingest(from: FakeHealthStore(clock: clock, historyDays: 90, tz: tz), range: range)

        let baselines = BaselineEngine(derivation: derivation, measurements: measurements,
                                       registry: .shared, clock: clock, deviceId: deviceId)
        let sleep = SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                            clock: clock, deviceId: deviceId)
        let readiness = ReadinessEngine(derivation: derivation, measurements: measurements,
                                        clock: clock, deviceId: deviceId)
        let effort = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: clock, deviceId: deviceId)
        try DerivationCoordinator(baselines: baselines, sleep: sleep, readiness: readiness,
                                  effort: effort).recompute(asOf: clock.now(), tz: tz)

        let m = try db.main.query("SELECT COUNT(*) AS n FROM interval_records;").first?.int("n") ?? 0
        let d = try db.main.query("SELECT COUNT(*) AS n FROM derived_values;").first?.int("n") ?? 0
        return (Int(m), Int(d))
    }
}
