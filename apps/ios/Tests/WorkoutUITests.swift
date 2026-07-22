import Foundation
import XCTest
@testable import BADAN

/// EPIC-42 slice 2 — coverage for the Workout UI lane's own view-logic and wiring, matching this
/// codebase's established convention of testing the PURE rules a screen renders from rather than
/// the rendered view tree itself (see `JournalSurfacesTests`, `HydrationSurfacesTests`, …).
///
/// `WorkoutSessionCoordinator` itself is the parallel engine lane's file and isn't constructed
/// here — every rule below is asserted directly against the exact VALUE TYPES the frozen
/// `WorkoutSessionCoordinator` contract exposes (`WorkoutCheckpoint?`, `Double?`,
/// `Set<WorkoutDegradedCondition>`), which already exist from slice 1 and need no live coordinator
/// to exercise.
final class WorkoutUITests: XCTestCase {
    private let device = "test-device"
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Reachability (mirrors scripts/check-reachability.py's own check, as a real XCTest)

    /// The repo root, resolved from this test file's own on-disk path (`apps/ios/Tests/
    /// WorkoutUITests.swift` is four path components below it) rather than a guessed relative
    /// path — robust to whatever working directory `xcodebuild test` happens to run from.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WorkoutUITests.swift
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
    }()

    private static func sourceText(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Drops every `#Preview { ... }` block's BODY (brace-matched), so a construction site that
    /// exists only inside a preview does not count as "reachable" — the exact rule
    /// `check-reachability.py`'s `strip_preview_blocks` enforces.
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

    /// Asserts `typeName(` appears somewhere in `relativePath`'s source outside any `#Preview`
    /// block — i.e. that a real (non-preview) construction site exists, matching exactly what the
    /// CI ratchet checks for the whole app, scoped here to this slice's five new screens.
    private func assertReachable(_ typeName: String, in relativePath: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = Self.strippingPreviewBlocks(Self.sourceText(relativePath))
        XCTAssertTrue(text.contains("\(typeName)("),
                      "\(typeName) has no construction site in \(relativePath) outside a #Preview — " +
                      "this is exactly the 'built but dark' defect check-reachability.py guards against.",
                      file: file, line: line)
    }

    func testWorkoutHomeScreenIsReachableFromLogHub() {
        assertReachable("WorkoutHomeScreen", in: "apps/ios/Sources/Features/LogHub/LogHubScreen.swift")
    }

    func testLiveAndStrengthAndPickerScreensAreReachableFromWorkoutHome() {
        assertReachable("LiveWorkoutScreen", in: "apps/ios/Sources/Features/Workout/WorkoutHomeScreen.swift")
        assertReachable("StrengthLoggingScreen", in: "apps/ios/Sources/Features/Workout/WorkoutHomeScreen.swift")
        assertReachable("ActivityPickerScreen", in: "apps/ios/Sources/Features/Workout/WorkoutHomeScreen.swift")
    }

    func testPostWorkoutSummaryScreenIsReachableFromBothLiveAndStrengthScreens() {
        assertReachable("PostWorkoutSummaryScreen", in: "apps/ios/Sources/Features/Workout/LiveWorkoutScreen.swift")
        assertReachable("PostWorkoutSummaryScreen", in: "apps/ios/Sources/Features/Workout/StrengthLoggingScreen.swift")
    }

    // MARK: - Recoverable-draft prompt (WorkoutStateMachine: "ask the user, never silently resume")

    private func checkpoint(activityType: String = "running", state: WorkoutLifecycleState = .active) -> WorkoutCheckpoint {
        WorkoutCheckpoint(
            sessionId: "session-1", activityType: activityType, state: state, startedAt: now,
            stateHistory: [WorkoutStateTransition(state: state, at: now)],
            hotState: WorkoutHotState(degradedConditions: [], stateBeforeInterruption: state,
                                      activeSeconds: 125, pausedSeconds: 0),
            lastCheckpointAt: now, originDeviceId: device)
    }

    func testRecoverableDraftPromptShowsWhenACheckpointIsPresent() {
        XCTAssertTrue(RecoverableDraftPromptRule.shouldShow(checkpoint()),
                      "a non-nil recoverableDraft must surface the resume/discard prompt")
    }

    func testRecoverableDraftPromptHiddenWhenNoCheckpointExists() {
        XCTAssertFalse(RecoverableDraftPromptRule.shouldShow(nil),
                       "no recoverable draft means the ordinary quick-start screen, not the prompt")
    }

    // MARK: - Heart-rate tile (plan: "HR tile omitted, never zeros, on phone-only Apple sessions")

    func testHeartRateTileOmittedWhenBpmIsNil() {
        XCTAssertNil(HeartRateTileFormat.valueText(bpm: nil, language: .en, arabicDigits: false),
                     "nil bpm must render no tile at all, never a placeholder")
    }

    func testHeartRateTileOmittedForNonPositiveOrNonFiniteBpm() {
        XCTAssertNil(HeartRateTileFormat.valueText(bpm: 0, language: .en, arabicDigits: false),
                     "a fabricated zero reading must never be rendered as if it were real")
        XCTAssertNil(HeartRateTileFormat.valueText(bpm: -12, language: .en, arabicDigits: false))
        XCTAssertNil(HeartRateTileFormat.valueText(bpm: .nan, language: .en, arabicDigits: false))
    }

    func testHeartRateTileRendersARealReading() {
        let text = HeartRateTileFormat.valueText(bpm: 118.6, language: .en, arabicDigits: false)
        XCTAssertEqual(text, "119") // rounds, matches every other on-screen numeral's convention
    }

    // MARK: - Degraded-condition banner

    func testEveryDegradedConditionRendersItsOwnDisplayLabel() {
        for condition in WorkoutDegradedCondition.allCases {
            let lines = DegradedBannerFormat.lines(for: [condition])
            XCTAssertEqual(lines, [condition.displayLabel],
                           "\(condition) must render exactly its own WorkoutDegradedCondition.displayLabel")
        }
    }

    func testDegradedBannerEmptyWhenNoConditionsActive() {
        XCTAssertTrue(DegradedBannerFormat.lines(for: []).isEmpty)
    }

    func testDegradedBannerOrderIsDeterministicRegardlessOfSetInsertionOrder() {
        let a = DegradedBannerFormat.lines(for: [.lowBattery, .sensorDegraded])
        let b = DegradedBannerFormat.lines(for: [.sensorDegraded, .lowBattery])
        XCTAssertEqual(a, b, "banner line order must not depend on Set iteration order")
    }

    // MARK: - Elapsed-time formatting

    func testElapsedTimeUnderAnHourOmitsTheHourComponent() {
        XCTAssertEqual(WorkoutTimeFormat.string(seconds: 90, language: .en, arabicDigits: false), "1:30")
    }

    func testElapsedTimePastAnHourIncludesIt() {
        XCTAssertEqual(WorkoutTimeFormat.string(seconds: 3_661, language: .en, arabicDigits: false), "1:01:01")
    }

    func testElapsedTimeNeverGoesNegative() {
        XCTAssertEqual(WorkoutTimeFormat.string(seconds: -5, language: .en, arabicDigits: false), "0:00")
    }

    // MARK: - Strength-modality routing (backs WorkoutFlowRoute.destination(forActivityType:))

    func testStrengthTrainingRoutesToTheStrengthLoggingScreen() {
        XCTAssertTrue(ActivityCatalog.shared.isStrength("strength_training"))
        XCTAssertEqual(WorkoutFlowRoute.destination(forActivityType: "strength_training"), .strength)
    }

    func testWalkingRoutesToThePlainLiveScreen() {
        XCTAssertFalse(ActivityCatalog.shared.isStrength("walking"))
        XCTAssertEqual(WorkoutFlowRoute.destination(forActivityType: "walking"), .live)
    }

    func testUnrecognizedActivityIdNeverGuessesStrength() {
        XCTAssertFalse(ActivityCatalog.shared.isStrength("not-a-real-activity"))
        XCTAssertFalse(ActivityCatalog.shared.isStrength(nil))
    }

    // MARK: - Pause announcement (FIX 1: must speak the ACTUAL resulting state)

    func testPauseAnnouncementSpeaksManuallyPausedNeverAutoPaused() {
        let spoken = PauseResumeAnnouncement.text(resultingState: .manuallyPaused, language: .en)
        XCTAssertEqual(spoken, WorkoutLifecycleState.manuallyPaused.displayLabel.en)
        XCTAssertNotEqual(spoken, WorkoutLifecycleState.autoPaused.displayLabel.en,
                          "coordinator.requestPause() always resolves to .manuallyPaused (nothing ever " +
                          "fires .autoPauseDetected) — the announcement must never speak .autoPaused's label")
    }

    func testPauseAnnouncementResolvesInBothLanguages() {
        XCTAssertEqual(PauseResumeAnnouncement.text(resultingState: .manuallyPaused, language: .ar),
                       WorkoutLifecycleState.manuallyPaused.displayLabel.ar)
    }

    // MARK: - `.preparing` countdown (FIX 4: a real elapsed interval, not an instantaneous no-op)

    func testWorkoutCountdownMatchesThePlansThreeSecondDefault() {
        XCTAssertEqual(WorkoutCountdown.defaultSeconds, 3, "plan §7A.5: \"countdown default 3s\"")
    }

    // MARK: - Crash-recovery body text (FIX 7: correct Arabic regardless of activity gender)

    /// الجري (running) is grammatically masculine; السباحة (swimming) is feminine; الفنون القتالية
    /// (martial arts) is feminine plural — the fixed "جلسة ... التي ... تُحفظ ... حفظها"
    /// construction (agreeing with the fixed-feminine head noun "جلسة", never with the activity's
    /// own gender) must read correctly for all three without any per-activity gender agreement.
    func testCrashRecoveryBodyTextIsGrammaticallyCorrectForActivitiesOfDifferentGender() {
        XCTAssertEqual(
            CrashRecoveryBodyText.compose(activityId: "running", language: .ar),
            "توجد جلسة الجري التي لم تُحفظ من وقت سابق — أُغلق التطبيق قبل حفظها.")
        XCTAssertEqual(
            CrashRecoveryBodyText.compose(activityId: "swimming", language: .ar),
            "توجد جلسة السباحة التي لم تُحفظ من وقت سابق — أُغلق التطبيق قبل حفظها.")
        XCTAssertEqual(
            CrashRecoveryBodyText.compose(activityId: "martial_arts", language: .ar),
            "توجد جلسة الفنون القتالية التي لم تُحفظ من وقت سابق — أُغلق التطبيق قبل حفظها.")
    }

    func testCrashRecoveryBodyTextEnglishReadsNaturally() {
        XCTAssertEqual(
            CrashRecoveryBodyText.compose(activityId: "running", language: .en),
            "A Running session from earlier wasn't saved — the app closed before it could save.")
    }

    // MARK: - Quick-start labels must match the canonical activity catalog (FIX 8)

    /// Every quick-start tile must read its label from the SAME canonical source
    /// (`ActivityCatalog`, backing `activities.json`) that `LiveWorkoutScreen.activityDisplayName`/
    /// `PostWorkoutSummaryScreen.activityDisplayName` already read from — never a hardcoded
    /// duplicate — so the SAME session's activity name can never visibly change between the home
    /// screen's quick-start tile and the live/summary screens.
    func testEveryQuickStartActivityLabelMatchesTheCanonicalActivityCatalog() {
        for activity in QuickStartActivity.allCases {
            guard let canonical = ActivityCatalog.shared.definition(activity.activityId)?.displayName else {
                XCTFail("\(activity.activityId) is missing from ActivityCatalog")
                continue
            }
            XCTAssertEqual(activity.label, canonical,
                          "\(activity) must resolve its label from ActivityCatalog(\(activity.activityId)), " +
                          "matching what the live/summary screens show for the same session")
        }
    }

    func testQuickStartCycleLabelIsTheActivityCyclingNotTheObjectABicycle() {
        // The specific regression this fix was named for: `.cycle`'s Arabic had drifted to
        // "دراجة" ("a bicycle", the object) instead of "ركوب الدراجة" ("cycling", the activity).
        XCTAssertEqual(QuickStartActivity.cycle.label.ar, "ركوب الدراجة")
    }
}
