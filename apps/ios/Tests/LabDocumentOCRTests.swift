import Foundation
import XCTest
import CoreGraphics
import PDFKit
import UIKit
@testable import BADAN

/// LAB-06: the on-device Vision OCR pipeline. Runs the REAL `VNRecognizeTextRequest` (never a
/// mock) against synthetic images rendered at test time via `UIGraphicsImageRenderer` — a
/// `CGContext`-backed renderer already available on this iOS test target with no extra fixture
/// asset to bundle and check in. This proves the pipeline's actual OCR->parse->match chain, not
/// just its parsing helpers in isolation, for the fields this slice's brief requires a test for:
/// a decimal value round-trips, a comparator symbol is captured, an unrecognized marker doesn't
/// block the rest of the page, and every extraction defaults to `needsReview`.
///
/// `analytes.json` does not exist in this working tree yet (a parallel Domain/Labs lane owns it),
/// so `AnalyteNameMatcher.loadFromBundle()` returns nil in every test here and every field reads as
/// `.unrecognized` by construction — which is itself exactly what the "unrecognized marker doesn't
/// block the rest of the page" test needs to demonstrate, not a limitation of the test.
final class LabDocumentOCRTests: XCTestCase {
    private func renderTextImage(
        _ lines: [String],
        size: CGSize = CGSize(width: 1000, height: 90),
        fontSize: CGFloat = 52,
        lineSpacing: CGFloat = 90
    ) -> CGImage {
        let canvasSize = CGSize(width: size.width, height: CGFloat(lines.count) * lineSpacing + 40)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let image = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: canvasSize))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: UIColor.black,
            ]
            for (index, line) in lines.enumerated() {
                let origin = CGPoint(x: 20, y: 20 + CGFloat(index) * lineSpacing)
                NSAttributedString(string: line, attributes: attributes).draw(at: origin)
            }
        }
        guard let cgImage = image.cgImage else {
            fatalError("failed to render the synthetic OCR test fixture — UIGraphicsImageRenderer produced no CGImage")
        }
        return cgImage
    }

    // MARK: - A recognizable decimal value round-trips correctly

    func testDecimalValueRoundTripsThroughRealOCR() throws {
        let image = renderTextImage(["Vitamin D 32.5 ng/mL"])
        let pipeline = LabDocumentOCR(analyteDictionary: nil)

        let extraction = pipeline.run(sourceDocumentId: "doc-1", pages: [image])

        XCTAssertEqual(extraction.status, .completed)
        let field = try XCTUnwrap(extraction.fields.first)
        let value = try XCTUnwrap(field.parsedValue)
        XCTAssertEqual(value, 32.5, accuracy: 0.001,
                       "OCR'd on a clean, large, machine-rendered line — the decimal must parse exactly")
        XCTAssertEqual(field.valueText, "32.5")
        XCTAssertNil(field.comparator, "no comparator was printed on this line")
    }

    // MARK: - A comparator symbol is captured

    func testComparatorSymbolIsCaptured() throws {
        let image = renderTextImage(["hs-CRP <0.1 mg/L"])
        let pipeline = LabDocumentOCR(analyteDictionary: nil)

        let extraction = pipeline.run(sourceDocumentId: "doc-2", pages: [image])

        let field = try XCTUnwrap(extraction.fields.first)
        XCTAssertEqual(field.comparator, .lessThan)
        let value = try XCTUnwrap(field.parsedValue)
        XCTAssertEqual(value, 0.1, accuracy: 0.001)
        // Case-insensitive: Vision's recognizer is not guaranteed character-perfect on case for a
        // mixed-case abbreviation, and case fidelity isn't the property this test is pinning —
        // "the comparator symbol must not leak into the label" is.
        XCTAssertEqual(field.analyteLabelRaw.lowercased(), "hs-crp",
                       "the comparator symbol must not leak into the analyte label")
    }

    // MARK: - An unrecognized marker doesn't block the rest of the page

    func testUnrecognizedMarkerDoesNotBlockTheRestOfThePage() {
        // No `analytes.json` is bundled in this working tree, so BOTH lines below read as
        // `.unrecognized` — the point of this test is that the SECOND line still produces a field
        // at all, proving one line's unrecognized/unmatched marker never drops its neighbors.
        let image = renderTextImage(["Xyzqmarker 42 units", "Glucose 95 mg/dL"], lineSpacing: 100)
        let pipeline = LabDocumentOCR(analyteDictionary: nil)

        let extraction = pipeline.run(sourceDocumentId: "doc-3", pages: [image])

        XCTAssertEqual(extraction.fields.count, 2,
                       "an unrecognized/unmatched marker on one line must not prevent the other line's field from being extracted")
        for field in extraction.fields {
            if case .unrecognized = field.analyteMatch {
                // expected — no dictionary is available in this working tree
            } else {
                XCTFail("no analytes.json exists in this working tree, so every field must read as .unrecognized")
            }
            XCTAssertTrue(field.ambiguityFlags.contains(.noAnalyteDictionaryAvailable))
        }
        let values = Set(extraction.fields.compactMap { $0.parsedValue })
        XCTAssertTrue(values.contains(42), "the first (unrecognized) line's value must still be extracted")
        XCTAssertTrue(values.contains(95), "the second line's value must still be extracted despite its neighbor")
    }

    /// A totally-failed run (Vision can throw e.g. on a truly blank/degenerate page) must still
    /// return a normal `OCRExtraction`, never propagate an error out of `run` — LAB-06's own
    /// "document stores even when extraction fails." Modeled here with a genuinely empty page set
    /// (the simplest reliable way to force zero successfully-processed pages without depending on
    /// Vision failing on a particular malformed image, which isn't something this test can force
    /// deterministically).
    func testEmptyPageSetProducesAFailedButNonThrowingExtraction() {
        let pipeline = LabDocumentOCR(analyteDictionary: nil)

        let extraction = pipeline.run(sourceDocumentId: "doc-4", pages: [])

        XCTAssertEqual(extraction.status, .failed)
        XCTAssertEqual(extraction.pageCount, 0)
        XCTAssertTrue(extraction.fields.isEmpty)
    }

    // MARK: - Every extracted result defaults to needs_review

    func testEveryExtractedFieldDefaultsToNeedsReview() {
        let image = renderTextImage(["Glucose 95 mg/dL 70-99"])
        let pipeline = LabDocumentOCR(analyteDictionary: nil)

        let extraction = pipeline.run(sourceDocumentId: "doc-5", pages: [image])

        XCTAssertFalse(extraction.fields.isEmpty)
        for field in extraction.fields {
            XCTAssertEqual(field.reviewState, .needsReview,
                           "this pipeline must never auto-commit a value as verified — a human always confirms")
        }
    }

    // MARK: - Bounding boxes + confidence are captured (pipeline steps 5 + 6)

    func testExtractedFieldsCarryConfidenceAndBoundingBoxes() throws {
        let image = renderTextImage(["Glucose 95 mg/dL"])
        let pipeline = LabDocumentOCR(analyteDictionary: nil)

        let extraction = pipeline.run(sourceDocumentId: "doc-6", pages: [image])
        let field = try XCTUnwrap(extraction.fields.first)

        XCTAssertNotNil(field.valueConfidence)
        XCTAssertNotNil(field.valueBoundingBox)
        XCTAssertNotNil(field.analyteConfidence)
        XCTAssertNotNil(field.analyteBoundingBox)
    }

    // MARK: - Locale-aware decimal parsing (pipeline step 2) — pure-function coverage
    //
    // Exercised directly against `LabOCRNumberParser` rather than through Vision: getting Apple's
    // Arabic-script text recognizer to reproduce Arabic-Indic digit glyphs reliably from a
    // synthetically rendered image is its own, separate source of flakiness this test has no need
    // to depend on — the PARSER's own correctness (given a string, however it arrived) is what
    // these two cases are pinning.

    func testArabicIndicDecimalParsesToTheSameLatinValue() {
        let match = LabOCRNumberParser.firstNumber(in: "الجلوكوز ٩٥ ملغ/دل")
        XCTAssertEqual(match?.value, 95)
        XCTAssertFalse(match?.wasAmbiguousDecimal ?? true)
    }

    func testArabicDecimalSeparatorParsesCorrectly() {
        let match = LabOCRNumberParser.firstNumber(in: "٣٫٥")
        XCTAssertEqual(match?.value, 3.5)
    }

    func testBareCommaDecimalIsResolvedAndFlaggedAmbiguous() {
        let match = LabOCRNumberParser.firstNumber(in: "3,5 mmol/L")
        XCTAssertEqual(match?.value, 3.5)
        XCTAssertTrue(match?.wasAmbiguousDecimal ?? false, "a bare comma with no dot present is genuinely ambiguous")
    }

    func testUnambiguousDotDecimalIsNotFlagged() {
        let match = LabOCRNumberParser.firstNumber(in: "5.2")
        XCTAssertEqual(match?.value, 5.2)
        XCTAssertFalse(match?.wasAmbiguousDecimal ?? true)
    }

    // MARK: - Row assembly (pipeline step 1b)
    //
    // Exercised against synthetic `OCRTextLine` fragments rather than through Vision on purpose:
    // WHETHER a given rendered image gets split into columns is Vision's decision and varies with
    // font, spacing and revision, so a test that depended on provoking a split would be flaky in
    // the one direction that matters. What is pinned here is the assembler's own contract given
    // fragments that ARE split — which is exactly the shape a real column-aligned lab PDF produced
    // on 2026-08-01. The end-to-end case below covers the whole chain.

    private func fragment(_ text: String, x: Double, y: Double,
                          width: Double = 0.2, height: Double = 0.03,
                          confidence: OCRConfidence = 0.9) -> OCRTextLine {
        OCRTextLine(pageIndex: 0, text: text,
                    boundingBox: OCRBoundingBox(x: x, y: y, width: width, height: height),
                    confidence: confidence)
    }

    func testColumnFragmentsSharingABandBecomeOneRowInPrintedOrder() {
        // The exact failure this whole mechanism exists for: Vision hands back the label, value and
        // interval of ONE printed row as three separate observations at the same height.
        let rows = LabOCRRowAssembler.rows(from: [
            fragment("Ferritin", x: 0.05, y: 0.80),
            fragment("32 ng/mL", x: 0.40, y: 0.80),
            fragment("(30-400)", x: 0.70, y: 0.80),
        ])

        XCTAssertEqual(rows.count, 1, "three fragments on one printed line are one row, not three")
        XCTAssertEqual(rows.first?.text, "Ferritin 32 ng/mL (30-400)",
                       "joined left-to-right, in the order they were printed")
    }

    func testFragmentsOnDifferentBandsStayDifferentRows() {
        let rows = LabOCRRowAssembler.rows(from: [
            fragment("Ferritin", x: 0.05, y: 0.80),
            fragment("32 ng/mL", x: 0.40, y: 0.80),
            fragment("Vitamin D", x: 0.05, y: 0.70),
            fragment("21 ng/mL", x: 0.40, y: 0.70),
        ])

        XCTAssertEqual(rows.map(\.text), ["Ferritin 32 ng/mL", "Vitamin D 21 ng/mL"],
                       "rows come back top-to-bottom, and two printed rows never merge into one")
    }

    func testAssemblyLosesNoFragment() {
        // The assembler reorders and joins; it must never drop. A fragment that vanished here would
        // be a lab value silently missing from the review screen with nothing to indicate it.
        let inputs = [
            fragment("Sodium", x: 0.05, y: 0.90),
            fragment("140 mmol/L", x: 0.40, y: 0.90),
            fragment("stray", x: 0.05, y: 0.50, height: 0.02),
            fragment("Potassium", x: 0.05, y: 0.10),
            fragment("4.2 mmol/L", x: 0.40, y: 0.10),
        ]

        let joined = LabOCRRowAssembler.rows(from: inputs).map(\.text).joined(separator: " ")

        for input in inputs {
            XCTAssertTrue(joined.contains(input.text), "\(input.text) was dropped during row assembly")
        }
    }

    func testArabicRowIsJoinedRightToLeft() {
        // On an Arabic report the marker sits at the right edge with its value to the left. Joined
        // by ascending x it would read "٩٥ الجلوكوز" — a number with no label before it, which
        // `extractField` correctly refuses, losing a row that was recognized perfectly well.
        let rows = LabOCRRowAssembler.rows(from: [
            fragment("95 mg/dL", x: 0.10, y: 0.80),
            fragment("الجلوكوز", x: 0.70, y: 0.80),
        ])

        XCTAssertEqual(rows.first?.text, "الجلوكوز 95 mg/dL",
                       "an Arabic row reads right-to-left, so its label comes first")
    }

    func testALatinRowWithArabicIndicDigitsStaysLeftToRight() {
        // Digits are excluded from the direction vote deliberately: Arabic-Indic numerals turn up
        // in otherwise-Latin reports, and a numeric column must not flip a row's reading order.
        let rows = LabOCRRowAssembler.rows(from: [
            fragment("Glucose", x: 0.05, y: 0.80),
            fragment("٩٥ mg/dL", x: 0.40, y: 0.80),
        ])

        XCTAssertEqual(rows.first?.text, "Glucose ٩٥ mg/dL")
    }

    func testRowConfidenceIsItsWeakestFragment() {
        let rows = LabOCRRowAssembler.rows(from: [
            fragment("Ferritin", x: 0.05, y: 0.80, confidence: 0.99),
            fragment("32 ng/mL", x: 0.40, y: 0.80, confidence: 0.31),
        ])

        XCTAssertEqual(rows.first?.confidence, 0.31,
                       "a confidently-read label must not hide a doubtful value — the flag is what tells the reviewer where to look")
    }

    func testSingleFragmentPageIsUntouched() {
        let only = [fragment("Glucose 95 mg/dL", x: 0.05, y: 0.80)]
        XCTAssertEqual(LabOCRRowAssembler.rows(from: only).map(\.text), ["Glucose 95 mg/dL"])
    }

    // MARK: - Non-marker row suppression (pipeline step 1c)

    func testPageMarkersAreNotMarkerCandidates() {
        XCTAssertFalse(LabOCRRowFilter.isMarkerCandidate("Report page 2 of 3"))
        XCTAssertFalse(LabOCRRowFilter.isMarkerCandidate("Page 1 / 4"))
        XCTAssertFalse(LabOCRRowFilter.isMarkerCandidate("صفحة ٢ من ٣"))
    }

    func testBareDateLinesAreNotMarkerCandidates() {
        XCTAssertFalse(LabOCRRowFilter.isMarkerCandidate("Collected 2026-03-14"))
        XCTAssertFalse(LabOCRRowFilter.isMarkerCandidate("Reported 14/03/2026 09:30"))
    }

    func testAResultPrintedAlongsideItsDateSurvives() {
        // The suppression must be narrow enough that a date sitting on the same row as a value
        // never costs the user the value.
        XCTAssertTrue(LabOCRRowFilter.isMarkerCandidate("Glucose 2026-03-14 5.4 mmol/L"))
    }

    func testMarkerNamesContainingDigitsAndDashesSurvive() {
        // "25-OH" is not a date and must never be read as one.
        XCTAssertTrue(LabOCRRowFilter.isMarkerCandidate("Vitamin D3 25-OH 32 ng/mL"))
        XCTAssertTrue(LabOCRRowFilter.isMarkerCandidate("Hemoglobin A1c 5.4 %"))
    }

    // MARK: - Page rasterization

    /// A one-page PDF built the way a sheet-fed scanner actually builds one: the bitmap is stored
    /// SIDEWAYS, and a `/Rotate` on the page is what makes it display upright. Reading `/Rotate` is
    /// therefore not a nicety — it is the difference between the page a reader sees and a bitmap
    /// lying on its side.
    private func scannerStylePDF(_ line: String) throws -> PDFDocument {
        let upright = UIImage(cgImage: renderTextImage([line]))
        // `.right` + baking = the bitmap turned a quarter turn clockwise, exactly what the scanner
        // stored; /Rotate 270 turns it back counter-clockwise for display.
        let sideways = UIImage(cgImage: try XCTUnwrap(upright.cgImage), scale: 1, orientation: .right)
            .uprightedForRecognition()
        let data = try XCTUnwrap(LabPDFRendering.pdfData(from: [sideways]))
        let document = try XCTUnwrap(PDFDocument(data: data))
        try XCTUnwrap(document.page(at: 0)).rotation = 270
        return document
    }

    func testAScannerRotatedPDFPageRasterizesAsTheReaderSeesIt() throws {
        // The previous implementation sized every canvas from `bounds(for:)`, which reports the box
        // BEFORE /Rotate — so rotated content was drawn into a canvas of the wrong aspect and part
        // of it fell outside. Measured on the first fixture written for this: zero lines recognized
        // on a page that opens perfectly straight in Preview, which the app could only report as
        // "no results on this report."
        let document = try scannerStylePDF("Glucose 95 mg/dL")
        let rendered = LabPDFRendering.pageImages(document: document)
        let page = try XCTUnwrap(rendered.images.first)

        let extraction = LabDocumentOCR(analyteDictionary: nil).run(sourceDocumentId: "doc-rot", pages: [page])

        XCTAssertEqual(extraction.fields.first?.parsedValue, 95,
                       "a scanner-rotated page must rasterize the way it displays — got \(extraction.rawLines.map(\.text))")
    }

    func testAQuarterTurnedPageRasterizesAtItsDisplayedAspect() throws {
        // The geometric half of the same rule, pinned separately because it holds whatever Vision
        // makes of the pixels: a page displayed landscape must not be rendered into a portrait
        // canvas, which is what silently cropped the content.
        let document = try scannerStylePDF("Glucose 95 mg/dL")
        let page = try XCTUnwrap(LabPDFRendering.pageImages(document: document).images.first)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)

        XCTAssertEqual(page.width > page.height, bounds.height > bounds.width,
                       "a quarter-turned page swaps the canvas's aspect; it does not keep the pre-rotation box")
    }

    func testPageImagesReportsTheDocumentsOwnPageCount() throws {
        let image = try XCTUnwrap(UIImage(cgImage: renderTextImage(["Glucose 95 mg/dL"])))
        let data = try XCTUnwrap(LabPDFRendering.pdfData(from: Array(repeating: image, count: 3)))
        let document = try XCTUnwrap(PDFDocument(data: data))

        let rendered = LabPDFRendering.pageImages(document: document, limit: 2)

        XCTAssertEqual(rendered.images.count, 2, "the limit bounds how much is READ")
        XCTAssertEqual(rendered.totalPages, 3, "the count is the DOCUMENT's, so the user can be told what was skipped")
    }

    // MARK: - Unit capture must survive the lab's own flag

    func testAFlagLetterIsNotStrippedFromInsideTheUnit() {
        // Observed on a real report on 2026-08-01: "21 ng/mL (30-100) L" recorded its unit as
        // "ng/m", because the flag "L" was removed from the first place an L occurs. Every unit a
        // lab prints for a flagged result is exposed to this — mL, mmol/L, mIU/L, µg/L.
        XCTAssertEqual(LabOCRRemainderParser.unit(in: "ng/mL (30-100) L"), "ng/mL")
        XCTAssertEqual(LabOCRRemainderParser.flag(in: "ng/mL (30-100) L"), "L")
        XCTAssertEqual(LabOCRRemainderParser.unit(in: "mmol/L (135-145) H"), "mmol/L")
        XCTAssertEqual(LabOCRRemainderParser.unit(in: "mIU/L (0.4-4.0)"), "mIU/L")
    }

    func testUnflaggedRowsStillReadTheirUnitAndInterval() {
        XCTAssertEqual(LabOCRRemainderParser.unit(in: "% (4.0-5.6)"), "%")
        XCTAssertEqual(LabOCRRemainderParser.interval(in: "% (4.0-5.6)"), "4.0-5.6")
        XCTAssertEqual(LabOCRRemainderParser.unit(in: "mg/dL"), "mg/dL")
    }

    // MARK: - End to end: a column-aligned row yields one clean field, not junk

    func testWidelySpacedColumnsProduceOneFieldWithItsRealMarkerName() throws {
        // Column spacing wide enough that Vision may return each column separately — the layout
        // that produced "marker name = (, value = 30, unit = -400" before row assembly existed.
        let image = renderTextImage(["Ferritin          32 ng/mL          (30-400)"],
                                    size: CGSize(width: 1800, height: 90))
        let pipeline = LabDocumentOCR(analyteDictionary: nil)

        let extraction = pipeline.run(sourceDocumentId: "doc-rows", pages: [image])

        XCTAssertEqual(extraction.fields.count, 1,
                       "one printed row is one candidate field, however many fragments Vision split it into")
        let field = try XCTUnwrap(extraction.fields.first)
        XCTAssertTrue(field.analyteLabelRaw.contains("Ferritin"),
                      "the marker name must be the printed label, not a stray bracket — got \(field.analyteLabelRaw)")
        XCTAssertEqual(field.parsedValue, 32)
        XCTAssertEqual(field.reviewState, .needsReview)
    }

    func testAnIntervalColumnAloneProducesNoField() {
        // Whatever else happens, a fragment with no letters in it is not a marker.
        let image = renderTextImage(["(30-400)"])
        let pipeline = LabDocumentOCR(analyteDictionary: nil)

        let extraction = pipeline.run(sourceDocumentId: "doc-bracket", pages: [image])

        XCTAssertTrue(extraction.fields.isEmpty,
                      "punctuation is not a marker name — got \(extraction.fields.map(\.analyteLabelRaw))")
    }

    func testAPageHeaderProducesNoField() {
        let image = renderTextImage(["Report page 2 of 3", "Collected 2026-03-14", "Glucose 95 mg/dL"],
                                    lineSpacing: 100)
        let pipeline = LabDocumentOCR(analyteDictionary: nil)

        let extraction = pipeline.run(sourceDocumentId: "doc-header", pages: [image])

        XCTAssertEqual(extraction.fields.count, 1,
                       "page furniture is not offered as a marker to confirm — got \(extraction.fields.map(\.analyteLabelRaw))")
        XCTAssertEqual(extraction.fields.first?.parsedValue, 95)
        XCTAssertEqual(extraction.rawLines.count, 3,
                       "suppression is an extraction decision only — the raw recognized lines are still the stored artifact")
    }
}
