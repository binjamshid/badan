import XCTest
@testable import BADAN

/// D-36 — on-device calibration from "does this match how you felt" feedback.
///
/// The rules that matter most are the ones that stop personalisation becoming detachment from the
/// measurement: nothing below the event floor, a hard clamp, and never carrying a calibration from
/// one method to another. All three are pure functions of the contract spec, so they are tested
/// without a database.
final class FeedbackCalibrationTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-calib-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var spec: CalibrationSpec { .defaultShared }

    // MARK: - The contract entry

    func testTheCalibrationContractEntryLoads() {
        XCTAssertTrue(spec.isLoaded,
                      "calibration.user_feedback_offset is missing from the bundled contract, so "
                      + "calibration is disabled entirely")
        XCTAssertGreaterThan(spec.minFeedbackEvents, 1)
        XCTAssertGreaterThan(spec.maxOffsetPoints, 0)
    }

    /// Fail-closed, and this is the property that makes the constants contract data rather than
    /// Swift literals: no entry means no calibration at all, never a silent built-in default.
    func testAMissingCalibrationContractEntryDisablesCalibrationEntirely() {
        let events = (0..<50).map { feedbackEvent(.under, daysAgo: $0) }
        XCTAssertNil(FeedbackCalibrator.offset(from: events, asOf: clock.now(), spec: .unavailable),
                     "with no contract entry, even unanimous feedback must produce no offset — a "
                     + "silent default is indistinguishable, on the stored row, from an authored "
                     + "constant.")
    }

    // MARK: - The rules

    func testNoCalibrationIsAppliedBelowMinFeedbackEventsRegardlessOfDirection() {
        for direction in FeedbackDirection.allCases {
            let events = (0..<(spec.minFeedbackEvents - 1)).map { feedbackEvent(direction, daysAgo: $0) }
            XCTAssertNil(FeedbackCalibrator.offset(from: events, asOf: clock.now(), spec: spec),
                         "\(direction) below the floor produced an offset. A handful of taps is a "
                         + "mood, not a signal.")
        }
    }

    /// `nil` and `0` are different: only a real calibration should produce a `calibration:` manifest
    /// input, so the below-floor case must not return a zero offset that reads as "calibrated by 0".
    func testBelowTheFloorReturnsNoOffsetRatherThanZero() {
        let events = (0..<(spec.minFeedbackEvents - 1)).map { feedbackEvent(.under, daysAgo: $0) }
        XCTAssertNil(FeedbackCalibrator.offset(from: events, asOf: clock.now(), spec: spec))
    }

    func testTheLearnedOffsetIsClampedToMaxOffsetPointsUnderUnanimousFeedback() {
        for direction in [FeedbackDirection.over, .under] {
            let events = (0..<200).map { feedbackEvent(direction, daysAgo: $0 % 3) }
            let offset = try! XCTUnwrap(FeedbackCalibrator.offset(from: events, asOf: clock.now(), spec: spec))
            XCTAssertLessThanOrEqual(abs(offset), spec.maxOffsetPoints + 0.0001,
                                     "an unbounded learned offset makes the number meaningless — "
                                     + "the clamp is what keeps a calibrated readiness a readiness")
            XCTAssertEqual(offset > 0, direction == .under,
                           "\(direction) moved the score the wrong way")
        }
    }

    /// Agreement actively pulls a drifting calibration back toward nothing, rather than being
    /// ignored — otherwise "it matches now" could never undo an earlier disagreement.
    func testUnanimousMatchesProduceNoAdjustment() {
        let events = (0..<40).map { feedbackEvent(.matches, daysAgo: $0) }
        let offset = try! XCTUnwrap(FeedbackCalibrator.offset(from: events, asOf: clock.now(), spec: spec))
        XCTAssertEqual(offset, 0, accuracy: 0.0001)
    }

    /// Older feedback counts for less, so a calibration follows how someone feels now rather than
    /// staying anchored to a month they were ill.
    func testRecentFeedbackOutweighsOldFeedback() {
        var events = (0..<20).map { feedbackEvent(.over, daysAgo: 365 + $0) }   // long ago
        events += (0..<20).map { feedbackEvent(.under, daysAgo: $0) }           // recent
        let offset = try! XCTUnwrap(FeedbackCalibrator.offset(from: events, asOf: clock.now(), spec: spec))
        XCTAssertGreaterThan(offset, 0,
                             "recent 'felt worse' feedback should dominate year-old 'felt better' "
                             + "feedback, and it did not")
    }

    // MARK: - Method scoping

    /// The scoping that makes the whole thing coherent: feedback about the sleep-led readiness
    /// method says nothing about the autonomic one.
    func testFeedbackOnOneMethodDoesNotCalibrateAnother() throws {
        let repo = FeedbackRepository(db.main)
        let coordinator = CalibrationCoordinator(feedback: repo, clock: clock, spec: spec)

        for day in 0..<(spec.minFeedbackEvents + 5) {
            try coordinator.recordFeedback(
                metricId: MetricID.readinessScore, periodKey: "day:2026-06-\(String(format: "%02d", day + 1))",
                derivedValueId: "dv-\(day)", algorithmId: "composite.readiness_score",
                algorithmVersion: "2.0.0", direction: .under)
        }

        XCTAssertNotNil(try repo.latestCalibration(metricId: MetricID.readinessScore,
                                                   algorithmId: "composite.readiness_score"),
                        "precondition: the method that received feedback is calibrated")
        XCTAssertNil(try repo.latestCalibration(metricId: MetricID.readinessScore,
                                                algorithmId: "composite.readiness_score_autonomic"),
                     "a method the user never gave feedback on must have no calibration — feedback "
                     + "about one weighting says nothing about another.")
    }

    /// Switching away must RETAIN the old calibration, so switching back restores it rather than
    /// starting from zero.
    func testACalibrationSurvivesSwitchingAwayAndBack() throws {
        let repo = FeedbackRepository(db.main)
        let coordinator = CalibrationCoordinator(feedback: repo, clock: clock, spec: spec)
        for day in 0..<(spec.minFeedbackEvents + 2) {
            try coordinator.recordFeedback(
                metricId: MetricID.readinessScore, periodKey: "day:2026-05-\(String(format: "%02d", day + 1))",
                derivedValueId: "dv-\(day)", algorithmId: "composite.readiness_score",
                algorithmVersion: "2.0.0", direction: .over)
        }
        let original = try XCTUnwrap(try repo.latestCalibration(metricId: MetricID.readinessScore,
                                                               algorithmId: "composite.readiness_score"))

        // Use another method for a while — nothing about the first is touched.
        try coordinator.recordFeedback(
            metricId: MetricID.readinessScore, periodKey: "day:2026-05-20",
            derivedValueId: "dv-x", algorithmId: "composite.readiness_score_equal",
            algorithmVersion: "0.1.0", direction: .under)

        let restored = try XCTUnwrap(try repo.latestCalibration(metricId: MetricID.readinessScore,
                                                               algorithmId: "composite.readiness_score"))
        XCTAssertEqual(restored.id, original.id, "the original method's calibration was disturbed")
    }

    // MARK: - Changing your mind about a day

    /// One opinion per (metric, day, method). Tapping "doesn't match" and then "matches" must leave
    /// one opinion of that day, not two that cancel.
    func testChangingYourMindAboutADayReplacesRatherThanStacks() throws {
        let repo = FeedbackRepository(db.main)
        func record(_ direction: FeedbackDirection) throws {
            try repo.record(DerivedFeedback(
                id: ULID.newID(), metricId: MetricID.readinessScore, periodKey: "day:2026-06-01",
                derivedValueId: "dv-1", algorithmId: "composite.readiness_score",
                algorithmVersion: "2.0.0", direction: direction, createdAt: clock.now()))
        }
        try record(.over)
        try record(.matches)

        let all = try repo.feedback(metricId: MetricID.readinessScore,
                                    algorithmId: "composite.readiness_score")
        XCTAssertEqual(all.count, 1, "a changed opinion stacked instead of replacing")
        XCTAssertEqual(all.first?.direction, .matches)
    }

    // MARK: - Deletion

    /// "Delete my feedback and calibrations" clears both tables and says plainly that it does not
    /// rewrite rows already computed. This asserts the first half; the second half is I2 and is
    /// what makes the disclosure on those rows survive.
    func testDeletingFeedbackClearsBothTables() throws {
        let repo = FeedbackRepository(db.main)
        let coordinator = CalibrationCoordinator(feedback: repo, clock: clock, spec: spec)
        for day in 0..<(spec.minFeedbackEvents + 1) {
            try coordinator.recordFeedback(
                metricId: MetricID.readinessScore, periodKey: "day:2026-04-\(String(format: "%02d", day + 1))",
                derivedValueId: "dv-\(day)", algorithmId: "composite.readiness_score",
                algorithmVersion: "2.0.0", direction: .under)
        }
        XCTAssertNotNil(try repo.latestCalibration(metricId: MetricID.readinessScore,
                                                   algorithmId: "composite.readiness_score"))

        try repo.deleteAllFeedbackAndCalibrations()

        XCTAssertTrue(try repo.feedback(metricId: MetricID.readinessScore,
                                        algorithmId: "composite.readiness_score").isEmpty)
        XCTAssertNil(try repo.latestCalibration(metricId: MetricID.readinessScore,
                                                algorithmId: "composite.readiness_score"))
    }

    // MARK: - What the app SAYS a calibration does (D-36, and ADR-0011 for the second half)
    //
    // Feedback is collected under EVERY derived value, but `ReadinessEngine.activeCalibration()` is
    // the only place a stored calibration is ever read back. That gap is fine; describing it wrongly
    // is not. Both tests below hold a claim about calibration to `CalibrationConsumers` — the one
    // list that names the engines which actually consume one — rather than to "a row exists".

    /// The card must not promise an adjustment for a metric nothing calibrates.
    ///
    /// Before this, tapping "felt worse" on sleep score produced the paragraph "BADAN uses this to
    /// adjust future values of this metric on this device" and a counter that filled to "10 of 10",
    /// after which `sleep.score` was computed exactly as before, forever. The feature is still
    /// offered on those metrics — what changes is that it says what it does.
    func testTheCardPromisesAdjustmentOnlyForMetricsAnEngineActuallyCalibrates() {
        XCTAssertEqual(FeedbackCopy.whatThisDoes(for: MetricID.readinessScore),
                       FeedbackCopy.whatThisDoesAdjusts,
                       "readiness IS calibrated — the card must still say so")
        XCTAssertNotNil(DerivedFeedbackCard.adjustmentProgress(
                            metricId: MetricID.readinessScore, have: 0, spec: spec,
                            calibrationEnabled: true),
                        "the countdown belongs on the one metric that has something to count to")

        for metricId in [MetricID.sleepScore, MetricID.sleepPerformance, MetricID.effortDay,
                         MetricID.stressDayTrend, MetricID.moodEstimate] {
            XCTAssertFalse(CalibrationConsumers.adjustsFutureValues(of: metricId),
                           "precondition: no engine reads a calibration for \(metricId). If one now "
                           + "does, wire it and add it to CalibrationConsumers — do not relax this.")
            XCTAssertEqual(FeedbackCopy.whatThisDoes(for: metricId),
                           FeedbackCopy.whatThisDoesRecordOnly,
                           "\(metricId) is told its feedback adjusts future values, and nothing in "
                           + "the app adjusts them")
            XCTAssertFalse(FeedbackCopy.whatThisDoes(for: metricId).en.contains("adjust future"),
                           "\(metricId)'s copy still promises adjustment")
            XCTAssertNil(DerivedFeedbackCard.adjustmentProgress(
                            metricId: metricId, have: spec.minFeedbackEvents - 1, spec: spec,
                            calibrationEnabled: true),
                         "\(metricId) counts down to an adjustment that never happens — the more "
                         + "convincing half of the same false promise")
        }
    }

    /// `calibrationApplied` on the wire is a statement about METHODOLOGY, so it must be false for a
    /// metric whose engine never reads a calibration — the stored row is not the claim.
    ///
    /// ADR-0011's closed schema keeps health data out of the payload. It cannot keep an untrue field
    /// out, and "a calibration was in force" about a number computed without reference to one is
    /// exactly the kind of statement the route exists to make honestly or not at all.
    func testTelemetryNeverReportsACalibrationAppliedForAMetricNoEngineCalibrates() throws {
        let repo = FeedbackRepository(db.main)
        try seedFeedbackAndCalibration(repo, metricId: MetricID.sleepScore,
                                       algorithmId: "sleep.score", count: 12)
        try seedFeedbackAndCalibration(repo, metricId: MetricID.readinessScore,
                                       algorithmId: "composite.readiness_score", count: 12)

        let collector = FootprintCollector(feedback: repo, registry: .shared,
                                           calibrationEnabled: { true })

        let sleep = try XCTUnwrap(collector.collect(metricIds: [MetricID.sleepScore], floor: 10)
            .first { $0.algorithmId == "sleep.score" })
        XCTAssertEqual(sleep.eventCount, 12, "precondition: the footprint is collected at all")
        XCTAssertFalse(sleep.calibrationApplied,
                       "a calibration row exists for sleep.score, but SleepIntelligenceEngine holds "
                       + "no FeedbackRepository and never reads one — reporting it as applied tells "
                       + "the server something false about how the number was computed")

        let readiness = try XCTUnwrap(
            collector.collect(metricIds: [MetricID.readinessScore], floor: 10)
                .first { $0.algorithmId == "composite.readiness_score" })
        XCTAssertTrue(readiness.calibrationApplied,
                      "readiness IS calibrated — the flag must still be reportable as true, or the "
                      + "fix has emptied the field rather than corrected it")

        // The engine's other gate, mirrored: with the feature off, no offset reaches a value, so
        // nothing was in force regardless of what the table holds.
        let disabled = FootprintCollector(feedback: repo, registry: .shared,
                                          calibrationEnabled: { false })
        XCTAssertFalse(try XCTUnwrap(
            disabled.collect(metricIds: [MetricID.readinessScore], floor: 10)
                .first { $0.algorithmId == "composite.readiness_score" }).calibrationApplied,
            "with calibration switched off ReadinessEngine applies nothing, so no calibration was "
            + "in force for these values")
    }

    /// Feedback on an uncalibrated metric is still RECORDED — the fix is about what is claimed, not
    /// about quietly dropping the feature on every metric but readiness.
    func testFeedbackOnAnUncalibratedMetricIsStillRecorded() throws {
        let repo = FeedbackRepository(db.main)
        let coordinator = CalibrationCoordinator(feedback: repo, clock: clock, spec: spec)
        for day in 0..<(spec.minFeedbackEvents + 2) {
            try coordinator.recordFeedback(
                metricId: MetricID.sleepScore,
                periodKey: "day:2026-02-\(String(format: "%02d", day + 1))",
                derivedValueId: "dv-\(day)", algorithmId: "sleep.score",
                algorithmVersion: "1.0.0", direction: .over)
        }
        XCTAssertEqual(try repo.feedback(metricId: MetricID.sleepScore, algorithmId: "sleep.score").count,
                       spec.minFeedbackEvents + 2,
                       "the answers must still be kept — they are the evidence the constants are "
                       + "waiting on (priority 3)")
    }

    // MARK: - What a calibrated row says about itself

    /// A calibrated row discloses its calibration through the manifest, and a reader can tell a
    /// contract-only row from a calibrated one from the manifest ALONE — no second table, no extra
    /// column, no out-of-band knowledge. That is what keeps I1 true for a personalised number.
    func testACalibratedRowDisclosesItsCalibrationThroughTheManifestAlone() throws {
        let fixture = try seededEngine(direction: .under)
        _ = try fixture.engine.compute(asOf: clock.now(), tz: fixture.tz)

        let row = try XCTUnwrap(try fixture.derivation.latestDerived(
            metricId: MetricID.readinessScore,
            periodKey: DayAttribution.dayPeriodKey(clock.now(), tz: fixture.tz)))
        let manifestId = try XCTUnwrap(row.inputManifestId,
                                       "a calibrated row must always carry a manifest — without one "
                                       + "the adjustment is undisclosable")
        let manifest = try XCTUnwrap(try fixture.derivation.manifest(id: manifestId))

        let calibrationInputs = manifest.inputs.filter {
            $0.recordId.hasPrefix(MetricCalibration.manifestRecordIdPrefix)
        }
        XCTAssertEqual(calibrationInputs.count, 1,
                       "exactly one calibration: input identifies which calibration moved this row")
        // The reserved id resolves to a real stored calibration — the disclosure is a pointer, not
        // a label.
        let id = String(calibrationInputs[0].recordId
            .dropFirst(MetricCalibration.manifestRecordIdPrefix.count))
        XCTAssertNotNil(try fixture.feedback.calibration(id: id),
                        "the calibration: input must resolve to a stored calibration row")
    }

    /// `provisional` means "the constants that produced this are not validated". A calibrated row is
    /// the contract default PLUS an unvalidated personal offset — less contract-backed, not more —
    /// so clearing the flag would be backwards.
    func testACalibratedRowIsStillProvisional() throws {
        let fixture = try seededEngine(direction: .under)
        _ = try fixture.engine.compute(asOf: clock.now(), tz: fixture.tz)

        let row = try XCTUnwrap(try fixture.derivation.latestDerived(
            metricId: MetricID.readinessScore,
            periodKey: DayAttribution.dayPeriodKey(clock.now(), tz: fixture.tz)))
        XCTAssertTrue(row.provisional,
                      "a calibrated row cleared provisional. It is the default constants plus an "
                      + "unvalidated personal offset, so it is LESS contract-backed than an "
                      + "uncalibrated one.")
    }

    /// The skip-write hole, closed. If a calibration changes but the adjusted value happens to round
    /// to the same number, skipping would leave the latest row pointing at the OLD calibration
    /// through its manifest — a row misreporting its own provenance.
    func testAChangedCalibrationAppendsAFreshRowEvenWhenTheComputedValueIsUnchanged() throws {
        let fixture = try seededEngine(direction: .under)
        let periodKey = DayAttribution.dayPeriodKey(clock.now(), tz: fixture.tz)
        let raw = try XCTUnwrap(try fixture.engine.compute(asOf: clock.now(), tz: fixture.tz)?.computation.score)
        let afterFirst = try rowCount(fixture.derivation, periodKey: periodKey)
        XCTAssertEqual(afterFirst, 1, "precondition: one row for the day so far")

        // Re-running with nothing changed must NOT append — the skip check still works.
        _ = try fixture.engine.compute(asOf: clock.now(), tz: fixture.tz)
        XCTAssertEqual(try rowCount(fixture.derivation, periodKey: periodKey), afterFirst,
                       "an unchanged re-run must still skip")

        // A calibration large enough to clamp the published value to the 100 ceiling.
        try fixture.feedback.appendCalibration(MetricCalibration(
            id: ULID.newID(), metricId: MetricID.readinessScore,
            algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0",
            offset: 100 - raw + 50, sampleCount: 99,
            computedAt: clock.now().addingTimeInterval(60)))
        _ = try fixture.engine.compute(asOf: clock.now(), tz: fixture.tz)
        let afterSecond = try rowCount(fixture.derivation, periodKey: periodKey)
        XCTAssertEqual(afterSecond, afterFirst + 1, "a new calibration must append")

        // A THIRD calibration that clamps to the same 100. The published value is byte-identical to
        // the previous row and ONLY the calibration id differs — the case the skip check was blind
        // to before D-36 added the id to it.
        try fixture.feedback.appendCalibration(MetricCalibration(
            id: ULID.newID(), metricId: MetricID.readinessScore,
            algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0",
            offset: 100 - raw + 80, sampleCount: 100,
            computedAt: clock.now().addingTimeInterval(120)))
        _ = try fixture.engine.compute(asOf: clock.now(), tz: fixture.tz)

        XCTAssertEqual(try rowCount(fixture.derivation, periodKey: periodKey), afterSecond + 1,
                       "a changed calibration did not append even though the published value was "
                       + "identical. The latest row would keep pointing at the old calibration "
                       + "through its manifest — misreporting its own provenance. Same rule that "
                       + "already forces an append on a version bump.")
    }

    /// Switching calibration off stops future adjustment and leaves already-calibrated rows intact
    /// (I2). The surface says exactly this, so it has to be true.
    func testDisablingCalibrationStopsFutureAdjustmentAndLeavesEarlierRowsIntact() throws {
        let on = try seededEngine(direction: .under)
        let periodKey = DayAttribution.dayPeriodKey(clock.now(), tz: on.tz)
        _ = try on.engine.compute(asOf: clock.now(), tz: on.tz)
        let calibratedRows = try rows(on.derivation, periodKey: periodKey)
        XCTAssertEqual(calibratedRows.count, 1)
        let calibrated = calibratedRows[0]
        XCTAssertTrue(try hasCalibrationInput(on.derivation, calibrated),
                      "precondition: the first row really was calibrated")

        // Same database, same data, calibration switched off.
        let off = ReadinessEngine(derivation: on.derivation, measurements: on.measurements,
                                  clock: clock, deviceId: "test-device",
                                  feedbackRepo: on.feedback, calibrationEnabled: { false })
        _ = try off.compute(asOf: clock.now(), tz: on.tz)

        let after = try rows(on.derivation, periodKey: periodKey)
        XCTAssertEqual(after.count, 2, "disabling calibration must append an uncalibrated row")
        let fresh = try XCTUnwrap(after.first { $0.id != calibrated.id })
        XCTAssertFalse(try hasCalibrationInput(on.derivation, fresh),
                       "with calibration off, a newly computed row must carry no calibration input")

        // The earlier calibrated row still exists and still discloses its adjustment (I2).
        XCTAssertTrue(try hasCalibrationInput(on.derivation, calibrated),
                      "an already-calibrated row must keep disclosing its calibration")
    }

    /// I1 stated as a test: a reader can distinguish a contract-only row from a calibrated one from
    /// the manifest ALONE. `INVARIANTS.md` gained a sentence under I1 saying exactly this, and this
    /// is what keeps that sentence true.
    func testAReaderCanDistinguishAContractOnlyRowFromACalibratedRowFromTheManifestAlone() throws {
        // Uncalibrated: same engine, no feedback repository at all.
        let tz = TimeZone.current.identifier
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        _ = try IngestionPipeline(measurements: measurements, catalog: CatalogRepository(db.main),
                                  reconciliation: ReconciliationRepository(db.main),
                                  registry: .shared, clock: clock, deviceId: "test-device")
            .ingest(from: FakeHealthStore(clock: clock, historyDays: 90, tz: tz),
                    range: HealthDateRange(start: clock.now().addingTimeInterval(-90 * 86_400),
                                           end: clock.now()))
        try BaselineEngine(derivation: derivation, measurements: measurements, registry: .shared,
                           clock: clock, deviceId: "test-device")
            .recomputeAll(asOf: clock.now(), tz: tz, includeInterimReadinessComposite: false)

        _ = try ReadinessEngine(derivation: derivation, measurements: measurements,
                                clock: clock, deviceId: "test-device")
            .compute(asOf: clock.now(), tz: tz)
        let periodKey = DayAttribution.dayPeriodKey(clock.now(), tz: tz)
        let plain = try XCTUnwrap(try rows(derivation, periodKey: periodKey).first)
        XCTAssertFalse(try hasCalibrationInput(derivation, plain),
                       "a contract-only row must carry no calibration input")
        XCTAssertNotNil(plain.inputManifestId,
                        "an uncalibrated derived row still has a manifest — the distinction is the "
                        + "presence of the calibration: input, not the presence of a manifest")
    }

    // MARK: - Helpers

    /// Rows for one period, read directly rather than through `latestDerived`.
    ///
    /// `latestDerived` orders by `computed_at DESC LIMIT 1`, and these tests run on a `FixedClock` —
    /// so every row of a period shares one timestamp and "the latest" is genuinely ambiguous between
    /// them. Counting rows is the assertion that actually means "did this append".
    private func rows(_ derivation: DerivationRepository, periodKey: String) throws -> [DerivedValue] {
        try derivation.allDerived(metricId: MetricID.readinessScore)
            .filter { $0.periodKey == periodKey }
    }

    private func rowCount(_ derivation: DerivationRepository, periodKey: String) throws -> Int {
        try rows(derivation, periodKey: periodKey).count
    }

    private func hasCalibrationInput(_ derivation: DerivationRepository,
                                     _ row: DerivedValue) throws -> Bool {
        guard let manifestId = row.inputManifestId,
              let manifest = try derivation.manifest(id: manifestId) else { return false }
        return manifest.inputs.contains {
            $0.recordId.hasPrefix(MetricCalibration.manifestRecordIdPrefix)
        }
    }

    /// A readiness engine over real ingested data, with enough feedback recorded to have produced a
    /// calibration. Returns the collaborators so a test can inspect what was written.
    private func seededEngine(direction: FeedbackDirection) throws
        -> (engine: ReadinessEngine, derivation: DerivationRepository,
            measurements: MeasurementRepository, feedback: FeedbackRepository, tz: String) {
        let tz = TimeZone.current.identifier
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        _ = try IngestionPipeline(measurements: measurements, catalog: CatalogRepository(db.main),
                                  reconciliation: ReconciliationRepository(db.main),
                                  registry: .shared, clock: clock, deviceId: "test-device")
            .ingest(from: FakeHealthStore(clock: clock, historyDays: 90, tz: tz),
                    range: HealthDateRange(start: clock.now().addingTimeInterval(-90 * 86_400),
                                           end: clock.now()))
        try BaselineEngine(derivation: derivation, measurements: measurements, registry: .shared,
                           clock: clock, deviceId: "test-device")
            .recomputeAll(asOf: clock.now(), tz: tz, includeInterimReadinessComposite: false)

        let feedback = FeedbackRepository(db.main)
        let coordinator = CalibrationCoordinator(feedback: feedback, clock: clock, spec: spec)
        for day in 0..<(spec.minFeedbackEvents + 3) {
            try coordinator.recordFeedback(
                metricId: MetricID.readinessScore,
                periodKey: "day:2026-03-\(String(format: "%02d", day + 1))",
                derivedValueId: "dv-\(day)", algorithmId: "composite.readiness_score",
                algorithmVersion: "2.0.0", direction: direction)
        }

        let engine = ReadinessEngine(derivation: derivation, measurements: measurements,
                                     clock: clock, deviceId: "test-device",
                                     feedbackRepo: feedback, calibrationEnabled: { true })
        return (engine, derivation, measurements, feedback, tz)
    }

    /// Enough feedback on one (metric, method) pair to clear the floor, PLUS a stored calibration
    /// row for it. The row is what the old `calibrationApplied` read, so a metric no engine
    /// calibrates has to be able to have one for the assertion to mean anything.
    private func seedFeedbackAndCalibration(_ repo: FeedbackRepository, metricId: String,
                                            algorithmId: String, count: Int) throws {
        for index in 0..<count {
            try repo.record(DerivedFeedback(
                id: ULID.newID(), metricId: metricId, periodKey: "day:\(algorithmId)-\(index)",
                derivedValueId: "dv-\(index)", algorithmId: algorithmId,
                algorithmVersion: "1.0.0", direction: .over,
                createdAt: clock.now().addingTimeInterval(-Double(index) * 86_400)))
        }
        try repo.appendCalibration(MetricCalibration(
            id: ULID.newID(), metricId: metricId, algorithmId: algorithmId,
            algorithmVersion: "1.0.0", offset: -5, sampleCount: count, computedAt: clock.now()))
    }

    private func feedbackEvent(_ direction: FeedbackDirection, daysAgo: Int) -> DerivedFeedback {
        DerivedFeedback(
            id: "f-\(direction)-\(daysAgo)-\(UUID().uuidString)", metricId: MetricID.readinessScore,
            periodKey: "day:key-\(daysAgo)", derivedValueId: "dv",
            algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0",
            direction: direction,
            createdAt: clock.now().addingTimeInterval(-Double(daysAgo) * 86_400))
    }
}
