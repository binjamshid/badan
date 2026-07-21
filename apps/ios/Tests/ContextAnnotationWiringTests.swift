import XCTest
@testable import BADAN

/// EPIC-29 / EPIC-34 — the two halves of plan §18's cross-metric context rule, asserted where they
/// are actually wired rather than where they are merely expressible.
///
/// `JournalTests` already covers `ContextStatus`/`ContextAnnotator` as pure types. What was missing
/// — and what this suite exists for — is that they are CONNECTED: that a score computed inside a
/// declared period really does come out of the engine with a lower stored confidence, that its
/// stored VALUE is byte-identical to the same day scored with no period declared (the invariant the
/// whole design is built around), that the caveat a surface renders is the same sentence the context
/// manager previewed, and that no word of that sentence lands in the main database.
///
/// The second half asserts EPIC-34's persistence: `stress.day_trend` is written by
/// `DerivationCoordinator` — the real app's produce order — and a day the density gate refuses
/// writes nothing at all.
final class ContextAnnotationWiringTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"
    let tz = "UTC"
    let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-context-wiring-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Readiness

    /// The acceptance case, stated as a pair: the SAME inputs scored twice, once with a declared
    /// travel window over the day and once without. The value must be identical to the last bit; the
    /// confidence must be strictly lower and must equal the published ceiling.
    func testReadinessInsideADeclaredWindowLosesConfidenceAndKeepsItsValue() throws {
        let plain = try scoreReadiness(withTravelWindow: false)
        let annotated = try scoreReadiness(withTravelWindow: true)

        XCTAssertEqual(annotated.value, plain.value,
                       "the stored value is the invariant — a declared context may never move it")
        XCTAssertEqual(try XCTUnwrap(plain.confidence), 1.0, accuracy: 1e-9,
                       "the unannotated day is a full-input, established-baseline score")
        XCTAssertEqual(try XCTUnwrap(annotated.confidence),
                       ContextAnnotator.activeContextConfidenceCeiling, accuracy: 1e-9,
                       "a declared period caps confidence at the one published ceiling")
        XCTAssertLessThan(try XCTUnwrap(annotated.confidence), try XCTUnwrap(plain.confidence))
    }

    /// `applying(to:)` is a ceiling, not a replacement: a score that was ALREADY less confident than
    /// the ceiling (here, a reduced-input score missing HRV) keeps its own lower number rather than
    /// being lifted to 0.7 by the presence of a context.
    func testAContextNeverRaisesAnAlreadyLowerConfidence() throws {
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        seedBaselines(derivation)
        // HRV (weight 0.5) deliberately absent → weight-coverage caps confidence at 0.5.
        insertVital(measurements, MetricID.restingHeartRate, value: 50)
        insertVital(measurements, MetricID.respiratoryRate, value: 15)
        try insertSleepPerformance(derivation, value: 80)
        try declareTravelWindow()

        _ = try readinessEngine(derivation: derivation, measurements: measurements, withContext: true)
            .compute(asOf: asOf, tz: tz)
        let row = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.readinessScore,
                                                            periodKey: dayPeriodKey))
        XCTAssertEqual(try XCTUnwrap(row.confidence), 0.5, accuracy: 1e-9,
                       "0.5 < the 0.7 ceiling, so min() leaves it alone — a context only ever lowers")
    }

    /// Declaring a period AFTER the day was scored must re-annotate it, and must do so by APPENDING
    /// (I2). The value is unchanged, so a skip-if-identical guard that ignored confidence would
    /// silently drop the annotation on the floor — which is exactly what the guard now prevents.
    func testDeclaringAPeriodAfterwardsAppendsAReAnnotatedRow() throws {
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        seedBaselines(derivation)
        seedFullInputs(measurements, derivation)

        let engine = try readinessEngine(derivation: derivation, measurements: measurements, withContext: true)
        _ = try engine.compute(asOf: asOf, tz: tz)
        let before = try derivation.allDerived(metricId: MetricID.readinessScore).count

        try declareTravelWindow()
        _ = try engine.compute(asOf: asOf, tz: tz)

        let rows = try derivation.allDerived(metricId: MetricID.readinessScore)
        XCTAssertEqual(rows.count, before + 1, "a re-annotated day appends; it never rewrites in place")
        let values = Set(rows.map { ($0.value * 1e9).rounded() })
        XCTAssertEqual(values.count, 1, "both rows carry the same value — only the confidence moved")
    }

    // MARK: - Sleep

    /// Sleep's confidence-bearing outputs (need, performance, consistency) are annotated the same
    /// way, per NIGHT — a fortnight-wide recompute must not cap nights that sat outside the window.
    func testSleepPerformanceIsAnnotatedOnlyOnTheNightsInsideTheWindow() throws {
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        try seedNights(measurements, count: 10)
        insertTimeAsleepBaseline(derivation)
        // The prior-day effort term, present on every night, so `completeness` is 1.0 and the
        // unannotated nights land at full confidence — otherwise the reduced-input halving would
        // already sit below the ceiling and the annotation would be invisible rather than absent.
        try seedPriorDayEffort(derivation, days: 12)

        // A window covering only the LAST night.
        let lastNightStart = DayAttribution.startOfDay(asOf, tz: tz)
        try upsertStatus(kind: .illness, from: lastNightStart,
                         to: DayAttribution.addingDays(1, to: lastNightStart, tz: tz))

        try SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                    clock: FixedClock(asOf), deviceId: deviceId,
                                    contextAnnotations: contextAnnotations())
            .recompute(asOf: asOf, tz: tz)

        let annotated = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.sleepPerformance,
                                                                  periodKey: dayPeriodKey))
        XCTAssertLessThanOrEqual(try XCTUnwrap(annotated.confidence),
                                 ContextAnnotator.activeContextConfidenceCeiling,
                                 "the declared night is capped")

        // A night three days earlier sat outside the window and must be untouched by it.
        let earlierKey = "day:" + DayAttribution.localDayKey(
            DayAttribution.addingDays(-3, to: lastNightStart, tz: tz), tz: tz)
        let earlier = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.sleepPerformance,
                                                                periodKey: earlierKey))
        XCTAssertGreaterThan(try XCTUnwrap(earlier.confidence),
                             ContextAnnotator.activeContextConfidenceCeiling,
                             "a night outside the declared window keeps its own confidence")
    }

    /// A disturbance count is an observation, not an interpretation against the person's usual
    /// pattern, so it is deliberately left unannotated. Pinning that keeps a future "annotate
    /// everything" change from quietly making the app say a counted fact is less certain.
    func testDisturbanceCountsAreNotContextAnnotated() throws {
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        try seedNights(measurements, count: 10, withStages: true)
        insertTimeAsleepBaseline(derivation)
        try declareTravelWindow()

        try SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                    clock: FixedClock(asOf), deviceId: deviceId,
                                    contextAnnotations: contextAnnotations())
            .recompute(asOf: asOf, tz: tz)

        let row = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.sleepDisturbances,
                                                            periodKey: dayPeriodKey))
        XCTAssertEqual(try XCTUnwrap(row.confidence), 1.0, accuracy: 1e-9,
                       "we counted the awake episodes; travelling does not make the count less true")
    }

    // MARK: - Stress

    func testStressTrendInsideADeclaredWindowLosesConfidenceAndKeepsItsValue() throws {
        let plain = try scoreStress(withTravelWindow: false)
        let annotated = try scoreStress(withTravelWindow: true)

        XCTAssertEqual(annotated.value, plain.value, "the stored trend value is untouched")
        XCTAssertLessThan(try XCTUnwrap(annotated.confidence), try XCTUnwrap(plain.confidence))
        XCTAssertLessThanOrEqual(try XCTUnwrap(annotated.confidence),
                                 ContextAnnotator.activeContextConfidenceCeiling)
    }

    // MARK: - The I7 boundary

    /// The caveat SENTENCE names a circumstance, so it is sensitive-plus and must never be written
    /// into `badan.db`. Only the ceiling — a bare number — crosses. This asserts the boundary the
    /// way it can actually break: by scanning every text column of the row and its manifest.
    func testNoCaveatTextIsEverWrittenIntoTheMainDatabase() throws {
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        seedBaselines(derivation)
        seedFullInputs(measurements, derivation)
        try declareTravelWindow()
        _ = try readinessEngine(derivation: derivation, measurements: measurements, withContext: true)
            .compute(asOf: asOf, tz: tz)

        let caveat = ContextStatusKind.travel.caveat
        let rows = try db.main.query("SELECT * FROM derived_values;") + (try db.main.query("SELECT * FROM input_manifests;"))
        for row in rows {
            for value in row.values.values {
                guard case let .text(text) = value else { continue }
                XCTAssertFalse(text.contains("travel"), "no circumstance word reaches the main database")
                XCTAssertNotEqual(text, caveat.en)
                XCTAssertNotEqual(text, caveat.ar)
            }
        }
    }

    /// The display half: what a score surface renders for a day inside a declared period is the same
    /// sentence `ContextStatusManagerView` previews on the card before the tap, in both languages.
    func testTheSurfaceCaveatIsTheSameSentenceTheManagerPreviews() throws {
        try declareTravelWindow()
        let caveats = try ContextCaveats.forDay(asOf, tz: tz, annotations: contextAnnotations())
        XCTAssertEqual(caveats.count, 1)
        XCTAssertEqual(caveats.first?.en, ContextStatusKind.travel.caveat.en)
        XCTAssertEqual(caveats.first?.ar, ContextStatusKind.travel.caveat.ar)
        XCTAssertTrue(try XCTUnwrap(caveats.first?.ar).contains("سفرك"), "real Arabic, not a placeholder")

        // An ordinary day renders nothing — the common case, and it must be silent rather than empty.
        let ordinary = DayAttribution.addingDays(-30, to: asOf, tz: tz)
        XCTAssertTrue(try ContextCaveats.forDay(ordinary, tz: tz, annotations: contextAnnotations()).isEmpty)
    }

    /// A period key that is not a local day (a session-scoped effort row, say) resolves to no
    /// caveats rather than to a guessed day.
    func testANonDayPeriodKeyResolvesToNoCaveats() throws {
        try declareTravelWindow()
        let annotations = contextAnnotations()
        XCTAssertTrue(try ContextCaveats.forPeriodKey("session:01ABC", tz: tz, annotations: annotations).isEmpty)
        XCTAssertFalse(try ContextCaveats.forPeriodKey(dayPeriodKey, tz: tz, annotations: annotations).isEmpty)
    }

    // MARK: - EPIC-34 persistence through the real produce order

    /// The finding: `StressEngine.compute`/`persist` were dead in the shipped app because the
    /// coordinator never called them. This drives the coordinator — the real app's produce order —
    /// and asserts a `stress.day_trend` row lands.
    func testTheCoordinatorPersistsStressDayTrendOnADayTheGateClears() throws {
        let derivation = DerivationRepository(db.main)
        let measurements = MeasurementRepository(db.main)
        seedModerateDaytimeHrv(measurements)

        try makeCoordinator(withStress: true).recompute(asOf: asOf, tz: tz)

        let rows = try derivation.allDerived(metricId: MetricID.stressDayTrend)
        XCTAssertFalse(rows.isEmpty, "the shipped pipeline must write the trend, not only the tests")
        let today = try XCTUnwrap(rows.first { $0.periodKey == dayPeriodKey })
        XCTAssertEqual(today.algorithmId, "stress.day_trend")
        XCTAssertNotNil(today.inputManifestId, "the per-day contribution manifest is written with it")
    }

    /// The other half, and the one that matters more: a day the gate refuses writes NOTHING — no
    /// zero, no null row, no sentinel.
    func testAHiddenDayWritesNothingThroughTheCoordinator() throws {
        let derivation = DerivationRepository(db.main)
        // No daytime HRV at all — the default for a user with no wearable.
        try makeCoordinator(withStress: true).recompute(asOf: asOf, tz: tz)
        XCTAssertTrue(try derivation.allDerived(metricId: MetricID.stressDayTrend).isEmpty,
                      "an absence is absent; it is never stored as a value")
    }

    /// Re-running the pipeline over unchanged data must not grow the append-only table — the same
    /// idempotency property every sibling engine holds.
    func testRepeatCoordinatorRunsDoNotGrowTheStressTable() throws {
        let derivation = DerivationRepository(db.main)
        seedModerateDaytimeHrv(MeasurementRepository(db.main))
        let coordinator = makeCoordinator(withStress: true)

        try coordinator.recompute(asOf: asOf, tz: tz)
        let after = try derivation.allDerived(metricId: MetricID.stressDayTrend).count
        try coordinator.recompute(asOf: asOf, tz: tz)
        XCTAssertEqual(try derivation.allDerived(metricId: MetricID.stressDayTrend).count, after,
                       "unchanged data appends nothing")
    }

    // MARK: - Fixtures

    private var dayPeriodKey: String { "day:" + DayAttribution.localDayKey(asOf, tz: tz) }

    /// The composition root's own seam, over this test's sensitive database.
    private func contextAnnotations() -> ContextAnnotationResolver {
        let journal = JournalRepository(sensitive: db.sensitive)
        return { from, to in
            ContextAnnotator.annotation(from: from, to: to,
                                        statuses: try journal.statuses(overlapping: from, to: to))
        }
    }

    private func readinessEngine(derivation: DerivationRepository, measurements: MeasurementRepository,
                                 withContext: Bool) throws -> ReadinessEngine {
        ReadinessEngine(derivation: derivation, measurements: measurements, clock: FixedClock(asOf),
                        deviceId: deviceId,
                        contextAnnotations: withContext ? contextAnnotations() : noContextAnnotations)
    }

    /// Score one readiness day into a FRESH database so the two halves of the pair cannot influence
    /// each other through the append-only log.
    private func scoreReadiness(withTravelWindow: Bool) throws -> DerivedValue {
        db = try Database(directory: tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        seedBaselines(derivation)
        seedFullInputs(measurements, derivation)
        if withTravelWindow { try declareTravelWindow() }
        _ = try readinessEngine(derivation: derivation, measurements: measurements, withContext: true)
            .compute(asOf: asOf, tz: tz)
        return try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.readinessScore,
                                                          periodKey: dayPeriodKey))
    }

    private func scoreStress(withTravelWindow: Bool) throws -> DerivedValue {
        db = try Database(directory: tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        // A DENSE window on purpose: the moderate gate's own contract cap (0.5) already sits below
        // the context ceiling, so a moderate fixture could not show the ceiling doing anything. The
        // dense cap is 1.0, which is where a context annotation is observable.
        seedDenseDaytimeHrv(measurements)
        if withTravelWindow { try declareTravelWindow() }
        _ = try StressEngine(derivation: derivation, measurements: measurements, registry: .shared,
                             clock: FixedClock(asOf), deviceId: deviceId,
                             contextAnnotations: contextAnnotations())
            .compute(asOf: asOf, tz: tz)
        return try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.stressDayTrend,
                                                          periodKey: dayPeriodKey))
    }

    /// The four engines wired exactly as `AppEnvironment` wires them, including the stress engine
    /// this pass added to the produce order.
    private func makeCoordinator(withStress: Bool) -> DerivationCoordinator {
        let derivation = DerivationRepository(db.main)
        let measurements = MeasurementRepository(db.main)
        let resolver = contextAnnotations()
        return DerivationCoordinator(
            baselines: BaselineEngine(derivation: derivation, measurements: measurements,
                                      registry: .shared, clock: FixedClock(asOf), deviceId: deviceId),
            sleep: SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                           clock: FixedClock(asOf), deviceId: deviceId,
                                           contextAnnotations: resolver),
            readiness: ReadinessEngine(derivation: derivation, measurements: measurements,
                                       clock: FixedClock(asOf), deviceId: deviceId,
                                       contextAnnotations: resolver),
            effort: EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                 clock: FixedClock(asOf), deviceId: deviceId),
            stress: withStress ? StressEngine(derivation: derivation, measurements: measurements,
                                              registry: .shared, clock: FixedClock(asOf),
                                              deviceId: deviceId, contextAnnotations: resolver) : nil)
    }

    private func declareTravelWindow() throws {
        let start = DayAttribution.addingDays(-1, to: DayAttribution.startOfDay(asOf, tz: tz), tz: tz)
        try upsertStatus(kind: .travel, from: start, to: nil)
    }

    private func upsertStatus(kind: ContextStatusKind, from: Date, to: Date?) throws {
        try JournalRepository(sensitive: db.sensitive).upsertStatus(ContextStatus(
            id: ULID.newID(), statusId: kind.rawValue, startAt: from, endAt: to, tzId: tz,
            provenance: Provenance(sourceId: deviceId, deviceId: deviceId, ingestionPath: .manual,
                                   measuredAt: from, measuredTimezone: tz, recordedAt: from, ingestedAt: from),
            updatedAt: from, originDeviceId: deviceId))
    }

    private func seedBaselines(_ derivation: DerivationRepository) {
        insertBaseline(derivation, MetricID.hrv, center: 50, spread: 5)
        insertBaseline(derivation, MetricID.restingHeartRate, center: 50, spread: 5)
        insertBaseline(derivation, MetricID.respiratoryRate, center: 15, spread: 2)
    }

    private func seedFullInputs(_ measurements: MeasurementRepository, _ derivation: DerivationRepository) {
        insertVital(measurements, MetricID.hrv, value: 50)
        insertVital(measurements, MetricID.restingHeartRate, value: 50)
        insertVital(measurements, MetricID.respiratoryRate, value: 15)
        try? insertSleepPerformance(derivation, value: 80)
    }

    private func insertBaseline(_ derivation: DerivationRepository, _ metricId: String,
                                center: Double, spread: Double, windowDays: Int = 14) {
        try? derivation.upsertBaseline(Baseline(
            id: ULID.newID(), metricId: metricId, windowDays: windowDays, center: center, spread: spread,
            bandLow: center - spread, bandHigh: center + spread, nPoints: windowDays, provisional: false,
            algorithmVersion: "baseline.rolling_median_mad@2.0.0", validFrom: asOf, computedAt: asOf, unit: "unit"))
    }

    private func insertTimeAsleepBaseline(_ derivation: DerivationRepository) {
        insertBaseline(derivation, MetricID.timeAsleep, center: 7 * 3600, spread: 1800)
    }

    private func insertVital(_ measurements: MeasurementRepository, _ metricId: String, value: Double) {
        let start = DayAttribution.startOfDay(asOf, tz: tz).addingTimeInterval(6 * 3600)
        let record = IntervalRecord(
            id: ULID.newID(), metricId: metricId, value: value, unit: "unit",
            startAt: start, endAt: start.addingTimeInterval(3600), tzId: tz, aggregation: .mean,
            provenance: Provenance(sourceId: "watch", ingestionPath: .platformStore,
                                   externalId: "\(metricId)#watch", measuredAt: start,
                                   measuredTimezone: tz, recordedAt: start, ingestedAt: start),
            updatedAt: asOf, originDeviceId: deviceId)
        _ = try? measurements.upsertIntervalRecord(record)
    }

    private func insertSleepPerformance(_ derivation: DerivationRepository, value: Double) throws {
        try derivation.appendDerived(DerivedValue(
            id: ULID.newID(), metricId: MetricID.sleepPerformance, value: value, unit: "percent",
            periodKey: dayPeriodKey, confidence: nil, provisional: false,
            algorithmId: "sleep.performance", algorithmVersion: "0.1.0",
            computedAt: asOf, updatedAt: asOf, originDeviceId: deviceId))
    }

    /// `count` consecutive nights of ~7h primary sleep, the most recent ending on `asOf`'s day.
    private func seedNights(_ measurements: MeasurementRepository, count: Int, withStages: Bool = false) throws {
        let lastDay = DayAttribution.startOfDay(asOf, tz: tz)
        for d in 0..<count {
            let dayStart = DayAttribution.addingDays(-d, to: lastDay, tz: tz)
            let end = dayStart.addingTimeInterval(7 * 3600)
            let start = end.addingTimeInterval(-7 * 3600 - 1800)
            let session = Session(
                id: ULID.newID(), kind: .sleepPrimary, startAt: start, endAt: end, tzId: tz,
                localNight: DayAttribution.localNight(sessionEnd: end, tz: tz),
                detail: SessionDetail(timeAsleepSeconds: 7 * 3600, timeInBedSeconds: 7 * 3600 + 1800),
                provenance: Provenance(sourceId: "watch", ingestionPath: .platformStore, externalId: ULID.newID(),
                                       measuredAt: start, measuredTimezone: tz, recordedAt: start, ingestedAt: start),
                updatedAt: start, originDeviceId: deviceId)
            let stages: [SessionStage]
            if withStages {
                // One 15-minute awake episode per night, long enough to count as a disturbance.
                let awakeStart = start.addingTimeInterval(3 * 3600)
                stages = [SessionStage(sessionId: session.id, seq: 0, stage: .awake,
                                       startAt: awakeStart, endAt: awakeStart.addingTimeInterval(900))]
            } else {
                stages = []
            }
            _ = try measurements.upsertSession(session, stages: stages)

        }
    }

    /// 28 days of vendor-grade daytime sampling (96 readings a day, one every 15 minutes = 4.0/hr,
    /// exactly the published dense floor), varying enough to give the personal reference a spread.
    private func seedDenseDaytimeHrv(_ measurements: MeasurementRepository) {
        let lastDay = DayAttribution.startOfDay(asOf, tz: tz)
        for d in 0..<28 {
            let dayStart = DayAttribution.addingDays(-d, to: lastDay, tz: tz)
            let value = d < 7 ? 38.0 : [45.0, 50.0, 55.0][d % 3]
            for i in 0..<96 {
                let at = dayStart.addingTimeInterval(Double(i) * 900)
                let record = IntervalRecord(
                    id: ULID.newID(), metricId: MetricID.hrv, value: value, unit: "ms",
                    startAt: at, endAt: at, tzId: tz, aggregation: .mean,
                    provenance: Provenance(sourceId: "ring", ingestionPath: .platformStore, externalId: ULID.newID(),
                                           measuredAt: at, measuredTimezone: tz, recordedAt: at, ingestedAt: at),
                    updatedAt: at, originDeviceId: deviceId)
                _ = try? measurements.upsertIntervalRecord(record)
            }
        }
    }

    /// One `effort.day` row per recent day — the sleep-need model's soft prior-day input.
    private func seedPriorDayEffort(_ derivation: DerivationRepository, days: Int) throws {
        let lastDay = DayAttribution.startOfDay(asOf, tz: tz)
        for d in 0..<days {
            let day = DayAttribution.addingDays(-d, to: lastDay, tz: tz)
            try derivation.appendDerived(DerivedValue(
                id: ULID.newID(), metricId: "effort.day", value: 40, unit: "score_0_100",
                periodKey: "day:" + DayAttribution.localDayKey(day, tz: tz), confidence: nil,
                provisional: true, algorithmId: "effort.day", algorithmVersion: "1.0.0",
                computedAt: asOf, updatedAt: asOf, originDeviceId: deviceId))
        }
    }

    /// 28 days of daytime HRV shaped to clear the moderate density floor on the last week — the same
    /// fixture shape `StressEngineTests.seedModerateWindow` uses.
    private func seedModerateDaytimeHrv(_ measurements: MeasurementRepository) {
        seedHRV(measurements, endingAt: asOf, days: 7, perDay: 14) { _, _ in 38 }
        seedHRV(measurements, endingAt: DayAttribution.addingDays(-7, to: asOf, tz: tz), days: 21, perDay: 3) { d, _ in
            [45.0, 50.0, 55.0][d % 3]
        }
    }

    private func seedHRV(_ measurements: MeasurementRepository, endingAt: Date, days: Int, perDay: Int,
                         value: (Int, Int) -> Double) {
        let lastDay = DayAttribution.startOfDay(endingAt, tz: tz)
        for d in 0..<days {
            let dayStart = DayAttribution.addingDays(-d, to: lastDay, tz: tz)
            for i in 0..<perDay {
                let at = dayStart.addingTimeInterval(9 * 3600 + Double(i) * 1800)
                let record = IntervalRecord(
                    id: ULID.newID(), metricId: MetricID.hrv, value: value(d, i), unit: "ms",
                    startAt: at, endAt: at, tzId: tz, aggregation: .mean,
                    provenance: Provenance(sourceId: "watch", ingestionPath: .platformStore, externalId: ULID.newID(),
                                           measuredAt: at, measuredTimezone: tz, recordedAt: at, ingestedAt: at),
                    updatedAt: at, originDeviceId: deviceId)
                _ = try? measurements.upsertIntervalRecord(record)
            }
        }
    }
}
