import XCTest
@testable import BadanWatch

/// `TodayViewState.build` is the single place `TodayView`'s content is decided — a pure function of
/// (snapshot, now, language), so every branch is directly testable here without SwiftUI or a
/// simulator.
final class TodayViewStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNilSnapshotProducesNeverSyncedWithThreeNoDataRows() {
        let state = TodayViewState.build(snapshot: nil, now: now, isArabic: false)
        XCTAssertTrue(state.neverSynced)
        XCTAssertFalse(state.isStale)
        XCTAssertNil(state.sentence)
        XCTAssertEqual(state.rows.count, 3)
        for row in state.rows {
            XCTAssertNil(row.valueText, "\(row.kind) must show no fabricated value for a nil snapshot")
            XCTAssertFalse(row.noDataText.isEmpty)
        }
    }

    func testFullSnapshotProducesAllThreeRowsWithRealValues() {
        let dto = AmbientSnapshotDto(
            generatedAt: now.addingTimeInterval(-60), language: "en",
            readiness: RingSnapshot(score: 72.4, provisional: false),
            sentence: SentenceSnapshot(en: "Steady day.", ar: "يوم مستقر."),
            sleep: SleepSnapshot(durationMinutes: 435, score: 78, provisional: false),
            medsDue: nil, effort: EffortSnapshot(score: 58.6, provisional: false))

        let state = TodayViewState.build(snapshot: dto, now: now, isArabic: false)
        XCTAssertFalse(state.neverSynced)
        XCTAssertFalse(state.isStale)
        XCTAssertEqual(state.sentence, "Steady day.")

        let readiness = state.rows.first { $0.kind == .readiness }
        XCTAssertEqual(readiness?.valueText, "72")
        XCTAssertFalse(readiness?.provisional ?? true)

        let effort = state.rows.first { $0.kind == .effort }
        XCTAssertEqual(effort?.valueText, "59", "effort score must round the same way readiness does")

        let sleep = state.rows.first { $0.kind == .sleep }
        XCTAssertNotNil(sleep?.valueText)
        XCTAssertTrue(sleep?.valueText?.contains("7") ?? false, "435 minutes must format as roughly 7h")
    }

    func testArabicSnapshotSelectsTheArabicSentenceAndRowTitles() {
        let dto = AmbientSnapshotDto(
            generatedAt: now, language: "ar", readiness: RingSnapshot(score: 50, provisional: false),
            sentence: SentenceSnapshot(en: "Steady day.", ar: "يوم مستقر."),
            sleep: nil, medsDue: nil, effort: nil)

        let state = TodayViewState.build(snapshot: dto, now: now, isArabic: true)
        XCTAssertEqual(state.sentence, "يوم مستقر.")
        let readiness = state.rows.first { $0.kind == .readiness }
        XCTAssertEqual(readiness?.title, "الاستعداد")
    }

    /// A snapshot the phone genuinely computed but with no effort score yet (e.g. only the
    /// reduced-input activity-load variant existed phone-side) must show effort's honest "no data"
    /// row alongside a real readiness value — one missing field must never blank the whole screen.
    func testPartialSnapshotDegradesOnlyTheMissingRowsIndependently() {
        let dto = AmbientSnapshotDto(
            generatedAt: now, language: "en", readiness: RingSnapshot(score: 80, provisional: true),
            sentence: nil, sleep: nil, medsDue: nil, effort: nil)

        let state = TodayViewState.build(snapshot: dto, now: now, isArabic: false)
        XCTAssertFalse(state.neverSynced, "a real (if partial) snapshot is not the same as never having synced")
        XCTAssertNil(state.sentence)

        let readiness = state.rows.first { $0.kind == .readiness }
        XCTAssertEqual(readiness?.valueText, "80")
        XCTAssertTrue(readiness?.provisional ?? false)

        let effort = state.rows.first { $0.kind == .effort }
        XCTAssertNil(effort?.valueText)
        let sleep = state.rows.first { $0.kind == .sleep }
        XCTAssertNil(sleep?.valueText)
    }

    func testStaleSnapshotIsFlaggedStaleNotNeverSynced() {
        let old = now.addingTimeInterval(-(SnapshotFreshness.staleAfter + 3600))
        let dto = AmbientSnapshotDto(
            generatedAt: old, language: "en", readiness: RingSnapshot(score: 40, provisional: false),
            sentence: nil, sleep: nil, medsDue: nil, effort: nil)

        let state = TodayViewState.build(snapshot: dto, now: now, isArabic: false)
        XCTAssertTrue(state.isStale)
        XCTAssertFalse(state.neverSynced)
        XCTAssertFalse(state.freshnessLabel.isEmpty)
        // Old data is still shown, honestly labelled — never blanked out just for being stale.
        XCTAssertEqual(state.rows.first { $0.kind == .readiness }?.valueText, "40")
    }

    func testFreshSnapshotFreshnessLabelUsesTheUpdatedTemplateNotTheStaleOne() {
        let dto = AmbientSnapshotDto(
            generatedAt: now.addingTimeInterval(-120), language: "en",
            readiness: nil, sentence: nil, sleep: nil, medsDue: nil, effort: nil)
        let state = TodayViewState.build(snapshot: dto, now: now, isArabic: false)
        XCTAssertTrue(state.freshnessLabel.hasPrefix("Updated"), "got: \(state.freshnessLabel)")
    }
}
