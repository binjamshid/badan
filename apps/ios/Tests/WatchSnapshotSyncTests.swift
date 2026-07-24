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
}
