import Foundation
import XCTest
@testable import BADAN

/// Phase 3D fix pass (EPIC-33), covering two audit findings in `apps/ios/BadanWidgets/`:
///
/// - FIX A: `SentenceWidget.swift`, `MedsDueWidget.swift`, and `SleepCardWidget.swift` used to
///   apply BOTH `.environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)` on a
///   view's outer content AND manually swap `.leading`/`.trailing` alignment with
///   `isArabic ? .trailing : .leading` inside that same subtree. `.leading`/`.trailing` already
///   auto-mirror against the ambient `layoutDirection`, so the two mirrors cancelled out and
///   Arabic content never actually moved to the visual-RTL position. `RingSingleWidget.swift` was
///   checked independently and never had this pattern (its layout is symmetric/centered) — it is
///   still covered by the ratchet below so the bug can't be introduced there later either.
/// - FIX B: all four widgets computed `isArabic` as `entry.snapshot?.language == "ar"`, which is
///   `false` (forcing English/LTR) whenever `entry.snapshot` is nil — e.g. an Arabic-locale user
///   who adds a widget before ever launching the app. The shared `WidgetLanguage.isArabic(for:)`
///   helper (`BadanWidgetsBundle.swift`) now falls back to the system locale in that gap instead.
///
/// Same rationale as `WidgetDeepLinkTests.swift` for why this lives here rather than in a test
/// target for `BadanWidgets` itself: that target has no test target of its own in this wave, and
/// giving it one is a `project.yml` change out of this fix's scope. Text-based source checks stand
/// in for anything that would otherwise need `@testable import BadanWidgets`, and the one piece of
/// real logic (`WidgetLanguage.isArabic`'s fallback algorithm) is exercised via a pinned, mirrored
/// pure-function copy below — the same "mirror + pin the source it mirrors" shape as this repo's
/// `*ParityTests.swift` files use for other cross-target-boundary logic.
final class WidgetRTLLayoutTests: XCTestCase {

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WidgetRTLLayoutTests.swift
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
    }()

    private static func sourceText(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static let bundleFile = "apps/ios/BadanWidgets/BadanWidgetsBundle.swift"

    /// Every widget view file that resolves `isArabic` and applies a `layoutDirection` override.
    /// `RingSingleWidget.swift` is included even though it never had the FIX A bug (its layout is
    /// centered, not directional) — it is exactly the file a future contributor might "fix" by
    /// copy-pasting the bad pattern from a sibling, so it stays covered by the ratchet below.
    private static let directionalWidgetFiles = [
        "apps/ios/BadanWidgets/RingSingleWidget.swift",
        "apps/ios/BadanWidgets/SentenceWidget.swift",
        "apps/ios/BadanWidgets/MedsDueWidget.swift",
        "apps/ios/BadanWidgets/SleepCardWidget.swift",
    ]

    // MARK: - FIX A: no widget double-mirrors alignment against `isArabic`

    func testNoWidgetConditionsAlignmentOnIsArabicOnTopOfTheEnvironmentOverride() {
        for file in Self.directionalWidgetFiles {
            let text = Self.sourceText(file)
            XCTAssertFalse(text.isEmpty, "\(file) could not be read")
            for pattern in ["isArabic ? .trailing", "isArabic ? .leading"] {
                XCTAssertFalse(
                    text.contains(pattern),
                    "\(file) conditions a `.leading`/`.trailing` alignment on `isArabic` in the " +
                    "same subtree as a `.environment(\\.layoutDirection, isArabic ? .rightToLeft : " +
                    ".leftToRight)` override. `.leading`/`.trailing` already auto-mirror against " +
                    "that environment value, so the two mirrors cancel and Arabic content never " +
                    "actually moves to the visual-RTL position — this is exactly the bug this " +
                    "ratchet exists to catch if it is ever reintroduced."
                )
            }
        }
    }

    func testEveryDirectionalWidgetKeepsTheLayoutDirectionEnvironmentOverride() {
        for file in Self.directionalWidgetFiles {
            let text = Self.sourceText(file)
            XCTAssertTrue(
                text.contains(".environment(\\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)"),
                "\(file) must keep the layoutDirection environment override — with the manual " +
                "isArabic ? .trailing : .leading conditionals gone, this is the ONLY mechanism " +
                "left that mirrors this widget's layout for Arabic. Removing it, not just the " +
                "manual conditionals, would silently regress this fix."
            )
        }
    }

    func testMedsDueWidgetInnerDueListHStackStaysUnconditioned() {
        // MedsDueWidget's inner due-list HStack never had a manual isArabic conditional — the audit
        // named it as the ALREADY-correct pattern the rest of the file was brought in line with.
        // This guards against a future contributor "fixing" it to add one back.
        let text = Self.sourceText("apps/ios/BadanWidgets/MedsDueWidget.swift")
        guard let dueListRange = text.range(of: "private func dueListBody") else {
            XCTFail("MedsDueWidget.swift's dueListBody no longer exists")
            return
        }
        let body = text[dueListRange.lowerBound...]
        XCTAssertTrue(
            body.contains("HStack {"),
            "MedsDueWidget.swift's dueListBody must keep a plain, unconditioned inner `HStack {` — " +
            "it already mirrors correctly via the ambient layoutDirection environment alone and " +
            "must not gain a redundant `isArabic ? .trailing : .leading` conditional"
        )
    }

    // MARK: - FIX B: nil-snapshot language fallback goes to the shared helper, not hardcoded English

    func testEveryWidgetDelegatesIsArabicToTheSharedHelper() {
        for file in Self.directionalWidgetFiles + ["apps/ios/BadanWidgets/MedsDueWidget.swift"] {
            let text = Self.sourceText(file)
            XCTAssertTrue(
                text.contains("WidgetLanguage.isArabic(for: entry.snapshot)"),
                "\(file) no longer delegates `isArabic` to the shared `WidgetLanguage` helper in " +
                "BadanWidgetsBundle.swift — duplicating this logic per-widget again is exactly how " +
                "the nil-snapshot system-locale fallback (FIX B) drifted out of sync before"
            )
            XCTAssertFalse(
                text.contains("entry.snapshot?.language == \"ar\""),
                "\(file) reintroduces the old inline isArabic check, which hardcodes English/LTR " +
                "whenever entry.snapshot is nil (e.g. before the app's first launch)"
            )
        }
    }

    /// Pins the production algorithm the mirrored pure function below exercises. `BadanWidgets`
    /// cannot be imported from this test target (see this file's header), so behavior is verified
    /// against a copy — this test is what keeps that copy honest: if `WidgetLanguage.isArabic`'s
    /// real implementation changes without updating the mirror below, this fails loudly instead of
    /// the mirror silently testing stale logic forever.
    func testWidgetLanguageSourcePinsTheAlgorithmTheMirrorBelowExercises() {
        let text = Self.sourceText(Self.bundleFile)
        XCTAssertFalse(text.isEmpty, "\(Self.bundleFile) could not be read")
        for pinnedLine in [
            "if let language = snapshot?.language {",
            "return language == \"ar\"",
            "guard let topLanguage = preferredLanguages.first else { return false }",
            "let languageCode = topLanguage.split(separator: \"-\").first.map(String.init) ?? topLanguage",
            "return languageCode == \"ar\"",
        ] {
            XCTAssertTrue(
                text.contains(pinnedLine),
                "WidgetLanguage.isArabic's implementation in \(Self.bundleFile) no longer contains " +
                "'\(pinnedLine)' — update this pin AND the mirroredWidgetLanguageIsArabic(...) copy " +
                "below together, in the same change, so the mirror never silently goes stale"
            )
        }
    }

    /// Mirror of `WidgetLanguage.isArabic(for:preferredLanguages:)` (`BadanWidgetsBundle.swift`),
    /// pinned against the real source by the test above. `snapshotLanguage` stands in for
    /// `snapshot?.language`.
    private func mirroredWidgetLanguageIsArabic(snapshotLanguage: String?, preferredLanguages: [String]) -> Bool {
        if let language = snapshotLanguage {
            return language == "ar"
        }
        guard let topLanguage = preferredLanguages.first else { return false }
        let languageCode = topLanguage.split(separator: "-").first.map(String.init) ?? topLanguage
        return languageCode == "ar"
    }

    func testNilSnapshotWithArabicSystemLocaleFallsBackToArabic() {
        // The exact regression this fix targets: a widget added from the Home Screen before the
        // app's first launch (no snapshot has ever been written yet) on an Arabic-locale device.
        XCTAssertTrue(
            mirroredWidgetLanguageIsArabic(snapshotLanguage: nil, preferredLanguages: ["ar-SA", "en-US"]),
            "A nil snapshot on an Arabic-system-locale device must fall back to Arabic, not " +
            "silently default to English/LTR"
        )
    }

    func testNilSnapshotWithEnglishSystemLocaleFallsBackToEnglish() {
        XCTAssertFalse(
            mirroredWidgetLanguageIsArabic(snapshotLanguage: nil, preferredLanguages: ["en-US", "ar-SA"])
        )
    }

    func testNilSnapshotWithNoPreferredLanguagesDefaultsToEnglishRatherThanCrashing() {
        XCTAssertFalse(mirroredWidgetLanguageIsArabic(snapshotLanguage: nil, preferredLanguages: []))
    }

    func testSnapshotLanguageWinsOverAConflictingSystemLocale() {
        // The snapshot's own field is authoritative whenever it exists — it reflects the user's
        // in-app language CHOICE, which is allowed to differ from the device's system locale.
        XCTAssertTrue(mirroredWidgetLanguageIsArabic(snapshotLanguage: "ar", preferredLanguages: ["en-US"]))
        XCTAssertFalse(mirroredWidgetLanguageIsArabic(snapshotLanguage: "en", preferredLanguages: ["ar-SA"]))
    }

    func testUnrelatedLanguageCodeStartingWithArDoesNotFalsePositive() {
        // Regression guard for exactly the false-positive a naive `hasPrefix("ar")` would produce:
        // "arn" (Mapudungun) starts with "ar" but is not Arabic.
        XCTAssertFalse(mirroredWidgetLanguageIsArabic(snapshotLanguage: nil, preferredLanguages: ["arn-CL"]))
    }
}
