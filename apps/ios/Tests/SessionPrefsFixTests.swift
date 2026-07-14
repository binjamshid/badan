import XCTest
@testable import BADAN

/// Headless-testable coverage for the panel-review-2026-07 STUB-06 fix: wiring the previously
/// dead `CustomizationProfile.sessionPreferences` plumbing into MetricDetail's period picker and
/// Export's format/range pickers. Covers the two pure, factored-out mapping helpers rather than
/// the views themselves (both have SwiftUI-only side effects — `env.update`/`.onAppear` — that
/// aren't reachable headlessly).
final class SessionPrefsFixTests: XCTestCase {

    // MARK: - STUB-06a: MetricDetail period-memory read side

    func testRememberedPeriodReturnsDefaultForUnseenMetric() {
        XCTAssertEqual(SessionPeriodMemory.rememberedPeriod(for: "body.weight", in: [:]), 30)
    }

    func testRememberedPeriodReturnsDefaultWhenMetricNotInMap() {
        let map = ["sleep.time_asleep": 90]
        XCTAssertEqual(SessionPeriodMemory.rememberedPeriod(for: "body.weight", in: map), 30)
    }

    func testRememberedPeriodRoundTripsAStoredValue() {
        let map = ["sleep.time_asleep": 7, "body.weight": 90]
        XCTAssertEqual(SessionPeriodMemory.rememberedPeriod(for: "sleep.time_asleep", in: map), 7)
        XCTAssertEqual(SessionPeriodMemory.rememberedPeriod(for: "body.weight", in: map), 90)
    }

    // MARK: - STUB-06b: Export format/range mapping fallbacks

    func testRememberedFormatFallsBackWhenNil() {
        XCTAssertEqual(SessionExportMemory.rememberedFormat(nil, fallback: .csv), .csv)
    }

    func testRememberedFormatFallsBackOnUnrecognizedRawValue() {
        // Guards against a future removed/renamed case, or corrupted persisted state, silently
        // crashing instead of degrading to the current default.
        XCTAssertEqual(SessionExportMemory.rememberedFormat("xml", fallback: .csv), .csv)
    }

    func testRememberedFormatRoundTripsAStoredValue() {
        XCTAssertEqual(SessionExportMemory.rememberedFormat("json", fallback: .csv), .json)
        XCTAssertEqual(SessionExportMemory.rememberedFormat("csv", fallback: .json), .csv)
    }

    func testRememberedRangeFallsBackWhenNil() {
        XCTAssertEqual(SessionExportMemory.rememberedRange(nil, fallback: .last30), .last30)
    }

    func testRememberedRangeFallsBackOnUnrecognizedRawValue() {
        XCTAssertEqual(SessionExportMemory.rememberedRange("lastWeek", fallback: .last30), .last30)
    }

    func testRememberedRangeRoundTripsAStoredValue() {
        XCTAssertEqual(SessionExportMemory.rememberedRange("last90", fallback: .last30), .last90)
        XCTAssertEqual(SessionExportMemory.rememberedRange("all", fallback: .last30), .all)
        XCTAssertEqual(SessionExportMemory.rememberedRange("custom", fallback: .last30), .custom)
    }
}
