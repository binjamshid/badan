import XCTest
@testable import BADAN

/// Headless-testable coverage for the panel-review-2026-07 logging fixes: Arabic-digit/decimal
/// parsing shared by every numeric log field (BUG-15), and the symptom trend aggregation that
/// replaced a permanently-dead derived-series read (STUB-05).
final class LoggingFixTests: XCTestCase {

    // MARK: - BUG-15: DecimalParsing

    func testParsesEasternArabicDigits() {
        // ١٢٣.٤٥ — Eastern Arabic-Indic digits with a Western decimal point.
        XCTAssertEqual(DecimalParsing.parse("١٢٣.٤٥"), 123.45)
    }

    func testParsesExtendedArabicIndicDigits() {
        // ۱۲۳ — Extended Arabic-Indic (Persian/Urdu) digits.
        XCTAssertEqual(DecimalParsing.parse("۱۲۳"), 123)
    }

    func testParsesArabicDecimalSeparator() {
        // ٧٥٫٥ — Eastern Arabic digits with the Arabic decimal separator ٫ (U+066B).
        XCTAssertEqual(DecimalParsing.parse("٧٥٫٥"), 75.5)
    }

    func testDropsArabicThousandsSeparator() {
        // ١٬٢٣٤ — Arabic thousands separator ٬ (U+066C) is dropped, not treated as a decimal.
        XCTAssertEqual(DecimalParsing.parse("١٬٢٣٤"), 1234)
    }

    func testWesternCommaStillTreatedAsDecimalSeparator() {
        // Pre-fix behavior (`replacingOccurrences(of: ",", with: ".")`) must not regress.
        XCTAssertEqual(DecimalParsing.parse("70,5"), 70.5)
    }

    func testMixedArabicAndWesternDigitsInOneString() {
        // A user correcting one digit on an Arabic-locale keyboard can end up with a mix.
        XCTAssertEqual(DecimalParsing.parse("1٢3"), 123)
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(DecimalParsing.parse("  42  "), 42)
    }

    func testRejectsGarbageInput() {
        XCTAssertNil(DecimalParsing.parse(""))
        XCTAssertNil(DecimalParsing.parse("abc"))
        XCTAssertNil(DecimalParsing.parse("--12"))
        XCTAssertNil(DecimalParsing.parse("١٢.٣.٤"))
    }

    func testParseIntFoldsArabicDigits() {
        XCTAssertEqual(DecimalParsing.parseInt("٤٥"), 45)
        XCTAssertEqual(DecimalParsing.parseInt("۹۰"), 90)
        XCTAssertNil(DecimalParsing.parseInt("not a number"))
    }

    // MARK: - STUB-05: symptom trend aggregation

    private func symptom(daysAgo: Double, severity: Int, now: Date) -> SymptomEntry {
        SymptomEntry(id: ULID.newID(), symptomId: "headache", severity: severity,
                     occurredAt: now.addingTimeInterval(-daysAgo * 86_400), tzId: "UTC",
                     updatedAt: now, originDeviceId: "test-device")
    }

    func testTrendAggregatesEmptyWindowReturnsNil() {
        let now = Date()
        let entries = [symptom(daysAgo: 20, severity: 5, now: now)] // outside the 14-day window
        let (count, avg) = SymptomLogViewModel.trendAggregates(from: entries, windowStart: now.addingTimeInterval(-14 * 86_400))
        XCTAssertNil(count)
        XCTAssertNil(avg)
    }

    func testTrendAggregatesCountsOnlyEntriesInWindow() {
        let now = Date()
        let windowStart = now.addingTimeInterval(-14 * 86_400)
        let entries = [
            symptom(daysAgo: 1, severity: 4, now: now),
            symptom(daysAgo: 5, severity: 6, now: now),
            symptom(daysAgo: 20, severity: 10, now: now), // outside window — must not count
        ]
        let (count, avg) = SymptomLogViewModel.trendAggregates(from: entries, windowStart: windowStart)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(avg ?? .nan, 5.0, accuracy: 0.0001)
    }

    func testTrendAggregatesIncludesEntryExactlyAtWindowStart() {
        let now = Date()
        let windowStart = now.addingTimeInterval(-14 * 86_400)
        let entries = [SymptomEntry(id: ULID.newID(), symptomId: "headache", severity: 7,
                                    occurredAt: windowStart, tzId: "UTC", updatedAt: now, originDeviceId: "d")]
        let (count, avg) = SymptomLogViewModel.trendAggregates(from: entries, windowStart: windowStart)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(avg, 7.0)
    }
}
