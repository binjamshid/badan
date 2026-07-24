import Foundation
import XCTest
@testable import BADAN

/// EPIC-39 (Phase 3F slice 2) — coverage for the cycle-history/prediction-detail/anomaly-history UI
/// lane's own pure view-logic (`CycleHistoryScreen.swift`): the "never a bare/single-date
/// prediction" rule, the "never render the engine's own internal suppressionReason placeholder"
/// rule, the anti-panic palette (no raw red, `BadanColor.outOfBand` actually used for the active
/// anomaly state only), the neutral "cycle" (never "period") language default, and the anomaly
/// history's "full audit trail, resolved ONLY through `CycleAnomalyMessages`" contract — all
/// exercised over the REAL `Domain/Cycle` types this slice is built on, exactly as
/// `LabNotebookUITests`/`CyclePredictionEngineTests` already do for their own slices.
final class CycleHistoryUITests: XCTestCase {
    private let device = "test-device"
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Fixtures over the REAL domain types (Domain/Cycle/CycleModels.swift)

    private func provenance(measuredAt: Date) -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: "UTC", recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func record(id: String, start: Date, end: Date? = nil, ongoing: Bool = false) -> CycleRecord {
        CycleRecord(id: id, startAt: start, endAt: end, ongoing: ongoing, originalId: id,
                   provenance: provenance(measuredAt: start), updatedAt: start, originDeviceId: device)
    }

    private func flowLog(id: String, cycleId: String, occurredAt: Date, label: String = "medium") -> FlowLog {
        FlowLog(id: id, cycleId: cycleId, occurredAt: occurredAt, originalLabel: label,
               normalizedIntensity: 0.5, provenance: provenance(measuredAt: occurredAt),
               updatedAt: occurredAt, originDeviceId: device)
    }

    private func prediction(
        low: Date? = nil, center: Date? = nil, high: Date? = nil, confidence: Double = 0.5,
        method: CyclePredictionMethod = .moderateHistory, status: CyclePredictionStatus = .active,
        suppressionReason: String? = nil, inputCycleIds: [String] = []
    ) -> CyclePrediction {
        CyclePrediction(id: "PRED-1", generatedAt: now, predictedNextStartLow: low,
                        predictedNextStartCenter: center, predictedNextStartHigh: high,
                        confidence: confidence, method: method, status: status,
                        suppressionReason: suppressionReason, algorithmVersion: "test@1.0.0",
                        inputCycleIds: inputCycleIds, updatedAt: now, originDeviceId: device)
    }

    private func phaseEstimate(
        phase: CyclePhase = .luteal, confidence: Double = 0.6,
        evidenceBasis: CyclePhaseEvidenceBasis = .calendarOnly
    ) -> CyclePhaseEstimate {
        CyclePhaseEstimate(id: "PHASE-1", dateRangeStart: now, dateRangeEnd: now, phase: phase,
                          confidence: confidence, evidenceBasis: evidenceBasis,
                          algorithmVersion: "test@1.0.0", computedAt: now, updatedAt: now, originDeviceId: device)
    }

    /// EPIC-39 CYCLE-12 (A17/ADR-0010/D-24) fixture, mirroring `prediction(...)`/`phaseEstimate(...)`
    /// above exactly — a fully-parameterized `CycleFertileWindowEstimate` for presentation-layer tests.
    private func fertileWindowEstimate(
        windowStart: Date? = nil, windowEnd: Date? = nil, confidence: Double = 0.3,
        mode: FertileWindowMode = .calendar, evidenceBasis: FertileWindowEvidenceBasis = .calendarOnly,
        status: FertileWindowStatus = .active, suppressionReason: String? = nil, inputCycleIds: [String] = []
    ) -> CycleFertileWindowEstimate {
        CycleFertileWindowEstimate(id: "FW-1", generatedAt: now, windowStart: windowStart, windowEnd: windowEnd,
                                   confidence: confidence, mode: mode, evidenceBasis: evidenceBasis, status: status,
                                   suppressionReason: suppressionReason, algorithmVersion: "test@1.0.0",
                                   inputCycleIds: inputCycleIds, updatedAt: now, originDeviceId: device)
    }

