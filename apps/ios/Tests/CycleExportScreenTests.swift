import Foundation
import XCTest
@testable import BADAN

/// Phase 3F slice 2 (CYCLE-07 contraceptive-context logging + CYCLE-08 scoped export) — coverage for
/// this lane's own view-logic: the export section builders' raw/derived separation (I5), the
/// bilingual `ContraceptiveMethodType.displayName` fix, the anomaly-message resolution's "key,
/// never invented text" guarantee, and this lane's own wellness-safe-language / neutral-tone /
/// anti-panic-palette rules — checked against the REAL COMPILED `LocalizedString` constants each
/// screen renders (never a source-text regex over multi-line concatenated string literals, which
/// would only ever see a value's first fragment and could silently miss a real violation in a later
/// one), plus a couple of structural source-text checks for code-pattern rules (no raw red color, no
/// bypass toggle on the passphrase gate) that a compiled-value test cannot express.
final class CycleExportScreenTests: XCTestCase {
    private let device = "test-device"
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Fixtures over the REAL domain types (Domain/Cycle/CycleModels.swift, already committed)

    private func provenance(measuredAt: Date? = nil) -> Provenance {
        let at = measuredAt ?? now
        return Provenance(sourceId: device, ingestionPath: .manual, measuredAt: at, measuredTimezone: "UTC",
                          recordedAt: at, ingestedAt: at)
    }

    private func cycleRecord(id: String = "cycle-1", endAt: Date? = nil, ongoing: Bool = false,
                             revision: Int = 1, supersedes: String? = nil) -> CycleRecord {
        CycleRecord(id: id, startAt: now, endAt: endAt, ongoing: ongoing, originalId: id,
                   supersedes: supersedes, revision: revision, provenance: provenance(),
                   updatedAt: now, originDeviceId: device)
    }

    private func flowLog(id: String = "flow-1", cycleId: String = "cycle-1", intensity: Double = 0.5) -> FlowLog {
        FlowLog(id: id, cycleId: cycleId, occurredAt: now, originalLabel: "medium", normalizedIntensity: intensity,
               provenance: provenance(), updatedAt: now, originDeviceId: device)
    }

    private func contraceptiveContext(id: String = "cc-1", methodType: ContraceptiveMethodType = .pill,
                                      endAt: Date? = nil) -> ContraceptiveContextLog {
        ContraceptiveContextLog(id: id, methodType: methodType, startAt: now, endAt: endAt,
                                provenance: provenance(), updatedAt: now, originDeviceId: device)
    }

    private func prediction(status: CyclePredictionStatus = .active) -> CyclePrediction {
        CyclePrediction(id: "pred-1", generatedAt: now, predictedNextStartLow: now.addingTimeInterval(86400 * 25),
                        predictedNextStartCenter: now.addingTimeInterval(86400 * 28),
                        predictedNextStartHigh: now.addingTimeInterval(86400 * 31), confidence: 0.6,
                        method: .moderateHistory, status: status, algorithmVersion: "v1",
                        inputCycleIds: ["cycle-1", "cycle-2"], updatedAt: now, originDeviceId: device)
    }

    private func phaseEstimate() -> CyclePhaseEstimate {
        CyclePhaseEstimate(id: "phase-1", dateRangeStart: now, dateRangeEnd: now.addingTimeInterval(86400 * 5),
                          phase: .luteal, confidence: 0.7, evidenceBasis: .calendarOnly, algorithmVersion: "v1",
                          computedAt: now, updatedAt: now, originDeviceId: device)
    }

    private func anomaly(type: CycleAnomalyType = .cycleLengthDeviation,
                        messageKey: String = CycleAnomalyMessageKey.cycleLengthDeviation.rawValue) -> CycleAnomalyEvent {
        CycleAnomalyEvent(id: "anom-1", type: type, detectedAt: now, severity: .medium, messageKey: messageKey,
                         algorithmVersion: "v1", confidence: 0.75, updatedAt: now, originDeviceId: device)
    }

    private func emptyBundle() -> CycleExportBundle {
        CycleExportBundle(cycles: [], flowLogs: [], contraceptiveContext: [], prediction: nil,
                         phaseEstimate: nil, anomalies: [])
    }

    // MARK: - ContraceptiveMethodType.displayName (mirrors LabSensitivityTier's own fix — never a
    // raw `rawValue` rendered to the user)

