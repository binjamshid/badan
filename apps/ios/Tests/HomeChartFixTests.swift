import XCTest
@testable import BADAN

/// Headless-testable coverage for the panel-review-2026-07 Home fixes (fix/panel-review-2026-07):
/// the Arabic plural helper (FIX-14), the staleness-bound pure function (UX-01-Home), and
/// `MetricChart`'s duplicate-timestamp handling (BUG-19). View-only changes (Dynamic Type
/// tokens, module visibility, the tappable DepthBadge) aren't exercised here since they need a
/// rendered hierarchy — see `ViewModelPerformanceTests`/`PipelineTests` for this repo's existing
/// pattern of testing the pure query/format cores rather than SwiftUI bodies directly.
final class HomeChartFixTests: XCTestCase {
    private func env(language: AppLanguage) -> (format: ValueFormatter, language: AppLanguage) {
        let profile = CustomizationProfile(language: language)
        let registry = MetricRegistry.shared
        return (ValueFormatter(profile: profile, registry: registry), language)
    }

    // MARK: - FIX-14: Arabic count-noun agreement

    /// English never changes shape — always "{n} of {total} {enNoun}" regardless of magnitude.
    func testArabicCountEnglishUnaffectedByMagnitude() {
        let (format, language) = env(language: .en)
        for total in [1, 2, 5, 11] {
            let text = HomeArabicCount.phrase(
                n: 1, total: total, language: language, format: format,
                enNoun: "days", arSingular: "-", arDual: "-", arPlural: "-", arMany: "-")
            XCTAssertEqual(text, "1 of \(total) days")
        }
    }

    /// The Arabic noun form is keyed off `total` (the denominator), not `n` — that's the actual
    /// bug: the old code hardcoded the 3–10 plural regardless of which bucket `total` fell in.
    func testArabicCountAgreesWithTotalNotN() {
        let (format, language) = env(language: .ar)

        func phrase(total: Int) -> String {
            HomeArabicCount.phrase(
                n: 1, total: total, language: language, format: format,
                enNoun: "days", arSingular: "يوم", arDual: "يومان", arPlural: "أيام", arMany: "يوماً")
        }

        XCTAssertTrue(phrase(total: 1).hasSuffix("يوم"))
        XCTAssertTrue(phrase(total: 2).hasSuffix("يومان"))
        XCTAssertTrue(phrase(total: 7).hasSuffix("أيام"))    // 3...10
        XCTAssertTrue(phrase(total: 14).hasSuffix("يوماً"))  // 11+
    }

    /// `n` still appears in the rendered string even when it isn't what drives noun agreement.
    func testArabicCountStillRendersN() {
        let (format, language) = env(language: .ar)
        let text = HomeArabicCount.phrase(
            n: 3, total: 7, language: language, format: format,
            enNoun: "days", arSingular: "يوم", arDual: "يومان", arPlural: "أيام", arMany: "يوماً")
        XCTAssertTrue(text.hasPrefix("3"))
    }

    // MARK: - UX-01-Home: staleness bound

    func testStalenessFreshWithinBound() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recordEnd = now.addingTimeInterval(-3_600) // 1h old
        XCTAssertTrue(HomeStaleness.isFresh(recordEnd, now: now, maxAge: HomeStaleness.sleepFallbackMaxAge))
    }

    func testStalenessStaleBeyondSleepBound() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recordEnd = now.addingTimeInterval(-49 * 3_600) // 49h old > 48h sleep bound
        XCTAssertFalse(HomeStaleness.isFresh(recordEnd, now: now, maxAge: HomeStaleness.sleepFallbackMaxAge))
    }

    func testStalenessKeyMetricBoundIsOneWeek() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let justInside = now.addingTimeInterval(-6 * 86_400 - 3_600)
        let justOutside = now.addingTimeInterval(-8 * 86_400)
        XCTAssertTrue(HomeStaleness.isFresh(justInside, now: now, maxAge: HomeStaleness.keyMetricMaxAge))
        XCTAssertFalse(HomeStaleness.isFresh(justOutside, now: now, maxAge: HomeStaleness.keyMetricMaxAge))
    }

    func testStalenessExactBoundaryIsFresh() {
        // <= maxAge counts as fresh (not strictly less-than) — exact equality shouldn't flip.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recordEnd = now.addingTimeInterval(-HomeStaleness.keyMetricMaxAge)
        XCTAssertTrue(HomeStaleness.isFresh(recordEnd, now: now, maxAge: HomeStaleness.keyMetricMaxAge))
    }

    // MARK: - BUG-19: MetricChart duplicate-timestamp points

    /// Two points sharing an identical timestamp used to collide under `Point`'s
    /// `date`-derived `Identifiable` id; the fix (index-based `ForEach` identity in
    /// `MetricChart.unscaledChart`) is a rendering-loop change, but this at least guards that
    /// the upstream `points` array itself still keeps both entries (nothing here silently
    /// dedupes by date before the chart ever gets to render them).
    func testMetricChartKeepsDuplicateTimestampPoints() {
        let sharedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let series: [(date: Date, value: Double)] = [
            (date: sharedDate, value: 10),
            (date: sharedDate, value: 20),
        ]
        let chart = MetricChart(series: series, language: .en)
        XCTAssertEqual(chart.points.count, 2)
    }
}
