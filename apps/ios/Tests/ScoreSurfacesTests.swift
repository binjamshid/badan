import XCTest
@testable import BADAN

/// Headless coverage for the iOS score-surface presentation layer (EPIC-24/25/26/27 UI): the pure
/// helpers behind the hypnogram, the need-vs-actual bar, the calibration countdown, the Health
/// Monitor tiles, the anatomy contribution bars and published formulas, the Effort reduced-input
/// label, and the sleep-need range reconstruction. These are the load-bearing bits — an off-by-one
/// in a fraction misplaces a band, a broken gate turns Effort's per-zone manifest into five identical
/// bars — so they are asserted directly rather than through a rendered view.
final class ScoreSurfacesTests: XCTestCase {

    private func format(_ language: AppLanguage = .en) -> ValueFormatter {
        ValueFormatter(profile: CustomizationProfile(language: language), registry: .shared)
    }

    // MARK: - Hypnogram layout

    private func stage(_ stage: SleepStage, from: TimeInterval, to: TimeInterval) -> SessionStage {
        SessionStage(sessionId: "s", seq: Int(from), stage: stage,
                     startAt: Date(timeIntervalSince1970: from), endAt: Date(timeIntervalSince1970: to))
    }

    func testHypnogramEmptyWhenNoStages() {
        XCTAssertTrue(HypnogramLayout(stages: []).segments.isEmpty)
    }

