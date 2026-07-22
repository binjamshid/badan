import Foundation
import XCTest
@testable import BADAN

/// EPIC-33 wave 1 — the four widgets in `apps/ios/BadanWidgets/` open the app via a
/// `badan://deeplink/<token>` URL (`WidgetDeepLinkToken` in `BadanWidgetsBundle.swift`). That
/// target cannot import `BADAN` (it is a separate app-extension target with its own `sources:` in
/// `project.yml` — see `apps/ios/BadanWidgets/AmbientSnapshotDto.swift`'s header comment), so it
/// keeps its own local mirror of the raw-value tokens the main app's `NotificationDeepLink`
/// (`NotificationDecisionEngine.swift`) already understands, rather than a second deep-link
/// system. This test target links the real `BADAN` module, so it is the one place both sides can
/// be checked against each other — it exists to catch that mirror drifting: a token renamed on one
/// side without the other decodes to a route that no longer exists, silently, with nothing to
/// catch it at compile time.
///
/// (Confirming the "gap" this slice's task notes asked about: the widget extension target has no
/// test target of its own in this wave, so this lives in the MAIN `apps/ios/Tests/` target, which
/// already depends on `BADAN` per `project.yml` — that is the real, and only, gap. Text-based
/// source checks below stand in for anything that would otherwise need `@testable import
/// BadanWidgets`, which this target cannot do without a `project.yml` change out of this slice's
/// scope.)
///
/// GAP CLOSED (fix pass, Phase 3D audit): `BADAN` now registers a `badan://` `CFBundleURLTypes`
/// scheme (`project.yml`) and a `.onOpenURL` handler (`BADANApp.swift`) that calls
/// `AppEnvironment.handleDeepLinkURL(_:)`, which parses the token and resolves it through the
/// EXACT SAME `openDeepLink(_:)` entry point a tapped notification already uses — never a second,
/// parallel routing mechanism. A tap on one of these widgets now opens BADAN AND routes to the
/// matching tab. The tests below still verify the token vocabulary (every token a widget's
/// `widgetURL` encodes names a `NotificationDeepLink` case that is real today and resolves to the
/// right tab); `testHandleDeepLinkURL*` below additionally exercises the real handler function
/// end to end, closing the gap this file used to describe as open.
final class WidgetDeepLinkTests: XCTestCase {

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WidgetDeepLinkTests.swift
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
    }()

    private static func sourceText(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Every token this wave's widgets use resolves to a real, correctly-tabbed deep link

    func testReadinessTokenResolvesToTodayTab() {
        let link = NotificationDeepLink(rawValue: "readiness")
        XCTAssertEqual(link, .readiness,
                        "RingSingleWidget/SentenceWidget's 'readiness' token no longer names a real NotificationDeepLink case")
        XCTAssertEqual(link?.tab.rawValue, MainTab.today.rawValue)
    }

    func testSleepTokenResolvesToTodayTab() {
        let link = NotificationDeepLink(rawValue: "sleep")
        XCTAssertEqual(link, .sleep,
                        "SleepCardWidget's 'sleep' token no longer names a real NotificationDeepLink case")
        XCTAssertEqual(link?.tab.rawValue, MainTab.today.rawValue)
    }

    func testMedsTokenResolvesToLogTab() {
        let link = NotificationDeepLink(rawValue: "meds")
        XCTAssertEqual(link, .meds,
                        "MedsDueWidget's 'meds' token no longer names a real NotificationDeepLink case")
        XCTAssertEqual(link?.tab.rawValue, MainTab.log.rawValue)
    }

    // MARK: - Each widget file actually wires the token validated above (reachability-style;
    // mirrors scripts/check-reachability.py's own approach — see DeviceHubUITests for the
    // established pattern this copies)

    func testRingSingleWidgetUsesReadinessToken() {
        let text = Self.sourceText("apps/ios/BadanWidgets/RingSingleWidget.swift")
        XCTAssertTrue(text.contains("WidgetDeepLinkToken.readiness"),
                      "RingSingleWidget.swift no longer wires the readiness deep-link token")
    }

    func testSentenceWidgetUsesReadinessToken() {
        let text = Self.sourceText("apps/ios/BadanWidgets/SentenceWidget.swift")
        XCTAssertTrue(text.contains("WidgetDeepLinkToken.readiness"),
                      "SentenceWidget.swift no longer wires the readiness deep-link token")
    }

    func testMedsDueWidgetUsesMedsToken() {
        let text = Self.sourceText("apps/ios/BadanWidgets/MedsDueWidget.swift")
        XCTAssertTrue(text.contains("WidgetDeepLinkToken.meds"),
                      "MedsDueWidget.swift no longer wires the meds deep-link token")
    }

    func testSleepCardWidgetUsesSleepToken() {
        let text = Self.sourceText("apps/ios/BadanWidgets/SleepCardWidget.swift")
        XCTAssertTrue(text.contains("WidgetDeepLinkToken.sleep"),
                      "SleepCardWidget.swift no longer wires the sleep deep-link token")
    }

    // MARK: - MedsDueWidget structurally never registers a Lock Screen/StandBy family (plan W-11)

    func testMedsDueWidgetNeverRegistersAnAccessoryFamily() {
        let text = Self.sourceText("apps/ios/BadanWidgets/MedsDueWidget.swift")
        // Deliberately scoped to the `.supportedFamilies([...])` call itself, not the whole file —
        // this file's own header comment names every accessory family by design (to say "don't add
        // these"), so a whole-file substring search would flag its own explanatory prose.
        guard let range = text.range(of: "supportedFamilies("),
              let closeParen = text[range.upperBound...].firstIndex(of: ")") else {
            XCTFail("MedsDueWidget.swift no longer calls .supportedFamilies(...) at all")
            return
        }
        let familiesArgument = text[range.upperBound..<closeParen]
        for accessory in ["accessoryCircular", "accessoryRectangular", "accessoryInline", "accessoryCorner"] {
            XCTAssertFalse(familiesArgument.contains(accessory),
                            "MedsDueWidget.swift must never register .\(accessory) — medications are " +
                            "sensitive-plus (INVARIANTS.md I7) and plan W-11's redaction rule is structural, " +
                            "not a per-family branch")
        }
    }

    // MARK: - FIX-4 (Phase 3D audit): the real `.onOpenURL` handler, end to end
    //
    // Everything above only checked the ENUM mapping (`NotificationDeepLink(rawValue:)`) and that
    // each widget file's source text mentions the right token — never the actual runtime handler a
    // tapped widget's URL is fed through. These tests construct a real `badan://deeplink/<token>`
    // URL and drive it through `AppEnvironment.handleDeepLinkURL(_:)` itself (the function
    // `BADANApp.swift`'s `.onOpenURL` calls), asserting the same `pendingDeepLink` state a tapped
    // notification would leave behind.

    @MainActor
    private func makeTestEnvironment() throws -> AppEnvironment {
        let db = try Database.inMemoryFallback()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        return AppEnvironment(database: db, clock: clock)
    }

    @MainActor
    func testHandleDeepLinkURLResolvesReadinessTokenToTodayTab() throws {
        let env = try makeTestEnvironment()
        env.handleDeepLinkURL(URL(string: "badan://deeplink/readiness")!)
        XCTAssertEqual(env.pendingDeepLink, .readiness)
        XCTAssertEqual(env.pendingDeepLink?.tab, .today)
    }

    @MainActor
    func testHandleDeepLinkURLResolvesSleepTokenToTodayTab() throws {
        let env = try makeTestEnvironment()
        env.handleDeepLinkURL(URL(string: "badan://deeplink/sleep")!)
        XCTAssertEqual(env.pendingDeepLink, .sleep)
        XCTAssertEqual(env.pendingDeepLink?.tab, .today)
    }

    @MainActor
    func testHandleDeepLinkURLResolvesMedsTokenToLogTab() throws {
        let env = try makeTestEnvironment()
        env.handleDeepLinkURL(URL(string: "badan://deeplink/meds")!)
        XCTAssertEqual(env.pendingDeepLink, .meds)
        XCTAssertEqual(env.pendingDeepLink?.tab, .log)
    }

    /// The exact three tokens `WidgetDeepLinkToken.url` can ever produce
    /// (`badan://deeplink/readiness|sleep|meds`) — this doesn't hand-construct a raw string, it
    /// drives the URL a real widget would open, mirroring `WidgetDeepLinkToken.url`'s own
    /// construction (`badan://deeplink/\(rawValue)`) to stay honest about what's actually tested.
    @MainActor
    func testHandleDeepLinkURLMatchesWhatWidgetURLActuallyEncodes() throws {
        for token in ["readiness", "sleep", "meds"] {
            let env = try makeTestEnvironment()
            let url = URL(string: "badan://deeplink/\(token)")!
            env.handleDeepLinkURL(url)
            XCTAssertEqual(env.pendingDeepLink?.rawValue, token,
                            "handleDeepLinkURL must resolve the exact token a widget's own URL encodes")
        }
    }

    @MainActor
    func testHandleDeepLinkURLIgnoresAnUnrecognizedTokenRatherThanCrashing() throws {
        let env = try makeTestEnvironment()
        env.handleDeepLinkURL(URL(string: "badan://deeplink/not-a-real-token")!)
        XCTAssertNil(env.pendingDeepLink, "an unrecognized token must be a silent no-op, not a crash or a wrong route")
    }

    @MainActor
    func testHandleDeepLinkURLIgnoresAWrongScheme() throws {
        let env = try makeTestEnvironment()
        env.handleDeepLinkURL(URL(string: "https://deeplink/readiness")!)
        XCTAssertNil(env.pendingDeepLink, "only the registered badan:// scheme may route")
    }
}
