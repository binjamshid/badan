import Foundation
import XCTest
@testable import BADAN

/// EPIC-39 CYCLE-05 (Phase 3F slice 1) — the pure, storage-free cycle anomaly engine and its
/// bilingual message-template library. Nothing in this suite touches a database or a repository:
/// `CycleAnomalyEngine.detectAnomalies` takes already-fetched `[CycleRecord]`/`[FlowLog]` arrays and
/// returns `[CycleAnomalyEvent]`, exactly mirroring `DuplicateConflictResolverTests`'s own posture
/// for `Domain/Labs/DuplicateConflictResolver.swift`.
///
/// Two invariants get outsized coverage here on purpose, per the standing constraints this slice was
/// built under: (1) every anomaly type must simply never appear below its own documented
/// minimum-history gate — never a low-confidence guess — and (2) every shipped message-template
/// string, in BOTH languages, must stay inside the wellness-safe phrasing library and never use any
/// banned diagnostic/verdict word, checked as a standing regression test, not a one-time review.
final class CycleAnomalyEngineTests: XCTestCase {
    private let device = "test-device"
    private let base = Date(timeIntervalSince1970: 1_784_000_000)

    private func provenance(measuredAt: Date) -> Provenance {
        Provenance(sourceId: device, ingestionPath: .manual, measuredAt: measuredAt, measuredTimezone: "UTC",
                  recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func cycle(_ id: String, start: Date, end: Date?, ongoing: Bool, deletedAt: Date? = nil) -> CycleRecord {
        CycleRecord(id: id, startAt: start, endAt: end, ongoing: ongoing, originalId: id,
                   provenance: provenance(measuredAt: start), updatedAt: start, originDeviceId: device,
                   deletedAt: deletedAt)
    }

    private func flowLog(_ id: String, cycleId: String, at: Date, intensity: Double) -> FlowLog {
        FlowLog(id: id, cycleId: cycleId, occurredAt: at, originalLabel: "medium",
               normalizedIntensity: intensity, provenance: provenance(measuredAt: at), updatedAt: at,
               originDeviceId: device)
    }

    private func days(_ n: Double) -> TimeInterval { n * 86400 }

    /// Builds `count` completed periods spaced `gapDays[i]` apart (each `durationDays` long), and
    /// returns the cycles plus the timestamp right after the last one — the common fixture shape
    /// almost every test below needs.
    private func regularCycles(count: Int, gapDays: Double = 28, durationDays: Double = 5) -> (cycles: [CycleRecord], asOf: Date) {
        var start = base
        var cycles: [CycleRecord] = []
        for i in 0..<count {
            cycles.append(cycle("c\(i)", start: start, end: start.addingTimeInterval(days(durationDays)), ongoing: false))
            start = start.addingTimeInterval(days(gapDays))
        }
        return (cycles, start)
    }

    // MARK: - Minimum-history gates: below the gate, a type never appears (never a low-confidence guess)

    func testCycleLengthDeviationNeverFiresBelowTheMinimumBaselineGate() {
        // Only 3 cycles -> 2 known length points -> below the "3 baseline + 1 current" floor, even
        // though the (only) known gap here is wildly different from a typical cycle.
        var start = base
        let cycles = [
            cycle("a0", start: start, end: start.addingTimeInterval(days(5)), ongoing: false),
        ]
        start = start.addingTimeInterval(days(28))
        var all = cycles
        all.append(cycle("a1", start: start, end: start.addingTimeInterval(days(5)), ongoing: false))
        start = start.addingTimeInterval(days(90)) // huge, but still below the gate
        all.append(cycle("a2", start: start, end: start.addingTimeInterval(days(5)), ongoing: false))

        let events = CycleAnomalyEngine.detectAnomalies(cycles: all, flowLogs: [], prediction: nil,
                                                         asOf: start, algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .cycleLengthDeviation },
                       "below the minimum-history gate, cycleLengthDeviation must never appear, regardless of magnitude")
    }

    func testPeriodDurationDeviationNeverFiresWhileAnyCompletedPeriodIsMissingAnEndAt() {
        var (cycles, asOf) = regularCycles(count: 3)
        // A 4th, ongoing period (no endAt) must never count as "current" or toward the gate.
        cycles.append(cycle("c-ongoing", start: asOf, end: nil, ongoing: true))
        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: asOf.addingTimeInterval(days(2)),
                                                         algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .periodDurationDeviation },
                       "an ongoing period with no endAt must never be usable as the 'current' duration point")
    }

    func testFlowDeviationExcludesPeriodsWithNoFlowLogsFromTheMinimumAndFromComparison() {
        var start = base
        var cycles: [CycleRecord] = []
        var logs: [FlowLog] = []
        for i in 0..<3 {
            let c = cycle("f\(i)", start: start, end: start.addingTimeInterval(days(5)), ongoing: false)
            cycles.append(c)
            logs.append(flowLog("fl\(i)", cycleId: c.id, at: start.addingTimeInterval(days(1)), intensity: 0.5))
            start = start.addingTimeInterval(days(28))
        }
        // A 4th period with ZERO flow logs must not count toward the minimum, and must never be
        // silently treated as a zero-flow data point.
        cycles.append(cycle("f-nologs", start: start, end: start.addingTimeInterval(days(5)), ongoing: false))
        start = start.addingTimeInterval(days(28))

        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: logs, prediction: nil,
                                                         asOf: start, algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .flowDeviation },
                       "only 3 periods ever logged flow at all, which is below the 4-point (3 baseline + current) gate")
    }

    func testMissedExpectedPeriodNeverFiresWithoutAPrediction() {
        let (cycles, asOf) = regularCycles(count: 2)
        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: asOf.addingTimeInterval(days(200)),
                                                         algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .missedExpectedPeriod },
                       "with no prediction at all, there is nothing 'expected' to have been missed")
    }

    func testMissedExpectedPeriodNeverFiresWhileThePredictionIsPaused() {
        let cycles = [cycle("m0", start: base, end: base.addingTimeInterval(days(5)), ongoing: false)]
        let paused = CyclePrediction(
            id: "pred-paused", generatedAt: base, predictedNextStartHigh: base.addingTimeInterval(days(30)),
            confidence: 0.6, method: .lowHistory, status: .paused, algorithmVersion: "cyc.v1",
            updatedAt: base, originDeviceId: device)
        let events = CycleAnomalyEngine.detectAnomalies(
            cycles: cycles, flowLogs: [], prediction: paused, asOf: base.addingTimeInterval(days(90)),
            algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .missedExpectedPeriod },
                       "a paused prediction (e.g. active contraceptive context) has no 'expected' period to miss")
    }

    func testMissedExpectedPeriodNeverFiresFromAnActiveLowHistoryPrediction() {
        // AUDIT FIX regression: an ACTIVE (not paused) `.lowHistory` prediction — built from just
        // 1-2 completed cycles per `CyclePredictionEngine.tier(forCompletedCount:)` — DOES carry a
        // populated `predictedNextStartHigh`, so a gate that only checked "is there a high edge at
        // all" let a single-cycle user's forecast fire this anomaly. The research doc's own matrix
        // requires 3 cycles minimum for this type ("3 cycles for forecast; otherwise inactive").
        let cycles = [cycle("m0", start: base, end: base.addingTimeInterval(days(5)), ongoing: false)]
        let lowHistoryActive = CyclePrediction(
            id: "pred-low-active", generatedAt: base, predictedNextStartHigh: base.addingTimeInterval(days(30)),
            confidence: 0.3, method: .lowHistory, status: .active, algorithmVersion: "cyc.v1",
            updatedAt: base, originDeviceId: device)
        let events = CycleAnomalyEngine.detectAnomalies(
            cycles: cycles, flowLogs: [], prediction: lowHistoryActive, asOf: base.addingTimeInterval(days(90)),
            algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .missedExpectedPeriod },
                       "a lowHistory forecast (1-2 completed cycles) is below this type's own 3-cycle minimum")
    }

    func testRepeatedIrregularityNeverFiresBelowTheFourCycleWindow() {
        // 3 gaps (regular) is below the pattern-level floor of 4, even were they wildly irregular.
        let (cycles, asOf) = regularCycles(count: 3, gapDays: 40) // only 3 cycles -> 2 length points
        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: asOf, algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .repeatedIrregularity },
                       "pattern-level calls need at least 4 cycle-length points; below that, never fire")
    }

    func testEmptyInputProducesNoAnomaliesAndNeverCrashes() {
        let events = CycleAnomalyEngine.detectAnomalies(cycles: [], flowLogs: [], prediction: nil, asOf: base,
                                                         algorithmVersion: "v1", originDeviceId: device)
        XCTAssertTrue(events.isEmpty)
    }

    func testPerfectlyRegularHistoryProducesZeroAnomaliesOfAnyType() {
        let (cycles, asOf) = regularCycles(count: 6)
        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: asOf, algorithmVersion: "v1", originDeviceId: device)
        XCTAssertTrue(events.isEmpty, "a perfectly regular history must never manufacture an anomaly")
    }

    // MARK: - Live-ledger filtering (tombstoned rows are never candidates)

    func testTombstonedCyclesAreExcludedEntirelyFromEveryDetection() {
        var (cycles, asOf) = regularCycles(count: 5)
        var wildOutlier = cycle("tombstoned", start: asOf, end: asOf.addingTimeInterval(days(5)), ongoing: false)
        wildOutlier.deletedAt = asOf // tombstoned
        cycles.append(wildOutlier)
        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: asOf.addingTimeInterval(days(60)),
                                                         algorithmVersion: "v1", originDeviceId: device)
        XCTAssertTrue(events.isEmpty, "a tombstoned row must never feed any detection, regardless of how it would deviate")
    }

    // MARK: - cycleLengthDeviation: fires on a genuine deviation, correct severity/state/messageKey

    func testCycleLengthDeviationFiresOnALongCurrentGapAndCarriesTheRightShape() {
        var start = base
        var cycles: [CycleRecord] = []
        for i in 0..<5 {
            cycles.append(cycle("d\(i)", start: start, end: start.addingTimeInterval(days(5)), ongoing: false))
            start = start.addingTimeInterval(days(i == 4 ? 55 : 28)) // last gap far longer than the rest
        }
        cycles.append(cycle("d-last", start: start, end: nil, ongoing: true))

        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: start, algorithmVersion: "algo.v1", originDeviceId: device)
        guard let event = events.first(where: { $0.type == .cycleLengthDeviation }) else {
            return XCTFail("expected a cycleLengthDeviation for a far-longer-than-usual final gap")
        }
        XCTAssertEqual(event.severity, .medium)
        XCTAssertEqual(event.state, .active)
        XCTAssertEqual(event.messageKey, CycleAnomalyMessageKey.cycleLengthDeviation.rawValue)
        XCTAssertEqual(event.algorithmVersion, "algo.v1")
        XCTAssertEqual(event.originDeviceId, device)
        XCTAssertGreaterThan(event.confidence, 0)
        XCTAssertLessThanOrEqual(event.confidence, 1)
        XCTAssertFalse(event.basisWindowCycleIds.isEmpty, "the audit manifest must name which cycles fed the call")
    }

    func testCycleLengthDeviationDoesNotFireForOrdinaryDayToDayVariationWithinTheBand() {
        var start = base
        let gaps: [Double] = [27, 29, 28, 28, 30] // mild, ordinary variation
        var cycles: [CycleRecord] = []
        for (i, gap) in gaps.enumerated() {
            cycles.append(cycle("e\(i)", start: start, end: start.addingTimeInterval(days(5)), ongoing: false))
            start = start.addingTimeInterval(days(gap))
        }
        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: start, algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .cycleLengthDeviation },
                       "ordinary 1-2 day variation must never itself be flagged")
    }

    // MARK: - periodDurationDeviation

    func testPeriodDurationDeviationFiresOnAnUnusuallyLongCompletedBleed() {
        var start = base
        var cycles: [CycleRecord] = []
        for i in 0..<4 {
            let duration = (i == 3) ? days(14) : days(5) // last completed period far longer
            cycles.append(cycle("q\(i)", start: start, end: start.addingTimeInterval(duration), ongoing: false))
            start = start.addingTimeInterval(days(28))
        }
        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: start, algorithmVersion: "v1", originDeviceId: device)
        guard let event = events.first(where: { $0.type == .periodDurationDeviation }) else {
            return XCTFail("expected periodDurationDeviation for a far-longer-than-usual completed bleed")
        }
        XCTAssertEqual(event.severity, .medium)
        XCTAssertEqual(event.state, .active)
        XCTAssertEqual(event.messageKey, CycleAnomalyMessageKey.periodDurationDeviation.rawValue)
    }

    // MARK: - flowDeviation

    func testFlowDeviationFiresOnAMateriallyHeavierCurrentPeriodAndIsLowSeverity() {
        var start = base
        var cycles: [CycleRecord] = []
        var logs: [FlowLog] = []
        for i in 0..<4 {
            let c = cycle("g\(i)", start: start, end: start.addingTimeInterval(days(5)), ongoing: false)
            cycles.append(c)
            let intensity = (i == 3) ? 0.95 : 0.3 // last period much heavier
            for d in 0..<3 {
                logs.append(flowLog("gl\(i)-\(d)", cycleId: c.id, at: start.addingTimeInterval(days(Double(d))),
                                    intensity: intensity))
            }
            start = start.addingTimeInterval(days(28))
        }
        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: logs, prediction: nil,
                                                         asOf: start, algorithmVersion: "v1", originDeviceId: device)
        guard let event = events.first(where: { $0.type == .flowDeviation }) else {
            return XCTFail("expected flowDeviation for a materially heavier logged period")
        }
        XCTAssertEqual(event.severity, .low, "flow deviation's default sensitivity is low per the anomaly matrix")
        XCTAssertEqual(event.messageKey, CycleAnomalyMessageKey.flowDeviation.rawValue)
    }

    // MARK: - missedExpectedPeriod

    func testMissedExpectedPeriodFiresPastTheConfidenceBandPlusGraceWithNothingNewLogged() {
        let cycles = [cycle("n0", start: base, end: base.addingTimeInterval(days(5)), ongoing: false)]
        let predictedHigh = base.addingTimeInterval(days(30))
        let prediction = CyclePrediction(
            id: "pred-active", generatedAt: base, predictedNextStartHigh: predictedHigh, confidence: 0.72,
            method: .moderateHistory, status: .active, algorithmVersion: "cyc.v1", inputCycleIds: ["n0"],
            updatedAt: base, originDeviceId: device)
        let asOf = predictedHigh.addingTimeInterval(days(3)) // past high + the small grace window

        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: prediction,
                                                         asOf: asOf, algorithmVersion: "v1", originDeviceId: device)
        guard let event = events.first(where: { $0.type == .missedExpectedPeriod }) else {
            return XCTFail("expected missedExpectedPeriod once asOf passes the forecast's high edge plus grace")
        }
        XCTAssertEqual(event.severity, .medium)
        XCTAssertEqual(event.confidence, 0.72, "reuses the forecast's own honest confidence, never invents a new one")
        XCTAssertEqual(event.basisWindowCycleIds, ["n0"], "reuses the prediction's own input manifest")
        XCTAssertEqual(event.messageKey, CycleAnomalyMessageKey.missedExpectedPeriod.rawValue)
    }

    func testMissedExpectedPeriodDoesNotFireBeforeTheGraceWindowElapses() {
        let cycles = [cycle("n0", start: base, end: base.addingTimeInterval(days(5)), ongoing: false)]
        let predictedHigh = base.addingTimeInterval(days(30))
        let prediction = CyclePrediction(
            id: "pred-active2", generatedAt: base, predictedNextStartHigh: predictedHigh, confidence: 0.72,
            method: .moderateHistory, status: .active, algorithmVersion: "cyc.v1", updatedAt: base,
            originDeviceId: device)
        let asOf = predictedHigh.addingTimeInterval(days(0.5)) // still within the grace window

        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: prediction,
                                                         asOf: asOf, algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .missedExpectedPeriod },
                       "must not fire before the confidence band's own high edge plus the grace window elapses")
    }

    func testMissedExpectedPeriodDoesNotFireOnceANewPeriodHasStartedSincePrediction() {
        let cycles = [
            cycle("o0", start: base, end: base.addingTimeInterval(days(5)), ongoing: false),
            cycle("o1", start: base.addingTimeInterval(days(29)), end: nil, ongoing: true),
        ]
        let predictedHigh = base.addingTimeInterval(days(30))
        let prediction = CyclePrediction(
            id: "pred-fulfilled", generatedAt: base, predictedNextStartHigh: predictedHigh, confidence: 0.7,
            method: .moderateHistory, status: .active, algorithmVersion: "cyc.v1", updatedAt: base,
            originDeviceId: device)
        let asOf = predictedHigh.addingTimeInterval(days(10))

        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: prediction,
                                                         asOf: asOf, algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .missedExpectedPeriod },
                       "a period that already started since the forecast was generated is a fulfilled forecast, not a miss")
    }

    // MARK: - repeatedIrregularity

    func testRepeatedIrregularityFiresWhenThreeOfTheLastFourGapsFallOutsideTheBaselineBand() {
        var start = base
        var cycles: [CycleRecord] = []
        let gaps: [Double] = [28, 28, 28, 60, 61, 59] // stable baseline, then a run of large gaps
        for (i, gap) in gaps.enumerated() {
            cycles.append(cycle("t\(i)", start: start, end: start.addingTimeInterval(days(5)), ongoing: false))
            start = start.addingTimeInterval(days(gap))
        }
        cycles.append(cycle("t-last", start: start, end: nil, ongoing: true))

        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: start, algorithmVersion: "v1", originDeviceId: device)
        guard let event = events.first(where: { $0.type == .repeatedIrregularity }) else {
            return XCTFail("expected repeatedIrregularity when 3 of the last 4 gaps deviate from the established band")
        }
        XCTAssertEqual(event.severity, .medium)
        XCTAssertEqual(event.messageKey, CycleAnomalyMessageKey.repeatedIrregularity.rawValue)
    }

    func testRepeatedIrregularityDoesNotFireOnASingleIsolatedDeviation() {
        var start = base
        // Only the LAST gap deviates; not 2 consecutive, not 3-of-4 -> pattern-level check stays quiet
        // even though the single-cycle cycleLengthDeviation check may itself still fire independently.
        let gaps: [Double] = [28, 28, 28, 28, 60]
        var cycles: [CycleRecord] = []
        for (i, gap) in gaps.enumerated() {
            cycles.append(cycle("u\(i)", start: start, end: start.addingTimeInterval(days(5)), ongoing: false))
            start = start.addingTimeInterval(days(gap))
        }
        cycles.append(cycle("u-last", start: start, end: nil, ongoing: true))

        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: start, algorithmVersion: "v1", originDeviceId: device)
        XCTAssertFalse(events.contains { $0.type == .repeatedIrregularity },
                       "a single isolated deviation is not a repeated pattern")
    }

    // MARK: - Multiple anomaly types can coexist in one call (never mutually suppressing)

    func testMultipleAnomalyTypesCanAppearTogetherInOneDetectionPass() {
        var start = base
        var cycles: [CycleRecord] = []
        let gaps: [Double] = [28, 28, 28, 60, 61, 59]
        for (i, gap) in gaps.enumerated() {
            cycles.append(cycle("w\(i)", start: start, end: start.addingTimeInterval(days(5)), ongoing: false))
            start = start.addingTimeInterval(days(gap))
        }
        cycles.append(cycle("w-last", start: start, end: nil, ongoing: true))

        let events = CycleAnomalyEngine.detectAnomalies(cycles: cycles, flowLogs: [], prediction: nil,
                                                         asOf: start, algorithmVersion: "v1", originDeviceId: device)
        XCTAssertTrue(events.contains { $0.type == .cycleLengthDeviation })
        XCTAssertTrue(events.contains { $0.type == .repeatedIrregularity })
    }

    // MARK: - Wellness-safe language: the banned-phrase regression test (mirrors
    // `LabNotebookUITests.testNoShippedEnglishCopyUsesATrafficLightVerdictWord`'s own source-scanning
    // pattern, applied to this file's own message-template literals instead of a UI screen's)

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CycleAnomalyEngineTests.swift
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
    }()

    private static let engineSourcePath = "apps/ios/Sources/Domain/Cycle/CycleAnomalyEngine.swift"

    private static func engineSourceText() -> String {
        let url = repoRoot.appendingPathComponent(engineSourcePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// research doc §6's exact banned list, plus named-condition/causal-claim equivalents it calls
    /// out in surrounding prose ("equivalents"), checked case-insensitively.
    private static let bannedPhrases = [
        "abnormal", "disorder", "pcos", "infertile", "implantation", "pregnancy likely",
        "failed ovulation", "hormone imbalance", "seek care immediately",
        // named-condition / causal-claim equivalents named alongside the core list in §6/§14:
        "endometriosis", "pmdd", "you are ovulating", "avoid pregnancy", "underperforming",
        "hemorrhage", "deficiency",
    ]

    func testNoShippedMessageTemplateStringAnywhereUsesABannedDiagnosticOrVerdictWord() {
        for (key, value) in CycleAnomalyMessages.templates {
            let enLower = value.en.lowercased()
            let arText = value.ar
            for phrase in Self.bannedPhrases {
                XCTAssertFalse(enLower.contains(phrase),
                              "message '\(key)' contains banned phrase '\(phrase)' in its English copy: \"\(value.en)\"")
                XCTAssertFalse(arText.contains(phrase),
                              "message '\(key)' contains banned phrase '\(phrase)' in its Arabic copy: \"\(value.ar)\"")
            }
        }
    }

    /// Same check, but by re-parsing this file's OWN source text (mirroring `LabNotebookUITests`'s
    /// literal-scanning approach exactly) rather than the already-loaded runtime dictionary — so a
    /// future edit that adds a banned word inside a literal, even one this test's dictionary-based
    /// sibling above might not enumerate (e.g. a brand-new key added without updating a helper), is
    /// still caught directly against the shipped source.
    func testEngineSourceLiteralsContainNoTrafficLightOrDiagnosticVerdictWord() {
        let text = Self.engineSourceText()
        XCTAssertFalse(text.isEmpty, "expected non-empty source at \(Self.engineSourcePath)")

        let bannedPattern = try! NSRegularExpression(
            pattern: #"\b(normal|healthy|danger|optimal|abnormal|unhealthy)\b"#, options: .caseInsensitive)
        let literalPattern = try! NSRegularExpression(pattern: #"(?:en|ar):\s*"((?:[^"\\]|\\.)*)""#)

        let fullRange = NSRange(text.startIndex..., in: text)
        var checkedAtLeastOne = false
        for match in literalPattern.matches(in: text, range: fullRange) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let literal = String(text[range])
            checkedAtLeastOne = true
            let literalRange = NSRange(literal.startIndex..., in: literal)
            XCTAssertEqual(bannedPattern.numberOfMatches(in: literal, range: literalRange), 0,
                          "\(Self.engineSourcePath) renders a traffic-light/verdict word in \"\(literal)\" — " +
                          "BADAN's cycle anomaly copy must only ever say \"different from your recent pattern\"")
        }
        XCTAssertTrue(checkedAtLeastOne, "expected to find at least one en:/ar: literal to scan — test would " +
                      "otherwise silently pass on nothing")
    }

    func testEveryAnomalyTypeHasExactlyOneNonEmptyBilingualMessageTemplate() {
        for key in CycleAnomalyMessageKey.allCases {
            guard let text = CycleAnomalyMessages.text(for: key.rawValue) else {
                return XCTFail("missing message template for \(key.rawValue)")
            }
            XCTAssertFalse(text.en.isEmpty, "\(key.rawValue) has an empty English string")
            XCTAssertFalse(text.ar.isEmpty, "\(key.rawValue) has an empty Arabic string")
            XCTAssertNotEqual(text.en, text.ar, "Arabic must be real translated copy, never the English placeholder")
        }
    }

    func testUnrecognizedMessageKeyResolvesToNilNeverAFabricatedFallback() {
        XCTAssertNil(CycleAnomalyMessages.text(for: "not.a.real.key"))
    }
}
