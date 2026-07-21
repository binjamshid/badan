import XCTest
@testable import BADAN

/// EPIC-34 — the device-gated stress monitor, where **the gate is the feature**.
///
/// The suite is deliberately weighted toward the gate rather than the number: the plan calls a
/// real-time stress index "the biggest false-precision trap in the plan", so what is asserted here is
/// mostly *what BADAN refuses to say*. Every threshold is pinned at its exact boundary (a value ON a
/// threshold clears it; one ULP below does not), honest absence is asserted as a shipped state with
/// rendered bilingual copy, and the Apple-Watch-only fixture — the DEFAULT case for today's users —
/// is asserted to be hidden, not softened.
///
/// The pure-core goldens (`classify`, `dailyLoad`, `recencyWeight`, `trendValue`, `band`) assert the
/// exact numbers the PUBLISHED contract constants produce, and the mirror suite `StressEngineGoldenTest`
/// on Android asserts the SAME numbers — a gate that differs by platform is not a gate.
final class StressEngineTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"
    let tz = "UTC"

    /// The real published contract — the same file the app ships.
    var spec: StressSpec { .load(from: .shared) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-stress-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Contract wiring

    func testSpecLoadsPublishedConstants() {
        XCTAssertTrue(spec.isLoaded)
        XCTAssertEqual(spec.algorithm.id, "stress.day_trend@0.2.0")
        let p = spec.params
        XCTAssertEqual(p.densityWindowDays, 7)
        XCTAssertEqual(p.denseMinSamplesPerHour, 4.0, accuracy: 1e-9)
        XCTAssertEqual(p.moderateMinSamplesPerHour, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.minDaysWithDaytimeSamples, 5)
        XCTAssertEqual(p.minDaytimeHoursInWindow, 24.0, accuracy: 1e-9)
        XCTAssertEqual(p.minDaytimeSamplesPerDay, 2)
        XCTAssertEqual(p.referenceWindowDays, 28)
        XCTAssertEqual(p.minReferenceDays, 14)
        XCTAssertEqual(p.trendWindowDays, 7)
        XCTAssertEqual(p.minTrendDays, 4)
        XCTAssertEqual(p.trendHalfLifeDays, 2.0, accuracy: 1e-9)
        XCTAssertEqual(p.zClampSigmas, 2.5, accuracy: 1e-9)
        XCTAssertEqual(p.bandNeutralHalfWidth, 10.0, accuracy: 1e-9)
        XCTAssertEqual(p.moderateConfidenceCap, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.denseConfidenceCap, 1.0, accuracy: 1e-9)
        XCTAssertTrue(p.algorithmProvisional, "stress.day_trend is provisional until its constants are validated")
        // Read from the BASELINE entry, never re-declared in the stress block — one definition of the
        // MAD→sigma constant in the whole contract.
        XCTAssertEqual(p.madToSigma, 1.4826, accuracy: 1e-9)
        XCTAssertEqual(AlgorithmRegistry.shared.param("stress.day_trend", "madToSigma"), nil,
                       "madToSigma must not be duplicated into the stress params block")
    }

    /// The contract did not load → the engine hides, it does not guess where the thresholds are.
    func testUnavailableContractHidesRatherThanGuessing() throws {
        let engine = StressEngine(derivation: DerivationRepository(db.main), measurements: MeasurementRepository(db.main),
                                  registry: .shared, clock: FixedClock(Date()), deviceId: deviceId, spec: .unavailable)
        let surface = try engine.evaluate(asOf: Date(), tz: tz)
        XCTAssertEqual(surface.absenceReason, .contractUnavailable)
        XCTAssertNil(surface.trend)
    }

    // MARK: - The gate: density boundaries (identical to StressEngineGoldenTest.kt)

    func testDensityArithmetic() {
        let density = StressEngine.measureDensity(buckets: buckets(days: 7, samplesPerDay: 8, hoursPerDay: 16), params: spec.params)
        XCTAssertEqual(density.daytimeSamples, 56)
        XCTAssertEqual(density.daytimeHours, 112, accuracy: 1e-9)
        XCTAssertEqual(density.samplesPerHour, 0.5, accuracy: 1e-9)
        XCTAssertEqual(density.daysWithSamples, 7)
        XCTAssertEqual(density.windowDays, 7)
    }

    /// Only the trailing `densityWindowDays` count. A dense month followed by a sparse week must read
    /// as the sparse week — the gate describes what the device is doing NOW, not what it once did.
    func testDensityMeasuresOnlyTheTrailingWindow() {
        var window = buckets(days: 21, samplesPerDay: 96, hoursPerDay: 16)
        window += buckets(days: 7, samplesPerDay: 1, hoursPerDay: 16)
        let density = StressEngine.measureDensity(buckets: window, params: spec.params)
        XCTAssertEqual(density.daytimeSamples, 7, "only the last 7 days feed the gate")
        XCTAssertEqual(StressEngine.classify(density: density, params: spec.params), .insufficient)
    }

    func testClassifyAtEachThresholdBoundary() {
        let p = spec.params
        // 7 days × 16 waking hours = 112 hours. The rate is samples ÷ 112.
        func state(samplesPerWeek: Int) -> StressDensityState {
            let perDay = samplesPerWeek / 7
            let remainder = samplesPerWeek % 7
            var window = buckets(days: 7, samplesPerDay: perDay, hoursPerDay: 16)
            if remainder > 0 {
                window[window.count - 1] = StressDayBucket(
                    dayKey: window[window.count - 1].dayKey, daytimeHours: 16,
                    daytimeHrv: Array(repeating: 50.0, count: perDay + remainder))
            }
            return StressEngine.classify(density: StressEngine.measureDensity(buckets: window, params: p), params: p)
        }

        // Moderate floor: exactly 0.5/hr clears (56 ÷ 112); one sample fewer does not.
        XCTAssertEqual(state(samplesPerWeek: 56), .moderate, "a rate exactly ON the threshold clears it")
        XCTAssertEqual(state(samplesPerWeek: 55), .insufficient, "just below the floor is hidden, not 'moderate with a caveat'")
        // Dense floor: exactly 4.0/hr clears (448 ÷ 112); one fewer stays moderate.
        XCTAssertEqual(state(samplesPerWeek: 448), .dense)
        XCTAssertEqual(state(samplesPerWeek: 447), .moderate)
    }

    /// A single dense day cannot unlock a surface the rest of the week cannot support — the
    /// days-covered gate is independent of the rate gate.
    func testDaysCoveredGateIsIndependentOfRate() {
        let p = spec.params
        // 4 days carrying 200 samples each (a very high rate) + 3 empty days.
        var window = buckets(days: 4, samplesPerDay: 200, hoursPerDay: 16)
        window += buckets(days: 3, samplesPerDay: 0, hoursPerDay: 16)
        let density = StressEngine.measureDensity(buckets: window, params: p)
        XCTAssertGreaterThan(density.samplesPerHour, p.denseMinSamplesPerHour)
        XCTAssertEqual(density.daysWithSamples, 4)
        XCTAssertEqual(StressEngine.classify(density: density, params: p), .insufficient)
        XCTAssertEqual(StressEngine.absenceReason(density: density, params: p), .tooFewDaysCovered)

        // One more covered day (5 of 7) clears it.
        window[4] = StressDayBucket(dayKey: window[4].dayKey, daytimeHours: 16, daytimeHrv: Array(repeating: 50.0, count: 200))
        let cleared = StressEngine.measureDensity(buckets: window, params: p)
        XCTAssertEqual(cleared.daysWithSamples, 5)
        XCTAssertEqual(StressEngine.classify(density: cleared, params: p), .dense)
    }

    /// The denominator guard: three samples in one waking hour is 3.0/hr arithmetically and evidence
    /// of nothing.
    func testWakingCoverageGuardsTheDenominator() {
        let p = spec.params
        let window = buckets(days: 7, samplesPerDay: 3, hoursPerDay: 0.5) // 3.5 waking hours all week
        let density = StressEngine.measureDensity(buckets: window, params: p)
        XCTAssertEqual(density.samplesPerHour, 6.0, accuracy: 1e-9, "arithmetically dense")
        XCTAssertEqual(StressEngine.classify(density: density, params: p), .insufficient)
        XCTAssertEqual(StressEngine.absenceReason(density: density, params: p), .notEnoughWakingCoverage)
    }

    func testAbsenceReasonsAreSpecific() {
        let p = spec.params
        let none = StressEngine.measureDensity(buckets: buckets(days: 7, samplesPerDay: 0, hoursPerDay: 16), params: p)
        XCTAssertEqual(StressEngine.absenceReason(density: none, params: p), .noDaytimeHrv)
        // The headline case: an Apple-Watch-class wearable — a couple of daytime readings a day.
        let watch = StressEngine.measureDensity(buckets: buckets(days: 7, samplesPerDay: 2, hoursPerDay: 16), params: p)
        XCTAssertEqual(watch.samplesPerHour, 14.0 / 112.0, accuracy: 1e-9)
        XCTAssertEqual(StressEngine.absenceReason(density: watch, params: p), .daytimeHrvTooSparse)
    }

    // MARK: - Honest absence is a shipped state, with rendered copy

    /// Every reason renders a bilingual explanation. There is no code path to a hidden surface without
    /// one, which is what makes "hidden with an explanation" a shipped state rather than an empty view.
    func testEveryAbsenceReasonRendersBilingualCopy() {
        for reason in StressAbsenceReason.allCases {
            XCTAssertFalse(reason.explanation.en.isEmpty, "\(reason) has no English explanation")
            XCTAssertFalse(reason.explanation.ar.isEmpty, "\(reason) has no Arabic explanation")
            XCTAssertNotEqual(reason.explanation.en, reason.explanation.ar)
            // Arabic must actually be Arabic script, not a latin placeholder.
            XCTAssertTrue(reason.explanation.ar.unicodeScalars.contains { (0x0600...0x06FF).contains(Int($0.value)) },
                          "\(reason)'s Arabic copy is not in Arabic script")
        }
    }

    /// The sparse-device explanation is a fact about the DEVICE. It must name the device and must not
    /// blame the user or dress the absence up as a BADAN failure.
    func testSparseExplanationIsAboutTheDeviceNotTheUser() {
        let copy = StressAbsenceReason.daytimeHrvTooSparse.explanation
        XCTAssertTrue(copy.en.lowercased().contains("your device"))
        XCTAssertTrue(copy.ar.contains("جهازك"))
        for banned in ["you didn't", "you did not", "you failed", "you need to", "error", "unavailable", "sorry", "wear your"] {
            XCTAssertFalse(copy.en.lowercased().contains(banned), "device copy blames the user or reads as an error: \(banned)")
        }
    }

    /// The wellness lint over every authored string in this engine (mirrors `DeviationEngineTests`).
    func testAbsenceCopyIsWellnessSafe() {
        let bannedEn = ["you may have", "signs of", "abnormal", "diagnos", "disease", "stressed out",
                        "do not", "don't ", "stop ", "risk", "warning", "danger", "urgent", "anxiety", "burnout"]
        let bannedAr = ["تشخيص", "مرض", "خطر", "توقف", "تحذير", "عاجل", "قلق"]
        for reason in StressAbsenceReason.allCases {
            let en = reason.explanation.en.lowercased()
            for phrase in bannedEn {
                XCTAssertFalse(en.contains(phrase), "\(reason): \"\(reason.explanation.en)\" contains banned frame \"\(phrase)\"")
            }
            for phrase in bannedAr {
                XCTAssertFalse(reason.explanation.ar.contains(phrase), "\(reason) Arabic contains banned frame \"\(phrase)\"")
            }
        }
    }

    // MARK: - No state can emit a live index

    /// The dense state exists so the SHAPE is fixed, but this build computes no intraday index — and
    /// says so in code rather than in a comment. A dense window still yields a DAILY trend describing a
    /// window, never an instantaneous value.
    func testDenseStateStillYieldsADailyTrendAndNoLiveIndex() {
        XCTAssertFalse(StressEngine.intradayIndexImplemented,
                       "Phase 3 ships no intraday index; flipping this without building one would be a false claim")
        let surface = StressEngine.evaluate(buckets: varyingBuckets(days: 28, samplesPerDay: 96), params: spec.params)
        guard case let .dense(trend) = surface else { return XCTFail("expected the dense state, got \(surface)") }
        XCTAssertEqual(trend.densityState, .dense)
        XCTAssertEqual(trend.windowDays, spec.params.trendWindowDays, "a trend describes a window, never a moment")
        XCTAssertEqual(trend.dayKey, "2026-01-28", "keyed to a DAY — there is no sub-day period key in this engine")
        XCTAssertGreaterThan(trend.confidence, spec.params.moderateConfidenceCap,
                             "the cap is state-dependent: dense data is not held to the moderate ceiling")
        XCTAssertLessThanOrEqual(trend.confidence, spec.params.denseConfidenceCap)
    }

    /// Every value this engine can persist is keyed to a local day. Asserted over the surface the
    /// engine actually produces, so a future "live" field cannot slip in unnoticed.
    func testEverySurfaceValueIsDayKeyed() {
        for samplesPerDay in [96, 14] {
            let surface = StressEngine.evaluate(buckets: varyingBuckets(days: 28, samplesPerDay: samplesPerDay), params: spec.params)
            let trend = try? XCTUnwrap(surface.trend)
            XCTAssertEqual(trend?.dayKey.count, 10, "a YYYY-MM-DD day key, not a timestamp")
            XCTAssertGreaterThanOrEqual(trend?.daysPresent ?? 0, spec.params.minTrendDays)
        }
    }

    // MARK: - Trend math goldens (identical to StressEngineGoldenTest.kt)

    func testDailyLoadGoldens() {
        let p = spec.params
        // A reference with logMad = 0.1 makes the z arithmetic exact: z = (ln v − ln 50) / (1.4826·0.1).
        let reference = StressReference(logCenter: log(50.0), logMad: 0.1, nDays: 28)
        XCTAssertEqual(StressEngine.dailyLoad(dayValue: 50, reference: reference, params: p), 50.0, accuracy: 1e-9,
                       "your own usual daytime value is the neutral 50")
        // z = −1 → one robust sigma BELOW your usual HRV → above 50 (more load): 50 + (1/2.5)·50.
        XCTAssertEqual(StressEngine.dailyLoad(dayValue: 50 * exp(-0.14826), reference: reference, params: p),
                       70.0, accuracy: 1e-9)
        // z = +1 → higher HRV than usual → below 50 (less load).
        XCTAssertEqual(StressEngine.dailyLoad(dayValue: 50 * exp(0.14826), reference: reference, params: p),
                       30.0, accuracy: 1e-9)
        // Clamped at ±zClampSigmas, so one extreme day reaches the edge of the scale and no further.
        XCTAssertEqual(StressEngine.dailyLoad(dayValue: 50 * exp(-1.0), reference: reference, params: p),
                       100.0, accuracy: 1e-9)
        XCTAssertEqual(StressEngine.dailyLoad(dayValue: 50 * exp(1.0), reference: reference, params: p),
                       0.0, accuracy: 1e-9)
        // A perfectly flat reference cannot define a deviation — neutral, never an infinite z.
        let flat = StressReference(logCenter: log(50.0), logMad: 0, nDays: 28)
        XCTAssertEqual(StressEngine.dailyLoad(dayValue: 20, reference: flat, params: p), 50.0, accuracy: 1e-9)
    }

    func testRecencyWeightGoldens() {
        let p = spec.params   // halfLife = 2 days
        XCTAssertEqual(StressEngine.recencyWeight(ageDays: 0, params: p), 1.0, accuracy: 1e-12)
        XCTAssertEqual(StressEngine.recencyWeight(ageDays: 1, params: p), 0.7071067811865476, accuracy: 1e-12)
        XCTAssertEqual(StressEngine.recencyWeight(ageDays: 2, params: p), 0.5, accuracy: 1e-12)
        XCTAssertEqual(StressEngine.recencyWeight(ageDays: 4, params: p), 0.25, accuracy: 1e-12)
        XCTAssertEqual(StressEngine.recencyWeight(ageDays: 6, params: p), 0.125, accuracy: 1e-12)
    }

    func testTrendValueIsARecencyWeightedMean() {
        let contributions = [
            StressDayContribution(dayKey: "2026-01-01", dayValue: 40, load: 0, weight: 0.5),
            StressDayContribution(dayKey: "2026-01-02", dayValue: 40, load: 100, weight: 1.0),
        ]
        XCTAssertEqual(StressEngine.trendValue(contributions: contributions), 66.66666666666667, accuracy: 1e-9)
        // Degenerate input is neutral, never a divide-by-zero or a fabricated extreme.
        XCTAssertEqual(StressEngine.trendValue(contributions: []), 50.0, accuracy: 1e-9)
    }

    func testBandBoundaries() {
        let p = spec.params   // neutral half-width 10
        XCTAssertEqual(StressEngine.band(value: 50, params: p), .aboutUsual)
        XCTAssertEqual(StressEngine.band(value: 60, params: p), .aboutUsual, "exactly on the edge stays neutral")
        XCTAssertEqual(StressEngine.band(value: 60.001, params: p), .higherThanUsual)
        XCTAssertEqual(StressEngine.band(value: 40, params: p), .aboutUsual)
        XCTAssertEqual(StressEngine.band(value: 39.999, params: p), .lowerThanUsual)
    }

    // MARK: - Pure surface fixtures

    /// Density is fine, history is not: this is a CALIBRATION absence and must not tell a vendor-device
    /// user their device samples too rarely — that would be false.
    func testDenseButShortHistoryIsStillLearningNotADeviceComplaint() {
        let surface = StressEngine.evaluate(buckets: varyingBuckets(days: 10, samplesPerDay: 96), params: spec.params)
        XCTAssertEqual(surface.absenceReason, .stillLearningDaytimePattern)
        XCTAssertNil(surface.trend)
        XCTAssertFalse(StressAbsenceReason.stillLearningDaytimePattern.explanation.en.lowercased().contains("device"))
    }

    /// A moderate window carries a capped confidence and a provisional flag — "low confidence" is
    /// structural here, not a matter of copy.
    func testModerateTrendCarriesACappedConfidence() {
        let surface = StressEngine.evaluate(buckets: varyingBuckets(days: 28, samplesPerDay: 14), params: spec.params)
        guard case let .moderate(trend) = surface else { return XCTFail("expected the moderate state, got \(surface)") }
        XCTAssertEqual(trend.confidence, spec.params.moderateConfidenceCap, accuracy: 1e-9,
                       "a full-coverage moderate window sits exactly at the cap, never above it")
        XCTAssertTrue(trend.provisional)
        XCTAssertEqual(trend.daysPresent, 7)
        XCTAssertGreaterThanOrEqual(trend.value, 0)
        XCTAssertLessThanOrEqual(trend.value, 100)
    }

    /// Days below the per-day sample minimum are GAPS: they neither contribute a value nor get imputed.
    func testThinDaysAreGapsNotImputedValues() {
        // Start from a densely-sampled window so the DENSITY gate still passes after the edit — the
        // point of this fixture is the per-day usability rule, not the rate gate.
        var window = varyingBuckets(days: 28, samplesPerDay: 96)
        // Reduce four of the last seven days to a single reading each (below the per-day minimum of
        // 2), leaving three usable days in the trend window.
        for i in (window.count - 7)..<(window.count - 3) {
            window[i] = StressDayBucket(dayKey: window[i].dayKey, daytimeHours: 16, daytimeHrv: [50])
        }
        let density = StressEngine.measureDensity(buckets: window, params: spec.params)
        XCTAssertNotEqual(StressEngine.classify(density: density, params: spec.params), .insufficient,
                          "the density gate still passes — this fixture isolates the per-day usability rule")
        let surface = StressEngine.evaluate(buckets: window, params: spec.params)
        XCTAssertEqual(surface.absenceReason, .tooFewRecentDays, "3 usable days < minTrendDays (4) → no trend")
    }

    // MARK: - DB: the Apple-Watch-only default (the headline acceptance)

    func testAppleWatchOnlyUserIsHiddenAndWritesNothing() throws {
        let (measurements, derivation) = repos()
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        // Two daytime HRV readings a day for a month — a realistic Apple-Watch-only picture, and far
        // below the moderate floor once measured per waking hour.
        seedHRV(measurements, endingAt: asOf, days: 28, perDay: 2, value: { _, _ in 50 })

        let engine = StressEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec)
        let surface = try engine.compute(asOf: asOf, tz: tz)
        XCTAssertEqual(surface.absenceReason, .daytimeHrvTooSparse)
        XCTAssertNil(surface.trend)
        XCTAssertTrue(try derivation.allDerived(metricId: MetricID.stressDayTrend).isEmpty,
                      "a hidden day writes NOTHING — an absence is not stored as a zero or a sentinel row")
    }

    /// Daytime is the entire point: the same readings recorded while asleep produce no daytime density.
    func testSleepWindowReadingsAreNotDaytimeDensity() throws {
        let (measurements, derivation) = repos()
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let today = DayAttribution.startOfDay(asOf, tz: tz)
        // A dense night: 20 readings between 00:00 and 08:00 every day, and a sleep session covering
        // exactly that window. Measured naively this is a dense week; measured against WAKING hours it
        // is zero.
        for d in 0..<28 {
            let dayStart = DayAttribution.addingDays(-d, to: today, tz: tz)
            try insertSleep(measurements, from: dayStart, to: dayStart.addingTimeInterval(8 * 3600))
            for i in 0..<20 {
                insertHRV(measurements, value: 50, at: dayStart.addingTimeInterval(Double(i) * 1200))
            }
        }

        let engine = StressEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec)
        let surface = try engine.compute(asOf: asOf, tz: tz)
        XCTAssertEqual(surface.absenceReason, .noDaytimeHrv,
                       "overnight readings are not daytime evidence — counting them would be the whole false-precision trap")
        XCTAssertTrue(try derivation.allDerived(metricId: MetricID.stressDayTrend).isEmpty)
    }

    // MARK: - DB: the moderate path appends an honest row (I2)

    func testModerateDayAppendsADayKeyedTrendRow() throws {
        let (measurements, derivation) = repos()
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        seedModerateWindow(measurements, endingAt: asOf)

        let engine = StressEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec)
        let surface = try engine.compute(asOf: asOf, tz: tz)
        guard case let .moderate(trend) = surface else { return XCTFail("expected the moderate state, got \(surface)") }

        let dayKey = DayAttribution.localDayKey(asOf, tz: tz)
        let row = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.stressDayTrend, periodKey: "day:" + dayKey))
        XCTAssertEqual(row.periodKey, "day:" + dayKey, "every row this engine writes is DAY-keyed")
        XCTAssertEqual(row.unit, "score_0_100")
        XCTAssertEqual(row.algorithmId, "stress.day_trend")
        XCTAssertEqual(row.algorithmVersion, "0.2.0")
        XCTAssertTrue(row.provisional)
        XCTAssertEqual(try XCTUnwrap(row.confidence), spec.params.moderateConfidenceCap, accuracy: 1e-9)
        XCTAssertEqual(row.value, trend.value, accuracy: 1e-9)
        XCTAssertGreaterThan(row.value, 50, "the recent week's HRV sits below the personal reference → more load than usual")
        XCTAssertEqual(trend.band, .higherThanUsual)

        // The manifest carries one input per contributing DAY, so the anatomy sheet renders straight
        // off it (lineage: the daytime `heart.hrv` samples on each of those days).
        let manifest = try XCTUnwrap(try derivation.manifest(id: XCTUnwrap(row.inputManifestId)))
        XCTAssertEqual(manifest.inputs.count, trend.daysPresent)
        XCTAssertTrue(manifest.inputs.allSatisfy { $0.metricId == MetricID.hrv })
        XCTAssertTrue(manifest.inputs.allSatisfy { ($0.weight ?? 0) > 0 })
    }

    func testRecomputeIsIdempotentAndAVersionBumpStillAppends() throws {
        let (measurements, derivation) = repos()
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        seedModerateWindow(measurements, endingAt: asOf)
        let periodKey = "day:" + DayAttribution.localDayKey(asOf, tz: tz)

        let engine = StressEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: FixedClock(asOf), deviceId: deviceId, spec: spec)
        _ = try engine.compute(asOf: asOf, tz: tz)
        _ = try engine.compute(asOf: asOf, tz: tz)
        XCTAssertEqual(try derivation.allDerived(metricId: MetricID.stressDayTrend).filter { $0.periodKey == periodKey }.count, 1,
                       "an unchanged recompute must not grow the append-only table")

        // Same params, bumped semver, later clock: the value is identical, yet it must APPEND under the
        // new version — never be skipped by a value-only guard (I2 auditability).
        let bumped = StressSpec(
            algorithm: AlgorithmVersion(algorithmId: spec.algorithm.algorithmId, semver: "9.9.9",
                                        introducedIn: spec.algorithm.introducedIn),
            params: spec.params, isLoaded: true)
        let engineB = StressEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                   clock: FixedClock(asOf.addingTimeInterval(3600)), deviceId: deviceId, spec: bumped)
        _ = try engineB.compute(asOf: asOf, tz: tz)

        let all = try derivation.allDerived(metricId: MetricID.stressDayTrend).filter { $0.periodKey == periodKey }
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.algorithmVersion)), ["0.2.0", "9.9.9"])
        XCTAssertEqual(all[0].value, all[1].value, accuracy: 1e-9, "only the version changed, not the value")
    }

    // MARK: - I7: the ontology classes this sensitive-plus

    /// `stress.day_trend` is `sensitivePlus` in the metric ontology, which is what keeps it out of any
    /// export that has not opted into sensitive data (`ExportRunner.metricAllowed`). Pinned here so a
    /// future ontology edit cannot silently downgrade an inference about someone's daily state.
    func testStressTrendIsSensitivePlusInTheOntology() throws {
        let definition = try XCTUnwrap(MetricRegistry.shared.definition(MetricID.stressDayTrend))
        XCTAssertEqual(definition.sensitiveClass, .sensitivePlus)
        XCTAssertEqual(definition.canonicalUnit, "score_0_100")
    }

    // MARK: - Fixtures

    private func repos() -> (MeasurementRepository, DerivationRepository) {
        (MeasurementRepository(db.main), DerivationRepository(db.main))
    }

    /// `days` identical buckets. Day keys are synthetic and consecutive, which is all the pure core
    /// needs (it takes age from bucket ORDER, never by parsing keys).
    private func buckets(days: Int, samplesPerDay: Int, hoursPerDay: Double) -> [StressDayBucket] {
        (0..<days).map { d in
            StressDayBucket(dayKey: String(format: "2026-01-%02d", d + 1), daytimeHours: hoursPerDay,
                            daytimeHrv: Array(repeating: 50.0, count: samplesPerDay))
        }
    }

    /// A window whose older days vary around ~50 ms (so the reference has a real spread) and whose last
    /// seven days sit lower (so the trend has a direction to report).
    private func varyingBuckets(days: Int, samplesPerDay: Int) -> [StressDayBucket] {
        (0..<days).map { d in
            let recent = d >= days - 7
            let value = recent ? 38.0 : [45.0, 50.0, 55.0][d % 3]
            return StressDayBucket(dayKey: String(format: "2026-01-%02d", d + 1), daytimeHours: 16,
                                   daytimeHrv: Array(repeating: value, count: samplesPerDay))
        }
    }

    /// 28 days of daytime HRV, with the last week dense enough to clear the moderate floor (14 readings
    /// a day over a 24-hour window = 0.583/hr) and the earlier days carrying just enough to build the
    /// personal reference.
    private func seedModerateWindow(_ measurements: MeasurementRepository, endingAt asOf: Date) {
        seedHRV(measurements, endingAt: asOf, days: 7, perDay: 14, value: { _, _ in 38 })
        seedHRV(measurements, endingAt: DayAttribution.addingDays(-7, to: asOf, tz: tz), days: 21, perDay: 3,
                value: { d, _ in [45.0, 50.0, 55.0][d % 3] })
    }

    private func seedHRV(_ measurements: MeasurementRepository, endingAt: Date, days: Int, perDay: Int,
                         value: (Int, Int) -> Double) {
        let lastDay = DayAttribution.startOfDay(endingAt, tz: tz)
        for d in 0..<days {
            let dayStart = DayAttribution.addingDays(-d, to: lastDay, tz: tz)
            for i in 0..<perDay {
                // Readings sit in the waking part of the day (from 09:00, half an hour apart) so they
                // land outside any sleep window a fixture adds.
                insertHRV(measurements, value: value(d, i), at: dayStart.addingTimeInterval(9 * 3600 + Double(i) * 1800))
            }
        }
    }

    private func insertHRV(_ measurements: MeasurementRepository, value: Double, at: Date) {
        let record = IntervalRecord(
            id: ULID.newID(), metricId: MetricID.hrv, value: value, unit: "ms",
            startAt: at, endAt: at, tzId: tz, aggregation: .mean,
            provenance: Provenance(sourceId: "watch", ingestionPath: .platformStore, externalId: ULID.newID(),
                                   measuredAt: at, measuredTimezone: tz, recordedAt: at, ingestedAt: at),
            updatedAt: at, originDeviceId: deviceId)
        _ = try? measurements.upsertIntervalRecord(record)
    }

    private func insertSleep(_ measurements: MeasurementRepository, from: Date, to: Date) throws {
        let session = Session(
            id: ULID.newID(), kind: .sleepPrimary, startAt: from, endAt: to, tzId: tz,
            localNight: DayAttribution.localNight(sessionEnd: to, tz: tz),
            provenance: Provenance(sourceId: "watch", ingestionPath: .platformStore, externalId: ULID.newID(),
                                   measuredAt: from, measuredTimezone: tz, recordedAt: from, ingestedAt: from),
            updatedAt: from, originDeviceId: deviceId)
        _ = try measurements.upsertSession(session)
    }
}