    func testEveryContraceptiveMethodTypeHasANonEmptyBilingualDisplayNameDistinctFromItsRawValue() {
        for method in ContraceptiveMethodType.allCases {
            let name = method.displayName
            XCTAssertFalse(name.en.isEmpty, "\(method.rawValue) is missing an English display name")
            XCTAssertFalse(name.ar.isEmpty, "\(method.rawValue) is missing an Arabic display name")
            XCTAssertNotEqual(name.en, method.rawValue, "\(method.rawValue) must never render its own raw rawValue")
        }
    }

    // MARK: - Export bundle emptiness must look at all six sources, not just the raw three

    func testBundleIsEmptyOnlyWhenEveryOneOfTheSixSourcesIsEmpty() {
        XCTAssertTrue(emptyBundle().isEmpty)

        var predictionOnly = emptyBundle()
        predictionOnly.prediction = prediction()
        XCTAssertFalse(predictionOnly.isEmpty,
                      "a coldStart prediction can exist with zero logged cycles (refreshAll always appends one) — " +
                      "isEmpty must not look only at the raw arrays")
    }

    // MARK: - Raw vs derived never blended (I5) — structural, not just by convention

    func testRawSectionRowsNeverCarryADerivedOnlyField() {
        var bundle = emptyBundle()
        bundle.cycles = [cycleRecord()]
        bundle.flowLogs = [flowLog()]
        bundle.contraceptiveContext = [contraceptiveContext()]
        let rawKeys = Set(CycleExportSections.cycleRecordRows(bundle).flatMap(\.keys))
            .union(CycleExportSections.flowLogRows(bundle).flatMap(\.keys))
            .union(CycleExportSections.contraceptiveContextRows(bundle).flatMap(\.keys))
        XCTAssertFalse(rawKeys.contains("confidence"), "a raw row must never carry a derived-only field like confidence")
        XCTAssertFalse(rawKeys.contains("algorithm_version"), "a raw row must never carry a derived-only field like algorithm_version")
    }

    func testDerivedSectionRowsNeverCarryARawOnlyField() {
        var bundle = emptyBundle()
        bundle.prediction = prediction()
        bundle.phaseEstimate = phaseEstimate()
        bundle.anomalies = [anomaly()]
        let derivedKeys = Set(CycleExportSections.predictionRows(bundle).flatMap(\.keys))
            .union(CycleExportSections.phaseEstimateRows(bundle).flatMap(\.keys))
            .union(CycleExportSections.anomalyRows(bundle).flatMap(\.keys))
        XCTAssertFalse(derivedKeys.contains("ongoing"), "a derived row must never carry a raw-only field like ongoing")
        XCTAssertFalse(derivedKeys.contains("original_label"), "a derived row must never carry a raw-only field like original_label")
    }

    func testJSONBundleKeepsRawAndDerivedUnderSeparateTopLevelKeysNeverMerged() {
        var bundle = emptyBundle()
        bundle.cycles = [cycleRecord()]
        bundle.prediction = prediction()
        let rendered = CycleJSONExport.render(bundle)
        XCTAssertTrue(rendered.contains("\"raw\":"))
        XCTAssertTrue(rendered.contains("\"derived\":"))
        XCTAssertTrue(rendered.contains("\"cycle_records\":[{"), "the raw cycle row must land under raw.cycle_records")
        XCTAssertTrue(rendered.contains("\"predictions\":[{"), "the derived prediction row must land under derived.predictions")
    }

    func testCSVFilesAreNamedWithAnExplicitRawOrDerivedPrefixSoTheSeparationSurvivesEvenAsFilenames() {
        for name in CycleCSVExport.files(emptyBundle()).keys {
            XCTAssertTrue(name.hasPrefix("cycle_raw_") || name.hasPrefix("cycle_derived_"),
                         "\(name) must declare itself raw or derived by name, never ambiguous")
        }
    }

    func testCSVFileAlwaysHasAHeaderRowEvenWithZeroDataRows() {
        let table = CycleCSVExport.table(columns: CycleExportColumns.cycleRecords,
                                         rows: CycleExportSections.cycleRecordRows(emptyBundle()))
        XCTAssertTrue(table.hasPrefix("record_id,"), "an empty export must still be a valid, self-describing table")
    }

    // MARK: - Row content honesty

    func testCycleRecordRowRendersOngoingAndRevisionHonestly() {
        var bundle = emptyBundle()
        bundle.cycles = [cycleRecord(revision: 2, supersedes: "cycle-0")]
        let rows = CycleExportSections.cycleRecordRows(bundle)
        XCTAssertEqual(rows.first?["revision"], "2")
        XCTAssertEqual(rows.first?["is_original"], "false", "a record with a non-nil supersedes is not an original")
    }

