import XCTest
@testable import BADAN

/// W-11 (EPIC-44 wave 1), including the execution plan's Phase-3 exit criterion: a **lock-screen
/// redaction non-overridability test**.
///
/// The load-bearing assertions here are the ones that try to BREAK the guarantee — a test that only
/// checks "medications don't show on the lock screen by default" would pass against a system where
/// any setting could turn that off, which is precisely what must not be true.
final class AmbientPrivacyTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-ambient-privacy-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWriter() -> AmbientSnapshotWriter {
        AmbientSnapshotWriter(
            derivation: DerivationRepository(db.main),
            measurements: MeasurementRepository(db.main, sensitive: db.sensitive),
            logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
            insights: InsightRepository(db.main),
            store: AmbientSnapshotStore(), clock: clock,
            reloadWidgets: { _ in })
    }

    // MARK: - Non-overridability

    /// No mode, and no combination of mode and consent, may put medication values on a Lock Screen.
    /// Enumerated over every case rather than spot-checked, so adding a mode that forgets this
    /// fails here rather than shipping.
    func testNoPrivacyModeCanPutMedicationsOnALockScreen() {
        for mode in AmbientPrivacyMode.allCases {
            let config = AmbientPrivacyConfig(mode: mode)
            XCTAssertFalse(config.allowsValues(for: .medsDue, isLockScreen: true),
                           "\(mode) must not permit medication values on a lock screen")
            XCTAssertFalse(config.allowsPresence(for: .medsDue, isLockScreen: true),
                           "\(mode) must not permit medications to appear on a lock screen at all")
        }
    }

    /// The rule is a property of the family, not of the current settings — `neverOnLockScreen` is a
    /// constant with no setter anywhere in the app.
    func testMedicationsAreInTheNonOverridableSet() {
        XCTAssertTrue(AmbientPrivacyConfig.neverOnLockScreen.contains(.medsDue))
    }

    /// And the same rule must not silently swallow everything else — a readiness score on a Lock
    /// Screen is fine in `.standard`. Without this, "nothing ever shows" would pass the test above.
    func testOrdinaryFamiliesAreStillAllowedOnALockScreenInStandardMode() {
        let config = AmbientPrivacyConfig(mode: .standard)
        XCTAssertTrue(config.allowsValues(for: .readiness, isLockScreen: true))
        XCTAssertTrue(config.allowsValues(for: .sleep, isLockScreen: true))
    }

    /// The structural backstop that does not depend on any of the above: `MedsDueWidget` registers
    /// no accessory family, so WidgetKit has no way to ask it to render on a Lock Screen. This is a
    /// source-level ratchet — the same shape as the existing `WidgetDeepLinkTests` check — because
    /// the guarantee has to survive someone adding a family without reading the header comment.
    func testMedsDueWidgetRegistersNoLockScreenFamily() throws {
        let source = try String(contentsOfFile: widgetSourcePath("MedsDueWidget.swift"), encoding: .utf8)
        let code = Self.strippingComments(source)

        for family in ["accessoryCircular", "accessoryRectangular", "accessoryInline"] {
            XCTAssertFalse(code.contains(family),
                           "MedsDueWidget must never register \(family) — that is what makes lock-screen "
                           + "redaction structural rather than a branch someone can forget")
        }
    }

    // MARK: - Modes actually change what is written

    func testOffModeAssemblesNoPersonalContentAtAll() async throws {
        let dto = try await makeWriter().buildSnapshot(
            now: clock.now(), tz: "Asia/Muscat", language: .en, medsDueConsentGranted: true,
            privacy: AmbientPrivacyConfig(mode: .off))

        XCTAssertNil(dto.readiness)
        XCTAssertNil(dto.sentence)
        XCTAssertNil(dto.sleep)
        XCTAssertNil(dto.effort)
        XCTAssertNil(dto.medsDue, "even a granted meds consent yields nothing in .off")
        XCTAssertFalse(dto.privacy.contentAllowed)
    }

    /// `.discreet` keeps the content (a ring needs its score to draw an arc) but marks it
    /// unrenderable as a value. Both halves matter: dropping the content would flatten the ring,
    /// and not marking it would show the number.
    func testDiscreetModeKeepsContentButForbidsValues() async throws {
        let dto = try await makeWriter().buildSnapshot(
            now: clock.now(), tz: "Asia/Muscat", language: .en, medsDueConsentGranted: false,
            privacy: AmbientPrivacyConfig(mode: .discreet))

        XCTAssertTrue(dto.privacy.contentAllowed)
        XCTAssertFalse(dto.privacy.valuesAllowed)
        XCTAssertFalse(dto.privacy.lockScreenValuesAllowed)
        XCTAssertNotNil(dto.sentence, "the sentence is still assembled; the flag is what withholds it")
    }

    func testStandardModeIsUnchangedFromPreviousBehaviour() async throws {
        let dto = try await makeWriter().buildSnapshot(
            now: clock.now(), tz: "Asia/Muscat", language: .en, medsDueConsentGranted: false,
            privacy: .default)

        XCTAssertTrue(dto.privacy.valuesAllowed)
        XCTAssertTrue(dto.privacy.contentAllowed)
        XCTAssertTrue(dto.privacy.lockScreenValuesAllowed)
    }

    // MARK: - Decode tolerance

    /// A snapshot written before W-11 has no `privacy` key. It must decode to `.standard` — the
    /// behaviour that file's content already assumed — not to a mode that hides content the user
    /// was already seeing, and not fail the decode outright.
    func testASnapshotWrittenBeforeThisFeatureDecodesAsStandard() throws {
        let json = """
        {"schemaVersion":1,"generatedAt":0,"language":"en",
         "readiness":{"score":72,"provisional":false}}
        """
        let dto = try JSONDecoder().decode(AmbientSnapshotDto.self, from: Data(json.utf8))

        XCTAssertTrue(dto.privacy.valuesAllowed)
        XCTAssertEqual(dto.readiness?.score, 72)
    }

    /// The profile field follows the same rule.
    func testAProfileWrittenBeforeThisFeatureDecodesAsStandard() throws {
        let encoded = try JSONEncoder().encode(CustomizationProfile())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "ambientPrivacy")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(CustomizationProfile.self, from: stripped)

        XCTAssertEqual(decoded.ambientPrivacy.mode, .standard)
    }

    // MARK: - Helpers

    private func widgetSourcePath(_ name: String) -> String {
        // `#filePath` is this test file inside `apps/ios/Tests/`; the widget target sits alongside
        // it under `apps/ios/BadanWidgets/`. Same navigation the existing widget source-scan test
        // uses, kept identical so both break together if the layout moves.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BadanWidgets/\(name)")
            .path
    }

    /// Strips `//` line comments before scanning. A doc comment that MENTIONS `accessoryCircular`
    /// (this codebase's widget headers do, precisely to warn against adding it) would otherwise
    /// make the assertion above fail for the wrong reason — and worse, an earlier version of this
    /// exact pattern elsewhere in the repo was comment-BLIND in the opposite direction, letting a
    /// comment satisfy a check the real code no longer did.
    static func strippingComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }
}
