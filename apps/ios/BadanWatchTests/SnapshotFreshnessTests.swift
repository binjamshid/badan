import XCTest
@testable import BadanWatch

/// A22/EPIC-42's honest-degradation requirement, pinned as a contract test: `SnapshotFreshness`
/// is the ONE place this app decides "never synced" vs. "fresh" vs. "stale" (see that type's own
/// header for why the age threshold is new, narrowly-scoped logic rather than borrowed from
/// anywhere else in this codebase).
final class SnapshotFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNeverSyncedWhenGeneratedAtIsNil() {
        XCTAssertEqual(SnapshotFreshness.state(generatedAt: nil, now: now), .neverSynced)
    }

    func testFreshJustUnderTheStaleThreshold() {
        let generatedAt = now.addingTimeInterval(-(SnapshotFreshness.staleAfter - 1))
        guard case .fresh(let age) = SnapshotFreshness.state(generatedAt: generatedAt, now: now) else {
            return XCTFail("expected .fresh just under the threshold")
        }
        XCTAssertEqual(age, SnapshotFreshness.staleAfter - 1, accuracy: 0.001)
    }

    func testStaleJustOverTheStaleThreshold() {
        let generatedAt = now.addingTimeInterval(-(SnapshotFreshness.staleAfter + 1))
        guard case .stale(let age) = SnapshotFreshness.state(generatedAt: generatedAt, now: now) else {
            return XCTFail("expected .stale just over the threshold")
        }
        XCTAssertEqual(age, SnapshotFreshness.staleAfter + 1, accuracy: 0.001)
    }

    func testExactlyAtTheThresholdIsStillFresh() {
        // `age > staleAfter` (strictly greater) is the documented rule — exactly at the boundary
        // must still read as fresh, not stale.
        let generatedAt = now.addingTimeInterval(-SnapshotFreshness.staleAfter)
        guard case .fresh = SnapshotFreshness.state(generatedAt: generatedAt, now: now) else {
            return XCTFail("expected exactly-at-threshold to still be .fresh")
        }
    }

    /// A `generatedAt` in the future (clock skew, or a snapshot built "now" and compared against a
    /// slightly earlier `now`) must never yield a negative age — that would read as nonsense
    /// ("-3 minutes ago" is not an honest label).
    func testFutureGeneratedAtClampsAgeToZeroRatherThanGoingNegative() {
        let generatedAt = now.addingTimeInterval(60)
        guard case .fresh(let age) = SnapshotFreshness.state(generatedAt: generatedAt, now: now) else {
            return XCTFail("expected .fresh for a future timestamp")
        }
        XCTAssertEqual(age, 0)
    }

    func testRelativeLabelProducesNonEmptyStringsInBothLanguages() {
        let past = now.addingTimeInterval(-3600)
        let en = SnapshotFreshness.relativeLabel(past, isArabic: false, now: now)
        let ar = SnapshotFreshness.relativeLabel(past, isArabic: true, now: now)
        XCTAssertFalse(en.isEmpty)
        XCTAssertFalse(ar.isEmpty)
        XCTAssertNotEqual(en, ar, "the two languages must not silently produce identical output")
    }
}
