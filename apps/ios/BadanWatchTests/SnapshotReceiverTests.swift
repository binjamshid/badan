import XCTest
@testable import BadanWatch

/// `SnapshotReceiver` is exercised here with `session: nil` (the same "unsupported WatchConnectivity"
/// seam `WatchSnapshotSync`'s own tests use on the phone side) and an overridden `WatchSnapshotStore`
/// directory — so every assertion below is about THIS type's own decode/cache logic, never about a
/// real `WCSession`'s delivery behavior, which this host cannot exercise at all.
final class SnapshotReceiverTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-watch-receiver-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let sampleDto = AmbientSnapshotDto(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000), language: "en",
        readiness: RingSnapshot(score: 55, provisional: false), sentence: nil, sleep: nil,
        medsDue: nil, effort: nil)

    func testFreshReceiverWithNoCacheHasNoSnapshot() {
        let receiver = SnapshotReceiver(session: nil, store: WatchSnapshotStore(overrideDirectory: directory))
        XCTAssertNil(receiver.snapshot)
        XCTAssertNil(receiver.receivedAt)
    }

    /// Covers the cold-launch-recovery path: a snapshot cached by a PREVIOUS process must be
    /// visible immediately on construction, before any new `WCSession` push arrives.
    func testReceiverRestoresFromAnExistingCacheOnInit() throws {
        let store = WatchSnapshotStore(overrideDirectory: directory)
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_500)
        store.write(snapshot: Self.sampleDto, receivedAt: receivedAt)

        let receiver = SnapshotReceiver(session: nil, store: store)
        XCTAssertEqual(receiver.snapshot, Self.sampleDto)
        let restoredReceivedAt = try XCTUnwrap(receiver.receivedAt)
        XCTAssertEqual(restoredReceivedAt.timeIntervalSince1970, receivedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testApplyDecodesValidDataUpdatesStateAndPersistsToTheStore() throws {
        let store = WatchSnapshotStore(overrideDirectory: directory)
        let receiver = SnapshotReceiver(session: nil, store: store)
        let data = try JSONEncoder().encode(Self.sampleDto)
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_900)

        receiver.apply(data: data, receivedAt: receivedAt)

        XCTAssertEqual(receiver.snapshot, Self.sampleDto)
        XCTAssertEqual(receiver.receivedAt, receivedAt)
        // Persisted, not just held in memory — a second receiver instance (simulating a relaunch)
        // must see it too.
        let reloaded = SnapshotReceiver(session: nil, store: store)
        XCTAssertEqual(reloaded.snapshot, Self.sampleDto)
    }

    /// Undecodable bytes (a corrupt or genuinely incompatible payload) must never crash, and must
    /// leave whatever was already known standing — never silently blank a real snapshot just
    /// because one bad push arrived.
    func testApplyIgnoresUndecodableDataAndLeavesExistingSnapshotIntact() throws {
        let store = WatchSnapshotStore(overrideDirectory: directory)
        let receiver = SnapshotReceiver(session: nil, store: store)
        let goodData = try JSONEncoder().encode(Self.sampleDto)
        receiver.apply(data: goodData, receivedAt: Date(timeIntervalSince1970: 1))

        receiver.apply(data: Data("not json at all".utf8), receivedAt: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(receiver.snapshot, Self.sampleDto, "a bad push must not clobber a good, already-known snapshot")
        XCTAssertEqual(receiver.receivedAt?.timeIntervalSince1970, 1)
    }
}
