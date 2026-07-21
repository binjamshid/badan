import XCTest
import PDFKit
@testable import BADAN

/// EPIC-31 — the report renderer. Model snapshots are covered in `ReportBuilderTests`; here the
/// concern is the shareable artifact: the Arabic document must be RTL, both languages must carry the
/// evidence refs, and the PDF stage must actually produce a PDF.
final class ReportRendererTests: XCTestCase {
    private let tz = "UTC"
    private let now = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07-14 03:33 UTC, ISO 2026-W29

    private func model(empty: Bool = false) -> ReportModel {
        let period = ReportPeriod.week(containing: now, tz: tz)
        let prior = ReportPeriod.prior(period, tz: tz)
        if empty {
            return ReportBuilder.build(.init(period: period, prior: prior, currentByMetric: [:],
                                             priorByMetric: [:], adherence: [], generatedAt: now))
        }
        func dv(_ day: String, _ v: Double, id: String) -> DerivedValue {
            DerivedValue(id: id, metricId: MetricID.sleepPerformance, value: v, unit: "score_0_100",
                         periodKey: "day:" + day, algorithmId: "t", algorithmVersion: "1", computedAt: now,
                         updatedAt: now, originDeviceId: "d")
        }
        let sleep = [dv(period.dayKeys[0], 70, id: "ev-alpha"),
                     dv(period.dayKeys[1], 80, id: "ev-beta"),
                     dv(period.dayKeys[2], 90, id: "ev-gamma")]
        return ReportBuilder.build(.init(period: period, prior: prior,
                                         currentByMetric: [MetricID.sleepPerformance: sleep],
                                         priorByMetric: [:], adherence: nil, generatedAt: now))
    }

    func testArabicHTMLIsRTL() {
        let html = ReportRenderer.renderHTML(model(), language: .ar, arabicDigits: true)
        XCTAssertTrue(html.contains("dir=\"rtl\""), "Arabic report must be dir=rtl")
        XCTAssertTrue(html.contains("lang=\"ar\""))
        XCTAssertTrue(html.contains("direction: rtl"))
        XCTAssertTrue(html.contains("النوم"), "Arabic section title must appear")
    }

    func testEnglishHTMLIsLTR() {
        let html = ReportRenderer.renderHTML(model(), language: .en, arabicDigits: false)
        XCTAssertTrue(html.contains("dir=\"ltr\""))
        XCTAssertTrue(html.contains("lang=\"en\""))
        XCTAssertTrue(html.contains("Sleep"))
    }

    func testHTMLCarriesEvidenceRefs() {
        let html = ReportRenderer.renderHTML(model(), language: .en, arabicDigits: false)
        for id in ["ev-alpha", "ev-beta", "ev-gamma"] {
            XCTAssertTrue(html.contains(id), "evidence ref \(id) must be present in the artifact")
        }
        XCTAssertTrue(html.contains("data-evidence"))
    }

    /// Every claim in the rendered artifact names the rows it rests on — in BOTH languages, since
    /// the Arabic report is the same report and must carry the same evidence, not a prettier
    /// summary of it. Mirrored by `ReportRendererTest.everyClaimCarriesItsEvidenceInBothLanguages`.
    func testEveryClaimCarriesItsEvidenceInBothLanguages() {
        for language in [AppLanguage.en, .ar] {
            let html = ReportRenderer.renderHTML(model(), language: language, arabicDigits: language == .ar)
            let claims = html.components(separatedBy: "class=\"narrative\"").count - 1
            let evidenceLines = html.components(separatedBy: "class=\"evidence\"").count - 1
            XCTAssertGreaterThan(claims, 0, "\(language): expected at least one claim")
            XCTAssertEqual(evidenceLines, claims, "\(language): every claim needs an evidence line")
            for id in ["ev-alpha", "ev-beta", "ev-gamma"] {
                XCTAssertTrue(html.contains(id), "\(language): evidence must name the real rows")
            }
        }
    }

    /// The renderer's offline guarantee, checked rather than asserted in a comment: a report is an
    /// export artifact GENERATED offline (D-8 / §8.3), so the document it produces must reference
    /// nothing outside itself — no image, stylesheet, script or absolute URL that a PDF stage (or a
    /// viewer) would have to fetch. `Sources/Export/`'s zero-network lint covers the imports; this
    /// covers the bytes they produce. Mirrored by `ReportRendererTest.documentIsSelfContainedAndOffline`.
    func testRenderedDocumentIsSelfContainedAndOffline() {
        for language in [AppLanguage.en, .ar] {
            for empty in [false, true] {
                let html = ReportRenderer.renderHTML(model(empty: empty), language: language,
                                                     arabicDigits: language == .ar)
                for token in ["<img", "<script", "<link", "http://", "https://"] {
                    XCTAssertFalse(html.contains(token),
                                   "\(language)/empty=\(empty): a report artifact must reference nothing external, found \(token)")
                }
            }
        }
    }

    /// The disclaimer is not optional: every report, every language, empty or not, says what it is
    /// and is not — and says it last, where a reader lands after the claims.
    func testEveryDocumentEndsWithTheDisclaimer() {
        for language in [AppLanguage.en, .ar] {
            for empty in [false, true] {
                let html = ReportRenderer.renderHTML(model(empty: empty), language: language,
                                                     arabicDigits: language == .ar)
                XCTAssertTrue(html.contains(ReportPresentation.disclaimer.resolved(language)),
                              "\(language)/empty=\(empty) must carry the disclaimer")
                guard let disclaimer = html.range(of: "class=\"disclaimer\"") else {
                    return XCTFail("\(language)/empty=\(empty): no disclaimer block")
                }
                // An empty report has no claims to sit below, so this half applies only when there are.
                if let lastClaim = html.range(of: "class=\"narrative\"", options: .backwards) {
                    XCTAssertGreaterThan(disclaimer.lowerBound, lastClaim.lowerBound,
                                         "\(language): the disclaimer sits below the claims")
                }
            }
        }
    }

