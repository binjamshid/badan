import XCTest
@testable import BADAN

/// ADR-0011 / D-37 — the payload boundary, enforced rather than described.
///
/// The schema is the boundary: `additionalProperties: false` and closed enums are what stop
/// "footprint" quietly widening into "reading". These tests check the Swift type and the contract
/// still agree, and that a health value cannot reach the wire.
final class TelemetryPayloadSchemaTests: XCTestCase {

    /// Repo root from `#filePath`, the technique `ReportModelSchemaTests` already uses — so the
    /// CANONICAL contract is read, not the bundled mirror. A test that read the mirror would pass
    /// while the two had drifted, which is the failure the CI gate exists for.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // apps/ios/Tests
            .deletingLastPathComponent()   // apps/ios
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // <repo root>
    }

    private func schema() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("packages/contracts/telemetry/footprint.schema.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sampleBatch() -> FootprintBatch {
        FootprintBatch(appVersion: "1.1", contractVersion: "0.2.0", footprints: [
            Footprint(metricId: "readiness.score", algorithmId: "composite.readiness_score",
                      algorithmSemver: "2.0.0", direction: .over,
                      eventCountBucket: .tenToNineteen, calibrationApplied: true),
        ])
    }

    // MARK: - The loud one

    /// Build a payload in a world where the readings are known, serialise it, and assert none of
    /// them are in the bytes.
    ///
    /// The fixture uses distinctive values (readiness 72, offset −8, a real period key) precisely so
    /// a leak is findable by substring. `FootprintBuilder.Source` does not even have fields for
    /// these, which is the actual guarantee — this test is what fails if someone gives it one.
    func testFootprintPayloadContainsNoHealthValue() throws {
        let readiness = 72.0
        let offset = -8.0
        let periodKey = "day:2026-07-14"

        let batch = try XCTUnwrap(FootprintBuilder.build(
            from: [.init(metricId: "readiness.score", algorithmId: "composite.readiness_score",
                         algorithmSemver: "2.0.0", direction: .over, eventCount: 14,
                         calibrationApplied: true)],
            appVersion: "1.1", contractVersion: "0.2.0", floor: 10))

        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(batch), encoding: .utf8))

        for forbidden in ["72", "-8", "\(readiness)", "\(offset)", periodKey, "2026-07-14", "day:"] {
            XCTAssertFalse(json.contains(forbidden), """
                A health value reached the telemetry payload. This payload may carry which method a \
                user disagreed with — never what their reading was. Found "\(forbidden)" in: \(json). \
                See ADR-0011.
                """)
        }
    }

    /// No identifier of any kind. The absence is the decision (ADR-0011), and its cost —
    /// aggregates cannot be deduplicated — was accepted in exchange.
    func testFootprintPayloadCarriesNoIdentifierLocaleOrDevice() throws {
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(sampleBatch()), encoding: .utf8))
        for forbidden in ["deviceId", "installId", "userId", "locale", "region", "timeZone",
                         "timezone", "deviceModel", "osVersion", "identifier"] {
            XCTAssertFalse(json.lowercased().contains(forbidden.lowercased()),
                           "\(forbidden) reached the payload — ADR-0011 carries no identifier")
        }
    }

    // MARK: - Swift type ⟷ contract

    /// The encoded object must have EXACTLY the schema's required keys and no others. With
    /// `additionalProperties: false` on the server side, an extra Swift property would be rejected
    /// at the boundary — but silently adding one that the schema happens to allow is the real risk,
    /// so this compares both directions.
    func testTheEncodedBatchMatchesTheSchemasPropertySetExactly() throws {
        let schema = try schema()
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(sampleBatch())) as? [String: Any])

        XCTAssertEqual(Set(encoded.keys), Set(properties.keys),
                       "the Swift batch and the contract disagree about the batch's fields")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false,
                       "the schema must be closed — an open schema is not a boundary")
    }

    func testTheEncodedFootprintMatchesTheSchemasPropertySetExactly() throws {
        let schema = try schema()
        let definitions = try XCTUnwrap(schema["definitions"] as? [String: Any])
        let footprint = try XCTUnwrap(definitions["footprint"] as? [String: Any])
        let properties = try XCTUnwrap(footprint["properties"] as? [String: Any])

        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(sampleBatch())) as? [String: Any])
        let first = try XCTUnwrap((encoded["footprints"] as? [[String: Any]])?.first)

        XCTAssertEqual(Set(first.keys), Set(properties.keys),
                       "the Swift footprint and the contract disagree about a footprint's fields")
        XCTAssertEqual(footprint["additionalProperties"] as? Bool, false)
    }

    /// Closed enums, both sides. An open `direction` or bucket would let a future value carry more
    /// than the decision authorised.
    func testDirectionAndBucketEnumsMatchTheContractExactly() throws {
        let definitions = try XCTUnwrap(try schema()["definitions"] as? [String: Any])
        let properties = try XCTUnwrap(
            (definitions["footprint"] as? [String: Any])?["properties"] as? [String: Any])

        let contractDirections = try XCTUnwrap(
            (properties["direction"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(contractDirections), Set(FeedbackDirection.allCases.map(\.rawValue)))

        let contractBuckets = try XCTUnwrap(
            (properties["eventCountBucket"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(contractBuckets),
                       Set(Footprint.EventCountBucket.allCases.map(\.rawValue)))
    }

    /// The bundled mirror must equal the canonical contract. CI gates this too, but a local failure
    /// is far cheaper than a red push — and the client validating against a drifted copy of the
    /// boundary is precisely the hazard.
    func testTheBundledSchemaMirrorMatchesTheCanonicalContract() throws {
        // Read straight from the bundle: `BundleJSON` decodes into a type, and the point here is
        // to compare the raw document rather than whatever a type would accept.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "footprint.schema", withExtension: "json"),
                                "footprint.schema.json is not in the app bundle — add it to the "
                                + "sync script and regenerate the project")
        let bundled = try Data(contentsOf: url)
        let mirrored = try XCTUnwrap(try JSONSerialization.jsonObject(with: bundled) as? NSDictionary)
        XCTAssertEqual(mirrored, try schema() as NSDictionary,
                       "the bundled schema has drifted from packages/contracts/telemetry/")
    }

    // MARK: - The floor

    /// Below the calibration minimum nothing is emitted at all — not a smaller bucket, not a zero.
    /// The floor is shared with `calibration.user_feedback_offset.minFeedbackEvents` so the two
    /// thresholds cannot drift apart.
    func testNothingIsEmittedBelowTheEventFloor() {
        let source = FootprintBuilder.Source(
            metricId: "readiness.score", algorithmId: "composite.readiness_score",
            algorithmSemver: "2.0.0", direction: .over, eventCount: 9, calibrationApplied: false)
        XCTAssertNil(FootprintBuilder.build(from: [source], appVersion: "1.1",
                                            contractVersion: "0.2.0", floor: 10),
                     "a count below the floor produced a payload — a count of 1 would re-identify a "
                     + "single tap, which is why there is no bucket beneath 10 at all")
    }

    func testTheEventFloorMatchesTheCalibrationMinimum() {
        let spec = CalibrationSpec.defaultShared
        XCTAssertTrue(spec.isLoaded)
        XCTAssertGreaterThanOrEqual(spec.minFeedbackEvents, 10,
                                    "the telemetry floor is 10 because that is the calibration "
                                    + "minimum; if the contract drops below 10 the two have drifted")
    }

    func testBucketBoundaries() {
        XCTAssertEqual(Footprint.EventCountBucket.bucket(for: 10, floor: 10), .tenToNineteen)
        XCTAssertEqual(Footprint.EventCountBucket.bucket(for: 19, floor: 10), .tenToNineteen)
        XCTAssertEqual(Footprint.EventCountBucket.bucket(for: 20, floor: 10), .twentyToFortyNine)
        XCTAssertEqual(Footprint.EventCountBucket.bucket(for: 49, floor: 10), .twentyToFortyNine)
        XCTAssertEqual(Footprint.EventCountBucket.bucket(for: 50, floor: 10), .fiftyPlus)
        XCTAssertEqual(Footprint.EventCountBucket.bucket(for: 5_000, floor: 10), .fiftyPlus)
    }
}
