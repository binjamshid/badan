import XCTest
@testable import BADAN

/// EPIC-39 CYCLE-06 "later integration" — closes the gap `CycleModuleServices.refreshAll`'s own
/// header named ("consuming that data from HomeScreen/BodyScreen/DeviationEngine's own read paths
/// is explicitly out of scope for this slice"). This suite proves three things about that
/// integration, exercising the REAL `HomeViewModel.fetch`/`BodyViewModel.fetch` cores (not a
/// re-implementation of their logic):
///
/// 1. With the cycle module disabled, `HomeViewModel.fetch`/`BodyViewModel.fetch`'s baseline reads
///    for HRV/resting-heart-rate/sleep-efficiency are bit-for-bit identical to a plain
///    `defaultDerivation.latestBaseline(metricId:)` read — even when a confident, calendar-only
///    luteal estimate genuinely exists on file (proving the module flag, not merely "no estimate
///    on file", is what gates this feature).
/// 2. With the module enabled and a confident, calendar-only luteal estimate on file whose
///    luteal-conditioned band differs from the default band, the screen actually surfaces the
///    luteal-conditioned reading — reproducing `CyclePhaseCovariateCoordinatorTests
///    .testLutealFixtureAvoidsDefaultBaselineFalseAlarm`'s own fixture numbers verbatim (never
///    invented ones), so the known-correct band edges from that suite apply unchanged here.
/// 3. Every OTHER metric (outside `hrv`/`restingHeartRate`/`sleepEfficiency`) reads identically
///    regardless of whether the cycle module is enabled.
final class PhaseAwareBaselineConsumptionTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"
    let tz = "UTC"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-phase-aware-consumption-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 1. Module disabled — bit-for-bit identical to before this change

    func testHomeModuleDisabledReadsBitForBitIdenticalToPlainDefaultRead() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = day0.addingTimeInterval(300 * 86_400)

        // Same false-alarm-prone fixture as test 2 below — including a genuinely confident,
        // calendar-only luteal estimate ON FILE — so this test proves the MODULE FLAG (not merely
        // "no estimate exists") is what gates the feature.
        try seedLutealFixture(measurements: measurements, defaultDerivation: defaultDerivation,
                             sensitiveDerivation: sensitiveDerivation, day0: day0, day1: day1)
        try appendLutealEstimate(confidence: 0.8, evidenceBasis: .calendarOnly, asOf: day1)
        try insertToday(measurements, metricId: MetricID.hrv, value: 36, asOf: day1)

        let expected = try XCTUnwrap(try defaultDerivation.latestBaseline(metricId: MetricID.hrv))

        let inputs = makeHomeInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: false, phaseEstimates: nil, sensitiveDerivation: nil)
        let outcome = HomeViewModel.fetch(inputs)
        guard case .loaded(let data) = outcome else { return XCTFail("expected .loaded, got \(outcome)") }
        let hrv = try XCTUnwrap(data.metric(MetricID.hrv))

        XCTAssertEqual(hrv.position, expected.position(of: 36))
        XCTAssertEqual(hrv.provisional, expected.provisional)
        XCTAssertNil(hrv.phaseCovariate, "module disabled must never surface a phase-covariate indicator")
        // The false alarm the phase-aware feature exists to fix is still present when disabled —
        // proving this is really the plain default band, not an accidentally-still-conditioned one.
        XCTAssertEqual(hrv.position, .below)
    }

    func testBodyModuleDisabledReadsBitForBitIdenticalToPlainDefaultRead() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = day0.addingTimeInterval(300 * 86_400)

        try seedLutealFixture(measurements: measurements, defaultDerivation: defaultDerivation,
                             sensitiveDerivation: sensitiveDerivation, day0: day0, day1: day1)
        try appendLutealEstimate(confidence: 0.8, evidenceBasis: .calendarOnly, asOf: day1)
        try insertToday(measurements, metricId: MetricID.hrv, value: 36, asOf: day1)

        let expected = try XCTUnwrap(try defaultDerivation.latestBaseline(metricId: MetricID.hrv))

        let inputs = makeBodyInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: false, phaseEstimates: nil, sensitiveDerivation: nil)
        let outcome = BodyViewModel.fetch(inputs)
        guard case .success(let data) = outcome else { return XCTFail("expected .success, got \(outcome)") }
        let heartPillar = try XCTUnwrap(data.pillars.first { $0.family == .heart })

        XCTAssertEqual(heartPillar.metricId, MetricID.hrv, "only HRV has data in this fixture's .heart family")
        XCTAssertEqual(heartPillar.baseline?.position(of: 36), expected.position(of: 36))
        XCTAssertEqual(heartPillar.baseline?.covariateContext, "default")
        XCTAssertNil(heartPillar.phaseCovariate, "module disabled must never surface a phase-covariate indicator")
    }

    // MARK: - 2. Module enabled + confident luteal estimate — surfaces the luteal-conditioned value

    /// Reproduces `CyclePhaseCovariateCoordinatorTests.testLutealFixtureAvoidsDefaultBaselineFalseAlarm`'s
    /// own fixture numbers verbatim: default HRV history (40/45/50/55/60/65 ms, 10 days apiece) bands
    /// to ~[42.35, 64.89]; this same user's luteal-only history (34/36/38 ms, 10 days apiece) bands to
    /// ~[33.24, 39.00]. A real luteal reading of 36ms is a false-alarm low outlier against the default
    /// band but normal against her own luteal band — exactly the WHOOP-documented gap this feature
    /// closes. Numbers are not re-derived here; they are the same already-audited fixture, reused.
    func testHomeSurfacesLutealConditionedHRVWhenConfidentCalendarOnlyEstimateExists() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = day0.addingTimeInterval(300 * 86_400)

        try seedLutealFixture(measurements: measurements, defaultDerivation: defaultDerivation,
                             sensitiveDerivation: sensitiveDerivation, day0: day0, day1: day1)
        try appendLutealEstimate(confidence: 0.8, evidenceBasis: .calendarOnly, asOf: day1)
        try insertToday(measurements, metricId: MetricID.hrv, value: 36, asOf: day1)

        // Sanity check the fixture itself still reproduces the coordinator suite's own numbers.
        let defaultBaseline = try XCTUnwrap(try defaultDerivation.latestBaseline(metricId: MetricID.hrv))
        XCTAssertEqual(defaultBaseline.bandLow, 42.35, accuracy: 0.05)
        XCTAssertEqual(defaultBaseline.bandHigh, 64.89, accuracy: 0.05)
        XCTAssertEqual(defaultBaseline.position(of: 36), .below,
                       "36ms must read as a false-alarm low outlier against the default band")
        let lutealBaseline = try XCTUnwrap(try sensitiveDerivation.latestBaseline(metricId: MetricID.hrv, context: "luteal"))
        XCTAssertEqual(lutealBaseline.bandLow, 33.24, accuracy: 0.05)
        XCTAssertEqual(lutealBaseline.bandHigh, 39.00, accuracy: 0.05)

        let phaseEstimates = CyclePhaseEstimateRepository(sensitive: db.sensitive)
        let inputs = makeHomeInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: true, phaseEstimates: phaseEstimates, sensitiveDerivation: sensitiveDerivation)
        let outcome = HomeViewModel.fetch(inputs)
        guard case .loaded(let data) = outcome else { return XCTFail("expected .loaded, got \(outcome)") }
        let hrv = try XCTUnwrap(data.metric(MetricID.hrv))

        XCTAssertEqual(hrv.position, .within,
                       "the screen must surface the luteal-conditioned band, which correctly contains 36ms")
        let covariate = try XCTUnwrap(hrv.phaseCovariate, "a phase-covariate indicator must be surfaced")
        XCTAssertEqual(covariate.phase, .luteal)
        XCTAssertEqual(covariate.confidence, 0.8, accuracy: 0.001)
    }

    func testBodySurfacesLutealConditionedHRVWhenConfidentCalendarOnlyEstimateExists() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = day0.addingTimeInterval(300 * 86_400)

        try seedLutealFixture(measurements: measurements, defaultDerivation: defaultDerivation,
                             sensitiveDerivation: sensitiveDerivation, day0: day0, day1: day1)
        try appendLutealEstimate(confidence: 0.8, evidenceBasis: .calendarOnly, asOf: day1)
        try insertToday(measurements, metricId: MetricID.hrv, value: 36, asOf: day1)

        let phaseEstimates = CyclePhaseEstimateRepository(sensitive: db.sensitive)
        let inputs = makeBodyInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: true, phaseEstimates: phaseEstimates, sensitiveDerivation: sensitiveDerivation)
        let outcome = BodyViewModel.fetch(inputs)
        guard case .success(let data) = outcome else { return XCTFail("expected .success, got \(outcome)") }
        let heartPillar = try XCTUnwrap(data.pillars.first { $0.family == .heart })

        XCTAssertEqual(heartPillar.metricId, MetricID.hrv)
        XCTAssertEqual(heartPillar.baseline?.covariateContext, "luteal")
        XCTAssertEqual(heartPillar.baseline?.position(of: 36), .within)
        let covariate = try XCTUnwrap(heartPillar.phaseCovariate)
        XCTAssertEqual(covariate.phase, .luteal)
    }

    /// Same mechanism, third metric: `sleepEfficiency` (via BodyScreen's `.sleep` family, whose
    /// headline candidates are `[timeAsleep, sleepEfficiency]` — `timeAsleep` is left with no data
    /// so the pillar's own "first candidate that actually has data" rule picks `sleepEfficiency`).
    func testBodySurfacesLutealConditionedSleepEfficiencyWhenConfidentCalendarOnlyEstimateExists() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        // A separate calendar anchor for the luteal-only dataset (same isolation reasoning as
        // `seedLutealFixture`/the coordinator suite's own `day0`/`day1` split) — so the two
        // datasets never land on the same days and one can never silently overwrite the other.
        let day1 = day0.addingTimeInterval(300 * 86_400)

        // A mixed, clearly-different-from-luteal default history (a pooled 20-day pattern).
        for daysAgo in 1...20 {
            let value: Double = daysAgo.isMultiple(of: 2) ? 70 : 90
            try insert(measurements, metricId: MetricID.sleepEfficiency, daysAgo: daysAgo, value: value, asOf: day0)
        }
        let defaultEngine = BaselineEngine(derivation: defaultDerivation, measurements: measurements,
                                          registry: .shared, clock: FixedClock(day1), deviceId: deviceId)
        try defaultEngine.recompute(metricId: MetricID.sleepEfficiency, asOf: day0, tz: tz, context: "default")

        // This SAME user's own tight, genuinely-different luteal-only history.
        for daysAgo in 1...20 {
            try insert(measurements, metricId: MetricID.sleepEfficiency, daysAgo: daysAgo, value: 60, asOf: day1)
        }
        let sensitiveEngine = BaselineEngine(derivation: sensitiveDerivation, measurements: measurements,
                                             registry: .shared, clock: FixedClock(day1), deviceId: deviceId)
        let estimate = try appendLutealEstimate(confidence: 0.9, evidenceBasis: .calendarOnly, asOf: day1)
        try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
            phaseEstimate: estimate, baselines: sensitiveEngine, asOf: day1, tz: tz)

        let defaultBaseline = try XCTUnwrap(try defaultDerivation.latestBaseline(metricId: MetricID.sleepEfficiency))
        let lutealBaseline = try XCTUnwrap(
            try sensitiveDerivation.latestBaseline(metricId: MetricID.sleepEfficiency, context: "luteal"))
        XCTAssertGreaterThan(abs(defaultBaseline.center - lutealBaseline.center), 5,
                             "the fixture must produce a luteal band that genuinely differs from default")

        let phaseEstimates = CyclePhaseEstimateRepository(sensitive: db.sensitive)
        let inputs = makeBodyInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: true, phaseEstimates: phaseEstimates, sensitiveDerivation: sensitiveDerivation)
        let outcome = BodyViewModel.fetch(inputs)
        guard case .success(let data) = outcome else { return XCTFail("expected .success, got \(outcome)") }
        let sleepPillar = try XCTUnwrap(data.pillars.first { $0.family == .sleep })

        XCTAssertEqual(sleepPillar.metricId, MetricID.sleepEfficiency,
                       "timeAsleep has no data in this fixture, so sleepEfficiency must be the chosen candidate")
        XCTAssertEqual(sleepPillar.baseline?.covariateContext, "luteal")
        XCTAssertNotNil(sleepPillar.phaseCovariate)
    }

    // MARK: - Gate: module enabled but the estimate itself isn't good enough

    func testHomeFallsBackToDefaultWhenModuleEnabledButNoPhaseEstimateOnFile() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = day0.addingTimeInterval(300 * 86_400)

        try seedLutealFixture(measurements: measurements, defaultDerivation: defaultDerivation,
                             sensitiveDerivation: sensitiveDerivation, day0: day0, day1: day1)
        // No `appendLutealEstimate` call at all — nothing on file for `cycle_phase_estimates`.
        try insertToday(measurements, metricId: MetricID.hrv, value: 36, asOf: day1)

        let phaseEstimates = CyclePhaseEstimateRepository(sensitive: db.sensitive)
        let inputs = makeHomeInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: true, phaseEstimates: phaseEstimates, sensitiveDerivation: sensitiveDerivation)
        let outcome = HomeViewModel.fetch(inputs)
        guard case .loaded(let data) = outcome else { return XCTFail("expected .loaded, got \(outcome)") }
        let hrv = try XCTUnwrap(data.metric(MetricID.hrv))

        XCTAssertEqual(hrv.position, .below, "with no phase estimate on file, must fall back to the default band")
        XCTAssertNil(hrv.phaseCovariate)
    }

    func testHomeFallsBackToDefaultWhenEstimateConfidenceBelowThreshold() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = day0.addingTimeInterval(300 * 86_400)

        try seedLutealFixture(measurements: measurements, defaultDerivation: defaultDerivation,
                             sensitiveDerivation: sensitiveDerivation, day0: day0, day1: day1)
        // `seedLutealFixture` already wrote a real, well-populated luteal band into the sensitive
        // DB (via its own internal confidence-0.8 write). This appended estimate — the one
        // `PhaseAwareBaselineReader` actually looks up for "today" — is deliberately BELOW
        // `CyclePhaseCovariateCoordinator.minPhaseConfidenceForConditionedRecompute` (0.5), so this
        // proves the read side refuses to surface that already-existing band on the strength of a
        // low-confidence CURRENT estimate, rather than "no luteal band happens to exist" being the
        // only reason the fallback test above passes.
        try appendLutealEstimate(confidence: 0.3, evidenceBasis: .calendarOnly, asOf: day1)
        try insertToday(measurements, metricId: MetricID.hrv, value: 36, asOf: day1)

        let phaseEstimates = CyclePhaseEstimateRepository(sensitive: db.sensitive)
        let inputs = makeHomeInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: true, phaseEstimates: phaseEstimates, sensitiveDerivation: sensitiveDerivation)
        let outcome = HomeViewModel.fetch(inputs)
        guard case .loaded(let data) = outcome else { return XCTFail("expected .loaded, got \(outcome)") }
        let hrv = try XCTUnwrap(data.metric(MetricID.hrv))

        XCTAssertEqual(hrv.position, .below)
        XCTAssertNil(hrv.phaseCovariate)
    }

    // MARK: - 3. Every OTHER metric is completely untouched

    func testEveryOtherHomeMetricIsUntouchedRegardlessOfCycleModuleState() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = day0.addingTimeInterval(300 * 86_400)

        try seedLutealFixture(measurements: measurements, defaultDerivation: defaultDerivation,
                             sensitiveDerivation: sensitiveDerivation, day0: day0, day1: day1)
        try appendLutealEstimate(confidence: 0.8, evidenceBasis: .calendarOnly, asOf: day1)
        try insertToday(measurements, metricId: MetricID.hrv, value: 36, asOf: day1)

        // `steps` is outside `CyclePhaseCovariateCoordinator.phaseConditionedMetricIds` — a plain
        // default baseline plus a fresh "today" reading, exactly like any ordinary metric.
        for daysAgo in 1...20 { try insert(measurements, metricId: MetricID.steps, daysAgo: daysAgo, value: 8000, asOf: day1) }
        let stepsEngine = BaselineEngine(derivation: defaultDerivation, measurements: measurements,
                                         registry: .shared, clock: FixedClock(day1), deviceId: deviceId)
        try stepsEngine.recompute(metricId: MetricID.steps, asOf: day1, tz: tz, context: "default")
        try insertToday(measurements, metricId: MetricID.steps, value: 8000, asOf: day1)

        let phaseEstimates = CyclePhaseEstimateRepository(sensitive: db.sensitive)
        let disabledInputs = makeHomeInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: false, phaseEstimates: nil, sensitiveDerivation: nil)
        let enabledInputs = makeHomeInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: true, phaseEstimates: phaseEstimates, sensitiveDerivation: sensitiveDerivation)

        guard case .loaded(let disabledData) = HomeViewModel.fetch(disabledInputs) else {
            return XCTFail("expected .loaded")
        }
        guard case .loaded(let enabledData) = HomeViewModel.fetch(enabledInputs) else {
            return XCTFail("expected .loaded")
        }
        let stepsDisabled = try XCTUnwrap(disabledData.metric(MetricID.steps))
        let stepsEnabled = try XCTUnwrap(enabledData.metric(MetricID.steps))

        XCTAssertEqual(stepsDisabled.heroValue, stepsEnabled.heroValue)
        XCTAssertEqual(stepsDisabled.position, stepsEnabled.position)
        XCTAssertEqual(stepsDisabled.provisional, stepsEnabled.provisional)
        XCTAssertEqual(stepsDisabled.deltaText, stepsEnabled.deltaText)
        XCTAssertNil(stepsDisabled.phaseCovariate)
        XCTAssertNil(stepsEnabled.phaseCovariate, "steps must never surface a phase-covariate indicator")

        // The HRV read in the SAME two fetches, by contrast, does differ — confirming the
        // untouched-steps assertion above isn't just "the whole feature silently no-op'd".
        let hrvDisabled = try XCTUnwrap(disabledData.metric(MetricID.hrv))
        let hrvEnabled = try XCTUnwrap(enabledData.metric(MetricID.hrv))
        XCTAssertNil(hrvDisabled.phaseCovariate)
        XCTAssertNotNil(hrvEnabled.phaseCovariate)
        XCTAssertNotEqual(hrvDisabled.position, hrvEnabled.position)
    }

    func testEveryOtherBodyMetricIsUntouchedRegardlessOfCycleModuleState() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = day0.addingTimeInterval(300 * 86_400)

        try seedLutealFixture(measurements: measurements, defaultDerivation: defaultDerivation,
                             sensitiveDerivation: sensitiveDerivation, day0: day0, day1: day1)
        try appendLutealEstimate(confidence: 0.8, evidenceBasis: .calendarOnly, asOf: day1)

        for daysAgo in 1...20 { try insert(measurements, metricId: MetricID.steps, daysAgo: daysAgo, value: 8000, asOf: day1) }
        let stepsEngine = BaselineEngine(derivation: defaultDerivation, measurements: measurements,
                                         registry: .shared, clock: FixedClock(day1), deviceId: deviceId)
        try stepsEngine.recompute(metricId: MetricID.steps, asOf: day1, tz: tz, context: "default")

        let phaseEstimates = CyclePhaseEstimateRepository(sensitive: db.sensitive)
        let disabledInputs = makeBodyInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: false, phaseEstimates: nil, sensitiveDerivation: nil)
        let enabledInputs = makeBodyInputs(
            derivation: defaultDerivation, measurements: measurements, now: day1,
            cycleModuleEnabled: true, phaseEstimates: phaseEstimates, sensitiveDerivation: sensitiveDerivation)

        guard case .success(let disabledData) = BodyViewModel.fetch(disabledInputs) else {
            return XCTFail("expected .success")
        }
        guard case .success(let enabledData) = BodyViewModel.fetch(enabledInputs) else {
            return XCTFail("expected .success")
        }
        let activityDisabled = try XCTUnwrap(disabledData.pillars.first { $0.family == .activity })
        let activityEnabled = try XCTUnwrap(enabledData.pillars.first { $0.family == .activity })

        XCTAssertEqual(activityDisabled.metricId, activityEnabled.metricId)
        XCTAssertEqual(activityDisabled.latest, activityEnabled.latest)
        XCTAssertEqual(activityDisabled.baseline?.covariateContext, "default")
        XCTAssertEqual(activityEnabled.baseline?.covariateContext, "default")
        XCTAssertNil(activityDisabled.phaseCovariate)
        XCTAssertNil(activityEnabled.phaseCovariate, "steps/activity must never surface a phase-covariate indicator")
    }

    // MARK: - Fixtures

    /// Verbatim reproduction of `CyclePhaseCovariateCoordinatorTests
    /// .testLutealFixtureAvoidsDefaultBaselineFalseAlarm`'s own HRV data — see that test for the
    /// hand-verified band numbers this reproduces. Writes the default band into `db.main` and the
    /// luteal-conditioned band into `db.sensitive`, exactly mirroring that suite's own two-engine
    /// setup (never one engine standing in for both, per I7).
    private func seedLutealFixture(
        measurements: MeasurementRepository, defaultDerivation: DerivationRepository,
        sensitiveDerivation: DerivationRepository, day0: Date, day1: Date
    ) throws {
        let defaultEngine = BaselineEngine(derivation: defaultDerivation, measurements: measurements,
                                           registry: .shared, clock: FixedClock(day1), deviceId: deviceId)
        let sensitiveEngine = BaselineEngine(derivation: sensitiveDerivation, measurements: measurements,
                                             registry: .shared, clock: FixedClock(day1), deviceId: deviceId)

        let defaultValues: [Double] = [40, 45, 50, 55, 60, 65]
        for (offset, value) in defaultValues.enumerated() {
            for rep in 0..<10 {
                let daysAgo = offset * 10 + rep + 1
                try insert(measurements, metricId: MetricID.hrv, daysAgo: daysAgo, value: value, asOf: day0)
            }
        }
        try defaultEngine.recompute(metricId: MetricID.hrv, asOf: day0, tz: tz, context: "default")

        let lutealValues: [Double] = [34, 36, 38]
        for (offset, value) in lutealValues.enumerated() {
            for rep in 0..<10 {
                let daysAgo = offset * 10 + rep + 1
                try insert(measurements, metricId: MetricID.hrv, daysAgo: daysAgo, value: value, asOf: day1)
            }
        }

        // Write side: only actually materializes the luteal band once a caller hands it a
        // confident, calendar-only estimate — mirrored here exactly like the coordinator suite,
        // using a throwaway high-confidence estimate purely to populate the stored band. The
        // separate estimate this test's caller appends via `appendLutealEstimate` is what the READ
        // side (`PhaseAwareBaselineReader`) actually looks up.
        let writeEstimate = CyclePhaseEstimate(
            id: ULID.newID(), dateRangeStart: day1.addingTimeInterval(-3 * 86_400), dateRangeEnd: day1,
            phase: .luteal, confidence: 0.8, evidenceBasis: .calendarOnly,
            algorithmVersion: "cycle.phase_estimate@1.0.0", computedAt: day1, updatedAt: day1,
            originDeviceId: deviceId)
        try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
            phaseEstimate: writeEstimate, baselines: sensitiveEngine, asOf: day1, tz: tz)
    }

    @discardableResult
    private func appendLutealEstimate(
        confidence: Double, evidenceBasis: CyclePhaseEvidenceBasis, asOf: Date
    ) throws -> CyclePhaseEstimate {
        let estimate = CyclePhaseEstimate(
            id: ULID.newID(), dateRangeStart: asOf.addingTimeInterval(-3 * 86_400), dateRangeEnd: asOf,
            phase: .luteal, confidence: confidence, evidenceBasis: evidenceBasis,
            algorithmVersion: "cycle.phase_estimate@1.0.0", computedAt: asOf, updatedAt: asOf,
            originDeviceId: deviceId)
        try CyclePhaseEstimateRepository(sensitive: db.sensitive).appendEstimate(estimate)
        return estimate
    }

    private func insert(_ measurements: MeasurementRepository, metricId: String, daysAgo: Int,
                        value: Double, asOf: Date) throws {
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        let day = DayAttribution.addingDays(-daysAgo, to: dayStart, tz: tz)
        let dayKey = DayAttribution.localDayKey(day, tz: tz)
        let record = IntervalRecord(
            id: ULID.newID(), metricId: metricId, value: value, unit: "unit",
            startAt: day, endAt: DayAttribution.addingDays(1, to: day, tz: tz), tzId: tz, aggregation: .mean,
            provenance: Provenance(sourceId: "src", ingestionPath: .platformStore, externalId: "\(metricId)#\(dayKey)",
                                   measuredAt: day, measuredTimezone: tz, recordedAt: day, ingestedAt: day),
            updatedAt: day, originDeviceId: deviceId)
        _ = try measurements.upsertIntervalRecord(record)
    }

    /// A fresh reading dated exactly `asOf` (today) — the value a screen actually evaluates
    /// against the band, distinct from the historical `insert(...)` rows the band is built FROM
    /// (`BaselineEngine.recompute` excludes the evaluation day itself from its own window).
    private func insertToday(_ measurements: MeasurementRepository, metricId: String, value: Double, asOf: Date) throws {
        let dayKey = DayAttribution.localDayKey(asOf, tz: tz)
        let record = IntervalRecord(
            id: ULID.newID(), metricId: metricId, value: value, unit: "unit",
            startAt: asOf, endAt: asOf.addingTimeInterval(3600), tzId: tz, aggregation: .mean,
            provenance: Provenance(sourceId: "src", ingestionPath: .platformStore, externalId: "\(metricId)#today#\(dayKey)",
                                   measuredAt: asOf, measuredTimezone: tz, recordedAt: asOf, ingestedAt: asOf),
            updatedAt: asOf, originDeviceId: deviceId)
        _ = try measurements.upsertIntervalRecord(record)
    }

    private func makeHomeInputs(
        derivation: DerivationRepository, measurements: MeasurementRepository, now: Date,
        cycleModuleEnabled: Bool, phaseEstimates: CyclePhaseEstimateRepository?,
        sensitiveDerivation: DerivationRepository?
    ) -> HomeFetchInputs {
        HomeFetchInputs(
            measurements: measurements, derivation: derivation, catalog: CatalogRepository(db.main),
            logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
            contextAnnotations: noContextAnnotations, insightsRepo: InsightRepository(db.main),
            registry: .shared, format: ValueFormatter(profile: CustomizationProfile(), registry: .shared),
            language: .en, depth: .casual, nutritionEnabled: false, sensitiveModulesEnabled: false,
            now: now, cycleModuleEnabled: cycleModuleEnabled, phaseEstimates: phaseEstimates,
            sensitiveDerivation: sensitiveDerivation)
    }

    private func makeBodyInputs(
        derivation: DerivationRepository, measurements: MeasurementRepository, now: Date,
        cycleModuleEnabled: Bool, phaseEstimates: CyclePhaseEstimateRepository?,
        sensitiveDerivation: DerivationRepository?
    ) -> BodyFetchInputs {
        BodyFetchInputs(
            registry: .shared, derivation: derivation, measurements: measurements, now: now,
            cycleModuleEnabled: cycleModuleEnabled, phaseEstimates: phaseEstimates,
            sensitiveDerivation: sensitiveDerivation)
    }
}
