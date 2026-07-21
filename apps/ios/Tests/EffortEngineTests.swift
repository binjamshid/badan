import XCTest
@testable import BADAN

/// EPIC-26 — the Effort engine (strain-equivalent).
///
/// The pure-math goldens (`effortScore`, `accumulate`, zone classification, the curve properties)
/// assert the exact numbers the PUBLISHED contract constants produce, and the mirror suite
/// `EffortEngineGoldenTest` on Android asserts the SAME numbers — that cross-platform identity is the
/// acceptance criterion, so the expected values here and there are hand-derived once (Python scratch)
/// and kept byte-identical.
///
/// The DB-backed tests cover what the pure core cannot: a zone-based day/workout flowing through the
/// engine, the sparse-HR reduced-input variant (never a zero-score), and the HR-max-edit backfill
/// supersession fixture (old rows survive, new rows append — I2).
final class EffortEngineTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"
    let tz = "UTC"

    /// The real published contract — the same file the app ships. Goldens assert against THIS, so a
    /// constant edit that would move a score is caught here.
    var spec: EffortSpec { .load(from: .shared) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-effort-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Contract wiring

    func testSpecLoadsPublishedConstants() {
        XCTAssertTrue(spec.isLoaded)
        XCTAssertEqual(spec.dayAlgorithm.id, "effort.day@0.1.0")
        XCTAssertEqual(spec.workoutAlgorithm.id, "effort.workout@0.1.0")
        let p = spec.params
        XCTAssertEqual(p.scaleMax, 100.0, accuracy: 1e-9)
        XCTAssertEqual(p.zoneWeights, [1.0, 1.6, 2.6, 4.2, 6.8])
        XCTAssertEqual(p.logCurveK, 0.045, accuracy: 1e-9)
        XCTAssertEqual(p.zoneFloorPcts, [50, 60, 70, 80, 90])
        XCTAssertEqual(p.hrMaxConstant, 208.0, accuracy: 1e-9)
        XCTAssertEqual(p.hrMaxAgeCoefficient, 0.7, accuracy: 1e-9)
        XCTAssertEqual(p.sparseHrMinSamplesPerMinute, 0.5, accuracy: 1e-9)
        XCTAssertTrue(p.algorithmProvisional, "effort.day is provisional until its constants are validated")
        // maxGap derives from the sparse density: 60 / 0.5 = 120s.
        XCTAssertEqual(p.maxAttributableGapSeconds, 120.0, accuracy: 1e-9)
    }

    /// The contract requires `effort.workout`'s scale + curve to match `effort.day`'s, or a workout's
    /// effort would not be comparable with the day it sits inside. Pin that here.
    func testWorkoutCurveMatchesDayCurve() {
        let registry = AlgorithmRegistry.shared
        XCTAssertEqual(registry.param("effort.workout", "scaleMax"), registry.param("effort.day", "scaleMax"))
        XCTAssertEqual(registry.param("effort.workout", "logCurveK"), registry.param("effort.day", "logCurveK"))
    }

    // MARK: - Pure goldens (identical to EffortEngineGoldenTest.kt)

    func testEffortScoreGoldens() {
        let p = spec.params
        XCTAssertEqual(EffortEngine.effortScore(load: 0, params: p), 0.0, accuracy: 1e-9)
        XCTAssertEqual(EffortEngine.effortScore(load: 10, params: p), 36.2371848378227, accuracy: 1e-9)
        XCTAssertEqual(EffortEngine.effortScore(load: 20, params: p), 59.3430340259401, accuracy: 1e-9)
        XCTAssertEqual(EffortEngine.effortScore(load: 26, params: p), 68.9633058734515, accuracy: 1e-9)
        XCTAssertEqual(EffortEngine.effortScore(load: 100, params: p), 98.8891003461758, accuracy: 1e-9)
        // Bounded above by scaleMax however large the load. At extreme load the exponential underflows
        // to 0 and the score reaches scaleMax exactly (float64), so the bound is `<=`; a realistic load
        // (100 above) stays strictly below it.
        XCTAssertLessThanOrEqual(EffortEngine.effortScore(load: 100_000, params: p), p.scaleMax)
    }

    func testZoneClassificationGoldens() {
        // hrMax 200 → floors [100,120,140,160,180]. A reading lands in the highest zone whose floor it
        // meets; the top zone is open above 180; below 100 is zone 0 (no load).
        let model = try! XCTUnwrap(HRZoneModel.resolve(override: nil, hrMax: 200, age: nil, params: spec.params))
        XCTAssertEqual(model.floorsBpm, [100, 120, 140, 160, 180])
        XCTAssertEqual(model.zoneIndex(bpm: 90), 0)
        XCTAssertEqual(model.zoneIndex(bpm: 100), 1, "exactly on a floor is in that zone")
        XCTAssertEqual(model.zoneIndex(bpm: 119.9), 1)
        XCTAssertEqual(model.zoneIndex(bpm: 120), 2)
        XCTAssertEqual(model.zoneIndex(bpm: 179), 4)
        XCTAssertEqual(model.zoneIndex(bpm: 180), 5)
        XCTAssertEqual(model.zoneIndex(bpm: 260), 5, "above the estimated max is still Z5, never dropped")
    }

    func testEffectiveHrMaxPrecedenceAndAgeDefault() {
        // Override wins.
        XCTAssertEqual(HRZoneModel.effectiveHrMax(hrMax: 185, age: 30, params: spec.params), 185)
        // No override → Tanaka default 208 − 0.7·age. Age 20 → 194.
        XCTAssertEqual(try XCTUnwrap(HRZoneModel.effectiveHrMax(hrMax: nil, age: 20, params: spec.params)), 194.0, accuracy: 1e-9)
        // Neither → nil (the engine then degrades to reduced-input, never invents an age).
        XCTAssertNil(HRZoneModel.effectiveHrMax(hrMax: nil, age: nil, params: spec.params))
        XCTAssertNil(HRZoneModel.resolve(override: nil, hrMax: nil, age: nil, params: spec.params))
    }

    func testStoredOverrideWinsOverDerivedZones() {
        let override = HRZones(zones: [
            HRZone(lowerBpm: 95, upperBpm: 109), HRZone(lowerBpm: 110, upperBpm: 124),
            HRZone(lowerBpm: 125, upperBpm: 139), HRZone(lowerBpm: 140, upperBpm: 154),
            HRZone(lowerBpm: 155, upperBpm: 190),
        ])
        let model = try! XCTUnwrap(HRZoneModel.resolve(override: override, hrMax: 200, age: nil, params: spec.params))
        XCTAssertEqual(model.floorsBpm, [95, 110, 125, 140, 155], "override floors win over the hrMax-derived ones")
        // A malformed override (wrong count) is ignored → falls through to the derived zones.
        let bad = HRZones(zones: Array(override.zones.dropLast()))
        let fallback = try! XCTUnwrap(HRZoneModel.resolve(override: bad, hrMax: 200, age: nil, params: spec.params))
        XCTAssertEqual(fallback.floorsBpm, [100, 120, 140, 160, 180])
    }

    func testAccumulateGoldenAndGapClamp() {
        let p = spec.params
        let model = HRZoneModel(floorsBpm: [100, 120, 140, 160, 180]) // hrMax 200
        // A: ten Z3 (150 bpm) samples 60s apart, window 600s → 10 min of Z3, load 26, score 68.96…
        let a = (0..<10).map { (t: Double($0) * 60, bpm: 150.0) }
        let accA = EffortEngine.accumulate(samples: a, windowEnd: 600, model: model, params: p)
        XCTAssertEqual(accA.coveredSeconds, 600, accuracy: 1e-9)
        XCTAssertEqual(accA.minutesPerZone, [0, 0, 10, 0, 0])
        XCTAssertEqual(accA.load, 26.0, accuracy: 1e-9)
        XCTAssertEqual(EffortEngine.effortScore(load: accA.load, params: p), 68.9633058734515, accuracy: 1e-9)

        // B: an hour-long recording gap is clamped to maxGap (120s), not credited as 3600s of Z3.
        let b = [(t: 0.0, bpm: 150.0), (t: 10.0, bpm: 150.0), (t: 3610.0, bpm: 150.0)]
        let accB = EffortEngine.accumulate(samples: b, windowEnd: 3670, model: model, params: p)
        XCTAssertEqual(accB.coveredSeconds, 190, accuracy: 1e-9, "10 + clamped 120 + 60, not 10 + 3600 + 60")
        XCTAssertEqual(accB.load, 8.2333333333333, accuracy: 1e-9)
    }

    // MARK: - Curve properties (the A3 mandate: monotonic + diminishing)

    func testEffortScoreIsMonotonicAndDiminishing() {
        let p = spec.params
        var prev = -1.0
        var prevMarginal = Double.greatestFiniteMagnitude
        var load = 0.0
        while load <= 300 {
            let s = EffortEngine.effortScore(load: load, params: p)
            XCTAssertGreaterThan(s, prev, "score must strictly increase with load (monotonic) at L=\(load)")
            if load > 0 {
                let marginal = s - EffortEngine.effortScore(load: load - 0.5, params: p)
                XCTAssertLessThan(marginal, prevMarginal + 1e-12,
                                  "each extra weighted-minute must add no more than the last (diminishing) at L=\(load)")
                prevMarginal = marginal
            }
            prev = s
            load += 0.5
        }
    }

    func testWeightedMinutesMonotonicInTimeAndIntensity() {
        let w = spec.params.zoneWeights
        // More minutes in a zone → strictly more load.
        let base = EffortEngine.weightedZoneMinutes(minutesPerZone: [5, 5, 5, 0, 0], zoneWeights: w)
        let more = EffortEngine.weightedZoneMinutes(minutesPerZone: [5, 5, 6, 0, 0], zoneWeights: w)
        XCTAssertGreaterThan(more, base)
        // Same minutes moved to a higher zone → strictly more load (higher zones never lower the score).
        let low = EffortEngine.weightedZoneMinutes(minutesPerZone: [10, 0, 0, 0, 0], zoneWeights: w)
        let high = EffortEngine.weightedZoneMinutes(minutesPerZone: [0, 0, 0, 0, 10], zoneWeights: w)
        XCTAssertGreaterThan(high, low)
    }

    // MARK: - Sparse detection

    func testSparseDetectionGates() {
        let p = spec.params
        // Workout gate: density in samples/min against the 0.5 threshold.
        XCTAssertEqual(EffortEngine.hrDensityPerMinute(sampleCount: 30, windowSeconds: 600), 3.0, accuracy: 1e-9)
        XCTAssertLessThan(EffortEngine.hrDensityPerMinute(sampleCount: 2, windowSeconds: 3600), p.sparseHrMinSamplesPerMinute)
        XCTAssertGreaterThanOrEqual(EffortEngine.hrDensityPerMinute(sampleCount: 60, windowSeconds: 3600), p.sparseHrMinSamplesPerMinute)
    }

    func testGuidanceBandThirds() {
        XCTAssertEqual(EffortEngine.guidanceBand(readiness: 10), .gentler)
        XCTAssertEqual(EffortEngine.guidanceBand(readiness: 33), .gentler)
        XCTAssertEqual(EffortEngine.guidanceBand(readiness: 50), .typical)
        XCTAssertEqual(EffortEngine.guidanceBand(readiness: 66), .typical)
        XCTAssertEqual(EffortEngine.guidanceBand(readiness: 67), .headroom)
        XCTAssertEqual(EffortEngine.guidanceBand(readiness: 95), .headroom)
    }

    // MARK: - DB: zone-based day effort

    func testComputeDayZoneBasedAppendsScore() throws {
        let (measurements, derivation, catalog) = repos()
        try saveProfile(catalog, hrMax: 200)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        // 30 minutes of Z3 (150 bpm) sampled every 30s inside the day.
        for i in 0..<60 { insertHR(measurements, bpm: 150, at: dayStart.addingTimeInterval(Double(i) * 30)) }

        let engine = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec,
                                  profileProvider: { try catalog.userProfile() })
        let result = try XCTUnwrap(try engine.computeDay(asOf: asOf, tz: tz))
        guard case .zoneBased = result.variant else { return XCTFail("expected a zone-based result") }

        let row = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.effortDay, periodKey: result.periodKey))
        XCTAssertEqual(row.unit, "score_0_100")
        XCTAssertGreaterThan(row.value, 0)
        XCTAssertLessThan(row.value, spec.params.scaleMax)
        XCTAssertTrue(row.provisional)
        XCTAssertEqual(row.algorithmId, "effort.day")
        // The manifest carries one input per zone (the zone-time bars read this straight off it).
        let manifest = try XCTUnwrap(try derivation.manifest(id: XCTUnwrap(row.inputManifestId)))
        XCTAssertEqual(manifest.inputs.count, HRZones.zoneCount)
    }

    // MARK: - DB: reduced-input variant (never a zero-score) — the honesty acceptance

    func testSparseHRUserGetsLabeledActivityLoadNotZero() throws {
        let (measurements, derivation, catalog) = repos()
        // A phone-only user: an HR max is set (so zones COULD be drawn) but there is NO continuous HR —
        // only steps and active energy. Scored on zones this reads 0; the engine must not shame them.
        try saveProfile(catalog, hrMax: 190)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        insertInterval(measurements, metricId: MetricID.activeEnergy, value: 1800, at: asOf) // 1800 kJ
        insertInterval(measurements, metricId: MetricID.steps, value: 12_000, at: asOf)

        let engine = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec,
                                  profileProvider: { try catalog.userProfile() })
        let result = try XCTUnwrap(try engine.computeDay(asOf: asOf, tz: tz))
        guard case let .reducedInput(load, reason) = result.variant else { return XCTFail("expected reduced-input") }
        XCTAssertEqual(reason, .sparseHeartRate)
        XCTAssertEqual(load.kind, .activeEnergy, "active energy is preferred over steps")

        let row = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.effortDay, periodKey: result.periodKey))
        XCTAssertNotEqual(row.unit, "score_0_100", "a reduced-input row is distinguished by its activity unit")
        XCTAssertEqual(row.value, 1800, accuracy: 1e-9, "the honest movement magnitude, never a zero-score")
        XCTAssertTrue(row.provisional)
    }

    func testNoHRMaxAndNoAgeFallsToActivityLoad() throws {
        let (measurements, derivation, catalog) = repos()
        // No hrMax, no birthYear → no zones can be drawn even though HR exists. Degrade honestly.
        try saveProfile(catalog, hrMax: nil, birthYear: nil)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        for i in 0..<60 { insertHR(measurements, bpm: 150, at: dayStart.addingTimeInterval(Double(i) * 30)) }
        insertInterval(measurements, metricId: MetricID.activeEnergy, value: 900, at: asOf)

        let engine = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec,
                                  profileProvider: { try catalog.userProfile() })
        let result = try XCTUnwrap(try engine.computeDay(asOf: asOf, tz: tz))
        guard case let .reducedInput(_, reason) = result.variant else { return XCTFail("expected reduced-input") }
        XCTAssertEqual(reason, .noHeartRateMax, "the absence is 'no zones', distinct from sparse HR")
    }

    func testNoDataDayIsAGapNotAZero() throws {
        let (measurements, derivation, catalog) = repos()
        try saveProfile(catalog, hrMax: 190)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec,
                                  profileProvider: { try catalog.userProfile() })
        XCTAssertNil(try engine.computeDay(asOf: asOf, tz: tz), "no HR and no movement → no number is honest")
        XCTAssertNil(try derivation.latestDerived(metricId: MetricID.effortDay, periodKey: "day:" + DayAttribution.localDayKey(asOf, tz: tz)))
    }

    // MARK: - DB: HR-max edit backfill supersession (I2 acceptance fixture)

    func testHRMaxEditBackfillAppendsAndOldRowsSurvive() throws {
        let (measurements, derivation, catalog) = repos()
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        for i in 0..<60 { insertHR(measurements, bpm: 150, at: dayStart.addingTimeInterval(Double(i) * 30)) }
        let periodKey = "day:" + DayAttribution.localDayKey(asOf, tz: tz)

        // First belief: a low max (150 bpm sits in Z5, weight 6.8 → a high score).
        try saveProfile(catalog, hrMax: 160)
        let clock1 = FixedClock(asOf)
        let engineA = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                   clock: clock1, deviceId: deviceId, spec: spec, profileProvider: { try catalog.userProfile() })
        _ = try engineA.computeDay(asOf: asOf, tz: tz)
        let firstRow = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.effortDay, periodKey: periodKey))
        let firstValue = firstRow.value
        let firstComputedAt = firstRow.computedAt

        // The user corrects their max UP (150 bpm now sits lower — a different, lower score). Recompute
        // the historical window at a LATER clock.
        try saveProfile(catalog, hrMax: 210)
        let clock2 = FixedClock(asOf.addingTimeInterval(3600))
        let engineB = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                   clock: clock2, deviceId: deviceId, spec: spec, profileProvider: { try catalog.userProfile() })
        let touched = try engineB.recompute(from: dayStart, to: asOf, tz: tz)
        XCTAssertGreaterThanOrEqual(touched, 1)

        let all = try derivation.allDerived(metricId: MetricID.effortDay).filter { $0.periodKey == periodKey }
        XCTAssertEqual(all.count, 2, "the edit APPENDS a fresh row; the pre-edit row is never mutated or deleted (I2)")

        // The OLD row survives verbatim — same computedAt, same pre-edit value, same algorithm id.
        let old = try XCTUnwrap(all.first { $0.computedAt == firstComputedAt })
        XCTAssertEqual(old.value, firstValue, accuracy: 1e-9, "the superseded row keeps its original value")
        XCTAssertEqual(old.algorithmId, "effort.day")

        // The latest read is the NEW belief, and it differs (a higher max → a lower score here).
        let latest = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.effortDay, periodKey: periodKey))
        XCTAssertEqual(latest.computedAt, clock2.now())
        XCTAssertLessThan(latest.value, firstValue, "raising the max moved 150 bpm into lower zones → lower score")
    }

    func testRecomputeIsIdempotentOverUnchangedData() throws {
        let (measurements, derivation, catalog) = repos()
        try saveProfile(catalog, hrMax: 200)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        for i in 0..<60 { insertHR(measurements, bpm: 150, at: dayStart.addingTimeInterval(Double(i) * 30)) }
        let periodKey = "day:" + DayAttribution.localDayKey(asOf, tz: tz)

        let engine = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec, profileProvider: { try catalog.userProfile() })
        _ = try engine.computeDay(asOf: asOf, tz: tz)
        _ = try engine.computeDay(asOf: asOf, tz: tz)
        let rows = try derivation.allDerived(metricId: MetricID.effortDay).filter { $0.periodKey == periodKey }
        XCTAssertEqual(rows.count, 1, "an unchanged recompute must not grow the append-only table")
    }

    // MARK: - DB: a version bump always records, even when the value is unchanged (I2 auditability)

    func testVersionBumpAppendsEvenWhenValueUnchanged() throws {
        let (measurements, derivation, catalog) = repos()
        try saveProfile(catalog, hrMax: 200)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        for i in 0..<60 { insertHR(measurements, bpm: 150, at: dayStart.addingTimeInterval(Double(i) * 30)) }
        let periodKey = "day:" + DayAttribution.localDayKey(asOf, tz: tz)

        // First pass at the published version.
        let engineA = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                   clock: FixedClock(asOf), deviceId: deviceId, spec: spec,
                                   profileProvider: { try catalog.userProfile() })
        _ = try engineA.computeDay(asOf: asOf, tz: tz)
        XCTAssertEqual(try derivation.allDerived(metricId: MetricID.effortDay).filter { $0.periodKey == periodKey }.count, 1)

        // Second pass: identical params, bumped semver, later clock. The score is byte-identical, yet it
        // must APPEND under the new version — never be skipped by the value-only guard (audit finding #5).
        let bumped = EffortSpec(
            dayAlgorithm: AlgorithmVersion(algorithmId: spec.dayAlgorithm.algorithmId, semver: "9.9.9",
                                           introducedIn: spec.dayAlgorithm.introducedIn),
            workoutAlgorithm: AlgorithmVersion(algorithmId: spec.workoutAlgorithm.algorithmId, semver: "9.9.9",
                                               introducedIn: spec.workoutAlgorithm.introducedIn),
            params: spec.params, isLoaded: spec.isLoaded)
        let engineB = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                   clock: FixedClock(asOf.addingTimeInterval(3600)), deviceId: deviceId, spec: bumped,
                                   profileProvider: { try catalog.userProfile() })
        _ = try engineB.computeDay(asOf: asOf, tz: tz)

        let all = try derivation.allDerived(metricId: MetricID.effortDay).filter { $0.periodKey == periodKey }
        XCTAssertEqual(all.count, 2, "same value + bumped version appends, keeping the old row")
        XCTAssertEqual(Set(all.map(\.algorithmVersion)), [spec.dayAlgorithm.semver, "9.9.9"],
                       "both the old and the bumped version are on record")
        XCTAssertEqual(all[0].value, all[1].value, accuracy: 1e-9, "only the version changed, not the value")
    }

    // MARK: - DB: workout effort

    func testComputeWorkoutZoneBasedAndReducedInput() throws {
        let (measurements, derivation, catalog) = repos()
        try saveProfile(catalog, hrMax: 200)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        // A: a workout with dense HR → a zone-based session score.
        let startA = base
        let endA = base.addingTimeInterval(1800) // 30 min
        try insertWorkout(measurements, id: "wkA", start: startA, end: endA, energyKcal: 400)
        for i in 0..<180 { insertHR(measurements, bpm: 155, at: startA.addingTimeInterval(Double(i) * 10)) } // 6/min

        // B: a workout with NO HR (watch didn't record it) but a recorded energy total → activity load.
        let startB = base.addingTimeInterval(7200)
        let endB = startB.addingTimeInterval(1800)
        try insertWorkout(measurements, id: "wkB", start: startB, end: endB, energyKcal: 250)

        let engine = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(endB), deviceId: deviceId, spec: spec, profileProvider: { try catalog.userProfile() })
        let results = try engine.computeWorkouts(from: base.addingTimeInterval(-60), to: endB.addingTimeInterval(60), tz: tz)
        XCTAssertEqual(results.count, 2)

        let rowA = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.effortWorkout, periodKey: "session:wkA"))
        XCTAssertEqual(rowA.unit, "score_0_100")
        XCTAssertGreaterThan(rowA.value, 0)

        let rowB = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.effortWorkout, periodKey: "session:wkB"))
        XCTAssertNotEqual(rowB.unit, "score_0_100", "no HR → labelled activity load, never a zero session score")
        XCTAssertEqual(rowB.value, 250, accuracy: 1e-9)
    }

    // MARK: - DB: guidance

    func testGuidanceReadsReadinessAndPersonalBaseline() throws {
        let (measurements, derivation, catalog) = repos()
        try saveProfile(catalog, hrMax: 200)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let dayKey = DayAttribution.localDayKey(asOf, tz: tz)

        // A low readiness score for the day, and an established personal effort baseline to reference.
        try derivation.appendDerived(DerivedValue(
            id: ULID.newID(), metricId: MetricID.readinessScore, value: 22, unit: "score_0_100",
            periodKey: "day:" + dayKey, provisional: false, algorithmId: "composite.readiness_score",
            algorithmVersion: "2.0.0", computedAt: asOf, updatedAt: asOf, originDeviceId: deviceId))
        try derivation.upsertBaseline(Baseline(
            id: ULID.newID(), metricId: MetricID.effortDay, windowDays: 28, center: 40, spread: 5,
            bandLow: 30, bandHigh: 50, nPoints: 20, provisional: false, algorithmVersion: "effort.day@0.1.0",
            validFrom: asOf, computedAt: asOf, unit: "score_0_100"))

        let engine = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec, profileProvider: { try catalog.userProfile() })
        let guidance = try XCTUnwrap(try engine.guidance(asOf: asOf, tz: tz))
        XCTAssertEqual(guidance.readinessBand, .gentler, "low readiness → a gentler range may suit today")
        XCTAssertEqual(try XCTUnwrap(guidance.suggestedCeiling), 40, accuracy: 1e-9, "the personal soft ceiling is the user's OWN effort baseline centre")
    }

    // MARK: - Fixtures

    private func repos() -> (MeasurementRepository, DerivationRepository, CatalogRepository) {
        (MeasurementRepository(db.main), DerivationRepository(db.main), CatalogRepository(db.main))
    }

    private func saveProfile(_ catalog: CatalogRepository, hrMax: Double?, birthYear: Int? = 1990) throws {
        try catalog.saveUserProfile(UserProfile(
            id: "u-1", birthYear: birthYear, hrMax: hrMax,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)))
    }

    private func insertHR(_ measurements: MeasurementRepository, bpm: Double, at: Date) {
        let s = RawSample(
            id: ULID.newID(), metricId: MetricID.heartRate, value: bpm, unit: "bpm",
            originalValue: bpm, originalUnit: "bpm", startAt: at, endAt: at, tzId: tz,
            provenance: Provenance(sourceId: "watch", ingestionPath: .platformStore, externalId: ULID.newID(),
                                   measuredAt: at, measuredTimezone: tz, recordedAt: at, ingestedAt: at),
            updatedAt: at, originDeviceId: deviceId)
        _ = try? measurements.upsertRawSample(s)
    }

    private func insertInterval(_ measurements: MeasurementRepository, metricId: String, value: Double, at: Date) {
        let dayStart = DayAttribution.startOfDay(at, tz: tz)
        let record = IntervalRecord(
            id: ULID.newID(), metricId: metricId, value: value, unit: "unit",
            startAt: dayStart, endAt: DayAttribution.addingDays(1, to: dayStart, tz: tz), tzId: tz, aggregation: .sum,
            provenance: Provenance(sourceId: "phone", ingestionPath: .platformStore, externalId: ULID.newID(),
                                   measuredAt: dayStart, measuredTimezone: tz, recordedAt: dayStart, ingestedAt: dayStart),
            updatedAt: dayStart, originDeviceId: deviceId)
        _ = try? measurements.upsertIntervalRecord(record)
    }

    private func insertWorkout(_ measurements: MeasurementRepository, id: String, start: Date, end: Date, energyKcal: Double) throws {
        let detail = SessionDetail(workout: WorkoutDetail(
            activityType: "running", totals: WorkoutTotals(energyKcal: energyKcal), sourceWorkoutUUID: id))
        let session = Session(
            id: id, kind: .workout, startAt: start, endAt: end, tzId: tz, detail: detail,
            provenance: Provenance(sourceId: "watch", ingestionPath: .platformStore, externalId: "ext-" + id,
                                   measuredAt: start, measuredTimezone: tz, recordedAt: start, ingestedAt: start),
            updatedAt: start, originDeviceId: deviceId)
        _ = try measurements.upsertSession(session)
    }
}
