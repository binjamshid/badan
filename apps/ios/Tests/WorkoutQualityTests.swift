import XCTest
@testable import BADAN

/// EPIC-42/28 — e1RM formulas, PR detection (the pure decision core AND its append-only
/// persistence), and per-session strength quality signals. Mirrors `StressEngineTests`/
/// `CorrelationEngineTests`' shape: pure-core goldens first, then the DB-backed append/read-latest
/// round trip.
final class WorkoutQualityTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let device = "test-device"

    /// The real published contract — the same file the app ships (mirrors `StressEngineTests.spec`).
    var spec: StrengthSpec { .load(from: .shared) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-workout-quality-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func derivation() -> DerivationRepository { DerivationRepository(db.main) }

    private func set(id: String = "set-1", movementId: String? = "squat", customLabel: String? = nil,
                     kind: StrengthSetKind = .working, seq: Int = 1, reps: Int? = 5,
                     weightValue: Double? = 100, weightUnit: WeightUnit? = .kg,
                     recordedAt: Date? = nil) -> StrengthSet {
        StrengthSetLedger.makeSet(id: id, sessionId: "session-1", movementId: movementId,
                                  customLabel: customLabel, kind: kind, seq: seq, reps: reps,
                                  weightValue: weightValue, weightUnit: weightUnit,
                                  recordedAt: recordedAt ?? clock.now(), updatedAt: clock.now(),
                                  originDeviceId: device)
    }

    // MARK: - Contract wiring

    func testSpecLoadsThePublishedContract() {
        XCTAssertTrue(spec.isLoaded)
        XCTAssertEqual(spec.epleyAlgorithm.id, "workout.strength.e1rm@0.1.0")
        XCTAssertEqual(spec.brzyckiAlgorithm.id, "workout.strength.e1rm_brzycki@0.1.0")
        XCTAssertEqual(spec.prAlgorithm.id, "workout.strength.pr@0.1.0")
        XCTAssertEqual(spec.params.epleyDivisor, 30, accuracy: 1e-9)
        XCTAssertEqual(spec.params.epleyMaxRepsForEstimate, 12)
        XCTAssertEqual(spec.params.brzyckiConstant, 36, accuracy: 1e-9)
        XCTAssertEqual(spec.params.brzyckiRepsCeiling, 37, accuracy: 1e-9)
        XCTAssertEqual(spec.params.brzyckiMaxRepsForEstimate, 10)
        XCTAssertEqual(spec.params.prMinImprovementFraction, 0.005, accuracy: 1e-9)
        XCTAssertEqual(spec.params.prLookbackDays, 365)
    }

    // MARK: - e1RM goldens (hand-computed)

    func testEpleyGoldenAt100kgFor8Reps() {
        // 100 * (1 + 8/30) = 100 * 1.2666... = 126.666...67
        let e = WorkoutQuality.epley1RM(weightKg: 100, reps: 8, spec: spec)
        XCTAssertEqual(e?.valueKg ?? 0, 126.66666667, accuracy: 1e-4)
        XCTAssertEqual(e?.algorithmId, "workout.strength.e1rm")
    }

    func testBrzyckiGoldenAt100kgFor8Reps() {
        // 100 * 36 / (37 - 8) = 3600 / 29 = 124.1379...
        let b = WorkoutQuality.brzycki1RM(weightKg: 100, reps: 8, spec: spec)
        XCTAssertEqual(b?.valueKg ?? 0, 124.13793103, accuracy: 1e-4)
        XCTAssertEqual(b?.algorithmId, "workout.strength.e1rm_brzycki")
    }

    func testBothFormulasAgreeAt60kgFor10RepsAsASanityCheck() {
        // A coincidental exact agreement point: Epley 60*(4/3)=80, Brzycki 60*36/27=80.
        XCTAssertEqual(WorkoutQuality.epley1RM(weightKg: 60, reps: 10, spec: spec)?.valueKg ?? 0, 80, accuracy: 1e-9)
        XCTAssertEqual(WorkoutQuality.brzycki1RM(weightKg: 60, reps: 10, spec: spec)?.valueKg ?? 0, 80, accuracy: 1e-9)
    }

    func testEpleyRefusesPastItsOwnCapButBrzyckiCapsEarlier() {
        // Epley's cap is 12, Brzycki's is 10 (widely considered less reliable at higher reps) — a
        // set past Brzycki's cap can still return an Epley estimate.
        XCTAssertNotNil(WorkoutQuality.epley1RM(weightKg: 100, reps: 11, spec: spec))
        XCTAssertNil(WorkoutQuality.brzycki1RM(weightKg: 100, reps: 11, spec: spec))
        XCTAssertNil(WorkoutQuality.epley1RM(weightKg: 100, reps: 13, spec: spec), "past Epley's own 12-rep cap")
    }

    func testBrzyckiRefusesAtItsSingularityRegardlessOfMaxRepsForEstimate() {
        // A custom spec with a deliberately raised cap (40) still must not evaluate AT or BEYOND
        // reps=37 — the formula's own denominator hits zero there. The ceiling check is a second,
        // independent guard from `maxRepsForEstimate`.
        let raisedCap = StrengthSpec(
            epleyAlgorithm: spec.epleyAlgorithm, brzyckiAlgorithm: spec.brzyckiAlgorithm,
            prAlgorithm: spec.prAlgorithm,
            params: StrengthParams(epleyDivisor: spec.params.epleyDivisor,
                                   epleyMaxRepsForEstimate: spec.params.epleyMaxRepsForEstimate,
                                   brzyckiConstant: spec.params.brzyckiConstant,
                                   brzyckiRepsCeiling: spec.params.brzyckiRepsCeiling,
                                   brzyckiMaxRepsForEstimate: 40,
                                   prMinImprovementFraction: spec.params.prMinImprovementFraction,
                                   prLookbackDays: spec.params.prLookbackDays,
                                   prProvisional: spec.params.prProvisional),
            isLoaded: true)
        XCTAssertNotNil(WorkoutQuality.brzycki1RM(weightKg: 100, reps: 36, spec: raisedCap))
        XCTAssertNil(WorkoutQuality.brzycki1RM(weightKg: 100, reps: 37, spec: raisedCap))
        XCTAssertNil(WorkoutQuality.brzycki1RM(weightKg: 100, reps: 38, spec: raisedCap))
    }

    func testEstimatedOneRepMaxesRefusesForAPartialSet() {
        let partial = set(reps: nil)   // missing reps — cannot estimate a max off it
        XCTAssertTrue(WorkoutQuality.estimatedOneRepMaxes(for: partial, spec: spec).isEmpty)
    }

    // MARK: - PR: pure decision core

    func testFirstCompleteSetForABucketIsARecordWithNoPriorHistory() {
        let candidate = set(reps: 5, weightValue: 100, weightUnit: .kg)
        let outcome = WorkoutQuality.evaluatePR(candidate: candidate, previous: nil, now: clock.now(), spec: spec)
        guard case .newRecord(let record) = outcome else { return XCTFail("expected a first-ever record") }
        XCTAssertEqual(record.weightKg, 100, accuracy: 1e-9)
        XCTAssertEqual(record.bucket, .fourToSix)
    }

    func testStrictlyHeavierBeatsThePreviousRecordPastTheMinimumImprovementFloor() {
        let previous = PersonalRecord(movementId: "squat", bucket: .fourToSix, weightKg: 100, reps: 5,
                                      setId: "prev", achievedAt: clock.now().addingTimeInterval(-86_400))
        // Threshold is 100 * 1.005 = 100.5.
        let notEnough = set(weightValue: 100.3)
        XCTAssertEqual(WorkoutQuality.evaluatePR(candidate: notEnough, previous: previous, now: clock.now(), spec: spec),
                       .notARecord(.notHeavierEnough(previousWeightKg: 100)))

        let enough = set(weightValue: 100.6)
        guard case .newRecord(let record) = WorkoutQuality.evaluatePR(candidate: enough, previous: previous,
                                                                       now: clock.now(), spec: spec)
        else { return XCTFail("100.6kg should clear the 100.5kg improvement floor") }
        XCTAssertEqual(record.weightKg, 100.6, accuracy: 1e-9)
    }

    /// Named edge case: TIE. An exact repeat of the previous best must never fire a PR — a
    /// floating-point-equal weight is definitionally not "a new" record.
    func testExactTieIsNotARecord() {
        let previous = PersonalRecord(movementId: "squat", bucket: .fourToSix, weightKg: 100, reps: 5,
                                      setId: "prev", achievedAt: clock.now().addingTimeInterval(-86_400))
        let tie = set(weightValue: 100)
        XCTAssertEqual(WorkoutQuality.evaluatePR(candidate: tie, previous: previous, now: clock.now(), spec: spec),
                       .notARecord(.notHeavierEnough(previousWeightKg: 100)))
    }

    /// Named edge case: UNIT SWITCH. The previous record was logged in kg; the new set is logged
    /// in lb. Comparing raw numbers (221 > 100) would wrongly fire a PR; comparing canonical
    /// kilograms correctly refuses it, since 221 lb (~100.24 kg) does not clear the 100.5 kg floor.
    func testUnitSwitchDoesNotFabricateAFalsePR() {
        let previous = PersonalRecord(movementId: "squat", bucket: .fourToSix, weightKg: 100, reps: 5,
                                      setId: "prev", achievedAt: clock.now().addingTimeInterval(-86_400))
        let notActuallyHeavier = set(weightValue: 221, weightUnit: .lb)   // ~100.24 kg
        XCTAssertEqual(WorkoutQuality.evaluatePR(candidate: notActuallyHeavier, previous: previous,
                                                 now: clock.now(), spec: spec),
                       .notARecord(.notHeavierEnough(previousWeightKg: 100)),
                       "a raw-number comparison (221 > 100) would wrongly fire a PR here")

        let genuinelyHeavier = set(weightValue: 226, weightUnit: .lb)   // ~102.51 kg, clears 100.5 kg
        guard case .newRecord = WorkoutQuality.evaluatePR(candidate: genuinelyHeavier, previous: previous,
                                                          now: clock.now(), spec: spec)
        else { return XCTFail("226 lb (~102.5 kg) genuinely clears the improvement floor over 100 kg") }
    }

    /// Named edge case: DELOAD. A lighter set in the SAME rep bucket after a heavier one must
    /// never register as a PR "in the wrong direction."
    func testDeloadWeekDoesNotRegisterAsAPR() {
        let previous = PersonalRecord(movementId: "squat", bucket: .fourToSix, weightKg: 100, reps: 5,
                                      setId: "prev", achievedAt: clock.now().addingTimeInterval(-86_400))
        let deload = set(reps: 6, weightValue: 80)   // still buckets to .fourToSix, well below 100
        XCTAssertEqual(WorkoutQuality.evaluatePR(candidate: deload, previous: previous, now: clock.now(), spec: spec),
                       .notARecord(.notHeavierEnough(previousWeightKg: 100)))
    }

    /// A record older than `prLookbackDays` no longer gates a new one — training resumed after a
    /// long gap can set a fresh record even at a lower weight than the stale historical max.
    func testAStalePriorRecordBeyondTheLookbackWindowDoesNotGateANewOne() {
        let ancient = PersonalRecord(movementId: "squat", bucket: .fourToSix, weightKg: 140, reps: 5,
                                     setId: "ancient", achievedAt: clock.now().addingTimeInterval(-400 * 86_400))
        let comeback = set(weightValue: 90)   // much lighter than 140, but the 140 record has aged out
        guard case .newRecord(let record) = WorkoutQuality.evaluatePR(candidate: comeback, previous: ancient,
                                                                       now: clock.now(), spec: spec)
        else { return XCTFail("a 400-day-old record (> 365-day lookback) should no longer gate a new one") }
        XCTAssertEqual(record.weightKg, 90, accuracy: 1e-9)
    }

    // MARK: - PR refusal on partial/incomplete data (never guessed)

    func testPartialSetMissingWeightRefusesRatherThanGuessing() {
        let partial = set(weightValue: nil, weightUnit: nil)
        XCTAssertEqual(WorkoutQuality.evaluatePR(candidate: partial, previous: nil, now: clock.now(), spec: spec),
                       .refused(.partialData))
    }

    func testPartialSetMissingRepsRefusesRatherThanGuessing() {
        let partial = set(reps: nil)
        XCTAssertEqual(WorkoutQuality.evaluatePR(candidate: partial, previous: nil, now: clock.now(), spec: spec),
                       .refused(.partialData))
    }

    func testWarmUpSetIsExcludedFromPRLogicByDefault() {
        let warmUp = set(kind: .warmUp, weightValue: 999)   // even an absurdly heavy warm-up never PRs
        XCTAssertEqual(WorkoutQuality.evaluatePR(candidate: warmUp, previous: nil, now: clock.now(), spec: spec),
                       .refused(.warmUpSet))
    }

    func testNonPositiveRepsRefusesAsUnrecognized() {
        let zeroReps = set(reps: 0)
        XCTAssertEqual(WorkoutQuality.evaluatePR(candidate: zeroReps, previous: nil, now: clock.now(), spec: spec),
                       .refused(.unrecognizedReps))
    }

    // MARK: - PR: append-only persistence (I2), mirrors CorrelationEngine/StressEngine

    func testRecordIfPRAppendsOnANewRecordAndSkipsARepeatThatDoesNotBeatIt() throws {
        let d = derivation()
        let periodKey = StrengthPRPeriodKey.make(movementId: "squat", bucket: .fourToSix)

        let first = try WorkoutQuality.recordIfPR(candidate: set(weightValue: 100), derivation: d,
                                                  clock: clock, deviceId: device, spec: spec)
        guard case .newRecord = first else { return XCTFail("first complete set is always a record") }
        XCTAssertEqual(try d.allDerived(metricId: "workout.strength.pr").count, 1)

        clock.advance(by: 3600)
        let second = try WorkoutQuality.recordIfPR(candidate: set(id: "set-2", weightValue: 100),
                                                   derivation: d, clock: clock, deviceId: device, spec: spec)
        XCTAssertEqual(second, .notARecord(.notHeavierEnough(previousWeightKg: 100)))
        XCTAssertEqual(try d.allDerived(metricId: "workout.strength.pr").count, 1,
                       "a non-improving repeat appends NOTHING — I2 never grows the table on a non-event")

        clock.advance(by: 3600)
        let third = try WorkoutQuality.recordIfPR(candidate: set(id: "set-3", weightValue: 102),
                                                  derivation: d, clock: clock, deviceId: device, spec: spec)
        guard case .newRecord(let record) = third else { return XCTFail("102kg beats 100kg past the improvement floor") }
        XCTAssertEqual(record.weightKg, 102, accuracy: 1e-9)
        let rows = try d.allDerived(metricId: "workout.strength.pr")
        XCTAssertEqual(rows.count, 2, "a genuine new record APPENDS a second row rather than replacing the first")
        XCTAssertEqual(rows.filter { $0.periodKey == periodKey }.count, 2)

        let latest = try d.latestDerived(metricId: "workout.strength.pr", periodKey: periodKey)
        XCTAssertNotNil(latest?.inputManifestId, "the winning row must carry a manifest so its weight is recoverable")
    }

    func testRecordIfPRRefusesAndAppendsNothingForAWarmUpSet() throws {
        let d = derivation()
        let outcome = try WorkoutQuality.recordIfPR(candidate: set(kind: .warmUp), derivation: d,
                                                    clock: clock, deviceId: device, spec: spec)
        XCTAssertEqual(outcome, .refused(.warmUpSet))
        XCTAssertEqual(try d.allDerived(metricId: "workout.strength.pr").count, 0)
    }

    // MARK: - Session quality (pure)

    func testEmptySessionYieldsHonestAbsenceNotFabricatedZeros() {
        let summary = WorkoutQuality.computeStrengthQuality(sets: [], computedAt: clock.now())
        XCTAssertNil(summary.completeness)
        XCTAssertNil(summary.continuity)
        XCTAssertNil(summary.accuracy)
        XCTAssertNil(summary.primarySourceId)
    }

    func testFullyCompleteContiguousSessionScoresPerfectAcrossAllThreeSignals() {
        let sets = [set(id: "1", seq: 1), set(id: "2", seq: 2), set(id: "3", seq: 3)]
        let summary = WorkoutQuality.computeStrengthQuality(sets: sets, computedAt: clock.now())
        XCTAssertEqual(summary.completeness, 1.0)
        XCTAssertEqual(summary.continuity, 1.0)
        XCTAssertEqual(summary.accuracy, 1.0)
        XCTAssertEqual(summary.primarySourceId, "badan.manual")
        XCTAssertEqual(summary.metricFamily, "strength")
    }

    func testAGapInTheSeqRunLowersContinuityEvenWithFewerSetsThanTheMaxSeq() {
        // seq 2 is missing entirely (a deleted/lost set) — 2 live sets present, but the run is 1...3.
        let sets = [set(id: "1", seq: 1), set(id: "3", seq: 3)]
        let summary = WorkoutQuality.computeStrengthQuality(sets: sets, computedAt: clock.now())
        XCTAssertEqual(summary.continuity ?? 0, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testAPartialSetLowersCompletenessWithoutAffectingAccuracy() {
        let sets = [set(id: "1", seq: 1), set(id: "2", seq: 2, weightValue: nil, weightUnit: nil)]
        let summary = WorkoutQuality.computeStrengthQuality(sets: sets, computedAt: clock.now())
        XCTAssertEqual(summary.completeness ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(summary.accuracy, 1.0, "both sets still name a recognized movement")
    }

    func testACustomLabelOnlySetLowersAccuracyWithoutAffectingCompleteness() {
        let sets = [set(id: "1", movementId: "squat", seq: 1),
                   set(id: "2", movementId: nil, customLabel: "Sled push", seq: 2)]
        let summary = WorkoutQuality.computeStrengthQuality(sets: sets, computedAt: clock.now())
        XCTAssertEqual(summary.completeness, 1.0, "a custom-label set can still be fully logged")
        XCTAssertEqual(summary.accuracy ?? 0, 0.5, accuracy: 1e-9)
    }
}
