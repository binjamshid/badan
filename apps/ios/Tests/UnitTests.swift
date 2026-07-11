import XCTest
@testable import BADAN

/// Pure-function tests for the small pieces of duplicated cross-platform logic (the ones the
/// Android port must match): unit conversion, dedup overlap math, ULID encoding.
final class UnitTests: XCTestCase {

    // MARK: - Units

    func testEnergyConversion() throws {
        // 1 kcal = 4.184 kJ
        let kJ = try Units.convert(1, from: "kcal", to: "kJ")
        XCTAssertEqual(kJ, 4.184, accuracy: 0.001)
        let back = try Units.convert(kJ, from: "kJ", to: "kcal")
        XCTAssertEqual(back, 1, accuracy: 0.0001)
    }

    func testDurationConversion() throws {
        XCTAssertEqual(try Units.convert(3600, from: "s", to: "h"), 1, accuracy: 0.0001)
        XCTAssertEqual(try Units.convert(90, from: "min", to: "s"), 5400, accuracy: 0.0001)
    }

    func testMassConversion() throws {
        XCTAssertEqual(try Units.convert(1, from: "kg", to: "lb"), 2.2046, accuracy: 0.001)
    }

    func testDistanceConversion() throws {
        XCTAssertEqual(try Units.convert(1000, from: "m", to: "km"), 1, accuracy: 0.0001)
        XCTAssertEqual(try Units.convert(1, from: "mi", to: "m"), 1609.344, accuracy: 0.01)
    }

    func testTemperatureOffsetConversion() throws {
        XCTAssertEqual(try Units.convert(32, from: "degF", to: "degC"), 0, accuracy: 0.001)
        XCTAssertEqual(try Units.convert(100, from: "degC", to: "degF"), 212, accuracy: 0.001)
    }

    func testUnknownUnitPassesThroughToCanonical() {
        // Non-convertible/unknown units pass through unchanged (never crash ingestion).
        XCTAssertEqual(Units.toCanonical(97, from: "percent", canonical: "percent"), 97)
        XCTAssertEqual(Units.toCanonical(55, from: "bpm", canonical: "bpm"), 55)
    }

    func testIncompatibleDimensionsThrow() {
        XCTAssertThrowsError(try Units.convert(1, from: "kg", to: "m"))
    }

    // MARK: - Dedup overlap

    func testOverlapFullContainment() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = (start: base, end: base.addingTimeInterval(3600))
        let b = (start: base.addingTimeInterval(300), end: base.addingTimeInterval(3300))
        // b is inside a; overlap over min-duration (b) is 1.0
        XCTAssertEqual(DedupLite.overlap(a, b), 1.0, accuracy: 0.001)
    }

    func testOverlapDisjoint() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = (start: base, end: base.addingTimeInterval(3600))
        let b = (start: base.addingTimeInterval(7200), end: base.addingTimeInterval(10800))
        XCTAssertEqual(DedupLite.overlap(a, b), 0.0, accuracy: 0.001)
    }

    func testDedupReconcilePicksHigherPriority() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func session(_ id: String, source: String) -> Session {
            Session(id: id, kind: .sleepPrimary, startAt: now, endAt: now.addingTimeInterval(28_800),
                    tzId: "UTC", localNight: "2001-01-01",
                    provenance: Provenance(sourceId: source, ingestionPath: .platformStore,
                                           measuredAt: now, measuredTimezone: "UTC", recordedAt: now, ingestedAt: now),
                    updatedAt: now, originDeviceId: "d")
        }
        let watch = session("watch", source: "src_watch")
        let phone = session("phone", source: "src_iphone")
        let outcome = DedupLite.reconcile(sessions: [phone, watch]) { $0 == "src_watch" ? 100 : 50 }
        XCTAssertEqual(outcome.winnerId, "watch")
        XCTAssertEqual(outcome.suppressed.map { $0.loserId }, ["phone"])
    }

    // MARK: - ULID

    func testULIDIsSortableAndDecodable() throws {
        let early = ULID.generate(date: Date(timeIntervalSince1970: 1_000_000), rng: &Self.rng)
        let late = ULID.generate(date: Date(timeIntervalSince1970: 2_000_000), rng: &Self.rng)
        XCTAssertEqual(early.count, 26)
        XCTAssertTrue(early < late, "ULIDs sort by embedded time")
        let ts = try XCTUnwrap(ULID.timestamp(of: early))
        XCTAssertEqual(ts.timeIntervalSince1970, 1_000_000, accuracy: 1)
    }

    nonisolated(unsafe) static var rng = SystemRandomNumberGenerator()

    // MARK: - Baseline math

    func testMedianAndMAD() {
        // Odd count median is the middle value.
        XCTAssertEqual(BaselineEngine.median([3, 1, 2]), 2, accuracy: 0.0001)
        // MAD of a symmetric set.
        let data = [1.0, 2, 3, 4, 5]
        let center = BaselineEngine.median(data)
        XCTAssertEqual(center, 3, accuracy: 0.0001)
        XCTAssertEqual(BaselineEngine.mad(data, center: center), 1, accuracy: 0.0001)
    }
}
