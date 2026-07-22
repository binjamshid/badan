import Foundation
import XCTest
@testable import BADAN

/// EPIC-39 (Phase 3F slice 2) — coverage for the cycle-home-screen + period/flow-logging UI lane's
/// own pure view-logic (`CycleHomeScreen.swift` + `PeriodLogScreen.swift`): reachability (mirrors
/// `LabNotebookUITests`/`CycleHistoryUITests`'s own checks, applied to this lane's owned sub-screen),
/// the anti-panic palette, the neutral "cycle" (never "period") language default checked against the
/// REAL COMPILED `LocalizedString` values this lane renders (never a source-text regex, matching
/// `CycleExportScreenTests`'s own superior approach for exactly the reason that file documents: a
/// regex only ever sees a value's first multi-line-`+`-concatenated fragment), the I7 "route
/// everything through `CycleModuleServices`, never a repository built directly against
/// `env.database`" rule, and this lane's own pure logic (`CycleStatusResolver`,
/// `CycleFlowNormalization`, `CycleHomeAnomalyPresentation`, `PeriodLogScreen.Mode`) — exercised over
/// the REAL `Domain/Cycle` types this slice is built on, exactly as `CyclePredictionEngineTests`/
/// `CycleHistoryUITests` already do for their own slices.
final class CycleHomeUITests: XCTestCase {
    private let device = "test-device"
    /// 2025-01-01T00:00:00Z — a UTC midnight anchor so day-arithmetic assertions can compare exact
    /// values without any DST ambiguity, matching `CyclePredictionEngineTests`'s own fixture anchor.
    private let base = Date(timeIntervalSince1970: 1_735_689_600)

    private func day(_ n: Int) -> Date { base.addingTimeInterval(Double(n) * 86_400) }

    // MARK: - Fixtures over the REAL domain types (Domain/Cycle/CycleModels.swift)

    private func provenance(measuredAt: Date) -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: "UTC", recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func record(id: String, start: Date, end: Date? = nil, ongoing: Bool = false,
                        originalId: String? = nil, supersedes: String? = nil, revision: Int = 1) -> CycleRecord {
        CycleRecord(id: id, startAt: start, endAt: end, ongoing: ongoing, originalId: originalId ?? id,
                   supersedes: supersedes, revision: revision, provenance: provenance(measuredAt: start),
                   updatedAt: start, originDeviceId: device)
    }

    private func prediction(
        low: Date? = nil, center: Date? = nil, high: Date? = nil, confidence: Double = 0.5,
        method: CyclePredictionMethod = .moderateHistory, status: CyclePredictionStatus = .active,
        inputCycleIds: [String] = []
    ) -> CyclePrediction {
        CyclePrediction(id: "PRED-1", generatedAt: base, predictedNextStartLow: low,
                        predictedNextStartCenter: center, predictedNextStartHigh: high,
                        confidence: confidence, method: method, status: status,
                        algorithmVersion: "test@1.0.0", inputCycleIds: inputCycleIds,
                        updatedAt: base, originDeviceId: device)
    }

    private func anomalyEvent(
        id: String = "ANOM-1", type: CycleAnomalyType = .cycleLengthDeviation,
        state: CycleAnomalyState = .active, messageKey: String? = nil
    ) -> CycleAnomalyEvent {
        CycleAnomalyEvent(id: id, type: type, detectedAt: base, severity: .medium,
                          messageKey: messageKey ?? CycleAnomalyMessageKey.cycleLengthDeviation.rawValue,
                          state: state, algorithmVersion: "test@1.0.0", confidence: 0.7,
                          updatedAt: base, originDeviceId: device)
    }

