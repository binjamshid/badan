import Foundation
import XCTest
@testable import BADAN

/// EPIC-39 CYCLE-12 (fertile-window estimation, A17/ADR-0010/D-24) — `CycleFertileWindowEngine`
/// coverage, mirroring `CyclePredictionEngineTests`'s own fixture/style conventions exactly (same
/// UTC-midnight `base`/`day(_:)` anchor, same `record`/`contraceptive`/`makeHistory` helpers) so the
/// two suites read as siblings, the same way the engines themselves are siblings.
///
/// Covers this slice's four hard, non-negotiable requirements: (1) the three declared modes
/// (`.calendar`/`.signalAssisted`/`.suppressed`) behave exactly as specified, including
/// `.signalAssisted` honestly degrading to the same calendar-only computation as `.calendar` today;
/// (2) contraceptive-context suppression overrides ANY declared mode, reusing
/// `CyclePredictionEngine.isSuppressive(_:)` exactly; (3) the gate ORDER (user-declared mode first,
/// then contraceptive context, then history depth) is itself verified, not just each gate in
/// isolation; (4) the structural "never a bare date" guarantee (`windowStart`/`windowEnd` always nil
/// together or present together) holds across every reachable scenario.
final class CycleFertileWindowEngineTests: XCTestCase {
    private let device = "test-device"
    /// 2025-01-01T00:00:00Z — a UTC midnight anchor so day-arithmetic assertions can compare exact
    /// `Date` values without any DST ambiguity (identical anchor to `CyclePredictionEngineTests`).
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

    private func estimate(
        history: [CycleRecord], context: ContraceptiveContextLog? = nil,
        mode: FertileWindowMode, asOf: Date = Date(timeIntervalSince1970: 1_735_689_600 + 100 * 86_400)
    ) -> CycleFertileWindowEstimate {
        CycleFertileWindowEngine.estimateFertileWindow(
            history: history, contraceptiveContext: context, mode: mode, asOf: asOf, algorithmVersion: "v1")
    }

    // MARK: - Three declared modes

    func testSuppressedModeAlwaysReturnsSuppressedRegardlessOfHistoryDepth() {
        for history in [[CycleRecord](), makeHistory(count: 8, lengthDays: 28)] {
            let result = estimate(history: history, mode: .suppressed, asOf: day(1_000))
            XCTAssertEqual(result.status, .suppressed)
            XCTAssertEqual(result.evidenceBasis, .suppressedByMode)
            XCTAssertEqual(result.suppressionReason, CycleFertileWindowEngine.suppressionReasonUserDeclaredSuppressed)
            XCTAssertNil(result.windowStart)
            XCTAssertNil(result.windowEnd)
            XCTAssertEqual(result.confidence, 0)
            XCTAssertEqual(result.mode, .suppressed)
            XCTAssertTrue(result.inputCycleIds.isEmpty)
        }
    }

    func testCalendarModeProducesARealWindowOnceHistoryQualifies() {
        // 5 records, 28 days apart -> 4 completed cycles (>= minimumCompletedCyclesForEstimate == 3).
        // Anchor (last, ongoing) record starts day(112). centralLength == 28 (zero spread) ->
        // ovulationDayOffset = 28 - 14 = 14 -> ovulationDay = day(126).
        // windowStart = day(126 - 5) = day(121); windowEnd = day(126 + 1) = day(127).
        let history = makeHistory(count: 5, lengthDays: 28)
        let result = estimate(history: history, mode: .calendar, asOf: day(1_000))
        XCTAssertEqual(result.status, .active)
        XCTAssertEqual(result.evidenceBasis, .calendarOnly)
        XCTAssertEqual(result.mode, .calendar)
        XCTAssertNil(result.suppressionReason)
        XCTAssertGreaterThan(result.confidence, 0)
        XCTAssertEqual(result.windowStart, day(121))
        XCTAssertEqual(result.windowEnd, day(127))
    }

    func testSignalAssistedModeComputesTheIdenticalCalendarOnlyWindowAsCalendarModeToday() {
        // The documented, deliberate degrade: no real signal input exists in this codebase yet
        // (CYCLE-10 deferred), so `.signalAssisted` must produce EXACTLY the same window/confidence
        // as `.calendar` — never a fabricated narrower/stronger result — while still recording the
        // user's actual selection in `mode`.
        let history = makeHistory(count: 6, lengthDays: 28)
        let calendarResult = estimate(history: history, mode: .calendar, asOf: day(1_000))
        let signalResult = estimate(history: history, mode: .signalAssisted, asOf: day(1_000))

        XCTAssertEqual(calendarResult.windowStart, signalResult.windowStart)
        XCTAssertEqual(calendarResult.windowEnd, signalResult.windowEnd)
        XCTAssertEqual(calendarResult.confidence, signalResult.confidence)
        XCTAssertEqual(signalResult.evidenceBasis, .calendarOnly,
                       "signal-assisted must never claim stronger evidence than calendar-only with no real signal input")
        XCTAssertEqual(calendarResult.mode, .calendar)
        XCTAssertEqual(signalResult.mode, .signalAssisted, "mode still records what the user actually selected")
    }

