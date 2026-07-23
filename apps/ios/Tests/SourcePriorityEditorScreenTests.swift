import Foundation
import XCTest
@testable import BADAN

/// EPIC-43 — coverage for the Source Priority Editor (`SourcePriorityEditorScreen.swift`), the UI
/// `DataConflictsScreen.swift`'s own header used to name as explicitly future work until
/// reconciliation-v2 was wired into the real ingestion pipeline (commit 4266c68). Three things:
/// reachability (mirrors `CycleIntegrationUITests`'s exact comment-stripping fix — see that file's
/// own doc for why a naive preview-block strip alone is not enough), the pure row-state/reorder
/// logic, and the load-bearing integration path: saving a priority order through this screen's real
/// write path (`SourcePriorityRuleRepository.insert`) is what `ConflictDecisionEngine.decide` reads
/// on its NEXT call — the exact seam `IngestionPipeline.reconcileConflictWindow` sits on top of.
final class SourcePriorityEditorScreenTests: XCTestCase {

    // MARK: - Reachability (mirrors CycleIntegrationUITests's exact comment-stripping fix)

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SourcePriorityEditorScreenTests.swift
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

    /// AUDIT FIX (mirrored verbatim from `CycleIntegrationUITests.strippingLineComments`):
    /// `strippingPreviewBlocks` alone is comment-blind — a doc comment that happens to mention a
    /// type name followed by `(` shadows a real construction site, so deleting the ACTUAL wiring
    /// while leaving the comment intact would leave `assertReachable` still passing. This file's
    /// own header comment above is exactly that hazard (it says "`SourcePriorityEditorScreen.swift`"
    /// without a trailing `(`, so it's harmless here, but every other doc comment across this
    /// feature folder that names this screen followed by `(` — see `DataConflictsScreen.swift`'s
    /// updated header — would otherwise neuter this exact check). Strips `//` line comments
    /// (naive — everything from the first `//` on a line to its end) BEFORE the preview-block
    /// strip, so only genuine, compiled construction sites can satisfy `assertReachable`.
    private static func strippingLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[line.startIndex..<range.lowerBound]
        }.joined(separator: "\n")
    }

    private func assertReachable(_ typeName: String, in relativePath: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = Self.strippingPreviewBlocks(Self.strippingLineComments(Self.sourceText(relativePath)))
        XCTAssertFalse(text.isEmpty, "expected non-empty source at \(relativePath)", file: file, line: line)
        XCTAssertTrue(text.contains("\(typeName)("),
                      "\(typeName) has no REAL (non-comment) construction site in \(relativePath) — " +
                      "this is exactly the 'built but dark' defect check-reachability.py guards against.",
                      file: file, line: line)
    }

    private static let deviceHubPath = "apps/ios/Sources/Features/DeviceHub/DeviceHubScreen.swift"

    func testSourcePriorityEditorScreenIsReachableFromDeviceHub() {
        assertReachable("SourcePriorityEditorScreen", in: Self.deviceHubPath)
    }

    // MARK: - Row-state logic (pure — SourcePriorityEditorLogic.rowState)

    func testHeartRateWithNoRuleShowsTheShippedChestStrapDefault() {
        let state = SourcePriorityEditorLogic.rowState(metricId: MetricID.heartRate, liveRule: nil)
        XCTAssertEqual(state, .editable(
            order: [SourcePriorityRule.ClassificationKey.bleChestStrapHR, SourcePriorityRule.ClassificationKey.wristOpticalHR],
            origin: .builtInDefault))
    }

    func testRestingHeartRateWithNoRuleShowsANeutralEditableStateRatherThanEmpty() {
        let state = SourcePriorityEditorLogic.rowState(metricId: MetricID.restingHeartRate, liveRule: nil)
        XCTAssertEqual(state, .editable(order: SourcePriorityClassification.editableKeys, origin: .noDefaultYet))
    }

    func testHrvWithNoRuleShowsANeutralEditableStateRatherThanEmpty() {
        let state = SourcePriorityEditorLogic.rowState(metricId: MetricID.hrv, liveRule: nil)
        XCTAssertEqual(state, .editable(order: SourcePriorityClassification.editableKeys, origin: .noDefaultYet))
    }

    func testWeightIsAlwaysFixedByEngineRegardlessOfAnyStoredRule() {
        let noRule = SourcePriorityEditorLogic.rowState(metricId: MetricID.weight, liveRule: nil)
        guard case .fixedByEngine = noRule else {
            XCTFail("expected weight to be read-only with no rule saved")
            return
        }

        // Even a STRAY saved row for weight (however it got there) must not make this screen offer
        // a reorder control: `ConflictDecisionEngine.decide` checks `MetricID.weight` and returns
        // before ever consulting a `SourcePriorityRule` (manual-wins, else most-recent-wins), so a
        // priority order for weight is provably inert.
        let stray = SourcePriorityRule(id: "stray", metricId: MetricID.weight, priorityOrder: ["a"], isUserOverride: true,
                                       createdAt: Date(epochMillis: 0), updatedAt: Date(epochMillis: 0), originDeviceId: "o")
        let withRule = SourcePriorityEditorLogic.rowState(metricId: MetricID.weight, liveRule: stray)
        guard case .fixedByEngine = withRule else {
            XCTFail("weight must stay read-only even if a stray rule row exists for it")
            return
        }
    }

    func testLiveUserOverrideRuleIsShownAsUserSetWithItsRealOrder() {
        let rule = SourcePriorityRule(id: "r1", metricId: MetricID.hrv, priorityOrder: ["x", "y"], isUserOverride: true,
                                      createdAt: Date(epochMillis: 0), updatedAt: Date(epochMillis: 0), originDeviceId: "o")
        let state = SourcePriorityEditorLogic.rowState(metricId: MetricID.hrv, liveRule: rule)
        XCTAssertEqual(state, .editable(order: ["x", "y"], origin: .userSet))
    }

    func testLiveBadanShippedRuleIsShownAsBuiltInDefaultWithItsRealOrder() {
        let rule = SourcePriorityRule(id: "r1", metricId: MetricID.heartRate, priorityOrder: ["x", "y"], isUserOverride: false,
                                      createdAt: Date(epochMillis: 0), updatedAt: Date(epochMillis: 0), originDeviceId: "o")
        let state = SourcePriorityEditorLogic.rowState(metricId: MetricID.heartRate, liveRule: rule)
        XCTAssertEqual(state, .editable(order: ["x", "y"], origin: .builtInDefault))
    }

    // MARK: - Reorder (pure — SourcePriorityReorder)

    func testMoveUpSwapsWithThePreviousItem() {
        XCTAssertEqual(SourcePriorityReorder.moveUp(["a", "b", "c"], at: 1), ["b", "a", "c"])
    }

    func testMoveUpAtTheTopIsANoOp() {
        XCTAssertEqual(SourcePriorityReorder.moveUp(["a", "b"], at: 0), ["a", "b"])
    }

    func testMoveDownSwapsWithTheNextItem() {
        XCTAssertEqual(SourcePriorityReorder.moveDown(["a", "b", "c"], at: 1), ["a", "c", "b"])
    }

    func testMoveDownAtTheBottomIsANoOp() {
        XCTAssertEqual(SourcePriorityReorder.moveDown(["a", "b"], at: 1), ["a", "b"])
    }

    func testMoveUpWithAnOutOfBoundsIndexIsANoOp() {
        XCTAssertEqual(SourcePriorityReorder.moveUp(["a", "b"], at: 5), ["a", "b"])
    }

    func testMoveDownWithAnOutOfBoundsIndexIsANoOp() {
        XCTAssertEqual(SourcePriorityReorder.moveDown(["a", "b"], at: -1), ["a", "b"])
    }

    // MARK: - Classification <-> SensorQualityMap bridge (SourcePriorityClassification)

    func testEveryEditableClassificationKeyResolvesARealBilingualDisplayName() {
        for key in SourcePriorityClassification.editableKeys {
            let name = SourcePriorityClassification.displayName(key)
            XCTAssertFalse(name.en.isEmpty)
            XCTAssertFalse(name.ar.isEmpty)
            XCTAssertNotEqual(name.en, key, "must resolve a real name via SensorQualityMap, not fall back to the raw key")
        }
    }

    func testChestStrapSourceClassIdMapsToTheChestStrapClassificationKey() {
        XCTAssertEqual(SourcePriorityClassification.classificationKey(forSourceClassId: "chest_strap"),
                       SourcePriorityRule.ClassificationKey.bleChestStrapHR)
    }

    func testWristWearableSourceClassIdMapsToTheWristOpticalClassificationKey() {
        XCTAssertEqual(SourcePriorityClassification.classificationKey(forSourceClassId: "wrist_wearable"),
                       SourcePriorityRule.ClassificationKey.wristOpticalHR)
    }

    func testManualEntrySourceClassIdMapsToTheManualClassificationKey() {
        XCTAssertEqual(SourcePriorityClassification.classificationKey(forSourceClassId: "manual_entry"),
                       SourcePriorityRule.ClassificationKey.manual)
    }

    func testUnmappedSourceClassIdsReturnNilRatherThanGuessing() {
        for id in ["ring_wearable", "smart_scale", "bp_cuff", "phone_handset", "unknown", "clinical_device", "file_import"] {
            XCTAssertNil(SourcePriorityClassification.classificationKey(forSourceClassId: id),
                        "\(id) is not part of this editor's closed vocabulary and must not be silently mapped to one")
        }
    }

    // MARK: - Persistence + engine integration

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-sourcepriorityeditor-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func reading(id: String, classification: String, at: Date) -> CandidateReading {
        CandidateReading(id: id, sourceId: "source-\(id)", classification: classification, measuredAt: at)
    }

    /// AUDIT CORRECTION: this test's own doc comment used to claim it proves "the real seam this
    /// screen sits on top of," including `IngestionPipeline.reconcileConflictWindow`'s real
    /// candidate-building — that overclaimed. This test genuinely proves the SAVE half of the seam
    /// (`SourcePriorityRuleRepository.insert`/`rule(forMetric:)` round-trips correctly, append-only
    /// per I2) and that `ConflictDecisionEngine.decide`'s pure priority-order logic is internally
    /// consistent given a correctly-classified candidate pair. It does NOT prove — and, by
    /// construction, cannot prove — that a real save-through-this-screen ever changes a real
    /// production outcome, because its own `reading(id:classification:at:)` helper hand-supplies the
    /// one field (`classification`) that `IngestionPipeline`'s real candidate-building code used to
    /// never set at all (an audit-confirmed critical bug: every real `CandidateReading` defaulted to
    /// `classification == ""`, so a saved priority order had ZERO effect in production for
    /// `restingHeartRate`/`hrv` — see `SourcePriorityRule.ClassificationKey.fromSensorClassId`'s own
    /// fix doc). The REAL end-to-end proof — a saved rule actually flipping a real suppression
    /// decision through the genuine `IngestionPipeline` candidate-building path, with no hand-supplied
    /// classification anywhere — is
    /// `IngestionReconciliationWiringTests.testSavingAPriorityRuleActuallyResolvesARealConflictBetweenCorrectlyClassifiedDevices`.
    /// This test remains valuable for what it actually verifies; it is just not, on its own, the
    /// production-path guarantee its old doc comment claimed.
    func testSavingANewPriorityOrderIsPickedUpByConflictDecisionEngineOnItsNextCall() throws {
        let repo = SourcePriorityRuleRepository(main: try Database(directory: tempDir).main)
        let metricId = MetricID.restingHeartRate
        let strapReading = reading(id: "strap-1", classification: SourcePriorityRule.ClassificationKey.bleChestStrapHR,
                                   at: Date(epochMillis: 1_000))
        let wristReading = reading(id: "wrist-1", classification: SourcePriorityRule.ClassificationKey.wristOpticalHR,
                                   at: Date(epochMillis: 1_000))

        // Before any rule is ever saved: genuinely unresolved — no engine default exists for this
        // metric at all (see `ConflictDecisionEngine.decide`'s own precedence doc).
        XCTAssertNil(try repo.rule(forMetric: metricId))
        XCTAssertNil(ConflictDecisionEngine.decide(scope: .metric(id: metricId),
                                                    candidates: [strapReading, wristReading], priorityRule: nil))

        // Save an order ranking the chest strap first — this screen's own write path: a brand-new,
        // `isUserOverride: true` row (never a mutation of a prior one).
        let firstOrder = [SourcePriorityRule.ClassificationKey.bleChestStrapHR, SourcePriorityRule.ClassificationKey.wristOpticalHR]
        try repo.insert(SourcePriorityRule(id: "user-rule-1", metricId: metricId, priorityOrder: firstOrder,
                                           isUserOverride: true, createdAt: Date(epochMillis: 2_000),
                                           updatedAt: Date(epochMillis: 2_000), originDeviceId: "device-1"))

        let liveAfterFirstSave = try XCTUnwrap(repo.rule(forMetric: metricId))
        let firstOutcome = try XCTUnwrap(ConflictDecisionEngine.decide(
            scope: .metric(id: metricId), candidates: [strapReading, wristReading], priorityRule: liveAfterFirstSave))
        XCTAssertEqual(firstOutcome.winnerId, "strap-1", "the chest strap is ranked first in the saved order")
        XCTAssertEqual(firstOutcome.ruleId, ConflictDecisionEngine.priorityOrderRuleId)

        // Reverse the order (mirrors what `SourcePriorityReorder.moveDown` would produce from the
        // screen's own reorder buttons) and save it as a SECOND, brand-new row — never overwriting
        // the first (append-only, I2 — `SourcePriorityRuleRepository`'s own documented contract).
        let reversedOrder = SourcePriorityReorder.moveDown(firstOrder, at: 0)
        XCTAssertEqual(reversedOrder,
                       [SourcePriorityRule.ClassificationKey.wristOpticalHR, SourcePriorityRule.ClassificationKey.bleChestStrapHR])
        try repo.insert(SourcePriorityRule(id: "user-rule-2", metricId: metricId, priorityOrder: reversedOrder,
                                           isUserOverride: true, createdAt: Date(epochMillis: 3_000),
                                           updatedAt: Date(epochMillis: 3_000), originDeviceId: "device-1"))

        // Both rows must still exist (history-preserving) but the freshest live one is what a NEXT
        // `decide` call actually reads — the winner must genuinely flip.
        let all = try repo.all()
        XCTAssertEqual(all.count, 1, "one row per metric on read — the freshest live one")
        XCTAssertEqual(all.first?.id, "user-rule-2")

        let liveAfterSecondSave = try XCTUnwrap(repo.rule(forMetric: metricId))
        XCTAssertEqual(liveAfterSecondSave.id, "user-rule-2")
        let secondOutcome = try XCTUnwrap(ConflictDecisionEngine.decide(
            scope: .metric(id: metricId), candidates: [strapReading, wristReading], priorityRule: liveAfterSecondSave))
        XCTAssertEqual(secondOutcome.winnerId, "wrist-1",
                       "after saving the reversed order, the SAME candidate set must now resolve to the wrist-optical reading")
    }

    /// A metric with no rule yet must still show the answer that matches what `decide` ACTUALLY
    /// does today for it — heart rate's one real, hardcoded default (chest-strap-beats-wrist-optical
    /// in a workout) — rather than an empty/confusing state. Distinct from the pure
    /// `SourcePriorityEditorLogic` unit test above: this one exercises the real engine end to end
    /// with the exact fallback order the screen would display, over a real (empty) repository.
    func testMetricWithNoRuleYetDisplaysTheOrderThatMatchesWhatTheEngineActuallyDoesToday() throws {
        let repo = SourcePriorityRuleRepository(main: try Database(directory: tempDir).main)
        XCTAssertNil(try repo.rule(forMetric: MetricID.heartRate))

        let state = SourcePriorityEditorLogic.rowState(
            metricId: MetricID.heartRate, liveRule: try repo.rule(forMetric: MetricID.heartRate))
        guard case .editable(let displayedOrder, let origin) = state else {
            XCTFail("heart rate must be shown as editable even with no saved rule")
            return
        }
        XCTAssertEqual(origin, .builtInDefault)
        XCTAssertEqual(displayedOrder.count, 2)

        let strap = reading(id: "strap", classification: displayedOrder[0], at: Date(epochMillis: 1_000))
        let wrist = reading(id: "wrist", classification: displayedOrder[1], at: Date(epochMillis: 1_000))
        // In a workout, with no saved rule at all: the hardcoded chest-strap default is what
        // actually decides it, and it must agree with what the screen would have displayed.
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(
            scope: .metric(id: MetricID.heartRate, inWorkout: true), candidates: [strap, wrist], priorityRule: nil))
        XCTAssertEqual(outcome.winnerId, "strap", "the displayed default order's #1 entry must be who the engine actually picks")
    }

    /// Resting heart rate / HRV's "no default yet" state must not be a dead end: the neutral
    /// starting order it displays is exactly what saving (with no further reordering) would
    /// persist, and that persisted rule must then genuinely resolve a future conflict — proving
    /// "not yet resolved unless you set one" is an honest description, not just reassuring copy.
    func testNoDefaultYetStateBecomesARealResolvingRuleOnceSavedAsIs() throws {
        let repo = SourcePriorityRuleRepository(main: try Database(directory: tempDir).main)
        let metricId = MetricID.hrv
        let state = SourcePriorityEditorLogic.rowState(metricId: metricId, liveRule: try repo.rule(forMetric: metricId))
        guard case .editable(let displayedOrder, let origin) = state else {
            XCTFail("hrv must be shown as editable even with no saved rule")
            return
        }
        XCTAssertEqual(origin, .noDefaultYet)

        try repo.insert(SourcePriorityRule(id: "hrv-rule-1", metricId: metricId, priorityOrder: displayedOrder,
                                           isUserOverride: true, createdAt: Date(epochMillis: 1_000),
                                           updatedAt: Date(epochMillis: 1_000), originDeviceId: "device-1"))

        let manual = reading(id: "manual-1", classification: SourcePriorityRule.ClassificationKey.manual,
                             at: Date(epochMillis: 5_000))
        let wrist = reading(id: "wrist-1", classification: SourcePriorityRule.ClassificationKey.wristOpticalHR,
                            at: Date(epochMillis: 5_000))
        let liveRule = try XCTUnwrap(repo.rule(forMetric: metricId))
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(
            scope: .metric(id: metricId), candidates: [manual, wrist], priorityRule: liveRule))
        XCTAssertEqual(outcome.winnerId, "wrist-1", "wrist-optical is ranked above manual in the saved starting order")
    }
}
