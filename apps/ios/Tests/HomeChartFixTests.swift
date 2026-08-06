import XCTest
@testable import BADAN

/// Headless-testable coverage for the panel-review-2026-07 Home fixes (fix/panel-review-2026-07):
/// the Arabic plural helper (FIX-14), the staleness-bound pure function (UX-01-Home), and
/// `MetricChart`'s duplicate-timestamp handling (BUG-19). View-only changes (Dynamic Type
/// tokens, module visibility, the tappable DepthBadge) aren't exercised here since they need a
/// rendered hierarchy — see `ViewModelPerformanceTests`/`PipelineTests` for this repo's existing
/// pattern of testing the pure query/format cores rather than SwiftUI bodies directly.
///
/// It also covers `MetricChartAccessibility`, the chart's spoken layer, for the same reason: the
/// `AXChartDescriptor` it feeds cannot be built headlessly, but the strings it announces can be
/// asserted on their own — and an English literal or an Eastern-digit numeral in that layer is
/// invisible to everyone who reads the screen with their eyes, so nothing else would catch it.
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

    // MARK: - The chart's spoken layer

    private func containsEasternArabicDigits(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) }
    }

    /// Everything the audio graph announces is bilingual. The axis titles and the series name were
    /// English literals inside the accessibility layer, so every chart announced "Date" and "Value"
    /// in English to an Arabic VoiceOver reader.
    func testAudioGraphAxisTitlesAndSeriesNameCarryBothLanguages() {
        let strings: [(String, LocalizedString)] = [
            ("dateAxisTitle", MetricChartAccessibility.dateAxisTitle),
            ("valueAxisTitle", MetricChartAccessibility.valueAxisTitle),
            ("namedSeries", MetricChartAccessibility.namedSeries),
            ("unnamedSeries", MetricChartAccessibility.unnamedSeries),
        ]
        for (name, text) in strings {
            XCTAssertFalse(text.en.isEmpty, "\(name) has no English")
            XCTAssertFalse(text.ar.isEmpty, "\(name) has no Arabic")
            XCTAssertNotEqual(text.en, text.ar, "\(name) is untranslated")
            XCTAssertTrue(text.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(name)'s Arabic is not in Arabic script")
        }
    }

    /// The series is named after the unit the chart was given, and is never left empty: an unnamed
    /// series is announced as a bare ordinal, which tells a listener nothing about what they hear.
    func testAudioGraphSeriesIsNamedAfterTheUnitInScope() {
        for language in [AppLanguage.en, .ar] {
            XCTAssertTrue(MetricChartAccessibility.seriesName(unit: "bpm", language: language).contains("bpm"),
                          "the series name states the unit it is plotting")
            XCTAssertFalse(MetricChartAccessibility.seriesName(unit: nil, language: language).isEmpty,
                           "a chart with no unit still names its series")
            XCTAssertFalse(MetricChartAccessibility.seriesName(unit: "", language: language).isEmpty)
        }
        XCTAssertNotEqual(MetricChartAccessibility.seriesName(unit: "bpm", language: .en),
                          MetricChartAccessibility.seriesName(unit: "bpm", language: .ar),
                          "the name is translated, not one string shown twice")
    }

    /// FEAT-244's contract, at the call site that was breaking it: the y values the audio graph
    /// speaks are Latin-numeral whatever the user's Arabic-Indic DISPLAY preference says, because
    /// they are spoken and never drawn. The old code called
    /// `Numerals.format(value, language:arabicDigits:)` here, feeding Eastern Arabic-Indic glyphs
    /// into VoiceOver — the digit form `accessibleSpokenForm` exists to keep out of speech.
    func testAudioGraphValuesAreSpokenInLatinNumerals() {
        XCTAssertEqual(MetricChartAccessibility.spokenValue(72, unit: "bpm"), "72 bpm")
        XCTAssertEqual(MetricChartAccessibility.spokenValue(72, unit: nil), "72")
        for value in [0.0, 7.0, 72.0, 1_234.0] {
            let spoken = MetricChartAccessibility.spokenValue(value, unit: "bpm")
            XCTAssertFalse(containsEasternArabicDigits(spoken),
                           "Eastern Arabic-Indic glyphs reached a spoken string: \(spoken)")
            XCTAssertEqual(spoken, Numerals.accessibleSpokenForm(value) + " bpm",
                           "the spoken value is the spoken form, not the display form")
        }
    }
}