    // MARK: - Insufficient history: a real, active-but-empty state, not a suppression

    func testFewerThanMinimumCompletedCyclesYieldsActiveButEmptyWindowNotSuppression() {
        for recordCount in [1, 2, 3] { // 0, 1, 2 completed cycles respectively (< minimum of 3)
            let history = makeHistory(count: recordCount, lengthDays: 28)
            let result = estimate(history: history, mode: .calendar, asOf: day(1_000))
            XCTAssertEqual(result.status, .active, "\(recordCount - 1) completed cycles must be active, not suppressed")
            XCTAssertEqual(result.evidenceBasis, .insufficientHistory)
            XCTAssertNil(result.suppressionReason)
            XCTAssertNil(result.windowStart)
            XCTAssertNil(result.windowEnd)
            XCTAssertEqual(result.confidence, 0)
        }
    }

    func testExactlyTheMinimumCompletedCyclesQualifiesForARealWindow() {
        // 4 records -> exactly 3 completed cycles == minimumCompletedCyclesForEstimate.
        let history = makeHistory(count: 4, lengthDays: 28)
        let result = estimate(history: history, mode: .calendar, asOf: day(1_000))
        XCTAssertEqual(result.status, .active)
        XCTAssertEqual(result.evidenceBasis, .calendarOnly)
        XCTAssertNotNil(result.windowStart)
        XCTAssertNotNil(result.windowEnd)
    }

    // MARK: - Contraceptive-context override: suppresses regardless of the user's declared mode

    func testActiveSuppressiveContraceptiveContextOverridesCalendarMode() {
        let history = makeHistory(count: 8, lengthDays: 28)
        let context = contraceptive(.pill, start: day(0))
        let result = estimate(history: history, context: context, mode: .calendar, asOf: day(1_000))
        XCTAssertEqual(result.status, .suppressed)
        XCTAssertEqual(result.evidenceBasis, .suppressedDueToContext)
        XCTAssertEqual(result.suppressionReason, CycleFertileWindowEngine.suppressionReasonSuppressiveContraceptiveContext)
        XCTAssertNil(result.windowStart)
        XCTAssertNil(result.windowEnd)
        XCTAssertEqual(result.confidence, 0)
        XCTAssertEqual(result.mode, .calendar, "mode still records the user's real selection even though suppressed")
    }

    func testActiveSuppressiveContraceptiveContextOverridesSignalAssistedModeToo() {
        let history = makeHistory(count: 8, lengthDays: 28)
        let context = contraceptive(.hormoneTherapy, start: day(0))
        let result = estimate(history: history, context: context, mode: .signalAssisted, asOf: day(1_000))
        XCTAssertEqual(result.status, .suppressed)
        XCTAssertEqual(result.evidenceBasis, .suppressedDueToContext)
        XCTAssertEqual(result.mode, .signalAssisted)
    }

    func testEveryDocumentedSuppressiveContraceptiveMethodOverridesFertileWindowEstimate() {
        for method: ContraceptiveMethodType in [.pill, .patch, .ring, .injection, .implant, .hormoneTherapy] {
            let history = makeHistory(count: 8, lengthDays: 28)
            let context = contraceptive(method, start: day(0))
            let result = estimate(history: history, context: context, mode: .calendar, asOf: day(1_000))
            XCTAssertEqual(result.status, .suppressed, "\(method) must suppress the fertile-window estimate")
        }
    }

    func testIUDContextDoesNotSuppressFertileWindowEstimate() {
        // Deliberately excluded from the suppressive set — cannot distinguish hormonal from copper.
        let history = makeHistory(count: 8, lengthDays: 28)
        let context = contraceptive(.iud, start: day(0))
        let result = estimate(history: history, context: context, mode: .calendar, asOf: day(1_000))
        XCTAssertEqual(result.status, .active)
        XCTAssertNotNil(result.windowStart)
        XCTAssertNotNil(result.windowEnd)
    }

    func testEmergencyContraceptionDoesNotSuppressFertileWindowEstimate() {
        let history = makeHistory(count: 8, lengthDays: 28)
        let context = contraceptive(.emergencyContraception, start: day(0))
        let result = estimate(history: history, context: context, mode: .calendar, asOf: day(1_000))
        XCTAssertEqual(result.status, .active)
        XCTAssertNotNil(result.windowStart)
    }

    func testEndedSuppressiveContraceptiveContextDoesNotSuppressFertileWindowEstimate() {
        let history = makeHistory(count: 8, lengthDays: 28)
        let context = contraceptive(.pill, start: day(0), end: day(10)) // no longer active
        let result = estimate(history: history, context: context, mode: .calendar, asOf: day(1_000))
        XCTAssertEqual(result.status, .active)
        XCTAssertNotNil(result.windowStart)
    }

    // MARK: - Gate ORDER: user-declared mode checked before contraceptive context

