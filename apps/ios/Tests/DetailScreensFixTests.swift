import XCTest
@testable import BADAN

/// Headless-testable coverage for the panel-review-2026-07 detail-screen fixes: Arabic search
/// folding in `MetricRegistry` (FIX-13) and the shared friendly load-error copy (BUG-14).
final class DetailScreensFixTests: XCTestCase {

    // MARK: - FIX-13: Arabic search folding

    private func makeDef(metricId: String, nameEn: String, nameAr: String) -> MetricDefinition {
        MetricDefinition(
            metricId: metricId, family: "body", kind: .rawSample, canonicalUnit: "kg",
            displayUnits: ["kg"], nameEn: nameEn, nameAr: nameAr, casualLabel: nameEn,
            preciseLabel: nameEn, chartHint: .line, baselineEligible: false,
            sensitiveClass: .normal)
    }

    /// A tashkeel-bearing (diacritic-marked) query must still match a stored Arabic name with no
    /// diacritics — before FIX-13, Arabic search compared raw substrings with no folding at all,
    /// so a query like "الوَزْن" (with fatha/sukun marks) silently failed to match "الوزن".
    func testArabicSearchFoldsTashkeel() {
        let registry = MetricRegistry(metrics: [
            makeDef(metricId: "test.weight", nameEn: "Weight", nameAr: "الوزن"),
            makeDef(metricId: "test.other", nameEn: "Other thing", nameAr: "شيء آخر"),
        ])

        let diacriticQuery = "الوَزْن"
        let results = registry.search(diacriticQuery)

        XCTAssertTrue(results.contains { $0.metricId == "test.weight" },
                      "Tashkeel-bearing Arabic query should match the undiacritized stored name")
        XCTAssertFalse(results.contains { $0.metricId == "test.other" })
    }

    /// Plain (no-diacritic) Arabic search keeps working exactly as before — folding must not
    /// regress the already-correct exact-match case.
    func testArabicSearchStillMatchesPlainQuery() {
        let registry = MetricRegistry(metrics: [
            makeDef(metricId: "test.weight", nameEn: "Weight", nameAr: "الوزن"),
        ])
        XCTAssertTrue(registry.search("الوزن").contains { $0.metricId == "test.weight" })
    }

    // MARK: - BUG-14: shared friendly load-error copy

    /// Every screen that used to render a raw `String(describing: error)` now shares one
    /// bilingual "couldn't load" string and retry label instead of inventing its own wording —
    /// assert both languages are populated (never empty) and distinct from each other.
    func testLoadErrorCopyIsBilingual() {
        XCTAssertFalse(LoadErrorCopy.message.en.isEmpty)
        XCTAssertFalse(LoadErrorCopy.message.ar.isEmpty)
        XCTAssertNotEqual(LoadErrorCopy.message.en, LoadErrorCopy.message.ar)

        XCTAssertFalse(LoadErrorCopy.retry.en.isEmpty)
        XCTAssertFalse(LoadErrorCopy.retry.ar.isEmpty)
        XCTAssertNotEqual(LoadErrorCopy.retry.en, LoadErrorCopy.retry.ar)
    }
}