    func testContraceptiveContextRowRendersMethodTypeAsItsRawStableValueNotADisplayString() {
        var bundle = emptyBundle()
        bundle.contraceptiveContext = [contraceptiveContext(methodType: .hormoneTherapy)]
        let rows = CycleExportSections.contraceptiveContextRows(bundle)
        XCTAssertEqual(rows.first?["method_type"], "hormoneTherapy",
                      "the export's own machine-readable field stays the raw enum value, independent of the in-app display name")
        XCTAssertEqual(rows.first?["is_active"], "true")
    }

    func testPredictionAndPhaseEstimateRowsAreNeverMoreThanOneRowEach() {
        var bundle = emptyBundle()
        bundle.prediction = prediction()
        bundle.phaseEstimate = phaseEstimate()
        XCTAssertLessThanOrEqual(CycleExportSections.predictionRows(bundle).count, 1,
                                "CyclePredictionRepository exposes only the latest prediction — this section can never have more than one row")
        XCTAssertLessThanOrEqual(CycleExportSections.phaseEstimateRows(bundle).count, 1,
                                "CyclePhaseEstimateRepository exposes only the latest estimate — this section can never have more than one row")
    }

    // MARK: - Anomaly message resolution: key + pre-approved resolved copy, never a fabricated fallback

    func testAnomalyRowCarriesBothTheKeyAndItsPreApprovedBilingualResolution() {
        var bundle = emptyBundle()
        bundle.anomalies = [anomaly(type: .missedExpectedPeriod, messageKey: CycleAnomalyMessageKey.missedExpectedPeriod.rawValue)]
        let rows = CycleExportSections.anomalyRows(bundle)
        let expected = CycleAnomalyMessages.text(for: CycleAnomalyMessageKey.missedExpectedPeriod.rawValue)
        XCTAssertEqual(rows.first?["message_key"], CycleAnomalyMessageKey.missedExpectedPeriod.rawValue)
        XCTAssertEqual(rows.first?["message_en"], expected?.en)
        XCTAssertEqual(rows.first?["message_ar"], expected?.ar)
    }

    func testAnomalyRowDegradesGracefullyForAnUnrecognizedMessageKeyRatherThanFabricatingOne() {
        var bundle = emptyBundle()
        bundle.anomalies = [anomaly(messageKey: "cycle.anomaly.some_future_key.v2")]
        let rows = CycleExportSections.anomalyRows(bundle)
        XCTAssertEqual(rows.first?["message_key"], "cycle.anomaly.some_future_key.v2")
        XCTAssertEqual(rows.first?["message_en"], "", "an unrecognized key must never be papered over with an invented sentence")
        XCTAssertEqual(rows.first?["message_ar"], "")
    }

    // MARK: - Wellness-safe language / neutral-tone checks over the REAL COMPILED copy this lane
    // renders — never a source-text regex, which would only ever see a `LocalizedString`'s first
    // fragment when it is built via multi-line `+` concatenation and could silently miss a real
    // violation hiding in a later fragment.

    private static let contraceptiveContextCopy: [LocalizedString] = [
        ContraceptiveContextStrings.title, ContraceptiveContextStrings.subtitle,
        ContraceptiveContextStrings.detailsSectionTitle, ContraceptiveContextStrings.currentlyLogged,
        ContraceptiveContextStrings.noCurrentMethod, ContraceptiveContextStrings.methodLabel,
        ContraceptiveContextStrings.startedLabel, ContraceptiveContextStrings.stillActiveToggle,
        ContraceptiveContextStrings.endedOnLabel, ContraceptiveContextStrings.noteLabel,
        ContraceptiveContextStrings.notePlaceholder, ContraceptiveContextStrings.saveAction,
        ContraceptiveContextStrings.historySectionTitle, ContraceptiveContextStrings.dateRange,
        ContraceptiveContextStrings.savedAnnouncement, ContraceptiveContextStrings.saveFailed,
        ContraceptiveContextStrings.loadFailed,
    ] + ContraceptiveMethodType.allCases.map(\.displayName)

    private static let cycleExportCopy: [LocalizedString] = [
        CycleExportStrings.title, CycleExportStrings.subtitle, CycleExportStrings.format,
        CycleExportStrings.exportAction, CycleExportStrings.empty, CycleExportStrings.loadFailed,
        CycleExportStrings.exportFailed,
    ]

    private static let bannedDiagnosticWords = [
        "abnormal", "irregular", "disorder", "diagnosis", "diagnostic", "pregnant", "pregnancy",
        "infertile", "healthy", "unhealthy", "danger",
    ]

