import Foundation
import XCTest
@testable import BADAN

/// EPIC-39 (Phase 3F slice 2) — Integrate-phase reconciliation coverage. Four parallel lanes each
/// wrote a reachability test scoped to the ONE sub-screen they themselves construct (see e.g.
/// `CycleHistoryUITests`'s own header: "This screen's OWN reachability from `CycleHomeScreen` is a
/// different lane's routing... and is not asserted here"), so no lane's suite ever asserted the
/// CROSS-lane wiring end to end. This file is that missing check, mirroring
/// `LabNotebookUITests`'s exact reachability pattern (`testLabNotebookHomeScreenIsReachableFromLogHub`
/// / `testEveryOtherLabScreenIsReachableFromLabNotebookHomeScreensOwnRouter`) and
/// `WorkoutUITests.testWorkoutHomeScreenIsReachableFromLogHub`, applied to the cycle module.
///
/// This suite would have caught the real "built but dark" defect this Integrate pass found and
/// fixed: `ContraceptiveContextScreen` (Lane D, CYCLE-07) had a real, tested screen with no
/// construction site anywhere in the shipping source set — `scripts/check-reachability.py` flags
/// exactly this failure mode. `testEveryOtherCycleScreenIsReachableFromCycleHomeScreensOwnRouter`
/// below is written to fail again if that ever regresses.
final class CycleIntegrationUITests: XCTestCase {

    // MARK: - Source scans (mirrors LabNotebookUITests's own helpers exactly)

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CycleIntegrationUITests.swift
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

    /// AUDIT FIX: `strippingPreviewBlocks` alone is comment-blind — a doc comment that happens to
    /// mention a type name followed by `(` (e.g. this very file's own header, or any screen's
    /// "routes to `Foo(services:)`" style doc comment) shadows a real construction site, so deleting
    /// the ACTUAL call while leaving the comment intact would leave `assertReachable` still passing.
    /// This was caught for real: `CycleHistoryScreen(` appears both in `CycleHomeScreen.swift`'s own
    /// header comment and at its genuine `case .history:` construction site, which neutered this
    /// exact check for that one type. Strips `//` line comments (naive — everything from the first
    /// `//` on a line to its end — sufficient here since none of these files' real code ever needs a
    /// literal `//` inside a string) BEFORE the preview-block strip, so only genuine, compiled
    /// construction sites can satisfy `assertReachable`.
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

    private static let logHubPath = "apps/ios/Sources/Features/LogHub/LogHubScreen.swift"
    private static let homeScreenPath = "apps/ios/Sources/Features/Cycle/CycleHomeScreen.swift"

    // MARK: - The module's own root: reachable from LogHub either enabled or not-yet-enabled

    func testCycleHomeScreenIsReachableFromLogHub() {
        assertReachable("CycleHomeScreen", in: Self.logHubPath)
    }

    /// The LogHub Cycle tile routes to `CycleConsentScreen` when the module hasn't been turned on
    /// yet (`env.profile.cycleModuleEnabled == false`) — this is the ONLY way a user could ever
    /// discover and enable the module in the first place (see `LogHubScreen`'s own doc comment on
    /// this tile), so it is its own real reachability path, not a fallback worth skipping.
    func testCycleConsentScreenIsReachableFromLogHubForTheNotYetEnabledCase() {
        assertReachable("CycleConsentScreen", in: Self.logHubPath)
    }

    // MARK: - Every other cycle screen, reachable from CycleHomeScreen's own router

    func testEveryOtherCycleScreenIsReachableFromCycleHomeScreensOwnRouter() {
        assertReachable("CycleHistoryScreen", in: Self.homeScreenPath)
        assertReachable("CycleExportScreen", in: Self.homeScreenPath)
        assertReachable("PeriodLogScreen", in: Self.homeScreenPath)
        // AUDIT FIX (this Integrate pass): ContraceptiveContextScreen (Lane D, CYCLE-07) was built
        // and tested but never wired into any navigation path anywhere in the app until this fix.
        assertReachable("ContraceptiveContextScreen", in: Self.homeScreenPath)
    }
}
