import CryptoKit
import Foundation
import XCTest
@testable import BADAN

/// The iOS half of the EPIC-12 (GPX) and EPIC-13 (aggregation + wide layout) cross-platform
/// fixtures — the exit criterion "the same input produces byte-identical output on both platforms".
///
/// What this pins is the *serialization contract* of the two new writers: given one frozen input,
/// what exact bytes do `GPXWriter`, `MetricAggregator` and `WideCSVProjector` produce? These are
/// where the two platforms diverge silently — a coordinate on a dyadic rational (`25 + 1/256`) that
/// C's `printf("%.7f")` rounds one way and the JVM's `String.format("%.7f")` rounds the other, a
/// DST-transition day whose length depends on getting the offset arithmetic right, a mixed-zone
/// bucket that has to agree on which zone anchors it. None of it is visible from inside one platform.
///
/// The golden artifacts live in `packages/fixtures/gpx/` and `packages/fixtures/aggregation/`, read
/// from the repo. The Android half is
/// `apps/android/app/src/test/java/net/albayyan/badan/GpxAggregationParityTest.kt`, which reads the
/// SAME inputs, builds the SAME objects, and must produce the same bytes through its own writers.
///
/// Fixtures are read from disk, never copied into either platform's source — same reasoning, same
/// shape, as `ExportSchemaParityTests` and `CanonicalizationParityTests`.
final class GPXAggregationParityTests: XCTestCase {

    // MARK: - EPIC-12: GPX

    func testGPXRoutesMatchTheSharedGoldensByte() throws {
        let input = try Self.json(Self.gpxDir, "gpx-input-v1.json")
        let appVersion = input["appVersion"] as! String
        let generatedAt = Self.date(input["generatedAtMillis"] as! String)
        let enabled = input["routeExportEnabled"] as! Bool

        let workouts: [GPXWorkout] = (input["workouts"] as! [[String: Any]]).map { w in
            let routes: [GPXRoute] = (w["routes"] as! [[String: Any]]).map { r in
                let routeId = r["routeId"] as! String
                let points: [RoutePoint] = (r["points"] as! [[String: Any]]).map { p in
                    let ele = p["ele"] as? String
                    return RoutePoint(routeId: routeId, seq: Int(p["seq"] as! String)!,
                                      latitude: Double(p["lat"] as! String)!,
                                      longitude: Double(p["lon"] as! String)!,
                                      altitudeMeters: ele.map { Double($0)! },
                                      horizontalAccuracyMeters: nil,
                                      timestamp: Self.date(p["ts"] as! String))
                }
                return GPXRoute(routeId: routeId, points: points)
            }
            return GPXWorkout(workoutId: w["workoutId"] as! String, name: w["name"] as! String, routes: routes)
        }

        let plan = RouteExportPlan.make(workouts)
        let confirmation = RouteExportConfirmation(acknowledging: plan, from: workouts)
        let artifacts = try GPXWriter(appVersion: appVersion, generatedAt: generatedAt)
            .artifacts(for: workouts, routeExportEnabled: enabled, confirmation: confirmation)

        XCTAssertEqual(artifacts.count, workouts.count, "one GPX file per workout")
        for artifact in artifacts {
            try Self.assertGolden(Self.gpxDir, artifact.fileName, Data(artifact.gpx.utf8))
        }
    }

    /// The two route-export gates are independent and both enforced *before* any bytes are written.
    /// Asserted rather than assumed because "requires the route-export toggle" and "confirm the
    /// exact route set" are this feature's privacy contract, not implementation details.
    func testGPXRefusesWithoutToggleAndOnStaleConfirmation() throws {
        let workouts = [GPXWorkout(workoutId: "01JQZ8WKATRN00000000000001", name: "run",
                                   routes: [GPXRoute(routeId: "r", points: [RoutePoint(routeId: "r", seq: 0,
                                       latitude: 1, longitude: 2, timestamp: Date(timeIntervalSince1970: 1))])])]
        let confirmation = RouteExportConfirmation(acknowledging: .make(workouts), from: workouts)
        let writer = GPXWriter(appVersion: "0.1.0", generatedAt: Date(timeIntervalSince1970: 0))

        XCTAssertThrowsError(try writer.artifacts(for: workouts, routeExportEnabled: false,
                                                  confirmation: confirmation)) { error in
            XCTAssertEqual(error as? GPXExportError, .routeExportNotEnabled)
        }

        let other = [GPXWorkout(workoutId: "01JQZ8WKACTY00000000000002", name: "ride",
                                routes: [GPXRoute(routeId: "r2", points: [RoutePoint(routeId: "r2", seq: 0,
                                    latitude: 3, longitude: 4, timestamp: Date(timeIntervalSince1970: 2))])])]
        let stale = RouteExportConfirmation(acknowledging: .make(other), from: other)
        XCTAssertThrowsError(try writer.artifacts(for: workouts, routeExportEnabled: true, confirmation: stale)) { error in
            guard case .confirmationStale = (error as? GPXExportError) else {
                return XCTFail("expected confirmationStale, got \(error)")
            }
        }
    }