    func testUserDeclaredSuppressedModeReasonWinsOverAnAlsoSuppressiveContraceptiveContext() {
        let history = makeHistory(count: 8, lengthDays: 28)
        let context = contraceptive(.pill, start: day(0)) // also suppressive, but must not be the reason cited
        let result = estimate(history: history, context: context, mode: .suppressed, asOf: day(1_000))
        XCTAssertEqual(result.evidenceBasis, .suppressedByMode,
                       "gate 1 (user-declared mode) must be checked and win before gate 2 (contraceptive context)")
        XCTAssertEqual(result.suppressionReason, CycleFertileWindowEngine.suppressionReasonUserDeclaredSuppressed)
    }

    func testContraceptiveContextWinsOverInsufficientHistory() {
        // Only 1 completed cycle (below minimum) AND an active suppressive context — the context
        // gate (2) must fire before the history-depth gate (3) is ever reached.
        let history = makeHistory(count: 2, lengthDays: 28)
        let context = contraceptive(.pill, start: day(0))
        let result = estimate(history: history, context: context, mode: .calendar, asOf: day(1_000))
        XCTAssertEqual(result.evidenceBasis, .suppressedDueToContext,
                       "gate 2 (contraceptive context) must be checked and win before gate 3 (history depth)")
    }

    // MARK: - Structural "never a bare date" guarantee

    func testWindowStartAndWindowEndAreAlwaysBothNilOrBothPresentAcrossEveryReachableScenario() {
        let plentyHistory = makeHistory(count: 8, lengthDays: 28)
        let sparseHistory = makeHistory(count: 2, lengthDays: 28)
        let suppressiveContext = contraceptive(.pill, start: day(0))

        let scenarios: [CycleFertileWindowEstimate] = [
            estimate(history: [], mode: .suppressed, asOf: day(1_000)),
            estimate(history: plentyHistory, mode: .suppressed, asOf: day(1_000)),
            estimate(history: plentyHistory, mode: .calendar, asOf: day(1_000)),
            estimate(history: plentyHistory, mode: .signalAssisted, asOf: day(1_000)),
            estimate(history: sparseHistory, mode: .calendar, asOf: day(1_000)),
            estimate(history: sparseHistory, mode: .signalAssisted, asOf: day(1_000)),
            estimate(history: plentyHistory, context: suppressiveContext, mode: .calendar, asOf: day(1_000)),
            estimate(history: plentyHistory, context: suppressiveContext, mode: .signalAssisted, asOf: day(1_000)),
            estimate(history: [], context: suppressiveContext, mode: .calendar, asOf: day(1_000)),
        ]

        for (index, result) in scenarios.enumerated() {
            XCTAssertEqual(result.windowStart == nil, result.windowEnd == nil,
                           "scenario \(index): windowStart/windowEnd must be nil together or present together, never one alone")
        }
    }

    // MARK: - Confidence discipline: fertile-window confidence must never reach/exceed phase confidence

    /// AUDIT REGRESSION (named explicitly in `CycleFertileWindowEngine`'s own header as the standing
    /// test for this ordering): calendar-only fertile-window estimation is documented as strictly
    /// weaker evidence than the calendar-only PHASE estimate for the identical completed-cycle count
    /// — this must hold at every history depth, not just be true by coincidence at one data point.
    func testFertileWindowConfidenceNeverReachesOrExceedsPhaseConfidenceForTheSameCompletedCount() {
        for recordCount in 4...10 { // 3...9 completed cycles
            let history = makeHistory(count: recordCount, lengthDays: 28)
            let phase = CyclePredictionEngine.estimatePhase(
                history: history, contraceptiveContext: nil, asOf: day(1_000), algorithmVersion: "v1")
            let fertileWindow = estimate(history: history, mode: .calendar, asOf: day(1_000))
            XCTAssertLessThan(fertileWindow.confidence, phase.confidence,
                              "\(recordCount - 1) completed cycles: fertile-window confidence must stay below phase confidence")
        }
    }

    func testFertileWindowConfidenceStaysWellBelowOneEvenAtTheMatureHistoryCap() {
        let history = makeHistory(count: 12, lengthDays: 28) // well beyond recentCycleWindowCap
        let result = estimate(history: history, mode: .calendar, asOf: day(1_000))
        XCTAssertLessThan(result.confidence, 0.6, "calendar-only fertile-window evidence is the weakest evidence class")
    }

    // MARK: - Input manifest honesty

    func testInputCycleIdsOnlyCiteRecordsWithinTheRecentCycleWindowCap() {
        // 10 records -> 9 completed cycles; the window caps at the most recent 6 lengths, i.e.
        // records R3...R9 (7 records) — R0, R1, R2 must NOT be cited.
        let history = makeHistory(count: 10, lengthDays: 28)
        let result = estimate(history: history, mode: .calendar, asOf: day(1_000))
        XCTAssertEqual(Set(result.inputCycleIds), Set((3...9).map { "R\($0)" }))
    }

    func testInputCycleIdsAreEmptyForAnySuppressedOrInsufficientHistoryResult() {
        XCTAssertTrue(estimate(history: [], mode: .suppressed, asOf: day(1_000)).inputCycleIds.isEmpty)
        XCTAssertTrue(estimate(history: makeHistory(count: 2, lengthDays: 28), mode: .calendar, asOf: day(1_000))
            .inputCycleIds.isEmpty)
    }
}
