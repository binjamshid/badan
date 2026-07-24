import XCTest
@testable import BadanWatch

final class WatchSnapshotStoreTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-watch-cache-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let sampleDto = AmbientSnapshotDto(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000), language: "en",
        readiness: RingSnapshot(score: 66, provisional: false), sentence: nil, sleep: nil,
        medsDue: nil, effort: EffortSnapshot(score: 33, provisional: true))

    func testWriteThenReadRoundTripsTheSnapshotAndReceivedAt() throws {
        let store = WatchSnapshotStore(overrideDirectory: directory)
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_500)
        store.write(snapshot: Self.sampleDto, receivedAt: receivedAt)

        let readBack = try XCTUnwrap(store.read())
        XCTAssertEqual(readBack.snapshot, Self.sampleDto)
        XCTAssertEqual(readBack.receivedAt.timeIntervalSince1970, receivedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testReadReturnsNilWhenNothingHasEverBeenWritten() {
        let store = WatchSnapshotStore(overrideDirectory: directory)
        XCTAssertNil(store.read())
    }

    func testASecondWriteOverwritesTheFirst() {
        let store = WatchSnapshotStore(overrideDirectory: directory)
        store.write(snapshot: Self.sampleDto, receivedAt: Date(timeIntervalSince1970: 100))
        let newer = AmbientSnapshotDto(
            generatedAt: Date(timeIntervalSince1970: 1_700_001_000), language: "ar",
            readiness: RingSnapshot(score: 90, provisional: false), sentence: nil, sleep: nil,
            medsDue: nil, effort: nil)
        store.write(snapshot: newer, receivedAt: Date(timeIntervalSince1970: 200))

        let readBack = store.read()
        XCTAssertEqual(readBack?.snapshot, newer)
        XCTAssertEqual(readBack?.receivedAt.timeIntervalSince1970, 200)
    }
}
