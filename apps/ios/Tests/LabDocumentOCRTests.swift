import Foundation
import XCTest
import CoreGraphics
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
}
