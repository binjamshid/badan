import Foundation
import XCTest
@testable import BADAN

/// EPIC-41: THE FOUR-CONCEPT REFERENCE-RANGE LAW — `ReferenceRangeEngine.render` never conflates
/// source interval / source flag / personal baseline / user threshold, a missing source concept is
/// never invented, and personal-baseline computation is minimum-n gated by mirroring
/// `BaselineEngine`'s own convention rather than a new invented threshold.
final class ReferenceRangeEngineTests: XCTestCase {
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))
    private let device = "test-device"

    private func provenance(measuredAt: Date) -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: "UTC", recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func result(id: String, value: Double, unit: String = "mmol/L", daysAgo: Int) -> LabResult {
        let measured = clock.now().addingTimeInterval(TimeInterval(-daysAgo * 86_400))
        return LabResult(id: id, reportId: "R", analyteId: "sodium", rawValueText: "\(value)",
                         numericValue: value, rawUnit: unit, resultType: .numeric, reviewState: .userEntered,
                         originalId: id, provenance: provenance(measuredAt: measured), updatedAt: clock.now(),
                         originDeviceId: device)
    }

    // MARK: - render: the four concepts are never blended

    func testRenderKeepsAllFourConceptsSeparateEvenWhenAllArePresent() {
        let range = ReferenceRange(id: "RR", resultId: "RES", sourceIntervalLow: 136, sourceIntervalHigh: 145,
                                   sourceIntervalUnit: "mmol/L", sourceFlag: "H", updatedAt: clock.now(),
                                   originDeviceId: device)
        let trend = DerivedTrend(id: "T", analyteId: "sodium", windowDays: 365, center: 140, spread: 1,
                                 bandLow: 138, bandHigh: 142, nPoints: 10, provisional: false,
                                 algorithmVersion: "1.0.0", unit: "mmol/L", validFrom: clock.now(),
                                 computedAt: clock.now(), updatedAt: clock.now(), originDeviceId: device)
        let threshold = ReferenceRangeEngine.UserLabThreshold(analyteKey: "sodium", direction: .above,
                                                              value: 150, unit: "mmol/L")

        let rendered = ReferenceRangeEngine.render(range: range, baseline: trend, threshold: threshold)

        XCTAssertEqual(rendered.sourceInterval?.low, 136, "concept 1 (source interval) unchanged")
        XCTAssertEqual(rendered.sourceInterval?.high, 145)
        XCTAssertEqual(rendered.sourceFlag, "H", "concept 2 (source flag) unchanged")
        XCTAssertEqual(rendered.personalBaseline?.center, 140, "concept 3 (personal baseline) unchanged")
        XCTAssertEqual(rendered.personalBaseline?.bandLow, 138)
        XCTAssertEqual(rendered.userThreshold?.value, 150, "concept 4 (user threshold) unchanged")
        // No single field could be read as "the" range: each concept keeps a genuinely different
        // value here, which is only possible because none of them was blended into another.
        XCTAssertNotEqual(rendered.sourceInterval?.low, rendered.personalBaseline?.bandLow)
        XCTAssertNotEqual(rendered.personalBaseline?.center, rendered.userThreshold?.value)
        XCTAssertTrue(rendered.hasAnyConcept)
    }

    func testMissingSourceIntervalAndFlagRenderAsAbsentNeverInvented() {
        let range = ReferenceRange(id: "RR2", resultId: "RES2", updatedAt: clock.now(), originDeviceId: device)
        let rendered = ReferenceRangeEngine.render(range: range, baseline: nil, threshold: nil)
        XCTAssertNil(rendered.sourceInterval, "the source printed nothing — never backfilled from a generic table")
        XCTAssertNil(rendered.sourceFlag)
        XCTAssertNil(rendered.personalBaseline)
        XCTAssertNil(rendered.userThreshold)
        XCTAssertFalse(rendered.hasAnyConcept)
    }

    func testNoReferenceRangeRowAtAllStillRendersCleanlyAbsent() {
        let rendered = ReferenceRangeEngine.render(range: nil, baseline: nil, threshold: nil)
        XCTAssertNil(rendered.sourceInterval)
        XCTAssertNil(rendered.sourceFlag)
        XCTAssertFalse(rendered.hasAnyConcept)
    }

    func testSourceIntervalWithOnlyTextIsStillPresentEvenWithNoNumbers() {
        // "Negative" / "<5" style printed intervals that aren't a clean low/high pair — the source
        // wording must still surface as present, per the notebook law.
        let range = ReferenceRange(id: "RR3", resultId: "RES3", sourceIntervalText: "Negative",
                                   updatedAt: clock.now(), originDeviceId: device)
        let rendered = ReferenceRangeEngine.render(range: range, baseline: nil, threshold: nil)
        XCTAssertEqual(rendered.sourceInterval?.text, "Negative")
        XCTAssertNil(rendered.sourceInterval?.low)
        XCTAssertNil(rendered.sourceInterval?.high)
    }

    func testSourceIntervalCaptionUsesTheOnlyHonestPhrasingNeverAbnormal() {
        let caption = ReferenceRangeEngine.sourceIntervalCaption
        XCTAssertFalse(caption.resolved(.en).localizedCaseInsensitiveContains("abnormal"))
        XCTAssertFalse(caption.resolved(.en).localizedCaseInsensitiveContains("unhealthy"))
        XCTAssertFalse(caption.resolved(.ar).isEmpty)
    }

    // MARK: - Personal baseline: minimum-n gating mirrors BaselineEngine's own convention

    func testPersonalBaselineIsNilBelowBaselineEnginesOwnMinimumPoints() {
        let minPoints = BaselineSpec.defaultShared.minPoints
        let history = (0..<(minPoints - 1)).map { result(id: "H-\($0)", value: 140 + Double($0), daysAgo: $0) }
        let trend = ReferenceRangeEngine.makeTrend(id: "T-short", analyteKey: "sodium", history: history,
                                                   unit: "mmol/L", validFrom: clock.now(), computedAt: clock.now(),
                                                   updatedAt: clock.now(), originDeviceId: device)
        XCTAssertNil(trend, "fewer points than BaselineEngine's own floor must never claim a baseline")
    }

    func testPersonalBaselineComputesOnceBaselineEnginesMinimumIsReached() throws {
        let minPoints = BaselineSpec.defaultShared.minPoints
        let history = (0..<minPoints).map { result(id: "H2-\($0)", value: 140, daysAgo: $0) }
        let trend = try XCTUnwrap(ReferenceRangeEngine.makeTrend(
            id: "T-full", analyteKey: "sodium", history: history, unit: "mmol/L", validFrom: clock.now(),
            computedAt: clock.now(), updatedAt: clock.now(), originDeviceId: device))
        XCTAssertEqual(trend.nPoints, minPoints)
        XCTAssertEqual(trend.center, 140, accuracy: 1e-9)
        XCTAssertEqual(trend.unit, "mmol/L")
        XCTAssertEqual(trend.analyteId, "sodium")
        XCTAssertEqual(trend.method, .medianMAD)
    }

    func testPersonalBaselineOnlyUsesMatchingUnitHistory() {
        let minPoints = BaselineSpec.defaultShared.minPoints
        var history = (0..<minPoints).map { result(id: "H3-\($0)", value: 140, unit: "mmol/L", daysAgo: $0) }
        history.append(result(id: "H3-wrong-unit", value: 9999, unit: "mg/dL", daysAgo: 0))
        let trend = ReferenceRangeEngine.makeTrend(id: "T-mixed", analyteKey: "sodium", history: history,
                                                   unit: "mmol/L", validFrom: clock.now(), computedAt: clock.now(),
                                                   updatedAt: clock.now(), originDeviceId: device)
        XCTAssertEqual(trend?.nPoints, minPoints,
                      "a differently-unit row must never be silently blended into the band")
    }

    func testPersonalBaselineIgnoresTombstonedHistory() {
        let minPoints = BaselineSpec.defaultShared.minPoints
        var history = (0..<minPoints).map { result(id: "H4-\($0)", value: 140, daysAgo: $0) }
        var extra = result(id: "H4-deleted", value: 5000, daysAgo: 0)
        extra.deletedAt = clock.now()
        history.append(extra)
        let trend = ReferenceRangeEngine.makeTrend(id: "T-tombstoned", analyteKey: "sodium", history: history,
                                                   unit: "mmol/L", validFrom: clock.now(), computedAt: clock.now(),
                                                   updatedAt: clock.now(), originDeviceId: device)
        XCTAssertEqual(trend?.nPoints, minPoints, "a tombstoned reading must never feed the personal baseline")
    }
}
