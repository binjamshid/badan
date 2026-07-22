import Foundation
import XCTest
@testable import BADAN

/// EPIC-41: the safe/conditional/unsafe/none conversion-safety gate. Only `.safe`-class analytes
/// ever get an auto-computed `canonicalValue`; every other class — and every unlisted/failed
/// conversion, even for a `.safe` analyte — keeps ONLY the as-entered value/unit.
final class UnitNormalizationTests: XCTestCase {
    private func analyte(id: String, canonicalUnit: String, safety: ConversionSafetyClass) -> AnalyteDefinition {
        AnalyteDefinition(id: id, nameEn: "x", nameAr: "س", category: "metabolic",
                         canonicalUnit: canonicalUnit, conversionSafetyClass: safety)
    }

    // MARK: - Safe class: the flagship examples actually convert

    func testHbA1cConvertsIFCCToNGSPViaThePublishedCrosswalk() {
        let hba1c = analyte(id: "hba1c", canonicalUnit: "%", safety: .safe)
        let normalized = UnitNormalization.normalize(value: 53.0, unit: "mmol/mol", analyte: hba1c)
        // NGSP master equation: percent = mmol/mol / 10.929 + 2.15 -> 53/10.929 + 2.15 ≈ 6.998.
        XCTAssertEqual(normalized.canonicalValue ?? -1, 6.998, accuracy: 0.01)
        XCTAssertEqual(normalized.canonicalUnit, "%")
    }

    func testGlucoseConvertsMgDlToMmolL() {
        let glucose = analyte(id: "glucose_fasting", canonicalUnit: "mmol/L", safety: .safe)
        let normalized = UnitNormalization.normalize(value: 100, unit: "mg/dL", analyte: glucose)
        XCTAssertEqual(normalized.canonicalValue ?? -1, 5.55, accuracy: 0.001)
        XCTAssertEqual(normalized.canonicalUnit, "mmol/L")
    }

    func testCreatinineConvertsMgDlToMicromolL() {
        let creatinine = analyte(id: "creatinine", canonicalUnit: "umol/L", safety: .safe)
        let normalized = UnitNormalization.normalize(value: 1.0, unit: "mg/dL", analyte: creatinine)
        XCTAssertEqual(normalized.canonicalValue ?? -1, 88.4, accuracy: 0.001)
        XCTAssertEqual(normalized.canonicalUnit, "umol/L")
    }

    // MARK: - Every other class keeps ONLY the as-entered value/unit — never zero, never guessed

    func testConditionalClassNeverAutoConverts() {
        let vitaminD = analyte(id: "vitamin_d_25oh", canonicalUnit: "ng/mL", safety: .conditional)
        let normalized = UnitNormalization.normalize(value: 30, unit: "nmol/L", analyte: vitaminD)
        XCTAssertEqual(normalized, .absent, "conditional class never gets an auto-computed value")
    }

    func testUnsafeClassNeverAutoConverts() {
        // The reject-list case named explicitly in this slice's brief: absolute-vs-percent
        // differentials must never be silently converted.
        let neutrophilsAbs = analyte(id: "neutrophils_abs", canonicalUnit: "x10^9/L", safety: .unsafe)
        let normalized = UnitNormalization.normalize(value: 60, unit: "%", analyte: neutrophilsAbs)
        XCTAssertEqual(normalized, .absent)
    }

    func testNoneClassNeverAutoConverts() {
        let tsh = analyte(id: "tsh", canonicalUnit: "mIU/L", safety: .none)
        let normalized = UnitNormalization.normalize(value: 2.5, unit: "uIU/mL", analyte: tsh)
        XCTAssertEqual(normalized, .absent)
    }

    func testUnknownAnalyteNeverAutoConverts() {
        let normalized = UnitNormalization.normalize(value: 100, unit: "mg/dL", analyte: nil)
        XCTAssertEqual(normalized, .absent, "an unrecognized marker never gets a fabricated canonical value")
    }