    func testHypnogramSequentialStagesAreTimeProportional() {
        // 1h light, 1h deep, 2h light — total 4h; fractions 0.25/0.25/0.5.
        let layout = HypnogramLayout(stages: [
            stage(.light, from: 0, to: 3600),
            stage(.deep, from: 3600, to: 7200),
            stage(.light, from: 7200, to: 14400),
        ])
        XCTAssertEqual(layout.totalSeconds, 14400, accuracy: 0.5)
        XCTAssertEqual(layout.segments.count, 3, "no gaps between contiguous stages")
        XCTAssertEqual(layout.segments.map(\.stage), [.light, .deep, .light])
        XCTAssertEqual(layout.segments[0].fraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(layout.segments[2].fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(layout.stageSeconds[.light] ?? 0, 10800, accuracy: 0.5, "light seconds accumulate across both light runs")
        XCTAssertEqual(layout.stageSeconds[.deep] ?? 0, 3600, accuracy: 0.5)
        // Fractions (incl. any gaps) cover the whole span.
        XCTAssertEqual(layout.segments.map(\.fraction).reduce(0, +), 1.0, accuracy: 0.001)
    }

    func testHypnogramInsertsGapSegmentForUnrecordedStretch() {
        // A 1h hole between two stages must be an explicit nil-stage gap, not silently closed up.
        let layout = HypnogramLayout(stages: [
            stage(.deep, from: 0, to: 3600),
            stage(.rem, from: 7200, to: 10800),
        ])
        XCTAssertEqual(layout.segments.count, 3)
        XCTAssertEqual(layout.segments[1].stage, nil, "the unrecorded stretch is a gap segment")
        XCTAssertEqual(layout.segments[1].seconds, 3600, accuracy: 0.5)
        // The gap contributes to no stage's ledger, so the ledger totals less than the whole span.
        XCTAssertLessThan(layout.stageSeconds.values.reduce(0, +), layout.totalSeconds)
    }

    func testHypnogramClampsOverlap() {
        // A later row starting before the cursor is clamped, never rendered behind the axis.
        let layout = HypnogramLayout(stages: [
            stage(.light, from: 0, to: 7200),
            stage(.deep, from: 3600, to: 10800), // overlaps the first by 1h
        ])
        // Total span 0…10800 (3h); the deep segment is clamped to start at 7200.
        XCTAssertEqual(layout.totalSeconds, 10800, accuracy: 0.5)
        XCTAssertEqual(layout.stageSeconds[.deep] ?? 0, 3600, accuracy: 0.5, "the overlapping hour is not double-counted")
        XCTAssertEqual(layout.segments.map(\.fraction).reduce(0, +), 1.0, accuracy: 0.001)
    }

    // MARK: - Need-vs-actual layout

    func testNeedVsActualFractionsPlaceTheBandAndMarker() {
        // need 7h ± ~1h, actual 6h.
        let layout = NeedVsActualLayout(actualSeconds: 6 * 3600, needLowSeconds: 6.5 * 3600,
                                        needCenterSeconds: 7 * 3600, needHighSeconds: 7.5 * 3600)
        XCTAssertGreaterThan(layout.trackMaxSeconds, 7.5 * 3600, "the track extends past the top of the band")
        XCTAssertLessThan(layout.bandLowFraction, layout.bandHighFraction)
        XCTAssertLessThan(layout.centerFraction, layout.bandHighFraction)
        XCTAssertGreaterThan(layout.centerFraction, layout.bandLowFraction)
        XCTAssertLessThan(layout.actualFraction, layout.centerFraction, "6h of sleep sits below a 7h need centre")
        for f in [layout.bandLowFraction, layout.bandHighFraction, layout.centerFraction, layout.actualFraction] {
            XCTAssertTrue((0...1).contains(f))
        }
    }

    func testNeedVsActualActualCanExceedNeed() {
        // Slept more than needed: the actual fraction leads and nothing pins to the very edge.
        let layout = NeedVsActualLayout(actualSeconds: 9 * 3600, needLowSeconds: 6.5 * 3600,
                                        needCenterSeconds: 7 * 3600, needHighSeconds: 7.5 * 3600)
        XCTAssertGreaterThan(layout.actualFraction, layout.bandHighFraction)
        XCTAssertLessThan(layout.actualFraction, 1.0)
    }

    // MARK: - Calibration countdown copy

    func testCalibrationDayPhraseEnglish() {
        let text = CalibrationCount.dayPhrase(n: 9, total: 14, language: .en, format: format(),
                                              template: LocalizedString(en: "Day {n} of {total}", ar: "اليوم {n} من {total}"))
        XCTAssertEqual(text, "Day 9 of 14")
    }

    func testCalibrationDayPhraseArabicAgreesWithTotal() {
        let template = LocalizedString(en: "Day {n} of {total}", ar: "اليوم {n} من {total}")
        // The agreeing noun is keyed off `total`: 1 singular, 2 dual, 3–10 plural, 11+ indeclinable.
        for (total, noun) in [(1, "يوم"), (2, "يومان"), (7, "أيام"), (14, "يوماً")] {
            let text = CalibrationCount.dayPhrase(n: 1, total: total, language: .ar, format: format(.ar), template: template)
            XCTAssertTrue(text.hasSuffix(noun), "total \(total) should end with \(noun) — got \(text)")
        }
    }

    // MARK: - Health Monitor tile presentation

    private func tile(metricId: String, family: MetricFamily, unit: String,
                      reading: VitalReading?, state: VitalState, band: PersonalBand? = nil) -> VitalTile {
        VitalTile(metricId: metricId, family: family, title: LocalizedString(en: "x", ar: "x"), unit: unit,
                  reading: reading, asOfDay: nil, band: band, state: state, isStale: false,
                  annotation: nil, sparkline: [], sourceQuality: nil)
    }

    func testTileChipMappingNeverClaimsWhileCalibratingOrNoData() {
        XCTAssertNil(HealthMonitorTilePresentation.chip(for: .noData), "no data claims nothing")
        XCTAssertNil(HealthMonitorTilePresentation.chip(for: .calibrating), "a calibrating band claims nothing")
        XCTAssertEqual(HealthMonitorTilePresentation.chip(for: .withinBand)?.status, .inBand)
        XCTAssertEqual(HealthMonitorTilePresentation.chip(for: .aboveBand)?.status, .above)
        XCTAssertEqual(HealthMonitorTilePresentation.chip(for: .belowBand)?.status, .below)
        XCTAssertEqual(HealthMonitorTilePresentation.chip(for: .deviation(.atUsual))?.status, .inBand)
        XCTAssertEqual(HealthMonitorTilePresentation.chip(for: .deviation(.aboveUsual))?.status, .above)
        XCTAssertEqual(HealthMonitorTilePresentation.chip(for: .deviation(.belowUsual))?.status, .below)
        // Band-position chip labels reuse the shared, bilingual `Loc` vocabulary.
        XCTAssertEqual(HealthMonitorTilePresentation.chip(for: .aboveBand)?.label, Loc.aboveYourRange)
    }

    func testDeviationReadingAlwaysCarriesSign() {
        let above = tile(metricId: MetricID.wristTempDeviation, family: .body, unit: "degC",
                         reading: .deviation(0.3), state: .deviation(.aboveUsual))
        let below = tile(metricId: MetricID.wristTempDeviation, family: .body, unit: "degC",
                         reading: .deviation(-0.2), state: .deviation(.belowUsual))
        let atUsual = tile(metricId: MetricID.wristTempDeviation, family: .body, unit: "degC",
                           reading: .deviation(0), state: .deviation(.atUsual))
        XCTAssertTrue(HealthMonitorTilePresentation.readingText(tile: above, reading: above.reading!, format: format()).hasPrefix("+"))
        XCTAssertTrue(HealthMonitorTilePresentation.readingText(tile: below, reading: below.reading!, format: format()).hasPrefix("\u{2212}"))
        XCTAssertTrue(HealthMonitorTilePresentation.readingText(tile: atUsual, reading: atUsual.reading!, format: format()).hasPrefix("\u{00B1}"),
                      "a zero deviation reads ±0, never a bare 0 that looks like an absolute reading")
    }

    func testAbsoluteReadingFormatsThroughUnitProfile() {
        let rhr = tile(metricId: MetricID.restingHeartRate, family: .heart, unit: "bpm",
                       reading: .absolute(57), state: .withinBand)
        XCTAssertEqual(HealthMonitorTilePresentation.readingText(tile: rhr, reading: rhr.reading!, format: format()), "57")
        XCTAssertEqual(HealthMonitorTilePresentation.unitText(tile: rhr, format: format()), "bpm")
    }

    // MARK: - Anatomy contribution bars

    private func input(_ metricId: String, value: Double, weight: Double) -> InputManifest.Input {
        InputManifest.Input(recordId: "r-\(metricId)", metricId: metricId, value: value, weight: weight)
    }

    func testContributionRowsFromReadinessManifest() throws {
        // Readiness stores one input per metric, weight = additive points, Σ = the score.
        let manifest = InputManifest(id: "m", inputs: [
            input(MetricID.hrv, value: 60, weight: 40),
            input(MetricID.restingHeartRate, value: 55, weight: 20),
            input(MetricID.sleepPerformance, value: 90, weight: 15),
            input(MetricID.respiratoryRate, value: 14, weight: 5),
        ])
        let rows = try XCTUnwrap(AnatomyContributions.rows(from: manifest))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first?.metricId, MetricID.hrv, "sorted by contribution, largest first")
        XCTAssertEqual(rows.map(\.share).reduce(0, +), 1.0, accuracy: 0.0001, "shares of the score sum to 1")
        XCTAssertEqual(rows.first?.barFraction ?? 0, 1.0, accuracy: 0.0001, "the top contributor fills the bar")
        XCTAssertEqual(rows.first?.share ?? 0, 40.0 / 80.0, accuracy: 0.0001)
    }

    func testContributionRowsRejectRepeatedMetricManifest() {
        // Effort's per-zone manifest is all `heart.hr` — a metric-keyed bar would just repeat one label,
        // so it is deliberately rejected and falls through to the plain records list.
        let manifest = InputManifest(id: "m", inputs: [
            input(MetricID.heartRate, value: 30, weight: 30),
            input(MetricID.heartRate, value: 20, weight: 32),
            input(MetricID.heartRate, value: 10, weight: 26),
        ])
        XCTAssertNil(AnatomyContributions.rows(from: manifest))
    }

    func testContributionRowsNeedAtLeastTwoWeightedInputs() {
        let single = InputManifest(id: "m", inputs: [input(MetricID.hrv, value: 60, weight: 40)])
        XCTAssertNil(AnatomyContributions.rows(from: single))
        let unweighted = InputManifest(id: "m", inputs: [
            InputManifest.Input(recordId: "a", metricId: MetricID.hrv, value: 60, weight: nil),
            InputManifest.Input(recordId: "b", metricId: MetricID.restingHeartRate, value: 55, weight: nil),
        ])
        XCTAssertNil(AnatomyContributions.rows(from: unweighted))
    }

    // MARK: - Published formulas + alt-text

    func testPublishedFormulasAreBilingualWithDistinctAltText() throws {
        // Includes the three sleep scores the audit flagged (debt/consistency/disturbances) — each
        // must ship bilingual math notation and a distinct plain-language reading for VoiceOver.
        for id in ["composite.readiness_score", "sleep.need", "sleep.performance", "sleep.debt",
                   "sleep.consistency", "sleep.disturbances", "effort.day", "baseline.rolling_median_mad"] {
            let f = try XCTUnwrap(AnatomyFormulas.byAlgorithmId[id], "\(id) should publish a formula")
            XCTAssertFalse(f.formula.en.isEmpty); XCTAssertFalse(f.formula.ar.isEmpty)
            XCTAssertFalse(f.altText.en.isEmpty); XCTAssertFalse(f.altText.ar.isEmpty)
            XCTAssertNotEqual(f.formula.en, f.altText.en, "alt-text is the plain-language reading, not the notation")
            XCTAssertNotEqual(f.formula.ar, f.altText.ar)
        }
    }

    /// Completeness gate (audit finding #3): EVERY derived score the app can surface reaches the
    /// anatomy sheet's formula card via `AnatomyFormulas.lookup(methodString)`, so each must publish a
    /// formula or the card is silently omitted (docs-yes / in-app-no). The ids are sourced from the
    /// engines' own published identities — not string literals — so a future engine output added
    /// without a formula fails HERE, closing the whole class rather than these three cases.
    func testEverySurfacedScoreHasAPublishedFormula() {
        let sleep = SleepSpec.defaultShared
        let effort = EffortSpec.defaultShared
        var surfaced: Set<String> = [
            BaselineEngine.baselineAlgorithm.algorithmId,
            BaselineEngine.efficiencyAlgorithm.algorithmId,
            BaselineEngine.readinessAlgorithm.algorithmId,
            ReadinessSpec.defaultShared.algorithm.algorithmId,
            effort.dayAlgorithm.algorithmId,
            effort.workoutAlgorithm.algorithmId,
        ]
        for output in [sleep.need, sleep.performance, sleep.debt, sleep.consistency, sleep.disturbances] {
            surfaced.insert(output.algorithm.algorithmId)
        }
        for id in surfaced {
            XCTAssertNotNil(AnatomyFormulas.lookup(id),
                            "\(id) is a surfaced score but has no in-app published formula")
        }
    }

    func testFormulaLookupToleratesVersionedToken() {
        XCTAssertNotNil(AnatomyFormulas.lookup("composite.readiness_score@2.0.0"))
        XCTAssertNotNil(AnatomyFormulas.lookup("composite.readiness_score"))
        XCTAssertNil(AnatomyFormulas.lookup("nonsense.algorithm"))
    }

    // MARK: - Effort reduced-input formatting

    func testEffortActivityLoadNeverBareCount() {
        let f = format()
        // Energy keeps its unit; a bare "count" reads as nothing, so steps show no unit suffix. Compare
        // against the formatter's own output so the assertion is locale-grouping independent.
        XCTAssertEqual(HomeEffortActivity.valueText(value: 420, unit: "kcal", format: f), "\(f.integer(420)) kcal")
        XCTAssertEqual(HomeEffortActivity.valueText(value: 8200, unit: "count", format: f), f.integer(8200))
    }

    // MARK: - Sleep-need range reconstruction (mirror of the engine)

    func testNeedRangeMirrorsEngineHalfWidth() {
        let spec = SleepSpec.defaultShared
        let center = 7.0 * 3600
        // At full confidence the half-width is exactly `rangeHalfWidthSeconds`.
        let full = SleepNeedRangeReconstruction.range(centerSeconds: center, confidence: 1.0)
        XCTAssertEqual(full.high - center, spec.rangeHalfWidthSeconds, accuracy: 0.5)
        XCTAssertEqual(center - full.low, spec.rangeHalfWidthSeconds, accuracy: 0.5)
        // Lower confidence widens the band (2 − confidence).
        let half = SleepNeedRangeReconstruction.range(centerSeconds: center, confidence: 0.0)
        XCTAssertEqual(half.high - center, spec.rangeHalfWidthSeconds * 2, accuracy: 0.5)
        // A missing confidence is treated as fully uncertain (widest), never tighter than earned.
        let missing = SleepNeedRangeReconstruction.range(centerSeconds: center, confidence: nil)
        XCTAssertEqual(missing.high, half.high, accuracy: 0.5)
    }

    func testNeedRangeLowClampsAtZero() {
        // A tiny centre with a wide band never produces a negative low bound.
        let range = SleepNeedRangeReconstruction.range(centerSeconds: 60, confidence: 0)
        XCTAssertEqual(range.low, 0, accuracy: 0.0001)
    }
}