    // MARK: - Reachability (mirrors LabNotebookUITests'/CycleHistoryUITests' own checks)

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CycleHomeUITests.swift
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
    }()

    private static func sourceText(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func strippingPreviewBlocks(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while let previewRange = text.range(of: "#Preview", range: index..<text.endIndex) {
            result += text[index..<previewRange.lowerBound]
            guard let openBrace = text[previewRange.upperBound...].firstIndex(of: "{") else {
                index = text.endIndex
                break
            }
            var depth = 1
            var cursor = text.index(after: openBrace)
            while cursor < text.endIndex, depth > 0 {
                if text[cursor] == "{" { depth += 1 }
                if text[cursor] == "}" { depth -= 1 }
                cursor = text.index(after: cursor)
            }
            index = cursor
        }
        result += text[index...]
        return result
    }

    private static let homeScreenPath = "apps/ios/Sources/Features/Cycle/CycleHomeScreen.swift"
    private static let periodLogScreenPath = "apps/ios/Sources/Features/Cycle/PeriodLogScreen.swift"
    private static let laneSourceFiles = [homeScreenPath, periodLogScreenPath]

    /// This lane's own reachability check for the one sub-screen it owns and constructs (mirrors
    /// `CycleHistoryUITests.testAnatomySheetIsActuallyConstructedWithinThisScreenNotJustDeclared`'s
    /// exact reasoning): `CycleHomeScreen`'s own reachability from `LogHubScreen` is a DIFFERENT
    /// lane's routing (already wired there, per that lane's own diff) and is not asserted here.
    func testPeriodLogScreenIsActuallyConstructedWithinCycleHomeScreenNotJustDeclared() {
        let text = Self.strippingPreviewBlocks(Self.sourceText(Self.homeScreenPath))
        XCTAssertFalse(text.isEmpty, "expected non-empty source at \(Self.homeScreenPath)")
        XCTAssertTrue(text.contains("PeriodLogScreen("),
                     "PeriodLogScreen must have a real construction site in CycleHomeScreen.swift — " +
                     "this is exactly the 'built but dark' defect scripts/check-reachability.py guards against")
    }

    // MARK: - Anti-panic palette (no raw red; the muted amber token is actually used)

    func testNeitherScreenUsesARawRedColorOrTheReservedCriticalToken() {
        for path in Self.laneSourceFiles {
            let text = Self.sourceText(path)
            XCTAssertFalse(text.isEmpty, "expected non-empty source at \(path)")
            XCTAssertFalse(text.contains("Color.red"), "\(path) must never use a raw red color for a flagged state")
            XCTAssertFalse(text.contains("UIColor.red"), "\(path) must never use a raw red color for a flagged state")
            XCTAssertFalse(text.contains("BadanColor.critical"),
                           "\(path) must never reach for the reserved-and-unused critical token — " +
                           "out-of-band is always the single muted amber, regardless of severity")
        }
    }

    func testTheOutOfBandTokenIsActuallyUsedForAnomalyCards() {
        let text = Self.sourceText(Self.homeScreenPath)
        XCTAssertTrue(text.contains("BadanColor.outOfBand"),
                     "the muted amber anti-panic token must be wired in for a flagged anomaly card")
    }

    // MARK: - I7: every read/write routes through CycleModuleServices, never env.database directly

    func testNeitherScreenConstructsARepositoryDirectlyAgainstEnvDatabase() {
        for path in Self.laneSourceFiles {
            let text = Self.sourceText(path)
            XCTAssertFalse(text.contains("env.database"),
                          "\(path) must route every cycle read/write through CycleModuleServices — " +
                          "never construct a repository directly against env.database.main or .sensitive")
        }
    }

    // MARK: - CycleFlowIntensity.displayName (never a raw rawValue rendered — mirrors
    // `LabSensitivityTier`'s/`ContraceptiveMethodType`'s own fix, and `CycleExportScreenTests`'s own
    // equivalent test for that sibling enum)

    func testEveryCycleFlowIntensityHasANonEmptyBilingualDisplayNameDistinctFromItsRawValue() {
        for intensity in CycleFlowIntensity.allCases {
            let name = intensity.displayName
            XCTAssertFalse(name.en.isEmpty, "\(intensity.rawValue) is missing an English display name")
            XCTAssertFalse(name.ar.isEmpty, "\(intensity.rawValue) is missing an Arabic display name")
            XCTAssertNotEqual(name.en, intensity.rawValue, "\(intensity.rawValue) must never render its own raw rawValue")
        }
    }

    // MARK: - Wellness-safe language / neutral-tone checks over the REAL COMPILED copy this lane
    // renders (mirrors `CycleExportScreenTests`'s own approach exactly, for the same reason: a
    // source-text regex would only ever see a `LocalizedString`'s first multi-line-`+`-concatenated
    // fragment and could silently miss a real violation hiding in a later one).

    private static let cycleHomeCopy: [LocalizedString] = [
        CycleHomeStrings.coldStartTitle, CycleHomeStrings.coldStartMessage, CycleHomeStrings.startCycleAction,
        CycleHomeStrings.endCycleAction, CycleHomeStrings.logFlowAction, CycleHomeStrings.dayLabel,
        CycleHomeStrings.ongoingSubtitle, CycleHomeStrings.predictionSectionTitle,
        CycleHomeStrings.anomaliesSectionTitle, CycleHomeStrings.likelyBetween, CycleHomeStrings.expectedAround,
        CycleHomeStrings.dismissAction, CycleHomeStrings.dismissFailed, CycleHomeStrings.settingsAction,
    ]

    private static let periodLogCopy: [LocalizedString] = [
        PeriodLogStrings.startTitle, PeriodLogStrings.endTitle, PeriodLogStrings.logFlowTitle,
        PeriodLogStrings.startDateLabel, PeriodLogStrings.endDateLabel, PeriodLogStrings.flowDateLabel,
        PeriodLogStrings.flowIntensityLabel, PeriodLogStrings.saveFailed, PeriodLogStrings.savedAnnouncement,
    ] + CycleFlowIntensity.allCases.map(\.displayName)

    private static let bannedDiagnosticWords = [
        "abnormal", "irregular", "disorder", "diagnosis", "diagnostic", "pregnant", "pregnancy",
        "infertile", "healthy", "unhealthy", "danger", "normal", "optimal",
    ]

    func testNoRenderedCopyInEitherScreenUsesABannedDiagnosticOrVerdictWord() {
        for value in Self.cycleHomeCopy + Self.periodLogCopy {
            let lowered = value.en.lowercased()
            for banned in Self.bannedDiagnosticWords {
                XCTAssertFalse(lowered.contains(banned),
                              "\"\(value.en)\" renders the banned diagnostic/verdict word \"\(banned)\"")
            }
        }
    }

    /// Neutral-by-default language (threat model §5): this lane's own rendered copy says "cycle",
    /// never "period" — the one rule this lane's OWN file names (`PeriodLogScreen.swift`,
    /// `PeriodLogStrings`, `Mode.end`/`.logFlow`) are exempt from, since those are internal Swift
    /// identifiers, never user-facing copy.
    func testNeitherScreensRenderedCopyUsesTheWordPeriodInsteadOfTheNeutralCycleDefault() {
        for value in Self.cycleHomeCopy + Self.periodLogCopy {
            XCTAssertFalse(value.en.lowercased().contains("period"),
                          "\"\(value.en)\" uses \"period\" instead of the neutral \"cycle\" default")
        }
    }

    // MARK: - CycleStatusResolver (pure — day-count math + defensive most-recent selection)

    func testStatusResolverReturnsNoRecordsYetForAnEmptyHistory() {
        XCTAssertEqual(CycleStatusResolver.resolve(liveRecords: [], asOf: day(0), tz: "UTC"), .noRecordsYet)
    }

    func testStatusResolverReturnsDayOneOnTheStartDateItself() {
        let status = CycleStatusResolver.resolve(
            liveRecords: [record(id: "R0", start: day(0), ongoing: true)], asOf: day(0), tz: "UTC")
        XCTAssertEqual(status, .tracking(dayNumber: 1, ongoing: true))
    }

    func testStatusResolverCountsDaysForwardFromTheStartDate() {
        let status = CycleStatusResolver.resolve(
            liveRecords: [record(id: "R0", start: day(0), ongoing: true)], asOf: day(13), tz: "UTC")
        XCTAssertEqual(status, .tracking(dayNumber: 14, ongoing: true))
    }

    func testStatusResolverReportsOngoingFalseForACycleThatHasEnded() {
        let status = CycleStatusResolver.resolve(
            liveRecords: [record(id: "R0", start: day(0), end: day(5), ongoing: false)], asOf: day(10), tz: "UTC")
        XCTAssertEqual(status, .tracking(dayNumber: 11, ongoing: false),
                      "the day count continues past the bleed's own end — a cycle day, not just a bleed day")
    }

    func testStatusResolverPicksTheMostRecentlyStartedRecordRegardlessOfArrayOrder() {
        // Deliberately out of chronological order — the resolver must not trust caller order.
        let later = record(id: "R1", start: day(30), ongoing: true)
        let earlier = record(id: "R0", start: day(0), end: day(5), ongoing: false)
        let status = CycleStatusResolver.resolve(liveRecords: [later, earlier], asOf: day(30), tz: "UTC")
        XCTAssertEqual(status, .tracking(dayNumber: 1, ongoing: true), "must resolve against R1 (the later start), not R0")
    }

    func testStatusResolverNeverReturnsADayNumberBelowOneEvenUnderClockSkew() {
        // asOf before startAt (a clock-skew edge case) must never render "Day 0" or negative.
        let status = CycleStatusResolver.resolve(
            liveRecords: [record(id: "R0", start: day(10), ongoing: true)], asOf: day(0), tz: "UTC")
        XCTAssertEqual(status, .tracking(dayNumber: 1, ongoing: true))
    }

    // MARK: - CycleFlowNormalization (pure — the write-time 0...1 mapping)

    func testFlowNormalizationValuesAreAllWithinTheZeroToOneScale() {
        for intensity in CycleFlowIntensity.allCases {
            let value = CycleFlowNormalization.normalizedIntensity(for: intensity)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    func testFlowNormalizationIsMonotonicallyIncreasingAcrossTheCasualDictionaryOrdering() {
        let spotting = CycleFlowNormalization.normalizedIntensity(for: .spotting)
        let light = CycleFlowNormalization.normalizedIntensity(for: .light)
        let medium = CycleFlowNormalization.normalizedIntensity(for: .medium)
        let heavy = CycleFlowNormalization.normalizedIntensity(for: .heavy)
        XCTAssertLessThan(spotting, light)
        XCTAssertLessThan(light, medium)
        XCTAssertLessThan(medium, heavy)
    }

    // MARK: - CycleHomeAnomalyPresentation (pure — filter + resolve, never a fabricated fallback)

    func testAnomalyPresentationExcludesDismissedEventsButKeepsEveryOtherState() {
        let events = [
            anomalyEvent(id: "A1", state: .active),
            anomalyEvent(id: "A2", state: .acknowledged),
            anomalyEvent(id: "A3", state: .dismissed),
            anomalyEvent(id: "A4", state: .suppressed),
        ]
        let renderable = CycleHomeAnomalyPresentation.renderable(events)
        XCTAssertEqual(Set(renderable.map(\.event.id)), Set(["A1", "A2", "A4"]),
                      "only .dismissed is excluded — every other state still renders a card, per this lane's exact brief")
    }

    func testAnomalyPresentationSkipsAnEventWithAnUnrecognizedMessageKeyRatherThanFabricatingText() {
        let events = [anomalyEvent(id: "A1", messageKey: "cycle.anomaly.some_future_key.v2")]
        XCTAssertTrue(CycleHomeAnomalyPresentation.renderable(events).isEmpty,
                     "an unresolvable messageKey must be silently skipped, never rendered with invented copy")
    }

    func testAnomalyPresentationResolvesTheExactApprovedTemplateNeverInventedText() {
        let events = [anomalyEvent(id: "A1", type: .missedExpectedPeriod,
                                   messageKey: CycleAnomalyMessageKey.missedExpectedPeriod.rawValue)]
        let renderable = CycleHomeAnomalyPresentation.renderable(events)
        XCTAssertEqual(renderable.first?.message.en,
                      CycleAnomalyMessages.text(for: CycleAnomalyMessageKey.missedExpectedPeriod.rawValue)?.en)
    }

    // MARK: - PeriodLogScreen.Mode (pure — sheet identity)

    func testPeriodLogModeIdsAreDistinctAcrossModesAndCarryTheUnderlyingRecordIdentity() {
        let r1 = record(id: "R1", start: day(0), ongoing: true)
        let r2 = record(id: "R2", start: day(28), ongoing: true)
        let ids: Set<String> = [
            PeriodLogScreen.Mode.start.id,
            PeriodLogScreen.Mode.end(r1).id,
            PeriodLogScreen.Mode.end(r2).id,
            PeriodLogScreen.Mode.logFlow(cycle: r1).id,
            PeriodLogScreen.Mode.logFlow(cycle: r2).id,
        ]
        XCTAssertEqual(ids.count, 5, "every mode/record combination must produce a distinct sheet identity")
    }

    // MARK: - Integration-assumption checks against `CyclePredictionPresentation`
    // (`CycleHistoryScreen.swift`, another lane's already-landed utility this screen's own
    // `predictionBody` reuses rather than re-deriving) — these guard THIS lane's own assumptions
    // about that shared surface, not a re-test of that lane's own suite.

    func testHasRangeIsFalseForAPausedPredictionEvenWithFullDatesPresent() {
        let paused = prediction(low: day(25), center: day(28), high: day(31), method: .moderateHistory, status: .paused)
        XCTAssertFalse(CyclePredictionPresentation.hasRange(paused),
                       "CycleHomeScreen's own range line must never render while status == .paused")
    }

    func testHasRangeIsFalseForAColdStartPredictionWithNoDates() {
        let coldStart = prediction(method: .coldStart)
        XCTAssertFalse(CyclePredictionPresentation.hasRange(coldStart))
    }

    func testHasRangeIsTrueForAnActiveLowHistoryPredictionWithAllThreeDates() {
        let low = prediction(low: day(20), center: day(24), high: day(28), confidence: 0.3, method: .lowHistory)
        XCTAssertTrue(CyclePredictionPresentation.hasRange(low))
    }
}
