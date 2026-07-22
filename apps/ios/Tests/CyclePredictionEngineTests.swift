import Foundation
import XCTest
@testable import BADAN

/// EPIC-39 CYCLE-04 (next-period forecast) + CYCLE-06 input (phase estimation), Phase 3F slice 1.
/// Covers the four documented invariants from this slice's brief: (1) `coldStart` NEVER returns a
/// predicted date, only after 1+ completed cycle does any date appear; (2) confidence/window width
/// behave monotonically as history tier increases (never proportionally WIDER at a higher tier for
/// the same variance); (3) an active, suppressive contraceptive context pauses prediction with a
/// non-nil reason and nil dates, regardless of tier; (4) phase estimation returns `.unknown` with
/// near-zero confidence below the history threshold or under suppression, never a guessed phase.
final class CyclePredictionEngineTests: XCTestCase {
    private let device = "test-device"
    /// 2025-01-01T00:00:00Z — a UTC midnight anchor so day-arithmetic assertions can compare exact
    /// `Date` values without any DST ambiguity.
    private let base = Date(timeIntervalSince1970: 1_735_689_600)

    private func day(_ n: Int) -> Date { base.addingTimeInterval(Double(n) * 86_400) }

    private func provenance(measuredAt: Date) -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: "UTC", recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func record(id: String, start: Date, end: Date? = nil, ongoing: Bool = false) -> CycleRecord {
        CycleRecord(id: id, startAt: start, endAt: end, ongoing: ongoing, originalId: id,
                   provenance: provenance(measuredAt: start), updatedAt: start, originDeviceId: device)
    }

    private func contraceptive(_ methodType: ContraceptiveMethodType, start: Date,
                               end: Date? = nil) -> ContraceptiveContextLog {
        ContraceptiveContextLog(id: "CTX-1", methodType: methodType, startAt: start, endAt: end,
                                provenance: provenance(measuredAt: start), updatedAt: start, originDeviceId: device)
    }

    /// `count` consecutive `CycleRecord`s, each `lengthDays` apart, starting at `day(0)` — yields
    /// exactly `count - 1` completed cycles (all of uniform length, i.e. zero spread).
    private func makeHistory(count: Int, lengthDays: Int) -> [CycleRecord] {
        var records: [CycleRecord] = []
        var offset = 0
        for i in 0..<count {
            records.append(record(id: "R\(i)", start: day(offset), ongoing: i == count - 1))
            offset += lengthDays
        }
        return records
    }

    /// One record per length in `lengths` plus a leading record at `day(0)` — yields exactly
    /// `lengths.count` completed cycles, with real (non-uniform) spread.
    private func makeHistory(lengths: [Int]) -> [CycleRecord] {
        var records: [CycleRecord] = [record(id: "R0", start: day(0), ongoing: lengths.isEmpty)]
        var offset = 0
        for (i, length) in lengths.enumerated() {
            offset += length
            records.append(record(id: "R\(i + 1)", start: day(offset), ongoing: i == lengths.count - 1))
        }
        return records
    }

    // MARK: - (1) coldStart never returns a predicted date

