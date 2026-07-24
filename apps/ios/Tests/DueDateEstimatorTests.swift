import Foundation
import XCTest
@testable import BADAN

/// A18/ADR-0010/D-25 (EPIC-40, pregnancy module P0 slice): `DueDateEstimator`'s four-source
/// priority model, the clinician-lineage nuance (ultrasound-adjusted as an update to, not a peer
/// of, provider-given), and the structural "never a bare date" guarantee.
final class DueDateEstimatorTests: XCTestCase {
    private let asOf = Date(timeIntervalSince1970: 1_784_000_000)
    private let device = "test-device"

    private func provenance(measuredAt: Date) -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: "UTC", recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func entry(_ type: DueDateSourceType, id: String, enteredDate: Date) -> DueDateSourceEntry {
        DueDateSourceEntry(id: id, pregnancyRecordOriginalId: "J-1", sourceType: type, enteredDate: enteredDate,
                           provenance: provenance(measuredAt: enteredDate), updatedAt: asOf, originDeviceId: device)
    }

    // MARK: - No source entries at all -> no estimate (never a guessed range)

    func testNoSourceEntriesProducesNoRangeAndZeroConfidence() {
        let estimate = DueDateEstimator.estimate(
            pregnancyRecordOriginalId: "J-1", liveEntriesByType: [:], asOf: asOf, algorithmVersion: "1.0.0")
        XCTAssertFalse(estimate.hasRange)
        XCTAssertNil(estimate.rangeLow)
        XCTAssertNil(estimate.rangeCenter)
        XCTAssertNil(estimate.rangeHigh)
        XCTAssertNil(estimate.resolvedSourceType)
        XCTAssertEqual(estimate.confidence, 0)
    }

    // MARK: - Structural "never a bare date" guarantee

    func testEverySourceTypeProducesAllThreeRangeFieldsTogetherNeverABareDate() {
        let dueDate = asOf.addingTimeInterval(100 * 86_400)
        for type in DueDateSourceType.allCases {
            let estimate = DueDateEstimator.estimate(
                pregnancyRecordOriginalId: "J-1", liveEntriesByType: [type: entry(type, id: "E", enteredDate: dueDate)],
                asOf: asOf, algorithmVersion: "1.0.0")
            XCTAssertTrue(estimate.hasRange, "\(type) must produce a full range")
            XCTAssertNotNil(estimate.rangeLow); XCTAssertNotNil(estimate.rangeCenter); XCTAssertNotNil(estimate.rangeHigh)
            XCTAssertLessThan(estimate.rangeLow!, estimate.rangeCenter!)
            XCTAssertLessThan(estimate.rangeCenter!, estimate.rangeHigh!)
            XCTAssertEqual(estimate.resolvedSourceType, type)
        }
    }

    // MARK: - Priority order

    func testProviderGivenAloneIsUsedDirectlyAsTheDueDate() {
        let dueDate = asOf.addingTimeInterval(150 * 86_400)
        let estimate = DueDateEstimator.estimate(
            pregnancyRecordOriginalId: "J-1",
            liveEntriesByType: [.providerGiven: entry(.providerGiven, id: "E", enteredDate: dueDate)],
            asOf: asOf, algorithmVersion: "1.0.0")
        XCTAssertEqual(estimate.resolvedSourceType, .providerGiven)
        XCTAssertEqual(estimate.rangeCenter, dueDate, "a provider-given date is used directly, not recomputed")
    }

    func testUltrasoundAdjustedOverridesProviderGivenWhenBothPresent() {
        let providerDate = asOf.addingTimeInterval(150 * 86_400)
        let ultrasoundDate = asOf.addingTimeInterval(148 * 86_400)
        let estimate = DueDateEstimator.estimate(
            pregnancyRecordOriginalId: "J-1",
            liveEntriesByType: [
                .providerGiven: entry(.providerGiven, id: "PG", enteredDate: providerDate),
                .ultrasoundAdjusted: entry(.ultrasoundAdjusted, id: "US", enteredDate: ultrasoundDate),
            ], asOf: asOf, algorithmVersion: "1.0.0")
        XCTAssertEqual(estimate.resolvedSourceType, .ultrasoundAdjusted,
                       "the research doc's own framing: ultrasound-adjusted is an UPDATE to the provider " +
                       "lineage, not an independent peer — when both exist, the more recent clinician " +
                       "figure wins")
        XCTAssertEqual(estimate.rangeCenter, ultrasoundDate)
        XCTAssertEqual(estimate.inputSourceEntryIds, ["US"])
    }

    func testConceptionBasedIsUsedWhenNoClinicianSourceExists() {
        let conceptionDate = asOf.addingTimeInterval(-10 * 86_400)
        let estimate = DueDateEstimator.estimate(
            pregnancyRecordOriginalId: "J-1",
            liveEntriesByType: [
                .conceptionBased: entry(.conceptionBased, id: "C", enteredDate: conceptionDate),
                .lmpBased: entry(.lmpBased, id: "L", enteredDate: conceptionDate.addingTimeInterval(-14 * 86_400)),
            ], asOf: asOf, algorithmVersion: "1.0.0")
        XCTAssertEqual(estimate.resolvedSourceType, .conceptionBased,
                       "conception-based outranks LMP-based when neither clinician source is present")
    }

    func testLMPBasedIsTheLastResort() {
        let lmpDate = asOf.addingTimeInterval(-30 * 86_400)
        let estimate = DueDateEstimator.estimate(
            pregnancyRecordOriginalId: "J-1", liveEntriesByType: [.lmpBased: entry(.lmpBased, id: "L", enteredDate: lmpDate)],
            asOf: asOf, algorithmVersion: "1.0.0")
        XCTAssertEqual(estimate.resolvedSourceType, .lmpBased)
        // Matches `DayAttribution.addingDays`'s own UTC-anchored calendar exactly — using the test
        // machine's LOCAL calendar here instead would drift by however many DST transitions fall
        // within a ~280-day span, which is not what this assertion is testing.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let expectedDue = utcCalendar.date(byAdding: .day, value: DueDateEstimator.gestationDaysFromLMP, to: lmpDate)!
        XCTAssertEqual(utcCalendar.dateComponents([.day], from: estimate.rangeCenter!, to: expectedDue).day, 0,
                       "LMP-based center = LMP date + standard gestation days")
    }

    // MARK: - Range width and confidence ordering (research doc: LMP is explicitly least precise)

    func testRangeWidthWidensFromClinicianSourceToLMPBased() {
        XCTAssertLessThan(DueDateEstimator.rangeHalfWidthDays(.providerGiven),
                          DueDateEstimator.rangeHalfWidthDays(.conceptionBased))
        XCTAssertLessThan(DueDateEstimator.rangeHalfWidthDays(.conceptionBased),
                          DueDateEstimator.rangeHalfWidthDays(.lmpBased))
    }

    func testConfidenceNeverHasALowerTierMeetOrExceedAHigherTier() {
        XCTAssertLessThan(DueDateEstimator.confidence(.lmpBased), DueDateEstimator.confidence(.conceptionBased))
        XCTAssertLessThan(DueDateEstimator.confidence(.conceptionBased), DueDateEstimator.confidence(.providerGiven))
        XCTAssertLessThanOrEqual(DueDateEstimator.confidence(.providerGiven), DueDateEstimator.confidence(.ultrasoundAdjusted))
    }
}
