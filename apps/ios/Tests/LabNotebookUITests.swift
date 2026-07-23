import Foundation
import XCTest
@testable import BADAN

/// EPIC-41 (Phase 3E) — coverage for the lab notebook UI lane's own view-logic and wiring:
/// reachability (mirrors `scripts/check-reachability.py`'s own check, exactly as established by
/// `WorkoutUITests`/`DeviceHubUITests`), the anti-panic-palette rule (no raw red-for-out-of-range
/// color usage, and no traffic-light verdict wording anywhere in shipped copy), and the
/// four-concept-reference-range law (a result's four concepts are NEVER conflated into one merged
/// verdict) as this UI lane renders it over the REAL `Domain/Labs/ReferenceRangeEngine` types.
final class LabNotebookUITests: XCTestCase {
    private let device = "test-device"
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Reachability (mirrors scripts/check-reachability.py's own check, as a real XCTest)

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LabNotebookUITests.swift
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

    /// AUDIT FIX (mirrors `CycleIntegrationUITests.swift`'s own fix): `strippingPreviewBlocks` alone
    /// is comment-blind — a doc comment mentioning a type name followed by `(` shadows a real
    /// construction site, so deleting the ACTUAL call while leaving the comment intact would leave
    /// `assertReachable` still passing. Strips `//` line comments (naive — everything from the first
    /// `//` on a line to its end) BEFORE the preview-block strip, so only genuine, compiled
    /// construction sites can satisfy this check.
    private static func strippingLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[line.startIndex..<range.lowerBound]
        }.joined(separator: "\n")
    }

    private func assertReachable(_ typeName: String, in relativePath: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = Self.strippingPreviewBlocks(Self.strippingLineComments(Self.sourceText(relativePath)))
        XCTAssertTrue(text.contains("\(typeName)("),
                      "\(typeName) has no REAL (non-comment) construction site in \(relativePath) outside a #Preview — " +
                      "this is exactly the 'built but dark' defect check-reachability.py guards against.",
                      file: file, line: line)
    }

    private static let homeScreenPath = "apps/ios/Sources/Features/Labs/LabNotebookHomeScreen.swift"
    private static let logHubPath = "apps/ios/Sources/Features/LogHub/LogHubScreen.swift"

    func testLabNotebookHomeScreenIsReachableFromLogHub() {
        assertReachable("LabNotebookHomeScreen", in: Self.logHubPath)
    }

    func testEveryOtherLabScreenIsReachableFromLabNotebookHomeScreensOwnRouter() {
        assertReachable("ReportViewerScreen", in: Self.homeScreenPath)
        assertReachable("MarkerDetailScreen", in: Self.homeScreenPath)
        assertReachable("OCRReviewScreen", in: Self.homeScreenPath)
        assertReachable("ManualEntryScreen", in: Self.homeScreenPath)
        assertReachable("LabExportScreen", in: Self.homeScreenPath)
    }

    // MARK: - Anti-panic palette (no raw red; the muted amber token is actually used)

    private static let labSourceFiles = [
        "apps/ios/Sources/Features/Labs/LabNotebookHomeScreen.swift",
        "apps/ios/Sources/Features/Labs/MarkerDetailScreen.swift",
        "apps/ios/Sources/Features/Labs/ReportViewerScreen.swift",
        "apps/ios/Sources/Features/Labs/ManualEntryScreen.swift",
        "apps/ios/Sources/Features/Labs/OCRReviewScreen.swift",
        "apps/ios/Sources/Features/Labs/LabExportScreen.swift",
    ]

    func testNoLabScreenUsesARawRedColorOrTheReservedCriticalToken() {
        for path in Self.labSourceFiles {
            let text = Self.sourceText(path)
            XCTAssertFalse(text.isEmpty, "expected non-empty source at \(path)")
            XCTAssertFalse(text.contains("Color.red"), "\(path) must never use a raw red color for an out-of-range state")
            XCTAssertFalse(text.contains("UIColor.red"), "\(path) must never use a raw red color for an out-of-range state")
            XCTAssertFalse(text.contains("BadanColor.critical"),
                           "\(path) must never reach for the reserved-and-unused `critical` token — " +
                           "out-of-band is always the single muted amber, regardless of magnitude")
        }
    }

    func testTheOutOfBandTokenIsActuallyUsedSomewhereInTheLabScreens() {
        let combined = Self.labSourceFiles.map(Self.sourceText).joined()
        XCTAssertTrue(combined.contains("BadanColor.outOfBand"),
                      "the muted amber anti-panic token must be the thing actually wired in for an out-of-range state")
    }

    /// Scans only the RENDERED English copy (`en: "..."` literal contents) for the banned
    /// traffic-light/verdict words — never the source text as a whole, so this cannot false-positive
    /// on an unrelated word like "normalized"/"normalization" (unit conversion) appearing in a
    /// doc comment or identifier.
    func testNoShippedEnglishCopyUsesATrafficLightVerdictWord() {
        let bannedPattern = try! NSRegularExpression(pattern: #"\b(normal|healthy|danger|optimal|abnormal|unhealthy)\b"#,
                                                      options: .caseInsensitive)
        let literalPattern = try! NSRegularExpression(pattern: #"en:\s*"((?:[^"\\]|\\.)*)""#)

        for path in Self.labSourceFiles {
            let text = Self.sourceText(path)
            let fullRange = NSRange(text.startIndex..., in: text)
            for match in literalPattern.matches(in: text, range: fullRange) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let literal = String(text[range])
                let literalRange = NSRange(literal.startIndex..., in: literal)
                XCTAssertEqual(bannedPattern.numberOfMatches(in: literal, range: literalRange), 0,
                              "\(path) renders a traffic-light/verdict word in \"\(literal)\" — BADAN never renders " +
                              "\"abnormal\"/\"unhealthy\"; the only honest phrasing for the source's own interval is " +
                              "\"outside/inside this laboratory's stated reference interval\"")
            }
        }
    }

    // MARK: - Fixtures over the REAL domain types (Domain/Labs/LabModels.swift)

    private func provenance(measuredAt: Date) -> Provenance {
        Provenance(sourceId: device, ingestionPath: .manual, measuredAt: measuredAt, measuredTimezone: "UTC",
                  recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func result(value: Double, analyteId: String = "glucose_fasting", measuredAt: Date? = nil) -> LabResult {
        let at = measuredAt ?? now
        return LabResult(
            id: "result-\(value)-\(at.timeIntervalSince1970)", reportId: "report-1", analyteId: analyteId,
            rawValueText: LabNumberFormat.string(value), numericValue: value, rawUnit: "mmol/L",
            resultType: .numeric, reviewState: .userEntered, originalId: "result-\(value)-\(at.timeIntervalSince1970)",
            provenance: provenance(measuredAt: at), updatedAt: at, originDeviceId: device)
    }

    private func range(low: Double? = 3.9, high: Double? = 5.5, flag: String? = nil, resultId: String = "r1") -> ReferenceRange {
        ReferenceRange(id: "range-1", resultId: resultId, sourceIntervalLow: low, sourceIntervalHigh: high,
                      sourceIntervalUnit: "mmol/L", sourceFlag: flag, updatedAt: now, originDeviceId: device)
    }

    // MARK: - The four-concept reference-range law (never conflated into one merged verdict)

    private var distinctBaseline: ReferenceRangeEngine.PersonalBaselineView {
        // Deliberately DIFFERENT numbers from the source interval (3.9-5.5) and the threshold
        // (7.0) — if a row's text ever leaked another concept's numbers, these fixtures would
        // catch it.
        ReferenceRangeEngine.PersonalBaselineView(center: 5.1, bandLow: 4.6, bandHigh: 5.6, unit: "mmol/L",
                                                  nPoints: 8, provisional: false, windowDays: 365)
    }

    private var distinctThreshold: ReferenceRangeEngine.UserLabThreshold {
        ReferenceRangeEngine.UserLabThreshold(analyteKey: "glucose_fasting", direction: .above, value: 7.0, unit: "mmol/L")
    }

    private func fullRenderable(flag: String? = "H") -> ReferenceRangeEngine.RenderableRange {
        ReferenceRangeEngine.RenderableRange(
            sourceInterval: .init(low: 3.9, high: 5.5, text: nil, unit: "mmol/L"),
            sourceFlag: flag, personalBaseline: distinctBaseline, userThreshold: distinctThreshold)
    }

    func testFourConceptRowsCoverAllFourConceptsExactlyOnce() {
        let rows = MarkerDetailConceptRows.rows(renderable: fullRenderable(), latestValue: (6.2, "mmol/L"), language: .en)
        XCTAssertEqual(Set(rows.map(\.concept)), Set(LabConcept.allCases),
                       "every one of the four concepts must get its own row, never fewer, never merged")
        XCTAssertEqual(rows.count, LabConcept.allCases.count, "no concept may be split into more than one row either")
    }

    func testSourceIntervalRowNeverMentionsThePersonalBaselineOrTheUserThreshold() {
        let rows = MarkerDetailConceptRows.rows(renderable: fullRenderable(), latestValue: (6.2, "mmol/L"), language: .en)
        guard let row = rows.first(where: { $0.concept == .sourceInterval }) else { return XCTFail("missing sourceInterval row") }
        let rendered = row.valueText + (row.captionText ?? "")
        XCTAssertFalse(rendered.contains("4.6"), "the source-interval row must never render the personal baseline's own numbers")
        XCTAssertFalse(rendered.contains("5.6"), "the source-interval row must never render the personal baseline's own numbers")
        XCTAssertFalse(rendered.contains("7"), "the source-interval row must never render the user threshold's own number")
    }

    func testPersonalBaselineRowNeverMentionsTheSourceIntervalOrTheUserThreshold() {
        let rows = MarkerDetailConceptRows.rows(renderable: fullRenderable(), latestValue: (6.2, "mmol/L"), language: .en)
        guard let row = rows.first(where: { $0.concept == .personalBaseline }) else { return XCTFail("missing personalBaseline row") }
        let rendered = row.valueText + (row.captionText ?? "")
        XCTAssertFalse(rendered.contains("3.9"), "the personal-baseline row must never render the lab's own interval numbers")
        XCTAssertFalse(rendered.contains("5.5"), "the personal-baseline row must never render the lab's own interval numbers")
    }

    func testSourceIntervalRowUsesTheEnginesOwnPinnedPhrasingNeverAVerdictWord() {
        // value 6.2 is above the 3.9-5.5 interval -> outside.
        let rows = MarkerDetailConceptRows.rows(renderable: fullRenderable(flag: nil), latestValue: (6.2, "mmol/L"), language: .en)
        guard let row = rows.first(where: { $0.concept == .sourceInterval }) else { return XCTFail("missing sourceInterval row") }
        XCTAssertEqual(row.captionText, ReferenceRangeEngine.sourceIntervalCaption.en)
    }

    func testSourceIntervalRowIsAbsentTextWhenTheSourcePrintedNoInterval() {
        let renderable = ReferenceRangeEngine.RenderableRange(sourceInterval: nil, sourceFlag: nil, personalBaseline: nil, userThreshold: nil)
        let rows = MarkerDetailConceptRows.rows(renderable: renderable, latestValue: nil, language: .en)
        guard let row = rows.first(where: { $0.concept == .sourceInterval }) else { return XCTFail("missing sourceInterval row") }
        XCTAssertEqual(row.valueText, "Not printed on this report",
                      "an absent source interval must say so honestly, never invent a generic range")
        XCTAssertNil(row.captionText)
    }

    func testUserThresholdIsIndependentOfSourceIntervalWhenTheyDisagree() {
        // value 6.2 is OUTSIDE the source interval (3.9-5.5) but NOT past the user's own threshold
        // (not > 7.0) — the two rows must disagree without either overwriting the other.
        let rows = MarkerDetailConceptRows.rows(renderable: fullRenderable(flag: nil), latestValue: (6.2, "mmol/L"), language: .en)
        let interval = rows.first { $0.concept == .sourceInterval }
        let threshold = rows.first { $0.concept == .userThreshold }
        XCTAssertEqual(interval?.captionText, ReferenceRangeEngine.sourceIntervalCaption.en)
        XCTAssertEqual(threshold?.captionText, "Within the threshold you set")
    }

    // MARK: - Out-of-interval count uses ONLY concept #1 (never the personal baseline or a threshold)

    func testOutOfIntervalCountIgnoresThePersonalBaselineAndTheUserThreshold() {
        // Inside the source interval — the count must read zero regardless of any baseline/threshold.
        let r = result(value: 5.0)
        let rng = range(low: 3.9, high: 5.5, flag: nil, resultId: r.id)
        XCTAssertEqual(LabHomeSummary.outOfSourceIntervalCount([(r, rng)]), 0)
    }

    func testOutOfIntervalCountCountsAPrintedFlagEvenWithoutANumericInterval() {
        let r = result(value: 5.0)
        let rng = ReferenceRange(id: "range-2", resultId: r.id, sourceFlag: "H", updatedAt: now, originDeviceId: device)
        XCTAssertEqual(LabHomeSummary.outOfSourceIntervalCount([(r, rng)]), 1,
                      "the lab's own printed flag counts on its own, independent of a numeric interval")
    }

    func testOutOfIntervalCountIsZeroWhenTheSourcePrintedNeitherAnIntervalNorAFlag() {
        let r = result(value: 5.0)
        XCTAssertEqual(LabHomeSummary.outOfSourceIntervalCount([(r, nil)]), 0,
                      "silence from the source is never treated as evidence of anything")
    }

    func testOutOfIntervalCountFlagsAValueAboveTheNumericInterval() {
        let r = result(value: 9.0)
        let rng = range(low: 3.9, high: 5.5, flag: nil, resultId: r.id)
        XCTAssertEqual(LabHomeSummary.outOfSourceIntervalCount([(r, rng)]), 1)
    }

    // MARK: - "Changes since last time"

    private func report(id: String, reportedAt: Date) -> LabReport {
        LabReport(id: id, collectionAt: now, reportedAt: reportedAt, tzId: "UTC", reviewState: .userEntered,
                 ingestionPath: .manual, updatedAt: now, originDeviceId: device)
    }

    func testChangesSinceLastVisitCountsOnlyReportsReceivedAfterTheMarker() {
        let r1 = report(id: "r1", reportedAt: now.addingTimeInterval(-100))
        let r2 = report(id: "r2", reportedAt: now.addingTimeInterval(100))
        XCTAssertEqual(LabHomeSummary.changesSinceLastVisit([r1, r2], lastViewedAt: now), 1)
        XCTAssertEqual(LabHomeSummary.changesSinceLastVisit([r1, r2], lastViewedAt: nil), 0,
                      "no prior visit recorded yet must never be treated as \"everything is new\"")
    }

    // MARK: - Personal baseline math (delegates to ReferenceRangeEngine — not enough history -> nil)

    func testMakeTrendIsNilWithNotEnoughHistory() {
        let history = [result(value: 5.0)]
        let trend = ReferenceRangeEngine.makeTrend(id: "t1", analyteKey: "glucose_fasting", history: history, unit: "mmol/L",
                                                   validFrom: now, computedAt: now, updatedAt: now, originDeviceId: device)
        XCTAssertNil(trend, "a single point must never fabricate a personal baseline")
    }

    // MARK: - OCR review gate: review_required stays the default until an explicit confirm/skip

    private func ocrField(state: OCRReviewState) -> OCRFieldExtraction {
        OCRFieldExtraction(id: ULID.newID(), pageIndex: 0, analyteLabelRaw: "Glucose", analyteMatch: .unrecognized,
                          valueText: "5.4", unitTextRaw: "mmol/L", reviewState: state)
    }

    func testOCRFieldExtractionDefaultsToNeedsReview() {
        let field = OCRFieldExtraction(id: "f1", pageIndex: 0, analyteLabelRaw: "Glucose", analyteMatch: .unrecognized, valueText: "5.4")
        XCTAssertEqual(field.reviewState, .needsReview, "review_required must be the default for every extracted field")
    }

    func testCannotFinalizeWhileAnyFieldStillNeedsReview() {
        let fields = [ocrField(state: .userEntered), ocrField(state: .needsReview)]
        XCTAssertFalse(OCRReviewGate.canFinalize(fields),
                       "a single low-confidence field left unconfirmed must block the whole set")
    }

    func testCanFinalizeOnceEveryFieldIsConfirmedOrCorrected() {
        let fields = [ocrField(state: .userEntered), ocrField(state: .corrected)]
        XCTAssertTrue(OCRReviewGate.canFinalize(fields))
    }

    func testCannotFinalizeAnEmptySet() {
        XCTAssertFalse(OCRReviewGate.canFinalize([]), "reviewing nothing must never silently finalize an empty report")
    }

    // MARK: - Unknown/unrecognized analyte is always a first-class free-text entry

    func testAnalyteCatalogDoesNotClaimToRecognizeAnArbitraryMarker() {
        XCTAssertTrue(AnalyteCatalog.shared.matching("xyz-not-a-real-marker-42", language: .en).isEmpty,
                     "the catalog is intentionally small and non-exhaustive")
    }

    func testManualEntryScreensFreeTextPathIsNeverGatedOnADictionaryMatch() {
        let text = Self.sourceText("apps/ios/Sources/Features/Labs/ManualEntryScreen.swift")
        XCTAssertTrue(text.contains("case custom(String)"), "the analyte picker must support a free-text pick")
        XCTAssertTrue(text.contains(".custom(query)"), "the free-text row must always be tappable and produce a `.custom` pick")
        XCTAssertFalse(text.contains("matches.isEmpty { return }") || text.contains("guard !matches.isEmpty"),
                       "the free-text path must never be gated on the dictionary already having a match — " +
                       "an unrecognized marker must never be blocked (REJECTED ANTI-PATTERN)")
    }

    // MARK: - LAB-16 duplicate/conflict wiring (`LabDuplicateCheck` — the resolver's own scoring is
    // tested directly in `DuplicateConflictResolverTests`; this covers only the "what does
    // `ManualEntryScreen.save()` do with each decision" glue that actually calls it).

    func testDuplicateCheckMergeReturnsTheExistingRowsIdAsTheWinner() {
        let existing = result(value: 5.20, measuredAt: now)
        let candidate = result(value: 5.20, measuredAt: now.addingTimeInterval(360)) // 0.1h later, same report
        let (resolved, winnerId) = LabDuplicateCheck.apply(candidate, against: [existing])
        XCTAssertEqual(winnerId, existing.id, "a merge decision names the pre-existing row as the winner to suppress the new one against")
        XCTAssertEqual(resolved.reviewState, candidate.reviewState, "a merge decision never alters the row's own reviewState")
    }

    func testDuplicateCheckFlagRaisesReviewStateToConflictFlagged() {
        let existing = result(value: 5.0, measuredAt: now)
        let candidate = result(value: 9.0, measuredAt: now.addingTimeInterval(720)) // 0.2h later, same report
        let (resolved, winnerId) = LabDuplicateCheck.apply(candidate, against: [existing])
        XCTAssertNil(winnerId, "a flag decision never suppresses anything")
        XCTAssertEqual(resolved.reviewState, .conflictFlagged)
    }

    func testDuplicateCheckIgnoresCandidatesFromADifferentAnalyte() {
        let existing = result(value: 5.20, analyteId: "sodium", measuredAt: now)
        let candidate = result(value: 5.20, analyteId: "potassium", measuredAt: now.addingTimeInterval(360))
        let (resolved, winnerId) = LabDuplicateCheck.apply(candidate, against: [existing])
        XCTAssertNil(winnerId)
        XCTAssertNotEqual(resolved.reviewState, .conflictFlagged, "different analytes are never compared, per the resolver's own rule")
    }

    func testDuplicateCheckReturnsUnchangedWhenNoCandidatesCompete() {
        let candidate = result(value: 5.20, measuredAt: now)
        let (resolved, winnerId) = LabDuplicateCheck.apply(candidate, against: [])
        XCTAssertNil(winnerId)
        XCTAssertEqual(resolved.id, candidate.id)
        XCTAssertEqual(resolved.reviewState, candidate.reviewState)
    }
}