    func testColdStartWithNoHistoryNeverPredictsADate() {
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: [], contraceptiveContext: nil, asOf: day(0), algorithmVersion: "v1")
        XCTAssertEqual(prediction.method, .coldStart)
        XCTAssertEqual(prediction.status, .active)
        XCTAssertNil(prediction.suppressionReason)
        XCTAssertEqual(prediction.confidence, 0)
        XCTAssertNil(prediction.predictedNextStartLow)
        XCTAssertNil(prediction.predictedNextStartCenter)
        XCTAssertNil(prediction.predictedNextStartHigh)
        XCTAssertTrue(prediction.inputCycleIds.isEmpty)
    }

    func testColdStartWithExactlyOneLoggedPeriodStillNeverPredicts() {
        // One logged (ongoing) period = zero COMPLETED cycles — the "day-one state" the research
        // doc names — must still be coldStart, not lowHistory.
        let history = [record(id: "R0", start: day(0), ongoing: true)]
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: history, contraceptiveContext: nil, asOf: day(10), algorithmVersion: "v1")
        XCTAssertEqual(prediction.method, .coldStart)
        XCTAssertNil(prediction.predictedNextStartCenter)
    }

    func testExactlyOneCompletedCycleEntersLowHistoryAndDoesPredict() {
        // Two records = one completed cycle: the FIRST tier that is allowed to predict anything.
        let history = makeHistory(count: 2, lengthDays: 28)
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: history, contraceptiveContext: nil, asOf: day(100), algorithmVersion: "v1")
        XCTAssertEqual(prediction.method, .lowHistory)
        XCTAssertNotNil(prediction.predictedNextStartCenter)
        XCTAssertNotNil(prediction.predictedNextStartLow)
        XCTAssertNotNil(prediction.predictedNextStartHigh)
    }

    // MARK: - Tier selection by exact completed-cycle count

    func testTierSelectionByExactCompletedCycleCount() {
        let cases: [(recordCount: Int, expectedCompleted: Int, expected: CyclePredictionMethod)] = [
            (1, 0, .coldStart),
            (2, 1, .lowHistory),
            (3, 2, .lowHistory),
            (4, 3, .moderateHistory),
            (6, 5, .moderateHistory),
            (7, 6, .matureHistory),
            (10, 9, .matureHistory),
        ]
        for c in cases {
            let history = makeHistory(count: c.recordCount, lengthDays: 28)
            let prediction = CyclePredictionEngine.predictNextCycle(
                history: history, contraceptiveContext: nil, asOf: day(1_000), algorithmVersion: "v1")
            XCTAssertEqual(prediction.method, c.expected,
                           "\(c.expectedCompleted) completed cycles (\(c.recordCount) records)")
        }
    }

    // MARK: - (2) Monotonic confidence / non-widening window across tiers

    func testConfidenceIncreasesStrictlyAcrossTiersForEquallyRegularCycles() {
        // All four histories are PERFECTLY regular (zero spread) so only the tier itself can move
        // confidence — isolating the tier effect from any data-quality effect.
        let coldStart = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(count: 1, lengthDays: 28), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")
        let low = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(count: 2, lengthDays: 28), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")
        let moderate = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(count: 5, lengthDays: 28), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")
        let mature = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(count: 8, lengthDays: 28), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")

        XCTAssertLessThan(coldStart.confidence, low.confidence)
        XCTAssertLessThan(low.confidence, moderate.confidence)
        XCTAssertLessThan(moderate.confidence, mature.confidence)
    }

    func testWindowWidthNeverGrowsProportionallyAcrossTiersForIdenticalZeroVariance() {
        let low = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(count: 2, lengthDays: 28), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")
        let moderate = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(count: 5, lengthDays: 28), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")
        let mature = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(count: 8, lengthDays: 28), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")

        func widthDays(_ p: CyclePrediction) -> Int {
            guard let low = p.predictedNextStartLow, let high = p.predictedNextStartHigh else { return 0 }
            return Calendar(identifier: .gregorian).dateComponents([.day], from: low, to: high).day ?? 0
        }

        let lowWidth = widthDays(low)
        let moderateWidth = widthDays(moderate)
        let matureWidth = widthDays(mature)

        XCTAssertGreaterThanOrEqual(lowWidth, moderateWidth,
                                    "same (zero) variance: moderate must not be wider than low")
        XCTAssertGreaterThanOrEqual(moderateWidth, matureWidth,
                                    "same (zero) variance: mature must not be wider than moderate")
        XCTAssertGreaterThan(lowWidth, matureWidth,
                             "a mature-history window must not be proportionally as wide as a low-history one for the same (zero) variance")
    }

    /// AUDIT REGRESSION: an earlier doc comment claimed window WIDTH never grows across tiers for
    /// the same underlying variance — false above ~2.67 days of spread (a genuinely irregular
    /// 3-cycle history can produce a WIDER window than a 1-2-cycle flat guess, because width here
    /// honestly reflects each tier's own measured spread rather than a generic constant). What DOES
    /// hold, and what this test proves with the audit's own worked example, is that CONFIDENCE never
    /// inverts across tiers even when width does not cooperate: more history is more trustworthy
    /// about the central estimate even when that history reveals real irregularity.
    func testConfidenceNeverInvertsAcrossTiersForAnyRealizableSpread() {
        // Genuinely irregular 3-cycle history (lengths 22, 34, 24) -> moderateHistory tier, spread 5
        // days (well above the ~2.67-day point where its width exceeds lowHistory's flat 4-day
        // half-width) — the exact fixture the audit used to show width can invert.
        let irregularModerate = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(lengths: [22, 34, 24]), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(irregularModerate.method, .moderateHistory)

        // A calm, regular 1-2-cycle "low history" comparison — confidence must still be LOWER than
        // the irregular moderate-tier prediction above, despite that prediction's wider window.
        let calmLow = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(lengths: [28]), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(calmLow.method, .lowHistory)

        XCTAssertLessThan(calmLow.confidence, irregularModerate.confidence,
                          "moderateHistory's confidence floor exceeds lowHistory's flat confidence for ANY spread, " +
                          "even though this specific moderateHistory window is WIDER than the lowHistory one here")

        // Same story one tier up: an irregular mature-tier history's confidence must still exceed
        // moderateHistory's, regardless of its own measured spread.
        let irregularMature = CyclePredictionEngine.predictNextCycle(
            history: makeHistory(lengths: [22, 34, 24, 20, 36, 26]), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(irregularMature.method, .matureHistory)
        XCTAssertLessThan(irregularModerate.confidence, irregularMature.confidence)
    }

    // MARK: - Central-tendency math (low = simple average, moderate/mature = recency-weighted)

    func testLowHistoryUsesSimpleAverageOfTheAvailableLengths() {
        // Completed lengths 25, then 31 -> simple average 28, anchored off the most recent start.
        let history = makeHistory(lengths: [25, 31])
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: history, contraceptiveContext: nil, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(prediction.method, .lowHistory)
        XCTAssertEqual(prediction.predictedNextStartCenter, day(56 + 28))
    }

    func testModerateHistoryWeightsRecentCyclesMoreHeavilyThanASimpleAverageWould() {
        // Completed lengths getting longer over time (24, 28, 32): a recency-weighted mean must
        // land ABOVE the simple average (28), because more weight goes to the most recent, longer
        // cycle. Weighted mean = (24*1 + 28*2 + 32*3) / 6 = 29.33 -> rounds to 29 days.
        let history = makeHistory(lengths: [24, 28, 32])
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: history, contraceptiveContext: nil, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(prediction.method, .moderateHistory)
        XCTAssertEqual(prediction.predictedNextStartCenter, day(84 + 29))
    }

    // MARK: - Input manifest honesty (mature tier windows to the last 6 lengths only)

    func testInputCycleIdsOnlyCiteRecordsActuallyUsedInTheMatureHistoryWindow() {
        // 10 records -> 9 completed cycles; the mature-tier window caps at the most recent 6
        // lengths, i.e. records R3...R9 (7 records) — R0, R1, R2 must NOT be cited.
        let history = makeHistory(count: 10, lengthDays: 28)
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: history, contraceptiveContext: nil, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(prediction.method, .matureHistory)
        XCTAssertEqual(Set(prediction.inputCycleIds), Set((3...9).map { "R\($0)" }))
    }

    // MARK: - (3) Suppressive contraceptive context pauses prediction

    func testActivePillContextPausesPrediction() {
        let history = makeHistory(count: 6, lengthDays: 28) // moderateHistory otherwise
        let context = contraceptive(.pill, start: day(0))
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: history, contraceptiveContext: context, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(prediction.status, .paused)
        XCTAssertEqual(prediction.suppressionReason,
                       CyclePredictionEngine.suppressionReasonSuppressiveContraceptiveContext)
        XCTAssertNil(prediction.predictedNextStartLow)
        XCTAssertNil(prediction.predictedNextStartCenter)
        XCTAssertNil(prediction.predictedNextStartHigh)
        XCTAssertEqual(prediction.confidence, 0)
    }

    func testActiveContextAlsoPausesAtColdStartTier() {
        let context = contraceptive(.pill, start: day(0))
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: [], contraceptiveContext: context, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(prediction.method, .coldStart)
        XCTAssertEqual(prediction.status, .paused)
        XCTAssertNotNil(prediction.suppressionReason)
    }

    func testEveryDocumentedSuppressiveMethodPausesPrediction() {
        for method: ContraceptiveMethodType in [.pill, .patch, .ring, .injection, .implant, .hormoneTherapy] {
            let history = makeHistory(count: 6, lengthDays: 28)
            let context = contraceptive(method, start: day(0))
            let prediction = CyclePredictionEngine.predictNextCycle(
                history: history, contraceptiveContext: context, asOf: day(1_000), algorithmVersion: "v1")
            XCTAssertEqual(prediction.status, .paused, "\(method) must pause prediction")
        }
    }

    func testIUDContextDoesNotPausePrediction() {
        // Deliberately excluded from the suppressive set: this type doesn't distinguish hormonal
        // from copper IUDs, and a copper IUD does not suppress ovulation at all.
        let history = makeHistory(count: 6, lengthDays: 28)
        let context = contraceptive(.iud, start: day(0))
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: history, contraceptiveContext: context, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(prediction.status, .active)
        XCTAssertNil(prediction.suppressionReason)
        XCTAssertNotNil(prediction.predictedNextStartCenter)
    }

    func testEmergencyContraceptionDoesNotPausePrediction() {
        // A one-off event, not an ongoing suppressive state.
        let history = makeHistory(count: 6, lengthDays: 28)
        let context = contraceptive(.emergencyContraception, start: day(0))
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: history, contraceptiveContext: context, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(prediction.status, .active)
        XCTAssertNotNil(prediction.predictedNextStartCenter)
    }

    func testEndedSuppressiveContextDoesNotPausePrediction() {
        let history = makeHistory(count: 6, lengthDays: 28)
        let context = contraceptive(.pill, start: day(0), end: day(10)) // no longer active
        let prediction = CyclePredictionEngine.predictNextCycle(
            history: history, contraceptiveContext: context, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(prediction.status, .active)
        XCTAssertNotNil(prediction.predictedNextStartCenter)
    }

    // MARK: - (4) Phase estimation: unknown below threshold / under suppression, never guessed

    func testPhaseUnknownBelowMinimumHistoryThreshold() {
        for recordCount in [1, 2, 3] { // 0, 1, 2 completed cycles respectively
            let history = makeHistory(count: recordCount, lengthDays: 28)
            let estimate = CyclePredictionEngine.estimatePhase(
                history: history, contraceptiveContext: nil, asOf: day(1_000), algorithmVersion: "v1")
            XCTAssertEqual(estimate.phase, .unknown, "\(recordCount - 1) completed cycles")
            XCTAssertEqual(estimate.evidenceBasis, .insufficientHistory)
            XCTAssertEqual(estimate.confidence, 0)
        }
    }

    func testPhaseSuppressedRegardlessOfHistoryDepth() {
        // Plenty of history (9 completed cycles) — suppression must still win.
        let history = makeHistory(count: 10, lengthDays: 28)
        let context = contraceptive(.pill, start: day(0))
        let estimate = CyclePredictionEngine.estimatePhase(
            history: history, contraceptiveContext: context, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(estimate.phase, .unknown)
        XCTAssertEqual(estimate.evidenceBasis, .suppressedDueToContext)
        XCTAssertEqual(estimate.confidence, 0)
    }

    func testPhaseUnknownRendersAsOfAsItsOwnDateRangeRatherThanAFabricatedSpan() {
        let estimate = CyclePredictionEngine.estimatePhase(
            history: [], contraceptiveContext: nil, asOf: day(1_000), algorithmVersion: "v1")
        XCTAssertEqual(estimate.dateRangeStart, day(1_000))
        XCTAssertEqual(estimate.dateRangeEnd, day(1_000))
    }

    // MARK: - Phase estimation: calendar-only classification once history qualifies

    func testPhaseCalendarOnlyClassifiesEachSegmentOfARegularCycle() {
        // 4 completed 28-day cycles qualifies (>= 3). Anchor cycle starts day(112); default 5-day
        // bleed assumption applies since this record has no endAt yet. Central length = 28 ->
        // ovulation day offset = 28 - 14 = 14 -> ovulation day = day(126), band = [124, 128].
        let history = makeHistory(count: 5, lengthDays: 28)

        func phase(at n: Int) -> CyclePhaseEstimate {
            CyclePredictionEngine.estimatePhase(history: history, contraceptiveContext: nil,
                                                asOf: day(n), algorithmVersion: "v1")
        }

        let menstrual = phase(at: 112)
        XCTAssertEqual(menstrual.phase, .menstrual)
        XCTAssertEqual(menstrual.evidenceBasis, .calendarOnly)
        XCTAssertGreaterThan(menstrual.confidence, 0)
        XCTAssertEqual(menstrual.dateRangeStart, day(112))
        XCTAssertEqual(menstrual.dateRangeEnd, day(117))

        XCTAssertEqual(phase(at: 115).phase, .menstrual, "still within the default 5-day bleed assumption")
        XCTAssertEqual(phase(at: 120).phase, .follicular, "after bleeding, before the ovulatory band")
        XCTAssertEqual(phase(at: 126).phase, .ovulatory, "centered on the estimated ovulation day")
        XCTAssertEqual(phase(at: 135).phase, .luteal, "after the ovulatory band, before the next expected start")
    }

    func testPhaseUsesTheCurrentCycleRecordsOwnEndAtOverTheDefaultBleedAssumption() {
        // Same regular 4-completed-cycle history, but the current (last) record has an EXPLICIT
        // 2-day endAt instead of being left open to the 5-day default.
        var history = makeHistory(count: 5, lengthDays: 28)
        let last = history.removeLast()
        history.append(record(id: last.id, start: last.startAt, end: day(112 + 2), ongoing: false))

        // Day 115 is AFTER the explicit 2-day end (day 114) but WOULD still have been inside the
        // 5-day default (day 117) — proving the real endAt, not the default, drove the boundary.
        let estimate = CyclePredictionEngine.estimatePhase(
            history: history, contraceptiveContext: nil, asOf: day(115), algorithmVersion: "v1")
        XCTAssertEqual(estimate.phase, .follicular)
    }

    func testPhaseConfidenceRisesWithMoreCompletedCyclesButStaysWellBelowOne() {
        let fewer = CyclePredictionEngine.estimatePhase(
            history: makeHistory(count: 4, lengthDays: 28), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1") // 3 completed cycles
        let more = CyclePredictionEngine.estimatePhase(
            history: makeHistory(count: 8, lengthDays: 28), contraceptiveContext: nil,
            asOf: day(1_000), algorithmVersion: "v1") // 7 completed cycles

        XCTAssertLessThan(fewer.confidence, more.confidence)
        XCTAssertLessThan(more.confidence, 1.0, "calendar-only evidence is the weakest evidence class — never near-certain")
    }
}
