import XCTest
@testable import BADAN

/// EPIC-24 — sleep intelligence engine.
///
/// The pure state-machine goldens (`assembleNights`, `score`, and the five sub-computations) assert
/// the exact numbers the PUBLISHED contract constants produce for a fixed input, and the mirror
/// suite `SleepIntelligenceEngineGoldenTest` on Android asserts the SAME numbers — that
/// cross-platform identity is the acceptance criterion, so the expected values here and there are
/// hand-derived once (a scratch reference) and kept identical. Fixtures cover the state machine's
/// hard cases: nap day, all-nighter (missed night), DST night, split night, travel-tz change.
///
/// The DB-backed tests cover what the pure core cannot: sessions/baseline/effort flowing through the
/// engine, the reduced-input (no-Effort) variant, append-only recompute (I2), and idempotency.
final class SleepIntelligenceEngineTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"

    /// The real published contract — the same file the app ships. Goldens are asserted against
    /// THIS, not a fixture, so a constant edit that would move a score is caught here.
    var spec: SleepSpec { .load(from: .shared) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-sleep-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Contract wiring

    func testSpecLoadsEveryConstant() {
        XCTAssertTrue(spec.isLoaded, "the five sleep.* entries must load from the bundled contract")
        XCTAssertEqual(spec.need.algorithm.id, "sleep.need@0.1.0")
        XCTAssertTrue(spec.need.provisional, "seeded constants are provisional → every row is provisional")
        XCTAssertEqual(spec.debtRepaymentFraction, 0.35, accuracy: 1e-9)
        XCTAssertEqual(spec.needDebtHalfLifeDays, 4.0, accuracy: 1e-9)
        XCTAssertEqual(spec.effortFactorSecondsPerPoint, 42.0, accuracy: 1e-9)
        XCTAssertEqual(spec.napCreditFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(spec.displayDebtHalfLifeDays, 7.0, accuracy: 1e-9)
        XCTAssertEqual(spec.debtLookbackDays, 14)
        XCTAssertEqual(spec.consistencyWindowDays, 14)
        XCTAssertEqual(spec.consistencyMinNights, 5)
        XCTAssertEqual(spec.minEpisodeSeconds, 300, accuracy: 1e-9)
        XCTAssertEqual(spec.mergeGapSeconds, 120, accuracy: 1e-9)
    }

    // MARK: - Need goldens (identical to Android)

    func testGoldenNeedEstablishedWithEffort() {
        // baseline 7h, maturity 1.0, effort 10 pts present → +420s; confidence 1.0 → ±30min band.
        let need = SleepIntelligenceEngine.computeNeed(
            baselineDurationSeconds: 25200, needDebtSeconds: 0, priorDayEffort: 10,
            napCreditSeconds: 0, baselineMaturity: 1.0, spec: spec)
        XCTAssertEqual(need.centerSeconds, 25620.0, accuracy: 1e-9)
        XCTAssertEqual(need.lowSeconds, 23820.0, accuracy: 1e-9)
        XCTAssertEqual(need.highSeconds, 27420.0, accuracy: 1e-9)
        XCTAssertEqual(need.confidence, 1.0, accuracy: 1e-9)
        XCTAssertTrue(need.effortPresent)

        let perf = SleepIntelligenceEngine.computePerformance(actualSeconds: 24000, need: need, spec: spec)
        XCTAssertEqual(perf.centerPercent, 93.6768149882904, accuracy: 1e-9)
        XCTAssertEqual(perf.lowPercent, 87.527352297593, accuracy: 1e-9)
        XCTAssertEqual(perf.highPercent, 100.75566750629723, accuracy: 1e-9)
        XCTAssertFalse(perf.showRange, "confidence 1.0 ≥ threshold → shown as a point")
    }

    func testGoldenNeedReducedInputNoEffort() {
        // No effort input → completeness 0.5 → confidence 0.5, band widens to ±45min.
        let need = SleepIntelligenceEngine.computeNeed(
            baselineDurationSeconds: 25200, needDebtSeconds: 0, priorDayEffort: nil,
            napCreditSeconds: 0, baselineMaturity: 1.0, spec: spec)
        XCTAssertEqual(need.centerSeconds, 25200.0, accuracy: 1e-9)
        XCTAssertEqual(need.lowSeconds, 22500.0, accuracy: 1e-9)
        XCTAssertEqual(need.highSeconds, 27900.0, accuracy: 1e-9)
        XCTAssertEqual(need.confidence, 0.5, accuracy: 1e-9)
        XCTAssertFalse(need.effortPresent, "the reduced-input variant is flagged, never silently degraded")

        let perf = SleepIntelligenceEngine.computePerformance(actualSeconds: 24000, need: need, spec: spec)
        XCTAssertEqual(perf.centerPercent, 95.23809523809523, accuracy: 1e-9)
        XCTAssertTrue(perf.showRange, "confidence 0.5 < 0.6 → shown as a range, no false precision")
    }

    func testGoldenNeedNapCreditSubtracts() {
        // 1h nap → 0.5·3600 = 1800s credit off need.
        let need = SleepIntelligenceEngine.computeNeed(
            baselineDurationSeconds: 25200, needDebtSeconds: 0, priorDayEffort: nil,
            napCreditSeconds: 1800, baselineMaturity: 1.0, spec: spec)
        XCTAssertEqual(need.centerSeconds, 23400.0, accuracy: 1e-9)
    }

    func testGoldenNeedClampsToFloorAndCeiling() {
        let low = SleepIntelligenceEngine.computeNeed(
            baselineDurationSeconds: 10000, needDebtSeconds: 0, priorDayEffort: nil,
            napCreditSeconds: 0, baselineMaturity: 1.0, spec: spec)
        XCTAssertEqual(low.centerSeconds, spec.minNeedSeconds, accuracy: 1e-9, "clamped to the published floor")
        let high = SleepIntelligenceEngine.computeNeed(
            baselineDurationSeconds: 50000, needDebtSeconds: 0, priorDayEffort: nil,
            napCreditSeconds: 0, baselineMaturity: 1.0, spec: spec)
        XCTAssertEqual(high.centerSeconds, spec.maxNeedSeconds, accuracy: 1e-9, "clamped to the published ceiling")
    }

    // MARK: - Forward-pass goldens: debt accumulation across nights

    func testGoldenThreeNightForwardDebt() {
        // Three consecutive nights, baseline 7h maturity 1.0, no effort/naps; actuals 5h/7h/7h.
        // Debt is a forward recurrence: tonight's need lifts with recent shortfall, and the
        // displayed debt trend (7-day half-life) rises as the fortnight's shortfalls accumulate.
        let assembly = makeAssembly(days: ["2026-05-01", "2026-05-02", "2026-05-03"],
                                    asleep: [18000, 25200, 25200])
        let scores = SleepIntelligenceEngine.score(assembly: assembly, baseline: (25200, 1.0),
                                                   effortByDayKey: [:], spec: spec)
        XCTAssertEqual(scores.count, 3)
        XCTAssertEqual(scores[0].need?.centerSeconds ?? 0, 25200.0, accuracy: 1e-6)
        XCTAssertEqual(scores[0].debtSeconds ?? 0, 7200.0, accuracy: 1e-6)
        XCTAssertEqual(scores[1].need?.centerSeconds ?? 0, 27319.0589664394, accuracy: 1e-6)
        XCTAssertEqual(scores[1].debtSeconds ?? 0, 8640.2693491395, accuracy: 1e-6)
        XCTAssertEqual(scores[2].need?.centerSeconds ?? 0, 27605.5772695966, accuracy: 1e-6)
        XCTAssertEqual(scores[2].debtSeconds ?? 0, 10231.2736847264, accuracy: 1e-6)
    }

    // MARK: - All-nighter (missed night is a gap, never a zero)

    func testGoldenMissedNightIsAGapAndDebtDecaysAcrossIt() {
        // Sleep on the 1st and 3rd, nothing on the 2nd. The engine emits no row for the 2nd (a gap,
        // not a fabricated zero), and the 3rd's debt reflects a 2-day decay of the 1st's shortfall.
        let assembly = makeAssembly(days: ["2026-05-01", "2026-05-03"], asleep: [18000, 25200])
        let scores = SleepIntelligenceEngine.score(assembly: assembly, baseline: (25200, 1.0),
                                                   effortByDayKey: [:], spec: spec)
        XCTAssertEqual(scores.count, 2, "the missing night is absent, not scored as zero")
        XCTAssertEqual(scores.map(\.localNight), ["2026-05-01", "2026-05-03"])
        XCTAssertEqual(scores[1].need?.centerSeconds ?? 0, 26981.9090885901, accuracy: 1e-6)
        XCTAssertEqual(scores[1].debtSeconds ?? 0, 7688.3236518451, accuracy: 1e-6)
    }

    func testNoBaselineMeansNoNeedButConsistencyStillComputes() {
        // Honest cold start: without a personal sleep-duration baseline there is no need/performance/
        // debt, but timing consistency does not depend on the baseline and stands alone.
        let assembly = makeAssembly(days: (1...6).map { String(format: "2026-05-%02d", $0) },
                                    asleep: Array(repeating: 25200, count: 6))
        let scores = SleepIntelligenceEngine.score(assembly: assembly, baseline: nil,
                                                   effortByDayKey: [:], spec: spec)
        XCTAssertTrue(scores.allSatisfy { $0.need == nil && $0.performance == nil && $0.debtSeconds == nil })
        XCTAssertNotNil(scores.last?.consistency, "consistency does not need a baseline")
    }

    // MARK: - Split night (two clusters, one night)

    func testGoldenSplitNightMergesAndCountsInterClusterGap() {
        // Two primary clusters one night: 23:00–02:00 then 02:30–06:30. They fold into one night
        // (7h asleep), and the 30-minute gap between them is a disturbance the sleeper lived through.
        let base = try! XCTUnwrap(DayAttribution.date(fromDayKey: "2026-05-01", tz: "UTC")).timeIntervalSince1970
        let c1 = SleepSessionInput(sessionId: "c1", kind: .primary, startEpoch: base + 23 * 3600,
                                   endEpoch: base + 26 * 3600, tzId: "UTC", asleepSeconds: 10800,
                                   inBedSeconds: 10800, awakeIntervals: [], hasStages: true)
        let c2 = SleepSessionInput(sessionId: "c2", kind: .primary, startEpoch: base + 26.5 * 3600,
                                   endEpoch: base + 30.5 * 3600, tzId: "UTC", asleepSeconds: 14400,
                                   inBedSeconds: 14400, awakeIntervals: [], hasStages: true)
        let assembly = SleepIntelligenceEngine.assembleNights([c2, c1]) // deliberately out of order

        XCTAssertEqual(assembly.nights.count, 1, "two clusters of one night are one night")
        let night = assembly.nights[0]
        XCTAssertEqual(night.localNight, "2026-05-02")
        XCTAssertEqual(night.asleepSeconds, 25200, accuracy: 1e-9, "a split night is one night's sleep")
        XCTAssertEqual(night.sessionIds, ["c1", "c2"], "clusters kept in chronological order for lineage")
        XCTAssertEqual(night.bedSecondsOfDay, 82800, accuracy: 1e-9, "bedtime is the earliest cluster's start (23:00)")
        XCTAssertEqual(night.wakeSecondsOfDay, 23400, accuracy: 1e-9, "wake is the latest cluster's end (06:30)")
        XCTAssertEqual(SleepIntelligenceEngine.countDisturbances(night.awakeIntervals, spec: spec), 1,
                       "the inter-cluster gap is one disturbance")
    }

    // MARK: - Disturbance counting

    func testGoldenDisturbanceMergeAndThreshold() {
        // Two 200s episodes 50s apart merge (gap ≤ 120s) into one 450s disturbance ≥ 300s → 1;
        // a far 400s episode → 1; total 2.
        let two = [SleepInterval(start: 1000, end: 1200), SleepInterval(start: 1250, end: 1450),
                   SleepInterval(start: 3000, end: 3400)]
        XCTAssertEqual(SleepIntelligenceEngine.countDisturbances(two, spec: spec), 2)
        // Two 100s episodes 50s apart merge to 200s, which is below the 300s floor → 0.
        let below = [SleepInterval(start: 0, end: 100), SleepInterval(start: 150, end: 250)]
        XCTAssertEqual(SleepIntelligenceEngine.countDisturbances(below, spec: spec), 0)
    }

    // MARK: - Consistency

    func testGoldenConsistencyTightWrapAndScattered() {
        XCTAssertEqual(SleepIntelligenceEngine.computeConsistency(
            bedTimes: Array(repeating: 82800, count: 5), wakeTimes: Array(repeating: 25200, count: 5),
            spec: spec), 100.0, accuracy: 1e-9, "identical timing → perfect consistency")

        // Bedtimes straddling midnight are close, not 24h apart — the spread is wrap-aware.
        let bed = [86280.0, 600, 85980, 300, 0]
        XCTAssertEqual(SleepIntelligenceEngine.circularSpreadSeconds(bed), 350.679340708859, accuracy: 1e-6)
        XCTAssertEqual(SleepIntelligenceEngine.computeConsistency(
            bedTimes: bed, wakeTimes: Array(repeating: 25200, count: 5), spec: spec),
            98.37648453375529, accuracy: 1e-6)

        let scattered = [75600.0, 82800, 79200, 86399, 72000]
        XCTAssertEqual(SleepIntelligenceEngine.circularSpreadSeconds(scattered), 5090.885989687846, accuracy: 1e-6)
        XCTAssertEqual(SleepIntelligenceEngine.computeConsistency(
            bedTimes: scattered, wakeTimes: Array(repeating: 25200, count: 5), spec: spec),
            76.43108338107479, accuracy: 1e-6)
    }

    // MARK: - DST night (wall-clock second-of-day survives the missing hour)

    func testGoldenDSTWallClockSecondOfDay() {
        // America/New_York springs forward 02:00→03:00 on 2026-03-08. A 07:00 wake is 25200s
        // second-of-day both sides of the transition — wall clock, not elapsed-since-midnight.
        XCTAssertEqual(SleepIntelligenceEngine.localSecondsOfDay(epochSeconds: 1_772_967_600.0, tz: "America/New_York"),
                       25200, accuracy: 1e-9, "07:00 EDT → 25200")
        XCTAssertEqual(SleepIntelligenceEngine.localSecondsOfDay(epochSeconds: 1_772_947_800.0, tz: "America/New_York"),
                       1800, accuracy: 1e-9, "00:30 EST → 1800")
    }

    // MARK: - Travel tz change (the night is computed in the tz at measurement)

    func testGoldenTravelTimezoneAttributesNightsInTheirOwnZone() {
        // A night recorded in Riyadh stays a Riyadh night even after the device flies to London.
        let riyadhEnd = 1_781_064_000.0 // 2026-06-10 07:00 Asia/Riyadh
        XCTAssertEqual(DayAttribution.localNight(sessionEnd: Date(timeIntervalSince1970: riyadhEnd), tz: "Asia/Riyadh"),
                       "2026-06-10")
        XCTAssertEqual(SleepIntelligenceEngine.localSecondsOfDay(epochSeconds: riyadhEnd, tz: "Asia/Riyadh"),
                       25200, accuracy: 1e-9)
        // The SAME instant misread in London time would be 05:00 (18000s) — which is exactly why the
        // engine attributes in the session's own zone, never the device's current one.
        XCTAssertEqual(SleepIntelligenceEngine.localSecondsOfDay(epochSeconds: riyadhEnd, tz: "Europe/London"),
                       18000, accuracy: 1e-9)

        let assembly = SleepIntelligenceEngine.assembleNights([
            SleepSessionInput(sessionId: "riyadh", kind: .primary, startEpoch: riyadhEnd - 7 * 3600,
                              endEpoch: riyadhEnd, tzId: "Asia/Riyadh", asleepSeconds: 25200, inBedSeconds: 25200),
            SleepSessionInput(sessionId: "london", kind: .primary, startEpoch: 1_781_157_600.0 - 7 * 3600,
                              endEpoch: 1_781_157_600.0, tzId: "Europe/London", asleepSeconds: 25200, inBedSeconds: 25200),
        ])
        XCTAssertEqual(assembly.nights.map(\.localNight), ["2026-06-10", "2026-06-11"])
    }

    // MARK: - Nap attribution through the state machine

    func testNapCreditFlowsToTheFollowingNight() {
        // A nap on 2026-05-01 daytime credits the night waking on 2026-05-02 (key − 1 = nap's day).
        let base = try! XCTUnwrap(DayAttribution.date(fromDayKey: "2026-05-01", tz: "UTC")).timeIntervalSince1970
        let nap = SleepSessionInput(sessionId: "nap", kind: .nap, startEpoch: base + 14 * 3600,
                                    endEpoch: base + 15 * 3600, tzId: "UTC", asleepSeconds: 3600, inBedSeconds: 3600)
        let night = SleepSessionInput(sessionId: "n", kind: .primary, startEpoch: base + 23 * 3600,
                                      endEpoch: base + 31 * 3600, tzId: "UTC", asleepSeconds: 25200, inBedSeconds: 28800)
        let assembly = SleepIntelligenceEngine.assembleNights([nap, night])
        XCTAssertEqual(assembly.napSecondsByDayKey["2026-05-01"], 3600, "nap accrues to its own local day")

        let scores = SleepIntelligenceEngine.score(assembly: assembly, baseline: (25200, 1.0),
                                                   effortByDayKey: [:], spec: spec)
        let night2 = try! XCTUnwrap(scores.first { $0.localNight == "2026-05-02" })
        XCTAssertEqual(night2.need?.centerSeconds ?? 0, 23400.0, accuracy: 1e-6,
                       "the prior-day nap lowers this night's need by 0.5·3600")
    }

    // MARK: - DB: recompute appends the wired ids, provisional, reduced-input

    func testRecomputeAppendsAllFiveWiredIdsAsProvisional() throws {
        let tz = "UTC"
        let asOf = try XCTUnwrap(DayAttribution.date(fromDayKey: "2026-05-10", tz: tz)).addingTimeInterval(12 * 3600)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        seedSleepBaseline(derivation, center: 25200, nPoints: 28)
        // Six consecutive nights, one with an awake stage so disturbances can compute.
        for d in 1...6 { try seedNight(measurements, dayKey: String(format: "2026-05-%02d", d + 3), asleep: 25200, withStage: d == 6) }

        try SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                    clock: FixedClock(asOf), deviceId: deviceId).recompute(asOf: asOf, tz: tz)

        XCTAssertGreaterThan(try derivation.allDerived(metricId: MetricID.sleepNeed).count, 0)
        XCTAssertGreaterThan(try derivation.allDerived(metricId: MetricID.sleepPerformance).count, 0)
        XCTAssertGreaterThan(try derivation.allDerived(metricId: MetricID.sleepDebt).count, 0)
        XCTAssertGreaterThan(try derivation.allDerived(metricId: MetricID.sleepConsistency).count, 0)
        XCTAssertEqual(try derivation.allDerived(metricId: MetricID.sleepDisturbances).count, 1,
                       "only the staged night gets a disturbance row; the rest are gaps, not zeros")

        for id in [MetricID.sleepNeed, MetricID.sleepPerformance, MetricID.sleepDebt] {
            let rows = try derivation.allDerived(metricId: id)
            XCTAssertTrue(rows.allSatisfy { $0.provisional }, "\(id) rows must be provisional (seeded constants)")
            XCTAssertTrue(rows.allSatisfy { $0.inputManifestId != nil }, "\(id) rows must carry an InputManifest (I1)")
        }

        // No effort seeded → reduced-input need with confidence 0.5 (maturity 1.0 × completeness 0.5).
        let latestNeed = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.sleepNeed, periodKey: "day:2026-05-09"))
        XCTAssertEqual(latestNeed.confidence ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(latestNeed.value, spec.minNeedSeconds)
        XCTAssertLessThanOrEqual(latestNeed.value, spec.maxNeedSeconds)
    }

    func testRecomputeIsIdempotentThenAppendsOnChange() throws {
        let tz = "UTC"
        let asOf = try XCTUnwrap(DayAttribution.date(fromDayKey: "2026-05-10", tz: tz)).addingTimeInterval(12 * 3600)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        seedSleepBaseline(derivation, center: 25200, nPoints: 28)
        for d in 1...6 { try seedNight(measurements, dayKey: String(format: "2026-05-%02d", d + 3), asleep: 25200, withStage: false) }

        let engine = SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                             clock: FixedClock(asOf), deviceId: deviceId)
        try engine.recompute(asOf: asOf, tz: tz)
        let after1 = try derivation.allDerived(metricId: MetricID.sleepNeed).count
        XCTAssertGreaterThan(after1, 0)

        // Re-running over unchanged data at the same as-of writes nothing (append-only stays lean).
        try engine.recompute(asOf: asOf, tz: tz)
        XCTAssertEqual(try derivation.allDerived(metricId: MetricID.sleepNeed).count, after1,
                       "an unchanged recompute must not grow the log")

        // Change one night's actual sleep and recompute at a LATER clock → the affected day appends a
        // fresh row; the old one is retained (I2).
        try seedNight(measurements, dayKey: "2026-05-09", asleep: 14000, withStage: false)
        let later = FixedClock(asOf.addingTimeInterval(3600))
        try SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                    clock: later, deviceId: deviceId).recompute(asOf: asOf, tz: tz)
        let perfRows = try derivation.allDerived(metricId: MetricID.sleepPerformance).filter { $0.periodKey == "day:2026-05-09" }
        XCTAssertGreaterThanOrEqual(perfRows.count, 2, "a changed night appends a new row, keeping the old (I2)")
    }

    // MARK: - DB: a version bump always records, even when the value is unchanged (I2 auditability)

    func testVersionBumpAppendsEvenWhenValueUnchanged() throws {
        let tz = "UTC"
        let asOf = try XCTUnwrap(DayAttribution.date(fromDayKey: "2026-05-10", tz: tz)).addingTimeInterval(12 * 3600)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        seedSleepBaseline(derivation, center: 25200, nPoints: 28)
        for d in 1...6 { try seedNight(measurements, dayKey: String(format: "2026-05-%02d", d + 3), asleep: 25200, withStage: false) }

        // First pass at the published version.
        try SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                    clock: FixedClock(asOf), deviceId: deviceId, spec: spec).recompute(asOf: asOf, tz: tz)
        let day9Before = try derivation.allDerived(metricId: MetricID.sleepNeed).filter { $0.periodKey == "day:2026-05-09" }
        XCTAssertEqual(day9Before.count, 1)

        // Second pass with an identical-params spec but a bumped semver, at a later clock. Every value
        // is byte-identical, yet each output must APPEND a fresh row stamped the new version — a version
        // bump is always recorded, never skipped by the value-only guard (audit finding #5).
        let bumped = bumpedSpec(spec, to: "9.9.9")
        try SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                    clock: FixedClock(asOf.addingTimeInterval(3600)), deviceId: deviceId,
                                    spec: bumped).recompute(asOf: asOf, tz: tz)

        let day9 = try derivation.allDerived(metricId: MetricID.sleepNeed).filter { $0.periodKey == "day:2026-05-09" }
        XCTAssertEqual(day9.count, 2, "same value + bumped version appends, keeping the old row")
        XCTAssertEqual(Set(day9.map(\.algorithmVersion)), [spec.need.algorithm.semver, "9.9.9"],
                       "both the old and the bumped version are on record")
        XCTAssertEqual(day9[0].value, day9[1].value, accuracy: 1e-9, "only the version changed, not the value")
    }

    // MARK: - Fixtures

    /// A copy of `base` with every output's semver replaced by `semver` and all params unchanged, so a
    /// recompute reproduces byte-identical values under a NEW algorithm identity — the version-bump case.
    private func bumpedSpec(_ base: SleepSpec, to semver: String) -> SleepSpec {
        func bump(_ o: SleepOutputSpec) -> SleepOutputSpec {
            SleepOutputSpec(algorithm: AlgorithmVersion(algorithmId: o.algorithm.algorithmId, semver: semver,
                                                        introducedIn: o.algorithm.introducedIn),
                            provisional: o.provisional)
        }
        return SleepSpec(
            need: bump(base.need), performance: bump(base.performance), debt: bump(base.debt),
            consistency: bump(base.consistency), disturbances: bump(base.disturbances),
            debtRepaymentFraction: base.debtRepaymentFraction, needDebtHalfLifeDays: base.needDebtHalfLifeDays,
            effortFactorSecondsPerPoint: base.effortFactorSecondsPerPoint, napCreditFraction: base.napCreditFraction,
            rangeHalfWidthSeconds: base.rangeHalfWidthSeconds, minNeedSeconds: base.minNeedSeconds,
            maxNeedSeconds: base.maxNeedSeconds, upperBoundPercent: base.upperBoundPercent,
            lowConfidenceThreshold: base.lowConfidenceThreshold, displayDebtHalfLifeDays: base.displayDebtHalfLifeDays,
            debtLookbackDays: base.debtLookbackDays, maxDebtSeconds: base.maxDebtSeconds,
            consistencyWindowDays: base.consistencyWindowDays, consistencyMinNights: base.consistencyMinNights,
            zeroScoreStdevSeconds: base.zeroScoreStdevSeconds, bedWakeWeightSplit: base.bedWakeWeightSplit,
            minEpisodeSeconds: base.minEpisodeSeconds, mergeGapSeconds: base.mergeGapSeconds, isLoaded: base.isLoaded)
    }

    /// Build a pure assembly of consecutive-or-not nights (each a single primary cluster ending at
    /// 07:00 local UTC) with the given asleep seconds. Bed is 23:00 the prior evening, wake 07:00.
    private func makeAssembly(days: [String], asleep: [Double]) -> SleepAssembly {
        var inputs: [SleepSessionInput] = []
        for (i, day) in days.enumerated() {
            let morning = DayAttribution.date(fromDayKey: day, tz: "UTC")!.timeIntervalSince1970
            let end = morning + 7 * 3600
            let start = end - 8 * 3600
            inputs.append(SleepSessionInput(sessionId: "s\(i)", kind: .primary, startEpoch: start,
                                            endEpoch: end, tzId: "UTC", asleepSeconds: asleep[i],
                                            inBedSeconds: 28800))
        }
        return SleepIntelligenceEngine.assembleNights(inputs)
    }

    private func seedSleepBaseline(_ derivation: DerivationRepository, center: Double, nPoints: Int) {
        let b = Baseline(id: ULID.newID(), metricId: MetricID.timeAsleep, windowDays: 28, center: center,
                         spread: 1800, bandLow: center - 1800, bandHigh: center + 1800, nPoints: nPoints,
                         provisional: false, algorithmVersion: "baseline.rolling_median_mad@2.0.0",
                         validFrom: Date(), computedAt: Date(), unit: "s")
        try? derivation.upsertBaseline(b)
    }

    /// Seed one primary sleep session ending at 07:00 UTC on `dayKey`, attributed to that night.
    private func seedNight(_ measurements: MeasurementRepository, dayKey: String, asleep: Double, withStage: Bool) throws {
        let morning = DayAttribution.date(fromDayKey: dayKey, tz: "UTC")!
        let end = morning.addingTimeInterval(7 * 3600)
        let start = end.addingTimeInterval(-8 * 3600)
        let sid = "sleep-\(dayKey)"
        let session = Session(
            id: sid, kind: .sleepPrimary, startAt: start, endAt: end, tzId: "UTC", localNight: dayKey,
            detail: SessionDetail(timeAsleepSeconds: asleep, timeInBedSeconds: 28800),
            provenance: Provenance(sourceId: "watch", ingestionPath: .platformStore,
                                   externalId: "ext-\(dayKey)", measuredAt: start, measuredTimezone: "UTC",
                                   recordedAt: start, ingestedAt: start),
            updatedAt: end, originDeviceId: deviceId)
        let stages: [SessionStage] = withStage
            ? [SessionStage(sessionId: sid, seq: 0, stage: .awake,
                            startAt: start.addingTimeInterval(3 * 3600), endAt: start.addingTimeInterval(3 * 3600 + 600))]
            : []
        _ = try measurements.upsertSession(session, stages: stages)
    }
}