    func testNoRenderedCopyInEitherScreenUsesABannedDiagnosticOrVerdictWord() {
        for value in Self.contraceptiveContextCopy + Self.cycleExportCopy {
            let lowered = value.en.lowercased()
            for banned in Self.bannedDiagnosticWords {
                XCTAssertFalse(lowered.contains(banned),
                              "\"\(value.en)\" renders the banned diagnostic/verdict word \"\(banned)\"")
            }
        }
    }

    /// Neutral-by-default language (threat model §5): this lane's own rendered copy says "cycle",
    /// never "period".
    func testNeitherScreensRenderedCopyUsesTheWordPeriodInsteadOfTheNeutralCycleDefault() {
        for value in Self.contraceptiveContextCopy + Self.cycleExportCopy {
            XCTAssertFalse(value.en.lowercased().contains("period"),
                          "\"\(value.en)\" uses \"period\" instead of the neutral \"cycle\" default")
        }
    }

    /// CYCLE-07's own instruction: neutral record-keeping only, no efficacy claim, no adherence
    /// nagging. Checked against the note field's OWN label/placeholder specifically — the subtitle is
    /// allowed to mention "adherence" once, in a DISCLAIMING sentence ("BADAN doesn't track
    /// adherence"), which is the opposite of nagging; this test guards the part that would actually
    /// be nagging if it slipped in: the note field presenting itself as an adherence/efficacy tracker.
    func testTheNoteFieldsOwnLabelNeverFramesItselfAsAdherenceOrEfficacyTracking() {
        for value in [ContraceptiveContextStrings.noteLabel, ContraceptiveContextStrings.notePlaceholder] {
            let lowered = value.en.lowercased()
            XCTAssertFalse(lowered.contains("adherence"), "\"\(value.en)\" frames the note field as adherence tracking")
            XCTAssertFalse(lowered.contains("efficacy"), "\"\(value.en)\" frames the note field as efficacy tracking")
            XCTAssertFalse(lowered.contains("effective"), "\"\(value.en)\" frames the note field as effectiveness tracking")
        }
    }

    /// The one place "adherence" is expected to appear at all — verifies it is used to DISCLAIM
    /// tracking, not to invite it, so a future edit can't quietly flip the sentence's meaning without
    /// this test catching it.
    func testSubtitlesOwnAdherenceMentionIsADisclaimerNotAnInvitation() {
        let subtitle = ContraceptiveContextStrings.subtitle.en.lowercased()
        XCTAssertTrue(subtitle.contains("doesn't track adherence") || subtitle.contains("does not track adherence"),
                     "the subtitle's only mention of adherence must be BADAN disclaiming that it tracks it")
    }

    // MARK: - Structural source-text checks (code-pattern rules a compiled-value test can't express)

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CycleExportScreenTests.swift
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
    }()

    private static func sourceText(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static let laneSourceFiles = [
        "apps/ios/Sources/Features/Cycle/ContraceptiveContextScreen.swift",
        "apps/ios/Sources/Features/Cycle/CycleExportScreen.swift",
    ]

    func testNeitherScreenSourceUsesARawRedColorOrTheReservedCriticalToken() {
        for path in Self.laneSourceFiles {
            let text = Self.sourceText(path)
            XCTAssertFalse(text.isEmpty, "expected non-empty source at \(path)")
            XCTAssertFalse(text.contains("Color.red"), "\(path) must never use a raw red color for a flagged state")
            XCTAssertFalse(text.contains("UIColor.red"), "\(path) must never use a raw red color for a flagged state")
            XCTAssertFalse(text.contains("BadanColor.critical"),
                           "\(path) must never reach for the reserved-and-unused critical token")
        }
    }

    func testCycleExportScreenAlwaysRoutesThroughTheSharedEncryptorWithNoIncludeSensitiveStyleToggle() {
        let text = Self.sourceText("apps/ios/Sources/Features/Cycle/CycleExportScreen.swift")
        XCTAssertTrue(text.contains("ExportEncryptor.encrypt("), "every export must go through the shared encryptor")
        XCTAssertTrue(text.contains("ExportPassphrasePolicy.isValid"),
                     "the passphrase gate must reuse the shared policy, not a bespoke check")
        XCTAssertTrue(text.contains(".disabled(!passphraseValid)"),
                     "the export action must be gated on a valid passphrase, unconditionally")
        XCTAssertFalse(text.contains("includeSensitive"),
                      "unlike a mixed-scope export surface, this screen must never offer a toggle to skip encryption")
    }
}