    // MARK: - EPIC-13: aggregation + wide

    func testAggregationRecordsAndWideMatchTheSharedGoldensByte() throws {
        let (rows, defs) = try Self.aggregationFixture()
        let agg = MetricAggregator()
        let hint = agg.aggregate(rows: rows, granularity: .day, method: nil, definitions: defs)
        let mam = agg.aggregate(rows: rows, granularity: .day, method: .minAvgMax, definitions: defs)

        try Self.assertGolden(Self.aggDir, "records-hint-v1.csv", Data(Self.recordsCSV(hint).utf8))
        try Self.assertGolden(Self.aggDir, "records-minavgmax-v1.csv", Data(Self.recordsCSV(mam).utf8))
        try Self.assertGolden(Self.aggDir, "wide-v1.csv", Data(WideCSVProjector().render(mam).utf8))
    }

    /// DST and timezone-change correctness on the record fields the wide layout drops. Same values
    /// the shared golden dump carries (bucket_start_ms / bucket_end_ms / contributing_tzs), stated
    /// readably here so the fixture's choice of dates is explained rather than mysterious.
    func testAggregationHandlesDSTAndTimezoneChanges() throws {
        let (rows, defs) = try Self.aggregationFixture()
        let hint = MetricAggregator().aggregate(rows: rows, granularity: .day, method: nil, definitions: defs)

        let spring = try XCTUnwrap(hint.first { $0.metricId == "activity.steps" && $0.bucketKey == "2026-03-08" })
        XCTAssertEqual(Int64(spring.bucketEnd.timeIntervalSince(spring.bucketStart) * 1000), 82_800_000, "23h day")

        let fall = try XCTUnwrap(hint.first { $0.metricId == "activity.steps" && $0.bucketKey == "2026-11-01" })
        XCTAssertEqual(Int64(fall.bucketEnd.timeIntervalSince(fall.bucketStart) * 1000), 90_000_000, "25h day")

        let mixed = try XCTUnwrap(hint.first { $0.metricId == "heart.hr" && $0.bucketKey == "2026-06-20" })
        XCTAssertEqual(mixed.contributingTimezones, ["America/New_York", "Asia/Dubai"])
        XCTAssertEqual(mixed.tzId, "Asia/Dubai", "boundaries anchored in the earliest row's zone")
        XCTAssertTrue(mixed.spansMultipleTimezones)
    }

    func testAggregationComputesDurationAndLatest() throws {
        let (rows, defs) = try Self.aggregationFixture()
        let agg = MetricAggregator()
        let duration = try XCTUnwrap(agg.aggregate(rows: rows, granularity: .day, method: .duration, definitions: defs)
            .first { $0.metricId == "activity.distance" && $0.bucketKey == "2026-03-08" })
        XCTAssertEqual(duration.value, 7200, accuracy: 0)
        XCTAssertEqual(duration.unit, "s")
        let latest = try XCTUnwrap(agg.aggregate(rows: rows, granularity: .day, method: .latest, definitions: defs)
            .first { $0.metricId == "activity.distance" && $0.bucketKey == "2026-03-08" })
        XCTAssertEqual(latest.value, 1500, accuracy: 0)
    }

    func testRegenerationSwitchIsNeverAPass() {
        if ProcessInfo.processInfo.environment["BADAN_REGENERATE_EXPORT_GOLDENS"] == "true" {
            XCTFail("goldens were regenerated from THIS platform's output. Run "
                + "scripts/check_fixture_hashes.sh --update, then run BOTH suites with the switch OFF.")
        }
    }

    // MARK: - Fixture plumbing

