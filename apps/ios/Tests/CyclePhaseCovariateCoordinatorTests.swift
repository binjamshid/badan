import XCTest
@testable import BADAN

/// EPIC-39 CYCLE-06 — phase-conditioned baseline wiring.
///
/// The named acceptance criterion for this task (plan's own backlog row): "Luteal-phase fixture no
/// longer trips generic illness/poor recovery false alarms." `testLutealFixtureAvoidsDefaultBaselineFalseAlarm`
/// below is that test: it builds a user whose OVERALL/default HRV baseline would flag a real luteal
/// reading as a low-outlier false alarm, and whose own luteal-specific history shows that same
/// reading is perfectly normal FOR THEM — then asserts `phaseAwareCalibration` returns the
/// luteal-conditioned band (which correctly contains the reading), not the default one (which would
/// have flagged it). Every number below is fed through the REAL `BaselineEngine.recompute` math
/// (median/MAD, HRV's own log transform) — nothing here is a hand-built `Baseline` standing in for
/// what the engine would compute.
///
/// I7, corrected after audit: the write side takes a `BaselineEngine` constructed over
/// `DerivationRepository(db.sensitive)` — NEVER `db.main` — because a phase-conditioned
/// `covariate_context` value is itself a reproductive-phase word ("luteal", "follicular", ...), and
/// sensitive migration v6 adds a `baselines` table inside `badan_sensitive.db` for exactly this
/// reason (see `CyclePhaseCovariateCoordinator`'s own header). Every test below constructs TWO
/// separate `DerivationRepository`s — `defaultDerivation` (main) and `sensitiveDerivation`
/// (sensitive) — never one repository standing in for both, which is precisely the mistake this
/// suite is now written to guard against re-occurring.
final class CyclePhaseCovariateCoordinatorTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"
    let tz = "UTC"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-cycle-covariate-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The named acceptance criterion

    func testLutealFixtureAvoidsDefaultBaselineFalseAlarm() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        // Far enough past day0 that day1's own 60-day HRV window never overlaps day0's inserted
        // history — the two datasets below must stay cleanly isolated from each other, exactly as
        // this user's true "overall" history and true "luteal-only" history would be two different
        // slices of the same underlying data, never one contaminating the other's band.
        let day1 = day0.addingTimeInterval(300 * 86_400)
        let defaultEngine = BaselineEngine(derivation: defaultDerivation, measurements: measurements,
                                           registry: .shared, clock: FixedClock(day1), deviceId: deviceId)
        let sensitiveEngine = BaselineEngine(derivation: sensitiveDerivation, measurements: measurements,
                                             registry: .shared, clock: FixedClock(day1), deviceId: deviceId)

        // This user's OVERALL/default HRV history: 60 days spanning every phase, genuinely varied
        // (40/45/50/55/60/65 ms, 10 days apiece) — a realistic pooled-across-phases distribution.
        // Computed by hand against the real engine math (median/MAD in the log domain, madToSigma
        // 1.4826, bandSigmas 1.0, from the published contract): center ≈ 52.4 ms, band ≈
        // [42.3, 64.9]. No value here is anywhere near an outlier (max deviation is well inside the
        // 3.5-MAD rejection threshold), so all 60 days survive into the band.
        let defaultValues: [Double] = [40, 45, 50, 55, 60, 65]
        for (offset, value) in defaultValues.enumerated() {
            for rep in 0..<10 {
                let daysAgo = offset * 10 + rep + 1
                try insertHRV(measurements, daysAgo: daysAgo, value: value, asOf: day0)
            }
        }
        try defaultEngine.recompute(metricId: MetricID.hrv, asOf: day0, tz: tz, context: "default")
        let defaultBaseline = try XCTUnwrap(
            try defaultDerivation.latestBaseline(metricId: MetricID.hrv, context: "default"))
        XCTAssertEqual(defaultBaseline.bandLow, 42.35, accuracy: 0.05)
        XCTAssertEqual(defaultBaseline.bandHigh, 64.89, accuracy: 0.05)

        // This SAME user's own luteal-phase-only HRV history: 30 days (34/36/38 ms, 10 apiece) —
        // tight and genuinely lower than her overall average. This is not a data-entry accident: for
        // this user, luteal HRV really does run lower, and that is her own normal. Computed by hand
        // against the real engine math: center ≈ 36.0 ms, band ≈ [33.2, 39.0].
        let lutealValues: [Double] = [34, 36, 38]
        for (offset, value) in lutealValues.enumerated() {
            for rep in 0..<10 {
                let daysAgo = offset * 10 + rep + 1
                try insertHRV(measurements, daysAgo: daysAgo, value: value, asOf: day1)
            }
        }

        // A confident, calendar-only luteal estimate — the gate this coordinator's write side
        // requires before it will condition a baseline on a phase label at all.
        let lutealEstimate = makeEstimate(phase: .luteal, confidence: 0.8, evidenceBasis: .calendarOnly, asOf: day1)

        try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
            phaseEstimate: lutealEstimate, baselines: sensitiveEngine, asOf: day1, tz: tz)

        let lutealBaseline = try XCTUnwrap(
            try sensitiveDerivation.latestBaseline(metricId: MetricID.hrv, context: "luteal"))
        XCTAssertEqual(lutealBaseline.bandLow, 33.24, accuracy: 0.05)
        XCTAssertEqual(lutealBaseline.bandHigh, 39.00, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(lutealBaseline.nPoints, CyclePhaseCovariateCoordinator.minPointsForConditionedBaseline,
                                    "the luteal band must have enough of its own backing points to be trustworthy")

        // I7: the luteal band must land in the SENSITIVE database, never main — confirmed directly
        // against the raw table, not just through the repository's own read path.
        XCTAssertEqual(try countBaselines(db.main, context: "luteal"), 0,
                       "a phase-conditioned baseline must never exist in badan.db")
        XCTAssertEqual(try countBaselines(db.sensitive, context: "luteal"), 1,
                       "a phase-conditioned baseline must live in badan_sensitive.db")

        // The reading in question: a real luteal-phase HRV value of 36ms.
        let reading = 36.0

        // Under the OVERALL/default band alone, this reading is a false-alarm low outlier —
        // exactly the WHOOP-documented failure mode this feature exists to close.
        XCTAssertEqual(defaultBaseline.position(of: reading), .below,
                       "36ms reads as a false-alarm low outlier against this user's POOLED band")

        // But it is squarely within this user's OWN luteal band — normal for her, in this phase.
        XCTAssertEqual(lutealBaseline.position(of: reading), .within,
                       "36ms is normal for this user's own luteal pattern")

        // The read-side helper must prefer the luteal-conditioned reading, not the default one.
        let chosen = try XCTUnwrap(try CyclePhaseCovariateCoordinator.phaseAwareCalibration(
            metricId: MetricID.hrv, phaseEstimate: lutealEstimate,
            sensitiveDerivation: sensitiveDerivation, defaultDerivation: defaultDerivation))
        XCTAssertEqual(chosen.covariateContext, "luteal",
                       "phaseAwareCalibration must return the luteal-conditioned baseline, not default")
        XCTAssertEqual(chosen.position(of: reading), .within,
                       "the chosen (luteal) band must correctly contain the reading, avoiding the false alarm")
    }

    // MARK: - I7: sensitive-namespace placement and purge coverage

    func testPhaseConditionedBaselineIsRemovedByPurgeWhileDefaultSurvives() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        for daysAgo in 1...20 { try insertHRV(measurements, daysAgo: daysAgo, value: 50, asOf: asOf) }

        let defaultEngine = BaselineEngine(derivation: defaultDerivation, measurements: measurements,
                                           registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        try defaultEngine.recompute(metricId: MetricID.hrv, asOf: asOf, tz: tz, context: "default")

        let sensitiveEngine = BaselineEngine(derivation: sensitiveDerivation, measurements: measurements,
                                             registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        let estimate = makeEstimate(phase: .luteal, confidence: 0.8, evidenceBasis: .calendarOnly, asOf: asOf)
        try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
            phaseEstimate: estimate, baselines: sensitiveEngine, asOf: asOf, tz: tz)

        XCTAssertEqual(try countBaselines(db.sensitive, context: "luteal"), 1)
        XCTAssertEqual(try countBaselines(db.main, context: "default"), 1)

        try db.purgeSensitiveNamespace()

        XCTAssertEqual(try countBaselines(db.sensitive, context: "luteal"), 0,
                       "purge must remove the phase-conditioned baseline along with every other sensitive row")
        XCTAssertEqual(try countBaselines(db.main, context: "default"), 1,
                       "purge must never touch the unconditioned default baseline in badan.db")
    }

    // MARK: - Write-side gating

    func testGateDeclinesBelowConfidenceThreshold() throws {
        let measurements = MeasurementRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        for daysAgo in 1...20 { try insertHRV(measurements, daysAgo: daysAgo, value: 50, asOf: asOf) }
        let engine = BaselineEngine(derivation: sensitiveDerivation, measurements: measurements,
                                    registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)

        let lowConfidence = makeEstimate(phase: .luteal, confidence: 0.3, evidenceBasis: .calendarOnly, asOf: asOf)
        try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
            phaseEstimate: lowConfidence, baselines: engine, asOf: asOf, tz: tz)

        XCTAssertNil(try sensitiveDerivation.latestBaseline(metricId: MetricID.hrv, context: "luteal"),
                    "below-threshold confidence must not write a phase-conditioned baseline")
    }

    func testGateDeclinesOnInsufficientHistoryEvidenceBasisEvenWithHighConfidence() throws {
        let measurements = MeasurementRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        for daysAgo in 1...20 { try insertHRV(measurements, daysAgo: daysAgo, value: 50, asOf: asOf) }
        let engine = BaselineEngine(derivation: sensitiveDerivation, measurements: measurements,
                                    registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)

        let estimate = makeEstimate(phase: .luteal, confidence: 0.95, evidenceBasis: .insufficientHistory, asOf: asOf)
        try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
            phaseEstimate: estimate, baselines: engine, asOf: asOf, tz: tz)

        XCTAssertNil(try sensitiveDerivation.latestBaseline(metricId: MetricID.hrv, context: "luteal"),
                    "insufficientHistory must fall back to default only, regardless of confidence")
    }

    func testGateDeclinesOnSuppressedDueToContextEvidenceBasisEvenWithHighConfidence() throws {
        let measurements = MeasurementRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        for daysAgo in 1...20 { try insertHRV(measurements, daysAgo: daysAgo, value: 50, asOf: asOf) }
        let engine = BaselineEngine(derivation: sensitiveDerivation, measurements: measurements,
                                    registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)

        let estimate = makeEstimate(phase: .luteal, confidence: 0.95, evidenceBasis: .suppressedDueToContext, asOf: asOf)
        try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
            phaseEstimate: estimate, baselines: engine, asOf: asOf, tz: tz)

        XCTAssertNil(try sensitiveDerivation.latestBaseline(metricId: MetricID.hrv, context: "luteal"),
                    "suppressedDueToContext must fall back to default only, regardless of confidence")
    }

    func testGatePassingRecomputesEveryPhaseConditionedMetric() throws {
        let measurements = MeasurementRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        for daysAgo in 1...20 {
            try insertHRV(measurements, daysAgo: daysAgo, value: 50, asOf: asOf)
            try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: daysAgo, value: 55, asOf: asOf)
        }
        // sleep.efficiency needs both time_asleep and time_in_bed to derive from — feed it directly
        // as a plain baseline-eligible metric instead (sleep.efficiency is itself an interval metric
        // once BaselineEngine reads it back), matching how every other baseline-eligible metric here
        // is exercised: BaselineEngine.recompute reads whatever IntervalRecord history exists for the
        // metric id, regardless of how that metric is ordinarily produced upstream.
        for daysAgo in 1...20 { try insert(measurements, metricId: MetricID.sleepEfficiency, daysAgo: daysAgo, value: 90, asOf: asOf) }

        let engine = BaselineEngine(derivation: sensitiveDerivation, measurements: measurements,
                                    registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        let estimate = makeEstimate(phase: .follicular, confidence: 0.8, evidenceBasis: .calendarOnly, asOf: asOf)
        try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
            phaseEstimate: estimate, baselines: engine, asOf: asOf, tz: tz)

        for metricId in CyclePhaseCovariateCoordinator.phaseConditionedMetricIds {
            XCTAssertNotNil(try sensitiveDerivation.latestBaseline(metricId: metricId, context: "follicular"),
                            "\(metricId) must get a phase-conditioned baseline when the gate passes")
        }
    }

    func testGatePassingNeverTouchesTheExistingDefaultContext() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        for daysAgo in 1...20 { try insertHRV(measurements, daysAgo: daysAgo, value: 50, asOf: asOf) }
        let defaultEngine = BaselineEngine(derivation: defaultDerivation, measurements: measurements,
                                           registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        try defaultEngine.recompute(metricId: MetricID.hrv, asOf: asOf, tz: tz, context: "default")
        let beforeCount = try countBaselines(db.main, context: "default")
        XCTAssertEqual(beforeCount, 1)

        let sensitiveEngine = BaselineEngine(derivation: sensitiveDerivation, measurements: measurements,
                                             registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        let estimate = makeEstimate(phase: .luteal, confidence: 0.8, evidenceBasis: .calendarOnly, asOf: asOf)
        try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
            phaseEstimate: estimate, baselines: sensitiveEngine, asOf: asOf, tz: tz)

        XCTAssertEqual(try countBaselines(db.main, context: "default"), beforeCount,
                       "a phase-conditioned recompute must never additionally write/duplicate the default context")
    }

    // MARK: - Read-side fallback

    func testReadSideFallsBackToDefaultWhenNoPhaseConditionedBaselineExists() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        for daysAgo in 1...20 { try insertHRV(measurements, daysAgo: daysAgo, value: 50, asOf: asOf) }
        let defaultEngine = BaselineEngine(derivation: defaultDerivation, measurements: measurements,
                                           registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        try defaultEngine.recompute(metricId: MetricID.hrv, asOf: asOf, tz: tz, context: "default")

        // No phase-conditioned recompute has ever run — "luteal" context has no rows at all.
        let estimate = makeEstimate(phase: .luteal, confidence: 0.9, evidenceBasis: .calendarOnly, asOf: asOf)
        let result = try XCTUnwrap(try CyclePhaseCovariateCoordinator.phaseAwareCalibration(
            metricId: MetricID.hrv, phaseEstimate: estimate,
            sensitiveDerivation: sensitiveDerivation, defaultDerivation: defaultDerivation))
        XCTAssertEqual(result.covariateContext, "default")
    }

    func testReadSideReturnsNilRatherThanThrowingWhenNothingExistsAtAll() throws {
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let estimate = makeEstimate(phase: .luteal, confidence: 0.9, evidenceBasis: .calendarOnly,
                                    asOf: Date(timeIntervalSince1970: 1_800_000_000))
        let result = try CyclePhaseCovariateCoordinator.phaseAwareCalibration(
            metricId: MetricID.hrv, phaseEstimate: estimate,
            sensitiveDerivation: sensitiveDerivation, defaultDerivation: defaultDerivation)
        XCTAssertNil(result, "no default and no phase-conditioned baseline must read as nil, never throw")
    }

    func testReadSideFallsBackWhenPhaseConditionedBaselineHasTooFewPoints() throws {
        let measurements = MeasurementRepository(db.main)
        let defaultDerivation = DerivationRepository(db.main)
        let sensitiveDerivation = DerivationRepository(db.sensitive)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        for daysAgo in 1...20 { try insertHRV(measurements, daysAgo: daysAgo, value: 50, asOf: asOf) }
        let defaultEngine = BaselineEngine(derivation: defaultDerivation, measurements: measurements,
                                           registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        try defaultEngine.recompute(metricId: MetricID.hrv, asOf: asOf, tz: tz, context: "default")

        // A thin, data-starved "luteal" band — fewer points than
        // `minPointsForConditionedBaseline` (7, from the published contract) — written directly to
        // simulate an early-adoption user who has logged very few luteal-phase days so far. Even
        // though this row exists, it must not be surfaced as a confident phase-conditioned reading.
        let thinLuteal = Baseline(
            id: ULID.newID(), metricId: MetricID.hrv, covariateContext: "luteal", windowDays: 60,
            center: 36, spread: 1, bandLow: 34, bandHigh: 38, nPoints: 3, provisional: true,
            algorithmVersion: BaselineEngine.baselineAlgorithm.id, validFrom: asOf, computedAt: asOf, unit: "ms")
        try sensitiveDerivation.upsertBaseline(thinLuteal)
        XCTAssertLessThan(thinLuteal.nPoints, CyclePhaseCovariateCoordinator.minPointsForConditionedBaseline)

        let estimate = makeEstimate(phase: .luteal, confidence: 0.9, evidenceBasis: .calendarOnly, asOf: asOf)
        let result = try XCTUnwrap(try CyclePhaseCovariateCoordinator.phaseAwareCalibration(
            metricId: MetricID.hrv, phaseEstimate: estimate,
            sensitiveDerivation: sensitiveDerivation, defaultDerivation: defaultDerivation))
        XCTAssertEqual(result.covariateContext, "default",
                       "a too-thin phase-conditioned band must never be surfaced as though reliable")
    }

    // MARK: - Fixtures

    private func makeEstimate(phase: CyclePhase, confidence: Double,
                              evidenceBasis: CyclePhaseEvidenceBasis, asOf: Date) -> CyclePhaseEstimate {
        CyclePhaseEstimate(
            id: ULID.newID(), dateRangeStart: asOf.addingTimeInterval(-3 * 86_400), dateRangeEnd: asOf,
            phase: phase, confidence: confidence, evidenceBasis: evidenceBasis,
            algorithmVersion: "cycle.phase_estimate@1.0.0", computedAt: asOf, updatedAt: asOf,
            originDeviceId: deviceId)
    }

    private func insertHRV(_ measurements: MeasurementRepository, daysAgo: Int, value: Double, asOf: Date) throws {
        try insert(measurements, metricId: MetricID.hrv, daysAgo: daysAgo, value: value, asOf: asOf)
    }

    /// Same shape as `BaselineEngineTests.insert` — a stable per-day external id so a re-insert
    /// corrects that day in place rather than creating a second same-day row.
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

    private func countBaselines(_ connection: SQLiteConnection, context: String) throws -> Int {
        let rows = try connection.query("SELECT COUNT(*) AS c FROM baselines WHERE covariate_context = ?;", [.text(context)])
        return Int(rows.first?.int("c") ?? 0)
    }
}
