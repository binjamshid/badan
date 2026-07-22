import Foundation
import XCTest
@testable import BADAN

/// EPIC-41, Phase 3E lab-notebook MVP: the canonical entity set, storage round-trips through the
/// four repositories, the I7 sensitive-namespace placement/purge contract, the append-first
/// `LabResult` revision chain, and the `analytes.json`/`units.json` contract data itself.
final class LabModelsTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))
    private let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-labs-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func reportRepo() -> LabReportRepository { LabReportRepository(sensitive: db.sensitive) }
    private func resultRepo() -> LabResultRepository { LabResultRepository(sensitive: db.sensitive) }
    private func rangeRepo() -> ReferenceRangeRepository { ReferenceRangeRepository(sensitive: db.sensitive) }
    private func trendRepo() -> DerivedTrendRepository { DerivedTrendRepository(sensitive: db.sensitive) }

    private func provenance(measuredAt: Date, tzId: String = "UTC") -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: tzId, recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func makeReport(id: String = "R-1", collectionAt: Date? = nil) -> LabReport {
        LabReport(id: id, sourceLabName: "Test Lab", collectionAt: collectionAt ?? clock.now(), tzId: "UTC",
                 reviewState: .userEntered, ingestionPath: .manual, sensitivityTier: .standard,
                 updatedAt: clock.now(), originDeviceId: device)
    }

    private func makeResult(id: String, reportId: String = "R-1", analyteId: String? = "sodium",
                           customLabel: String? = nil, rawValueText: String = "140",
                           numericValue: Double? = 140, rawUnit: String? = "mmol/L",
                           originalId: String? = nil, supersedes: String? = nil,
                           revision: Int = 1) -> LabResult {
        LabResult(id: id, reportId: reportId, analyteId: analyteId, customLabel: customLabel,
                 rawValueText: rawValueText, numericValue: numericValue, rawUnit: rawUnit,
                 resultType: .numeric, reviewState: .userEntered, originalId: originalId ?? id,
                 supersedes: supersedes, revision: revision, provenance: provenance(measuredAt: clock.now()),
                 updatedAt: clock.now(), originDeviceId: device)
    }

    // MARK: - Round trips through the repositories

    func testReportPanelResultRoundTripThroughRepositories() throws {
        try reportRepo().insertReport(makeReport())
        try reportRepo().insertPanel(LabPanel(id: "P-1", reportId: "R-1", name: "Basic Metabolic Panel",
                                             sortOrder: 0, updatedAt: clock.now(), originDeviceId: device))
        try resultRepo().insertResult(makeResult(id: "RES-1"))

        let report = try XCTUnwrap(try reportRepo().report(id: "R-1"))
        XCTAssertEqual(report.sourceLabName, "Test Lab")
        XCTAssertEqual(report.reviewState, .userEntered)
        XCTAssertEqual(report.sensitivityTier, .standard)
        XCTAssertEqual(report.ingestionPath, .manual)

        let panels = try reportRepo().panels(reportId: "R-1")
        XCTAssertEqual(panels.map(\.name), ["Basic Metabolic Panel"])

        let results = try resultRepo().liveResults(reportId: "R-1")
        XCTAssertEqual(results.map(\.id), ["RES-1"])
        XCTAssertEqual(results[0].analyteId, "sodium")
        XCTAssertEqual(results[0].numericValue, 140)
        XCTAssertEqual(results[0].provenance.ingestionPath, .manual, "I1: a manual lab entry is still provenanced")
    }

    func testReferenceRangeRoundTrip() throws {
        try resultRepo().insertResult(makeResult(id: "RES-2"))
        try rangeRepo().insertRange(ReferenceRange(id: "RR-1", resultId: "RES-2", sourceIntervalLow: 136,
                                                   sourceIntervalHigh: 145, sourceIntervalUnit: "mmol/L",
                                                   updatedAt: clock.now(), originDeviceId: device))
        let range = try XCTUnwrap(try rangeRepo().range(resultId: "RES-2"))
        XCTAssertEqual(range.sourceIntervalLow, 136)
        XCTAssertEqual(range.sourceIntervalHigh, 145)
        XCTAssertTrue(range.hasSourceInterval)
        XCTAssertFalse(range.hasSourceFlag, "no source flag was ever set on this row")
    }

    func testDerivedTrendAppendOnlyLatestWins() throws {
        let first = DerivedTrend(id: "T-1", analyteId: "sodium", windowDays: 365, center: 140, spread: 2,
                                bandLow: 136, bandHigh: 144, nPoints: 5, provisional: true,
                                algorithmVersion: "1.0.0", unit: "mmol/L", validFrom: clock.now(),
                                computedAt: clock.now(), updatedAt: clock.now(), originDeviceId: device)
        try trendRepo().appendTrend(first)
        clock.advance(by: 86_400)
        let second = DerivedTrend(id: "T-2", analyteId: "sodium", windowDays: 365, center: 141, spread: 2,
                                 bandLow: 137, bandHigh: 145, nPoints: 6, provisional: false,
                                 algorithmVersion: "1.0.0", unit: "mmol/L", validFrom: clock.now(),
                                 computedAt: clock.now(), updatedAt: clock.now(), originDeviceId: device)
        try trendRepo().appendTrend(second)

        let latest = try XCTUnwrap(try trendRepo().latestTrend(analyteId: "sodium"))
        XCTAssertEqual(latest.id, "T-2", "the newest row wins on read")
        XCTAssertEqual(try trendRepo().allTrends(analyteId: "sodium").count, 2, "I2: nothing is overwritten")
    }

    func testUserCorrectionAndAnnotationRoundTrip() throws {
        try reportRepo().insertReport(makeReport())
        try reportRepo().insertCorrection(UserCorrection(id: "C-1", targetType: .report, targetId: "R-1",
                                                         fieldName: "sourceLabName", previousValueText: "Test Lab",
                                                         correctedValueText: "Test Lab (Main Branch)",
                                                         correctedAt: clock.now(), updatedAt: clock.now(),
                                                         originDeviceId: device))
        let corrections = try reportRepo().corrections(targetType: .report, targetId: "R-1")
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].correctedValueText, "Test Lab (Main Branch)")

        try reportRepo().insertAnnotation(LabAnnotation(id: "A-1", targetType: .report, targetId: "R-1",
                                                        kind: .clinicianQuestion, text: "Ask about retest timing",
                                                        createdAt: clock.now(), updatedAt: clock.now(),
                                                        originDeviceId: device))
        var annotations = try reportRepo().annotations(targetType: .report, targetId: "R-1")
        XCTAssertEqual(annotations.count, 1)
        XCTAssertFalse(annotations[0].resolved)
        try reportRepo().setAnnotationResolved(id: "A-1", resolved: true, at: clock.now())
        annotations = try reportRepo().annotations(targetType: .report, targetId: "R-1")
        XCTAssertTrue(annotations[0].resolved)
    }

    // MARK: - Revision chain / live view (append-first, never destructive)

    func testAmendedResultSupersedesWithHistoryNeverMutatesOriginal() throws {
        let original = makeResult(id: "RES-3", rawValueText: "5.2", numericValue: 5.2, rawUnit: "mmol/L")
        try resultRepo().insertResult(original)

        let amendment = DuplicateConflictResolver.makeAmendment(
            of: original, id: "RES-3-rev2", rawValueText: "5.4", numericValue: 5.4,
            provenance: provenance(measuredAt: clock.now()), updatedAt: clock.now(), originDeviceId: device)
        try resultRepo().insertResult(amendment)

        let history = try resultRepo().history(originalId: "RES-3")
        XCTAssertEqual(history.count, 2)
        let originalRow = try XCTUnwrap(try resultRepo().result(id: "RES-3"))
        XCTAssertEqual(originalRow.rawValueText, "5.2", "the stored original row is never mutated")
        XCTAssertEqual(originalRow.numericValue, 5.2)

        let live = try resultRepo().liveResult(originalId: "RES-3")
        XCTAssertEqual(live?.id, "RES-3-rev2")
        XCTAssertEqual(live?.rawValueText, "5.4")
        XCTAssertEqual(live?.reviewState, .corrected)
        XCTAssertEqual(live?.revision, 2)
    }

    func testLiveResultsExcludeSupersededAndTombstonedRows() {
        let original = makeResult(id: "X-1", originalId: "X-1")
        let revision = LabResult(id: "X-2", reportId: original.reportId, analyteId: original.analyteId,
                                 rawValueText: "141", numericValue: 141, rawUnit: "mmol/L",
                                 resultType: .numeric, reviewState: .corrected, originalId: "X-1",
                                 supersedes: "X-1", revision: 2, provenance: original.provenance,
                                 updatedAt: clock.now(), originDeviceId: device)
        var deleted = makeResult(id: "Y-1", analyteId: "potassium")
        deleted.deletedAt = clock.now()

        let live = LabResultLedger.liveResults([original, revision, deleted])
        XCTAssertEqual(Set(live.map(\.id)), Set(["X-2"]))
    }

    func testLiveResultsExcludeDedupSuppressedRows() {
        var suppressed = makeResult(id: "S-1")
        suppressed.provenance.suppressedBy = "S-winner"
        let winner = makeResult(id: "S-winner")

        let live = LabResultLedger.liveResults([winner, suppressed])
        XCTAssertEqual(Set(live.map(\.id)), Set(["S-winner"]),
                       "LAB-16: a merge-suppressed row is hidden from every live view — never deleted, per I3")
    }

    // MARK: - LAB-16: suppress() hides a row from every "live" repository read, never deletes it

    func testSuppressHidesARowFromLiveReadsButIncludeSuppressedStillReturnsIt() throws {
        try resultRepo().insertResult(makeResult(id: "DUP-1"))
        try resultRepo().insertResult(makeResult(id: "DUP-2"))
        try resultRepo().suppress(id: "DUP-2", by: "DUP-1", at: clock.now())

        XCTAssertEqual(try resultRepo().liveResults(reportId: "R-1").map(\.id), ["DUP-1"])
        XCTAssertEqual(try resultRepo().liveResults(analyteId: "sodium").map(\.id), ["DUP-1"])
        XCTAssertEqual(try resultRepo().allLiveResults().map(\.id), ["DUP-1"])

        let withSuppressed = try resultRepo().allLiveResults(includeSuppressed: true)
        XCTAssertEqual(Set(withSuppressed.map(\.id)), Set(["DUP-1", "DUP-2"]),
                       "the suppressed row still exists — suppress() is an UPDATE, never a DELETE (I3)")
        XCTAssertEqual(withSuppressed.first { $0.id == "DUP-2" }?.provenance.suppressedBy, "DUP-1")
    }

    // MARK: - analyteKey: dictionary id first, normalized custom label otherwise — never blocked

    func testAnalyteKeyPrefersDictionaryIdAndFallsBackToNormalizedCustomLabel() {
        let known = makeResult(id: "K-1", analyteId: "sodium", customLabel: nil)
        XCTAssertEqual(known.analyteKey, "sodium")

        let custom = makeResult(id: "K-2", analyteId: nil, customLabel: "  My Weird Marker  ")
        XCTAssertEqual(custom.analyteKey, "custom:my weird marker",
                      "an unrecognized marker still gets a stable, normalized identity — never blocked")
    }

    // MARK: - I7: sensitive placement + purge

    func testLabTablesExistOnlyInTheSensitiveDatabase() throws {
        for table in ["lab_reports", "lab_panels", "lab_results", "reference_ranges",
                     "user_corrections", "lab_annotations", "derived_trends"] {
            let inMain = try db.main.query(
                "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='\(table)';")
                .first?.int("c") ?? 0
            XCTAssertEqual(inMain, 0, "\(table) is sensitive-plus (I7) and must not exist in badan.db")
            let inSensitive = try db.sensitive.query(
                "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='\(table)';")
                .first?.int("c") ?? 0
            XCTAssertEqual(inSensitive, 1, "\(table) must live in badan_sensitive.db")
        }
    }

    func testSensitivePurgeRemovesEveryLabTable() throws {
        try reportRepo().insertReport(makeReport())
        try resultRepo().insertResult(makeResult(id: "PURGE-1"))
        try rangeRepo().insertRange(ReferenceRange(id: "PURGE-RR", resultId: "PURGE-1",
                                                   updatedAt: clock.now(), originDeviceId: device))
        try trendRepo().appendTrend(DerivedTrend(id: "PURGE-T", analyteId: "sodium", windowDays: 365,
                                                 center: 140, spread: 1, bandLow: 138, bandHigh: 142,
                                                 nPoints: 5, provisional: true, algorithmVersion: "1.0.0",
                                                 unit: "mmol/L", validFrom: clock.now(), computedAt: clock.now(),
                                                 updatedAt: clock.now(), originDeviceId: device))
        try reportRepo().insertAnnotation(LabAnnotation(id: "PURGE-A", targetType: .result, targetId: "PURGE-1",
                                                        kind: .note, text: "note", createdAt: clock.now(),
                                                        updatedAt: clock.now(), originDeviceId: device))
        try reportRepo().insertCorrection(UserCorrection(id: "PURGE-C", targetType: .result, targetId: "PURGE-1",
                                                         fieldName: "rawUnit", correctedValueText: "mmol/L",
                                                         correctedAt: clock.now(), updatedAt: clock.now(),
                                                         originDeviceId: device))

        try db.purgeSensitiveNamespace()

        XCTAssertNil(try reportRepo().report(id: "R-1"), "I7: a purge is a file deletion — nothing survives")
        XCTAssertTrue(try resultRepo().allLiveResults().isEmpty)
        XCTAssertNil(try rangeRepo().range(resultId: "PURGE-1"))
        XCTAssertNil(try trendRepo().latestTrend(analyteId: "sodium"))
        XCTAssertTrue(try reportRepo().annotations(targetType: .result, targetId: "PURGE-1").isEmpty)
        XCTAssertTrue(try reportRepo().corrections(targetType: .result, targetId: "PURGE-1").isEmpty)
    }

    // MARK: - Contract data: analytes.json / units.json

    /// Read from the repo rather than the app bundle so a sync-script regression can't make this
    /// pass against a stale copy (same approach `JournalTests` takes for `behaviors.json`).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testAnalytesJSONIsBilingualWellFormedAndSpansTheTwentyCategories() throws {
        let url = repoRoot.appendingPathComponent("packages/contracts/analytes/analytes.json")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let analytes = try XCTUnwrap(json?["analytes"] as? [[String: Any]])

        XCTAssertGreaterThanOrEqual(analytes.count, 60, "a usable representative analyte set (documented non-exhaustive)")
        var ids = Set<String>()
        var categories = Set<String>()
        for a in analytes {
            let id = try XCTUnwrap(a["id"] as? String)
            XCTAssertTrue(ids.insert(id).inserted, "duplicate analyte id \(id) — ids are the join key")
            XCTAssertFalse((a["nameEn"] as? String ?? "").isEmpty, "\(id) carries English")
            XCTAssertFalse((a["nameAr"] as? String ?? "").isEmpty, "\(id) carries Arabic")
            XCTAssertNotEqual(a["nameEn"] as? String, a["nameAr"] as? String,
                              "\(id): the Arabic name must be real Arabic, not the English string copied over")
            categories.insert(try XCTUnwrap(a["category"] as? String))
            XCTAssertFalse((a["canonicalUnit"] as? String ?? "").isEmpty, "\(id) carries a canonical unit")
            let classRaw = try XCTUnwrap(a["conversionSafetyClass"] as? String)
            XCTAssertNotNil(ConversionSafetyClass(rawValue: classRaw), "\(id): unknown conversion class \(classRaw)")
        }
        // The 20 §7A.4 categories, `user_defined` deliberately excepted — the file's own top-level
        // note documents it as reserved for a future user-authored definition, shipping zero rows.
        let expected = ["cbc", "iron", "metabolic", "liver", "kidney", "lipids", "glucose", "glycemic",
                       "thyroid", "reproductive", "vitamins", "inflammation", "urinalysis", "micro_culture",
                       "allergy", "drug_monitoring", "genetic_meta", "custom", "derived"]
        for category in expected {
            XCTAssertTrue(categories.contains(category), "analytes.json must cover category \(category)")
        }
    }

    func testUnitsJSONCoversEveryCanonicalUnitAnalytesJSONUses() throws {
        let unitsURL = repoRoot.appendingPathComponent("packages/contracts/analytes/units.json")
        let analytesURL = repoRoot.appendingPathComponent("packages/contracts/analytes/analytes.json")
        let unitsJSON = try JSONSerialization.jsonObject(with: try Data(contentsOf: unitsURL)) as? [String: Any]
        let analytesJSON = try JSONSerialization.jsonObject(with: try Data(contentsOf: analytesURL)) as? [String: Any]
        let units = try XCTUnwrap(unitsJSON?["units"] as? [[String: Any]])
        let analytes = try XCTUnwrap(analytesJSON?["analytes"] as? [[String: Any]])

        let symbols = Set(units.compactMap { $0["symbol"] as? String })
        for a in analytes {
            let id = try XCTUnwrap(a["id"] as? String)
            let unit = try XCTUnwrap(a["canonicalUnit"] as? String)
            XCTAssertTrue(symbols.contains(unit), "\(id)'s canonicalUnit \(unit) is missing from units.json")
        }
    }

    /// Every analyte this file marks `safe` must have a real, cited conversion entry in
    /// `UnitNormalization` — a `safe` class with nothing that actually converts it would be a silent
    /// no-op masquerading as a capability (the "built but dark" failure mode `docs/HANDOFF.md` names).
    func testEverySafeClassAnalyteActuallyConverts() throws {
        let url = repoRoot.appendingPathComponent("packages/contracts/analytes/analytes.json")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let analytes = try XCTUnwrap(json?["analytes"] as? [[String: Any]])
        var checked = 0
        for a in analytes where (a["conversionSafetyClass"] as? String) == "safe" {
            let id = try XCTUnwrap(a["id"] as? String)
            let canonicalUnit = try XCTUnwrap(a["canonicalUnit"] as? String)
            let definition = AnalyteDefinition(id: id, nameEn: "x", nameAr: "x",
                                              category: a["category"] as? String ?? "custom",
                                              canonicalUnit: canonicalUnit, conversionSafetyClass: .safe)
            let probeUnit = (id == "hba1c") ? "mmol/mol" : "mg/dL"
            let normalized = UnitNormalization.normalize(value: 1, unit: probeUnit, analyte: definition)
            XCTAssertNotEqual(normalized, .absent, "\(id) is marked safe but has no working conversion entry")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