    static let repoRoot = URL(fileURLWithPath: #filePath) // apps/ios/Tests/GPXAggregationParityTests.swift
        .deletingLastPathComponent()  // apps/ios/Tests
        .deletingLastPathComponent()  // apps/ios
        .deletingLastPathComponent()  // apps
        .deletingLastPathComponent()  // <repo root>
    private static let gpxDir = repoRoot.appendingPathComponent("packages/fixtures/gpx", isDirectory: true)
    private static let aggDir = repoRoot.appendingPathComponent("packages/fixtures/aggregation", isDirectory: true)

    private static func date(_ ms: String) -> Date { Date(timeIntervalSince1970: Double(ms)! / 1000.0) }

    private static func aggregationFixture() throws -> ([AggregateInputRow], [String: MetricDefinition]) {
        let input = try json(aggDir, "aggregation-input-v1.json")
        var defs: [String: MetricDefinition] = [:]
        for d in input["definitions"] as! [[String: Any]] {
            let id = d["metricId"] as! String
            defs[id] = MetricDefinition(metricId: id, family: "",
                                        kind: MetricKind(rawValue: d["kind"] as! String) ?? .rawSample,
                                        canonicalUnit: d["canonicalUnit"] as! String, displayUnits: [],
                                        nameEn: "", nameAr: "", casualLabel: "", preciseLabel: "",
                                        chartHint: .line, baselineEligible: false, sensitiveClass: .normal)
        }
        let rows: [AggregateInputRow] = (input["rows"] as! [[String: Any]]).map { r in
            let endMs = r["endMs"] as? String
            let stored = r["storedAggregation"] as? String
            return AggregateInputRow(metricId: r["metricId"] as! String,
                                     value: Double(r["value"] as! String)!, unit: r["unit"] as! String,
                                     startAt: date(r["startMs"] as! String), endAt: endMs.map { date($0) },
                                     tzId: r["tzId"] as! String,
                                     storedAggregation: stored.flatMap { Aggregation(rawValue: $0) })
        }
        return (rows, defs)
    }

    /// Test-only serialization of the aggregator's records. NOT the product tidy CSV (CSVWriter owns
    /// that); this dumps every `AggregateRecord` field so DST instants and mixed-zone provenance are
    /// pinned cross-platform. Must stay byte-identical to Android `GpxAggregationParityTest.recordsCsv`.
    static func recordsCSV(_ records: [AggregateRecord]) -> String {
        let cols = ["metric_id", "bucket_key", "granularity", "aggregation_method", "value", "unit",
                    "bucket_start_ms", "bucket_end_ms", "tz_id", "contributing_tzs", "sample_count"]
        var out = cols.map(CSVWriter.escape).joined(separator: ",")
        for r in records {
            let cells: [String] = [
                r.metricId, r.bucketKey, r.granularity.rawValue, r.stat.csvMethod.rawValue,
                CSVWriter.decimal(r.value), r.unit,
                String(Int64(r.bucketStart.timeIntervalSince1970 * 1000)),
                String(Int64(r.bucketEnd.timeIntervalSince1970 * 1000)),
                r.tzId, r.contributingTimezones.joined(separator: ";"), String(r.sampleCount),
            ]
            out += CSVWriter.newline + cells.map(CSVWriter.escape).joined(separator: ",")
        }
        return out + CSVWriter.newline
    }

    private static func json(_ dir: URL, _ fileName: String) throws -> [String: Any] {
        let data = try readVerified(dir, fileName)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Byte comparison, or a rewrite when `BADAN_REGENERATE_EXPORT_GOLDENS=true` (which always fails
    /// the run so a rewrite can never be mistaken for a pass — see `testRegenerationSwitchIsNeverAPass`).
    static func assertGolden(_ dir: URL, _ fileName: String, _ produced: Data) throws {
        if ProcessInfo.processInfo.environment["BADAN_REGENERATE_EXPORT_GOLDENS"] == "true" {
            try produced.write(to: dir.appendingPathComponent(fileName))
            return
        }
        let expected = try readVerified(dir, fileName)
        XCTAssertEqual(produced, expected, "\(fileName) is not byte-identical to what this platform's writer produced")
    }

    /// Reads a shared fixture and checks its SHA-256 against the manifest before returning it.
    static func readVerified(_ dir: URL, _ fileName: String) throws -> Data {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw FixtureError.unreadable("missing fixture manifest at \(manifestURL.path)")
        }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let files = try XCTUnwrap(root["files"] as? [[String: Any]], "fixture manifest has no `files` array")
        let entry = try XCTUnwrap(files.first { $0["file"] as? String == fileName },
                                  "fixture manifest has no entry for '\(fileName)'")

        let fileURL = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw FixtureError.unreadable("missing fixture at \(fileURL.path)")
        }
        if ProcessInfo.processInfo.environment["BADAN_REGENERATE_EXPORT_GOLDENS"] != "true" {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, entry["sha256"] as? String,
                           "fixture '\(fileName)' does not match the SHA-256 in manifest.json — the shared "
                           + "artifact changed underneath this test.")
        }
        return data
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String { switch self { case .unreadable(let m): return m } }
    }
}