    private func anomalyEvent(
        id: String = "ANOM-1", detectedAt: Date? = nil, state: CycleAnomalyState = .active,
        messageKey: String? = nil
    ) -> CycleAnomalyEvent {
        CycleAnomalyEvent(id: id, type: .cycleLengthDeviation, detectedAt: detectedAt ?? now,
                          severity: .medium, messageKey: messageKey ?? CycleAnomalyMessageKey.cycleLengthDeviation.rawValue,
                          state: state, algorithmVersion: "test@1.0.0", confidence: 0.7,
                          updatedAt: now, originDeviceId: device)
    }

    // MARK: - Source scans over this lane's own file (mirrors LabNotebookUITests' own checks)

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CycleHistoryUITests.swift
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
    }()

    private static func sourceText(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static let screenPath = "apps/ios/Sources/Features/Cycle/CycleHistoryScreen.swift"

    /// This lane's own reachability check (`scripts/check-reachability.py`'s "built but dark"
    /// guard, applied to the one sub-screen this file itself owns and constructs): the "why this
    /// estimate?" anatomy sheet is another lane's-worth of UI on its own, so it must actually be
    /// wired into a `.sheet` presentation here, not merely declared. This screen's OWN
    /// reachability from `CycleHomeScreen` is a different lane's routing (explicitly out of scope
    /// per this lane's brief) and is not asserted here.
    func testAnatomySheetIsActuallyConstructedWithinThisScreenNotJustDeclared() {
        let text = Self.sourceText(Self.screenPath)
        XCTAssertFalse(text.isEmpty, "expected non-empty source at \(Self.screenPath)")
        XCTAssertTrue(text.contains("CyclePredictionAnatomySheet("),
                     "the 'why this estimate?' anatomy sheet must have a real construction site in this screen")
    }

    func testNoRawRedColorOrTheReservedCriticalTokenAnywhereInThisScreen() {
        let text = Self.sourceText(Self.screenPath)
        XCTAssertFalse(text.contains("Color.red"), "must never use a raw red color for an anomaly/prediction state")
        XCTAssertFalse(text.contains("UIColor.red"), "must never use a raw red color for an anomaly/prediction state")
        XCTAssertFalse(text.contains("BadanColor.critical"),
                       "must never reach for the reserved-and-unused critical token — anomalies get exactly one " +
                       "muted amber, regardless of type")
    }

    func testTheOutOfBandTokenIsActuallyUsedForTheActiveAnomalyStateOnly() {
        let text = Self.sourceText(Self.screenPath)
        XCTAssertTrue(text.contains("BadanColor.outOfBand"),
                     "the muted amber anti-panic token must be wired in for the active anomaly state")
    }

    /// `CyclePrediction.suppressionReason` is documented (`CyclePredictionEngine`'s own file
    /// header) as an internal, non-user-facing placeholder — this screen must write its own calm
    /// sentence for the paused case instead of ever reading that field directly.
    func testNeverRendersThePredictionEnginesOwnInternalSuppressionReasonField() {
        let text = Self.sourceText(Self.screenPath)
        XCTAssertFalse(text.contains("prediction.suppressionReason"),
                      "must never read CyclePrediction.suppressionReason — it is an internal placeholder, never rendered text")
        XCTAssertFalse(text.contains(CyclePredictionEngine.suppressionReasonSuppressiveContraceptiveContext),
                      "the raw internal placeholder string itself must never appear as shipped UI copy")
    }

    func testNoShippedEnglishCopyUsesATrafficLightVerdictWord() {
        let bannedPattern = try! NSRegularExpression(
            pattern: #"\b(normal|healthy|danger|optimal|abnormal|unhealthy|irregular)\b"#, options: .caseInsensitive)
        let literalPattern = try! NSRegularExpression(pattern: #"en:\s*"((?:[^"\\]|\\.)*)""#)
        let text = Self.sourceText(Self.screenPath)
        let fullRange = NSRange(text.startIndex..., in: text)
        for match in literalPattern.matches(in: text, range: fullRange) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let literal = String(text[range])
            let literalRange = NSRange(literal.startIndex..., in: literal)
            XCTAssertEqual(bannedPattern.numberOfMatches(in: literal, range: literalRange), 0,
                          "renders a traffic-light/verdict word in \"\(literal)\" — BADAN never renders a verdict here")
        }
    }

    /// Neutral-language-default (`docs/legal/reproductive-threat-model.md` §5): every user-facing
    /// string in this screen says "cycle", never "period".
    func testNeutralCycleLanguageNeverSaysPeriodInShippedEnglishCopy() {
        let literalPattern = try! NSRegularExpression(pattern: #"en:\s*"((?:[^"\\]|\\.)*)""#)
        let text = Self.sourceText(Self.screenPath)
        let fullRange = NSRange(text.startIndex..., in: text)
        var checked = 0
        for match in literalPattern.matches(in: text, range: fullRange) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let literal = String(text[range]).lowercased()
            checked += 1
            XCTAssertFalse(literal.contains("period"),
                          "\"\(literal)\" says \"period\" — this screen's default framing must say \"cycle\"")
        }
        XCTAssertGreaterThan(checked, 0, "sanity check: the literal-scan regex must actually match this file's strings")
    }

    // MARK: - CyclePredictionPresentation (never a bare/single-date prediction)

    func testHasRangeIsTrueOnlyWhenActiveWithAllThreeRangeFieldsPresent() {
        let full = prediction(low: now, center: now, high: now, method: .matureHistory, status: .active)
        XCTAssertTrue(CyclePredictionPresentation.hasRange(full))

        XCTAssertFalse(CyclePredictionPresentation.hasRange(prediction(method: .coldStart, status: .active)))

        let paused = prediction(low: now, center: now, high: now, method: .moderateHistory, status: .paused)
        XCTAssertFalse(CyclePredictionPresentation.hasRange(paused),
                       "a paused forecast must never be treated as having a usable range")
    }

    func testRecentCycleCountIsNilForColdStartPausedAndAnEmptyManifest() {
        XCTAssertNil(CyclePredictionPresentation.recentCycleCount(prediction(method: .coldStart)))
        XCTAssertNil(CyclePredictionPresentation.recentCycleCount(prediction(status: .paused, inputCycleIds: ["A"])))
        XCTAssertNil(CyclePredictionPresentation.recentCycleCount(prediction(method: .lowHistory, inputCycleIds: [])))
    }

    func testRecentCycleCountNamesExactlyTheInputManifestCount() {
        let p = prediction(method: .matureHistory, inputCycleIds: ["A", "B", "C", "D"])
        XCTAssertEqual(CyclePredictionPresentation.recentCycleCount(p), 4)
    }

    func testConfidenceDescriptorPrioritizesPausedOverMethod() {
        let paused = prediction(method: .matureHistory, status: .paused)
        XCTAssertEqual(CyclePredictionPresentation.confidenceDescriptor(paused).en, CycleHistoryStrings.predictionPaused.en)
    }

    func testConfidenceDescriptorNeverRendersTheRawSuppressionReasonPlaceholder() {
        let paused = prediction(status: .paused,
                                suppressionReason: CyclePredictionEngine.suppressionReasonSuppressiveContraceptiveContext)
        let descriptor = CyclePredictionPresentation.confidenceDescriptor(paused)
        XCTAssertFalse(descriptor.en.contains("suppressive_contraceptive_context_active"))
        XCTAssertFalse(descriptor.ar.contains("suppressive_contraceptive_context_active"))
    }

    func testConfidenceDescriptorMapsEachHistoryTierToItsOwnSentence() {
        XCTAssertEqual(CyclePredictionPresentation.confidenceDescriptor(prediction(method: .coldStart)).en,
                      CycleHistoryStrings.noEstimateYet.en)
        XCTAssertEqual(CyclePredictionPresentation.confidenceDescriptor(prediction(method: .lowHistory)).en,
                      CycleHistoryStrings.broadEstimate.en)
        XCTAssertEqual(CyclePredictionPresentation.confidenceDescriptor(prediction(method: .moderateHistory)).en,
                      CycleHistoryStrings.moderateEstimate.en)
        XCTAssertEqual(CyclePredictionPresentation.confidenceDescriptor(prediction(method: .matureHistory)).en,
                      CycleHistoryStrings.confidentEstimate.en)
    }

    // MARK: - CyclePredictionAnatomy ("why this estimate?" resolution)

    func testResolvedInputsPreservesInputCycleIdsOrderAndSkipsAMissingId() {
        let recordA = record(id: "A", start: now)
        let recordB = record(id: "B", start: now.addingTimeInterval(86_400))
        let p = prediction(inputCycleIds: ["B", "MISSING", "A"])
        let resolved = CyclePredictionAnatomy.resolvedInputs(p, records: [recordA, recordB])
        XCTAssertEqual(resolved.map(\.id), ["B", "A"],
                      "must preserve inputCycleIds' own order and silently skip an id with no matching record")
    }

    func testResolvedInputsIsEmptyWhenTheManifestIsEmpty() {
        let recordA = record(id: "A", start: now)
        XCTAssertTrue(CyclePredictionAnatomy.resolvedInputs(prediction(inputCycleIds: []), records: [recordA]).isEmpty)
    }

    // MARK: - CyclePhasePresentation (calm, gated)

    func testShouldShowPhaseNameRequiresCalendarOnlyAndConfidenceAtOrAboveTheFloor() {
        let floor = CyclePhasePresentation.minConfidenceToShowPhase
        XCTAssertTrue(CyclePhasePresentation.shouldShowPhaseName(phaseEstimate(confidence: floor, evidenceBasis: .calendarOnly)))
        XCTAssertFalse(CyclePhasePresentation.shouldShowPhaseName(phaseEstimate(confidence: floor - 0.01, evidenceBasis: .calendarOnly)))
        XCTAssertFalse(CyclePhasePresentation.shouldShowPhaseName(phaseEstimate(confidence: 0.99, evidenceBasis: .insufficientHistory)))
        XCTAssertFalse(CyclePhasePresentation.shouldShowPhaseName(phaseEstimate(confidence: 0.99, evidenceBasis: .suppressedDueToContext)))
    }

    func testCaveatIsNilExactlyWhenThePhaseNameWouldShowAndNamedOtherwise() {
        XCTAssertNil(CyclePhasePresentation.caveat(phaseEstimate(confidence: 0.9, evidenceBasis: .calendarOnly)))

        XCTAssertEqual(CyclePhasePresentation.caveat(phaseEstimate(evidenceBasis: .insufficientHistory))?.en,
                      CycleHistoryStrings.notEnoughPatternYet.en)
        XCTAssertEqual(CyclePhasePresentation.caveat(phaseEstimate(evidenceBasis: .suppressedDueToContext))?.en,
                      CycleHistoryStrings.pausedForContraceptiveContext.en)

        let lowConfidenceCalendarOnly = phaseEstimate(confidence: 0.1, evidenceBasis: .calendarOnly)
        XCTAssertEqual(CyclePhasePresentation.caveat(lowConfidenceCalendarOnly)?.en, CycleHistoryStrings.notEnoughPatternYet.en,
                      "a low-confidence calendar-only estimate must still fall back to the plain caveat, never a low-confidence phase name")
    }

    // MARK: - CycleFertileWindowPresentation (EPIC-39 CYCLE-12, A17/ADR-0010/D-24 — never a bare date)

    func testFertileWindowHasWindowIsTrueOnlyWhenActiveWithBothRangeFieldsPresent() {
        let full = fertileWindowEstimate(windowStart: now, windowEnd: now, status: .active)
        XCTAssertTrue(CycleFertileWindowPresentation.hasWindow(full))

        XCTAssertFalse(CycleFertileWindowPresentation.hasWindow(fertileWindowEstimate(status: .active)),
                       "no range fields at all must never read as having a window")

        let suppressedButSomehowDated = fertileWindowEstimate(windowStart: now, windowEnd: now, status: .suppressed)
        XCTAssertFalse(CycleFertileWindowPresentation.hasWindow(suppressedButSomehowDated),
                       "a suppressed estimate must never be treated as having a usable window, defensively, " +
                       "even if range fields were somehow present")
    }

    func testFertileWindowHasWindowRequiresBothDatesTogetherNeverJustOne() {
        // Structural "never a bare date" guarantee, checked at the presentation layer too (the
        // engine's own guarantee is covered separately in `CycleFertileWindowEngineTests`): even if
        // only one of the two range fields were somehow populated, this must never read as a window.
        XCTAssertFalse(CycleFertileWindowPresentation.hasWindow(
            fertileWindowEstimate(windowStart: now, windowEnd: nil, status: .active)))
        XCTAssertFalse(CycleFertileWindowPresentation.hasWindow(
            fertileWindowEstimate(windowStart: nil, windowEnd: now, status: .active)))
    }

    func testFertileWindowRecentCycleCountIsNilWhenNoWindowOrAnEmptyManifest() {
        XCTAssertNil(CycleFertileWindowPresentation.recentCycleCount(fertileWindowEstimate(status: .active)),
                    "no window at all -> no method label")
        XCTAssertNil(CycleFertileWindowPresentation.recentCycleCount(
            fertileWindowEstimate(windowStart: now, windowEnd: now, inputCycleIds: [])),
                    "a window with an empty input manifest -> no method label")
    }

    func testFertileWindowRecentCycleCountNamesExactlyTheInputManifestCount() {
        let estimate = fertileWindowEstimate(windowStart: now, windowEnd: now, inputCycleIds: ["A", "B", "C"])
        XCTAssertEqual(CycleFertileWindowPresentation.recentCycleCount(estimate), 3)
    }

    func testFertileWindowActiveCaveatIsHonestAboutSignalAssistedModeNotActuallyNarrowingAnything() {
        let calendarActive = fertileWindowEstimate(windowStart: now, windowEnd: now, mode: .calendar)
        XCTAssertEqual(CycleFertileWindowPresentation.activeCaveat(calendarActive).en,
                      CycleHistoryStrings.fertileWindowBroadEstimate.en)

        let signalAssistedActive = fertileWindowEstimate(windowStart: now, windowEnd: now, mode: .signalAssisted)
        XCTAssertEqual(CycleFertileWindowPresentation.activeCaveat(signalAssistedActive).en,
                      CycleHistoryStrings.fertileWindowSignalAssistedNotYetAvailable.en,
                      "a user who picked signal-assisted mode must be told no additional signal narrowed this, " +
                      "never shown the plain calendar-only caveat as if nothing were different about their choice")
    }

    func testFertileWindowCaveatIsNilExactlyWhenAWindowWouldShow() {
        XCTAssertNil(CycleFertileWindowPresentation.caveat(fertileWindowEstimate(windowStart: now, windowEnd: now)))

        XCTAssertEqual(CycleFertileWindowPresentation.caveat(
            fertileWindowEstimate(evidenceBasis: .suppressedDueToContext, status: .suppressed))?.en,
                      CycleHistoryStrings.fertileWindowSuppressedByContext.en)
        XCTAssertEqual(CycleFertileWindowPresentation.caveat(
            fertileWindowEstimate(evidenceBasis: .suppressedByMode, status: .suppressed))?.en,
                      CycleHistoryStrings.fertileWindowOff.en,
                      "off (suppressed by user-declared mode) is a different fact from insufficient " +
                      "history and must get its own copy, not the 'log more cycles' string")
        XCTAssertEqual(CycleFertileWindowPresentation.caveat(
            fertileWindowEstimate(evidenceBasis: .insufficientHistory))?.en,
                      CycleHistoryStrings.fertileWindowInsufficientHistory.en)
    }

    func testFertileWindowCaveatNeverRendersARawSuppressionReasonPlaceholder() {
        let suppressed = fertileWindowEstimate(
            evidenceBasis: .suppressedDueToContext, status: .suppressed,
            suppressionReason: CycleFertileWindowEngine.suppressionReasonSuppressiveContraceptiveContext)
        let caveat = CycleFertileWindowPresentation.caveat(suppressed)
        XCTAssertNotNil(caveat)
        XCTAssertFalse(caveat?.en.contains("suppressive_contraceptive_context_active") ?? true)
        XCTAssertFalse(caveat?.ar.contains("suppressive_contraceptive_context_active") ?? true)
    }

    // MARK: - CycleFertileWindowAnatomy ("why this estimate?" resolution)

    func testFertileWindowResolvedInputsPreservesInputCycleIdsOrderAndSkipsAMissingId() {
        let recordA = record(id: "A", start: now)
        let recordB = record(id: "B", start: now.addingTimeInterval(86_400))
        let estimate = fertileWindowEstimate(windowStart: now, windowEnd: now, inputCycleIds: ["B", "MISSING", "A"])
        let resolved = CycleFertileWindowAnatomy.resolvedInputs(estimate, records: [recordA, recordB])
        XCTAssertEqual(resolved.map(\.id), ["B", "A"],
                      "must preserve inputCycleIds' own order and silently skip an id with no matching record")
    }

    func testFertileWindowResolvedInputsIsEmptyWhenTheManifestIsEmpty() {
        let recordA = record(id: "A", start: now)
        let estimate = fertileWindowEstimate(inputCycleIds: [])
        XCTAssertTrue(CycleFertileWindowAnatomy.resolvedInputs(estimate, records: [recordA]).isEmpty)
    }

    // MARK: - CycleAnomalyPresentation (full audit trail, messageKey-only copy)

    func testRowsAreOrderedMostRecentlyDetectedFirst() {
        let older = anomalyEvent(id: "OLD", detectedAt: now)
        let newer = anomalyEvent(id: "NEW", detectedAt: now.addingTimeInterval(3_600))
        XCTAssertEqual(CycleAnomalyPresentation.rows([older, newer]).map(\.id), ["NEW", "OLD"])
    }

    func testRowsIncludeEveryStateNotJustActiveOnesTheFullAuditTrail() {
        let events = [
            anomalyEvent(id: "A", state: .active),
            anomalyEvent(id: "B", state: .acknowledged),
            anomalyEvent(id: "C", state: .dismissed),
            anomalyEvent(id: "D", state: .suppressed),
        ]
        XCTAssertEqual(Set(CycleAnomalyPresentation.rows(events).map(\.id)), Set(["A", "B", "C", "D"]))
    }

    func testRowsResolveTextOnlyThroughCycleAnomalyMessagesNeverFabricatingASentence() {
        let event = anomalyEvent(messageKey: CycleAnomalyMessageKey.missedExpectedPeriod.rawValue)
        let row = CycleAnomalyPresentation.rows([event])[0]
        XCTAssertEqual(row.text?.en, CycleAnomalyMessages.text(for: CycleAnomalyMessageKey.missedExpectedPeriod.rawValue)?.en)
    }

    func testRowsGiveANilTextForAnUnrecognizedMessageKeyRatherThanFabricatingOne() {
        let event = anomalyEvent(messageKey: "some.future.engine.key.v9")
        let row = CycleAnomalyPresentation.rows([event])[0]
        XCTAssertNil(row.text, "an unrecognized key must resolve to nil, never a guessed or fabricated sentence")
    }

    // MARK: - CycleHistorySummary (ordering + flow-log summary)

    func testSortedMostRecentFirst() {
        let a = record(id: "A", start: now)
        let b = record(id: "B", start: now.addingTimeInterval(86_400))
        let c = record(id: "C", start: now.addingTimeInterval(-86_400))
        XCTAssertEqual(CycleHistorySummary.sortedMostRecentFirst([a, b, c]).map(\.id), ["B", "A", "C"])
    }

    func testFlowSummaryIsNilWhenThereAreNoLogs() {
        XCTAssertNil(CycleHistorySummary.flowSummary([]))
    }

    func testFlowSummaryCountsAndNamesTheMostRecentlyLoggedLabelVerbatim() {
        let logs = [
            flowLog(id: "F1", cycleId: "CYC-1", occurredAt: now, label: "light"),
            flowLog(id: "F2", cycleId: "CYC-1", occurredAt: now.addingTimeInterval(3_600), label: "Custom free text"),
        ]
        let summary = CycleHistorySummary.flowSummary(logs)
        XCTAssertEqual(summary?.count, 2)
        XCTAssertEqual(summary?.mostRecentLabel, "Custom free text",
                      "must be the last (most recently logged) entry's own original label, verbatim, never rewritten")
    }

    // MARK: - CyclePhase.displayName (mirrors LabSensitivityTier.displayName)

    func testEveryCyclePhaseHasANonEmptyBilingualDisplayName() {
        for phase in CyclePhase.allCases {
            let name = phase.displayName
            XCTAssertFalse(name.en.isEmpty, "\(phase) is missing an English display name")
            XCTAssertFalse(name.ar.isEmpty, "\(phase) is missing an Arabic display name")
        }
    }
}