    func testEmptyWeekHTMLShowsHonestMessage() {
        let en = ReportRenderer.renderHTML(model(empty: true), language: .en, arabicDigits: false)
        XCTAssertTrue(en.contains("Not enough logged this week"))
        let ar = ReportRenderer.renderHTML(model(empty: true), language: .ar, arabicDigits: true)
        XCTAssertTrue(ar.contains("dir=\"rtl\""))
        XCTAssertTrue(ar.contains("لا توجد بيانات كافية"))
    }

    @MainActor
    func testPDFRendersForBothLanguages() {
        for language in [AppLanguage.en, .ar] {
            let data = ReportRenderer.renderPDF(model(), language: language, arabicDigits: language == .ar)
            XCTAssertGreaterThan(data.count, 0, "\(language) PDF must not be empty")
            // A well-formed PDF starts with the "%PDF" magic.
            let header = data.prefix(4)
            XCTAssertEqual(header, Data("%PDF".utf8), "\(language) output must be a PDF")
        }
    }

    /// The claim the markup assertions stand in for, checked on the artifact itself: in the Arabic
    /// PDF the title line is laid against the RIGHT margin, and in the English one against the left.
    /// `dir="rtl"` in the markup is only a promise until the print formatter honours it, and that is
    /// exactly the step that is easy to get wrong — so this reads the produced page back with
    /// PDFKit and compares where the first line actually sits on the page.
    @MainActor
    func testArabicPDFLaysTheTitleAgainstTheRightMargin() throws {
        func titleBounds(_ language: AppLanguage) throws -> (box: CGRect, page: CGRect) {
            let data = ReportRenderer.renderPDF(model(), language: language, arabicDigits: language == .ar)
            let document = try XCTUnwrap(PDFDocument(data: data), "\(language) output must parse as a PDF")
            let page = try XCTUnwrap(document.page(at: 0))
            let pageBox = page.bounds(for: .mediaBox)
            // The first character of the page is the title's leading glyph; its box tells us which
            // margin the line was laid from.
            XCTAssertGreaterThan(page.numberOfCharacters, 0, "\(language) page must carry text")
            return (page.characterBounds(at: 0), pageBox)
        }

        let (arBox, arPage) = try titleBounds(.ar)
        let (enBox, enPage) = try titleBounds(.en)
        XCTAssertGreaterThan(arBox.midX, arPage.midX,
                             "the Arabic title must start from the right margin, not the left")
        XCTAssertLessThan(enBox.midX, enPage.midX,
                          "the English title must start from the left margin")
    }

    @MainActor
    func testEmptyWeekPDFStillRenders() {
        let data = ReportRenderer.renderPDF(model(empty: true), language: .ar, arabicDigits: true)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))
    }

    // MARK: - Counted nouns

    /// A report counts days, records and doses, and a week's counts sit in the 3–10 band where
    /// Arabic takes the plural — so the noun has to agree with the number rather than be fixed.
    /// English needs the singular at 1. Mirrored by `ReportRendererTest.kt`.
    func testArabicCountedNounsAgreeWithTheNumber() {
        func days(_ n: Int) -> String { ReportPresentation.dayCount(n, language: .ar, arabicDigits: false) }
        XCTAssertEqual(days(1), "يوم واحد")
        XCTAssertEqual(days(2), "يومين")           // the dual needs no numeral
        XCTAssertEqual(days(7), "7 أيام")           // a full week — the common case
        XCTAssertEqual(days(11), "11 يوماً")

        XCTAssertEqual(ReportPresentation.recordCount(5, language: .ar, arabicDigits: false), "5 سجلات")
        XCTAssertEqual(ReportPresentation.recordCount(30, language: .ar, arabicDigits: false), "30 سجلاً")
        XCTAssertEqual(ReportPresentation.doseCount(4, language: .ar, arabicDigits: false), "4 جرعات")
        XCTAssertEqual(ReportPresentation.sectionCount(3, language: .ar, arabicDigits: false), "3 أقسام")
    }

    func testEnglishCountedNounsAreSingularAtOne() {
        XCTAssertEqual(ReportPresentation.dayCount(1, language: .en, arabicDigits: false), "1 day")
        XCTAssertEqual(ReportPresentation.dayCount(7, language: .en, arabicDigits: false), "7 days")
        XCTAssertEqual(ReportPresentation.recordCount(1, language: .en, arabicDigits: false), "1 record")
        XCTAssertEqual(ReportPresentation.doseCount(1, language: .en, arabicDigits: false), "1 dose")
    }

    /// The counted-noun path formats its number through `Numerals`, so the profile's digit
    /// preference reaches a report's copy instead of being bypassed by a raw interpolation.
    /// (Which glyphs `Numerals` chooses is its own contract, and differs by platform locale data —
    /// this asserts the wiring, not the digit shapes.)
    func testCountedNounFormatsItsNumberThroughNumerals() {
        let expected = Numerals.format(3.0, language: .ar, arabicDigits: true, fractionDigits: 0)
        XCTAssertEqual(ReportPresentation.evidenceCountPhrase(3, language: .ar, arabicDigits: true),
                       "استناداً إلى \(expected) سجلات")
    }
}