    // MARK: - Never guesses on a failed/unlisted conversion, even for a `.safe` analyte

    func testSafeClassWithNoMatchingConversionEntryStaysAbsentRatherThanGuessing() {
        // Forcing an analyte id that has no entry in UnitNormalization's cited table to `.safe`
        // must still decline to convert rather than invent an unpublished factor.
        let unlisted = analyte(id: "not_a_real_analyte_id", canonicalUnit: "mmol/L", safety: .safe)
        let normalized = UnitNormalization.normalize(value: 140, unit: "mg/dL", analyte: unlisted)
        XCTAssertEqual(normalized, .absent, "no cited conversion exists for this pair — never guessed")
    }

    func testUnitAlreadyEqualToCanonicalHasNothingToAdd() {
        let glucose = analyte(id: "glucose_fasting", canonicalUnit: "mmol/L", safety: .safe)
        let normalized = UnitNormalization.normalize(value: 5.5, unit: "mmol/L", analyte: glucose)
        XCTAssertEqual(normalized, .absent, "already in canonical form — nothing additional to compute")
    }

    func testMissingValueOrUnitNeverConverts() {
        let glucose = analyte(id: "glucose_fasting", canonicalUnit: "mmol/L", safety: .safe)
        XCTAssertEqual(UnitNormalization.normalize(value: nil, unit: "mg/dL", analyte: glucose), .absent)
        XCTAssertEqual(UnitNormalization.normalize(value: 100, unit: nil, analyte: glucose), .absent)
    }

    // MARK: - applying(to:) writes only the two normalization fields, never the as-entered ones

    func testApplyingWritesOnlyCanonicalFieldsAndLeavesEverythingElseUntouched() {
        let glucose = analyte(id: "glucose_fasting", canonicalUnit: "mmol/L", safety: .safe)
        let provenance = Provenance(sourceId: "device", ingestionPath: .manual, measuredAt: Date(),
                                   measuredTimezone: "UTC", recordedAt: Date(), ingestedAt: Date())
        let original = LabResult(id: "R", reportId: "REP", analyteId: "glucose_fasting", rawValueText: "100",
                                 numericValue: 100, rawUnit: "mg/dL", resultType: .numeric,
                                 reviewState: .userEntered, originalId: "R", provenance: provenance,
                                 updatedAt: Date(), originDeviceId: "device")
        let applied = UnitNormalization.applying(to: original, analyte: glucose)
        XCTAssertEqual(applied.canonicalValue ?? -1, 5.55, accuracy: 0.001)
        XCTAssertEqual(applied.canonicalUnit, "mmol/L")
        XCTAssertEqual(applied.rawValueText, original.rawValueText, "the as-reported value is never replaced")
        XCTAssertEqual(applied.rawUnit, original.rawUnit)
        XCTAssertEqual(applied.id, original.id)
    }

    func testApplyingToAnUnsafeResultLeavesCanonicalFieldsAbsent() {
        let neutrophilsAbs = analyte(id: "neutrophils_abs", canonicalUnit: "x10^9/L", safety: .unsafe)
        let provenance = Provenance(sourceId: "device", ingestionPath: .manual, measuredAt: Date(),
                                   measuredTimezone: "UTC", recordedAt: Date(), ingestedAt: Date())
        let original = LabResult(id: "R2", reportId: "REP", analyteId: "neutrophils_abs", rawValueText: "4.2",
                                 numericValue: 4.2, rawUnit: "x10^9/L", resultType: .numeric,
                                 reviewState: .userEntered, originalId: "R2", provenance: provenance,
                                 updatedAt: Date(), originDeviceId: "device")
        let applied = UnitNormalization.applying(to: original, analyte: neutrophilsAbs)
        XCTAssertNil(applied.canonicalValue)
        XCTAssertNil(applied.canonicalUnit)
    }
}
