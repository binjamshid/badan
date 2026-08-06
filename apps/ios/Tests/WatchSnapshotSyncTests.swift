import XCTest
@testable import BADAN

/// A22/EPIC-42 (Phase 4) — the phone-side half of the new watch transport. `WatchSnapshotSync`'s
/// only genuinely host-testable logic is its pure dto→payload translation (`applicationContext(for:)`)
/// and its no-op guard when `WCSession` is unsupported/uninitialized; the real `WCSession` delivery
/// path (activation, `updateApplicationContext` actually reaching a paired Watch) needs real
/// WatchConnectivity runtime state this host does not have, exactly as the app-group container
/// resolution `AmbientSnapshotStore`'s own tests avoid touching directly (see that type's
/// `overrideContainerURL` doc for the parallel).
final class WatchSnapshotSyncTests: XCTestCase {
    private static let sampleDto = AmbientSnapshotDto(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000), language: "ar",
        readiness: RingSnapshot(score: 71, provisional: false),
        sentence: SentenceSnapshot(en: "hi", ar: "أهلاً"),
        sleep: SleepSnapshot(durationMinutes: 400, score: 80, provisional: false),
        medsDue: nil, effort: EffortSnapshot(score: 44, provisional: true))

    /// This is the load-bearing contract with `BadanWatch/Sync/SnapshotReceiver.swift`, which this
    /// target cannot import to check directly (separate watchOS module — see `WatchSnapshotSync`'s
    /// own header) — so this test pins the exact wire shape both sides must agree on: the encoded
    /// snapshot round-trips byte-for-byte under `WatchSnapshotSync.applicationContextKey`.
    func testApplicationContextPayloadRoundTripsTheSameDtoUnderTheDocumentedKey() throws {
        let payload = try WatchSnapshotSync.applicationContext(for: Self.sampleDto)
        let data = try XCTUnwrap(
            payload[WatchSnapshotSync.applicationContextKey] as? Data,
            "the payload must carry the encoded snapshot under its documented key")
        let decoded = try JSONDecoder().decode(AmbientSnapshotDto.self, from: data)
        XCTAssertEqual(decoded, Self.sampleDto)
        XCTAssertEqual(decoded.effort, Self.sampleDto.effort)
    }

    /// `session: nil` is exactly what production gets when `WCSession.isSupported()` is false (the
    /// test seam `WatchSnapshotSync.init(session:)` exists precisely for this). Must never crash
    /// and must not attempt to reach a session that doesn't exist.
    func testSyncIsAHarmlessNoOpWhenWatchConnectivityIsUnsupported() {
        let sync = WatchSnapshotSync(session: nil)
        sync.sync(Self.sampleDto)
        // No assertion beyond "did not crash/throw" — there is nothing else observable about a
        // deliberate no-op.
    }

    // MARK: - W-11: the ambient privacy mode reaches the watch (H1)
    //
    // The watch cannot honour `AmbientSnapshotDto.privacy` — its own copy of the DTO has no such
    // field, so the flags are dropped at decode and every watch render site draws whatever number
    // it was handed. Enforcement therefore has to be "do not send it", and these are the tests
    // that hold that line. They assert on the WIRE PAYLOAD, not on a rendering decision, because
    // the payload is the only thing this side controls.

    /// The exact flags `AmbientSnapshotWriter.privacySnapshot` stamps for `.discreet` — pinned by
    /// `AmbientPrivacyTests.testDiscreetModeKeepsContentButForbidsValues`, restated here as a
    /// literal so this file tests the transport rather than re-testing the writer.
    private static let discreetFlags = AmbientPrivacySnapshot(
        valuesAllowed: false, contentAllowed: true, lockScreenValuesAllowed: false)

    /// Deliberately populated in EVERY field, including the two the watch app does not even render
    /// today (`medsDue`) — the question is what crosses to the wrist, not what the current watch
    /// build happens to draw.
    private static let discreetDto = AmbientSnapshotDto(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000), language: "en",
        readiness: RingSnapshot(score: 71, provisional: false),
        sentence: SentenceSnapshot(en: "Your evening looked calm.", ar: "بدت أمسيتك هادئة."),
        sleep: SleepSnapshot(durationMinutes: 400, score: 80, provisional: false),
        medsDue: MedsDueSnapshot(items: [MedsDueItem(regimenId: "r1", displayName: "Metformin",
                                                     timeLabel: "8:00 AM")]),
        effort: EffortSnapshot(score: 44, provisional: true),
        privacy: WatchSnapshotSyncTests.discreetFlags)

    func testDiscreetSnapshotReachesTheWatchCarryingNoValueAtAll() throws {
        let payload = try WatchSnapshotSync.applicationContext(for: Self.discreetDto)
        let data = try XCTUnwrap(payload[WatchSnapshotSync.applicationContextKey] as? Data)
        let decoded = try JSONDecoder().decode(AmbientSnapshotDto.self, from: data)

        XCTAssertNil(decoded.readiness, "a discreet readiness score must not reach an always-on wrist display")
        XCTAssertNil(decoded.effort, "a discreet effort score must not reach an always-on wrist display")
        XCTAssertNil(decoded.sleep, "a discreet sleep duration/score must not reach an always-on wrist display")
        XCTAssertNil(decoded.sentence, "a sentence IS the value — discreet withholds it whole")
        XCTAssertNil(decoded.medsDue, "medication names have no watch surface to justify the trip at all")
    }

    /// The decode assertions above would still pass if a value survived under some key this
    /// version's decoder ignores. This one looks at the bytes actually handed to WatchConnectivity.
    func testDiscreetPayloadBytesContainNoneOfTheWithheldContent() throws {
        let payload = try WatchSnapshotSync.applicationContext(for: Self.discreetDto)
        let data = try XCTUnwrap(payload[WatchSnapshotSync.applicationContextKey] as? Data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        for secret in ["Your evening looked calm.", "بدت أمسيتك هادئة.", "Metformin", "8:00 AM"] {
            XCTAssertFalse(json.contains(secret),
                           "the discreet watch payload still carries \"\(secret)\"")
        }
    }

    /// And the withholding must not take the two non-personal fields with it: without `generatedAt`
    /// the watch cannot tell fresh from stale (it would show `.neverSynced` for a snapshot it holds),
    /// and without `language` it cannot pick Arabic/RTL copy. Both are properties of the sync, not
    /// readings about the person.
    func testDiscreetPayloadKeepsFreshnessAndLanguageSoTheWatchCanStillDegradeHonestly() throws {
        let payload = try WatchSnapshotSync.applicationContext(for: Self.discreetDto)
        let data = try XCTUnwrap(payload[WatchSnapshotSync.applicationContextKey] as? Data)
        let decoded = try JSONDecoder().decode(AmbientSnapshotDto.self, from: data)

        XCTAssertEqual(decoded.generatedAt, Self.discreetDto.generatedAt)
        XCTAssertEqual(decoded.language, "en")
    }

    /// The other half of the guarantee: `.standard` must be completely untouched by this, or the
    /// test above would also pass against a transport that simply sends nothing ever.
    func testStandardSnapshotStillReachesTheWatchWithEveryValueIntact() throws {
        let payload = try WatchSnapshotSync.applicationContext(for: Self.sampleDto)
        let data = try XCTUnwrap(payload[WatchSnapshotSync.applicationContextKey] as? Data)
        let decoded = try JSONDecoder().decode(AmbientSnapshotDto.self, from: data)

        XCTAssertEqual(decoded, Self.sampleDto)
    }

    /// `.off` already carries nothing (the writer assembles no personal content in that mode), so
    /// this is a belt-and-braces check that the same guard covers it rather than a second code
    /// path: any mode that forbids values, present or future, is withheld by the SAME condition.
    func testAnyModeThatForbidsValuesIsWithheldNotJustDiscreet() throws {
        let offFlags = AmbientPrivacySnapshot(valuesAllowed: false, contentAllowed: false,
                                              lockScreenValuesAllowed: false)
        let dto = AmbientSnapshotDto(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), language: "ar",
            readiness: RingSnapshot(score: 90, provisional: false), sentence: nil, sleep: nil,
            medsDue: nil, effort: nil, privacy: offFlags)

        XCTAssertNil(WatchSnapshotSync.watchPayload(for: dto).readiness)
    }

    // MARK: - Watch-side ratchets (source scans)
    //
    // `BadanWatch`/`BadanWatchWidgets` are separate watchOS modules this iOS test target cannot
    // import — the same gap `WidgetDeepLinkTests`' header documents for `BadanWidgets`, and the
    // same stand-in: a text scan of the real source. Weaker than a behavioural assertion, and the
    // behavioural versions belong in `apps/ios/BadanWatchTests/SnapshotReceiverTests.swift`, but
    // these do fail if the wiring below is removed, which is what they exist for.

    private static func watchSource(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// M4: a complication is a separate process reading the cache the watch app writes, so writing
    /// that file announces nothing. Without an explicit reload the only refresh is the provider's
    /// `.after(15 * 60)` policy, which watchOS throttles — a synced number can sit invisible on the
    /// face long after it landed.
    func testWatchReceiverReloadsComplicationsWhenASnapshotIsApplied() {
        let code = AmbientPrivacyTests.strippingComments(
            Self.watchSource("BadanWatch/Sync/SnapshotReceiver.swift"))
        XCTAssertTrue(code.contains("WidgetCenter.shared.reloadAllTimelines()"),
                      "SnapshotReceiver must nudge WidgetKit when a new snapshot is applied — nothing "
                      + "else in BadanWatch/BadanWatchWidgets ever calls WidgetCenter")
        XCTAssertTrue(code.contains("reloadComplications()"),
                      "the reload must be invoked on the apply path, not merely defined")
    }

    /// M3: `activate()` is asynchronous and `receivedApplicationContext` is only dependable once it
    /// has completed. An empty `activationDidCompleteWith` is exactly the state in which a first
    /// launch after reinstall shows "Not synced with your phone yet" over a context already sitting
    /// in the daemon — so the callback must re-run the pending-context check.
    func testWatchReceiverRechecksThePendingContextOnceActivationCompletes() throws {
        let code = AmbientPrivacyTests.strippingComments(
            Self.watchSource("BadanWatch/Sync/SnapshotReceiver.swift"))
        let start = try XCTUnwrap(code.range(of: "activationDidCompleteWith activationState"),
                                  "SnapshotReceiver no longer implements the activation callback at all")
        let rest = code[start.upperBound...]
        // Bounded to this one callback's body — the next `func` at method indentation ends it — so
        // the check cannot be satisfied by the pre-activation call site further up the file.
        let body = rest.range(of: "\n    func ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        XCTAssertTrue(body.contains("applyPendingContextIfAny"),
                      "activationDidCompleteWith must re-check the pending application context; it is "
                      + "the only moment that property is known to be reliable")
    }
}
