import Foundation
import XCTest
@testable import BADAN

/// EPIC-41, LAB-16: the weighted-score duplicate/conflict detector, and the supersede-with-history
/// amendment builder it hands off to. Nothing in this suite ever deletes a row — a `.merge` decision
/// is a recommendation the caller applies via `LabResultRepository.suppress` (I3), and an amendment
/// is always an APPEND, never a mutation of the original.
final class DuplicateConflictResolverTests: XCTestCase {
    private let device = "test-device"
    private let base = Date(timeIntervalSince1970: 1_784_000_000)

    private func provenance(measuredAt: Date) -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: "UTC", recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func result(id: String, analyteId: String = "sodium", reportId: String = "R1", value: Double,
                        unit: String = "mmol/L", hoursOffset: Double = 0) -> LabResult {
        let measured = base.addingTimeInterval(hoursOffset * 3600)
        return LabResult(id: id, reportId: reportId, analyteId: analyteId, rawValueText: "\(value)",
                         numericValue: value, rawUnit: unit, resultType: .numeric, reviewState: .userEntered,
                         originalId: id, provenance: provenance(measuredAt: measured), updatedAt: measured,
                         originDeviceId: device)
    }

    // MARK: - Decisions

    func testNearIdenticalValueCloseInTimeSameReportMerges() {
        let a = result(id: "A", value: 5.20)
        let b = result(id: "B", value: 5.20, hoursOffset: 0.1)
        XCTAssertEqual(DuplicateConflictResolver.evaluate(a, b).decision, .merge)
    }

    func testDifferingValuesInTheSameReportFlagsForReview() {
        let a = result(id: "A", value: 5.0)
        let b = result(id: "B", value: 9.0, hoursOffset: 0.2)
        XCTAssertEqual(DuplicateConflictResolver.evaluate(a, b).decision, .flag)
    }

    func testFarApartInTimeIsDistinctRegardlessOfValue() {
        let a = result(id: "A", value: 5.0)
        let b = result(id: "B", value: 5.0, hoursOffset: 24 * 30) // a month later
        let evaluation = DuplicateConflictResolver.evaluate(a, b)
        XCTAssertEqual(evaluation.decision, .distinct)
        XCTAssertEqual(evaluation.score, 0)
    }

    func testDifferentAnalytesAreAlwaysDistinctNeverCompared() {
        let a = result(id: "A", analyteId: "sodium", value: 140)
        let b = result(id: "B", analyteId: "potassium", value: 140)
        XCTAssertEqual(DuplicateConflictResolver.evaluate(a, b).decision, .distinct)
    }

    func testTombstonedRowIsNeverACandidate() {
        var a = result(id: "A", value: 5.2)
        a.deletedAt = base
        let b = result(id: "B", value: 5.2, hoursOffset: 0.1)
        XCTAssertEqual(DuplicateConflictResolver.evaluate(a, b).decision, .distinct,
                      "a tombstoned row must never be recommended for merge/link/flag")
    }

    func testEvaluateCandidatesOnlyReturnsNonDistinctPairs() {
        let a = result(id: "A", value: 5.2)
        let b = result(id: "B", value: 5.2, hoursOffset: 0.1)      // merges with a
        let c = result(id: "C", analyteId: "potassium", value: 4.0) // unrelated analyte
        let pairs = DuplicateConflictResolver.evaluate(candidates: [a, b, c])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(Set([pairs[0].a.id, pairs[0].b.id]), Set(["A", "B"]))
        XCTAssertEqual(pairs[0].evaluation.decision, .merge)
    }

    // MARK: - Amendment: supersede-with-history, never mutates, never deletes

    func testMakeAmendmentSupersedesWithHistoryAndNeverMutatesTheOriginal() {
        let original = result(id: "ORIG", value: 5.2)
        let amendment = DuplicateConflictResolver.makeAmendment(
            of: original, id: "AMEND", rawValueText: "5.6", numericValue: 5.6,
            provenance: provenance(measuredAt: base), updatedAt: base, originDeviceId: device)

        XCTAssertEqual(amendment.originalId, original.originalId, "same logical identity across the chain")
        XCTAssertEqual(amendment.supersedes, original.id, "the amendment points back at what it replaces")
        XCTAssertEqual(amendment.revision, original.revision + 1)
        XCTAssertEqual(amendment.reviewState, .corrected)
        XCTAssertEqual(amendment.rawValueText, "5.6")
        XCTAssertEqual(amendment.numericValue, 5.6)

        // `original` is a value-type struct passed BY VALUE into `makeAmendment` — asserting its own
        // fields are untouched here is the domain-level half of "never mutates the original"; the
        // storage-level half (the persisted row itself is unchanged after the amendment is inserted)
        // is `LabModelsTests.testAmendedResultSupersedesWithHistoryNeverMutatesOriginal`.
        XCTAssertEqual(original.rawValueText, "5.2")
        XCTAssertEqual(original.numericValue, 5.2)
        XCTAssertNil(original.supersedes)
        XCTAssertEqual(original.revision, 1)
    }

    func testMakeAmendmentCarriesOverUnspecifiedFieldsFromTheOriginal() {
        let original = result(id: "ORIG2", analyteId: "sodium", value: 140)
        let amendment = DuplicateConflictResolver.makeAmendment(
            of: original, id: "AMEND2", rawUnit: "mEq/L",
            provenance: provenance(measuredAt: base), updatedAt: base, originDeviceId: device)
        XCTAssertEqual(amendment.analyteId, original.analyteId, "unspecified fields carry over unchanged")
        XCTAssertEqual(amendment.rawValueText, original.rawValueText, "only rawUnit was overridden here")
        XCTAssertEqual(amendment.rawUnit, "mEq/L")
        XCTAssertEqual(amendment.reportId, original.reportId)
        XCTAssertEqual(amendment.sensitivityTier, original.sensitivityTier)
    }

    func testMakeAmendmentDefaultsToCorrectedReviewStateButAcceptsAnOverride() {
        let original = result(id: "ORIG3", value: 5.2)
        let flagged = DuplicateConflictResolver.makeAmendment(
            of: original, id: "AMEND3", reviewState: .conflictFlagged,
            provenance: provenance(measuredAt: base), updatedAt: base, originDeviceId: device)
        XCTAssertEqual(flagged.reviewState, .conflictFlagged)
    }
}
