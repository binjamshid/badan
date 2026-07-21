import XCTest
@testable import BADAN

/// EPIC-31 — the encoded `ReportModel` conforms to the shared contract,
/// `packages/contracts/report_model.schema.json`.
///
/// The point of writing the report model as a real JSON Schema rather than prose is that something
/// can check it. Nothing did until this test, which made "shared shape" a claim about a file rather
/// than about what either platform emits. It reads the contract from the repo (the same way
/// `CanonicalizationParityTests` reads its fixture) and walks the encoded model against it: required
/// keys present, no key the contract does not declare, patterns and enums honoured. The Android half
/// is `ReportModelSchemaTest.kt`, driven by the same file.
///
/// Deliberately not a general JSON Schema engine — it validates the subset this contract uses
/// (`required`, `additionalProperties: false`, `pattern`, `enum`, `$ref`), so a drift in the model's
/// FIELD NAMES or enum cases fails here rather than silently making the contract fiction.
final class ReportModelSchemaTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath) // apps/ios/Tests/ReportModelSchemaTests.swift
        .deletingLastPathComponent()  // apps/ios/Tests
        .deletingLastPathComponent()  // apps/ios
        .deletingLastPathComponent()  // apps
        .deletingLastPathComponent()  // <repo root>

    private var schema: [String: Any]!
    private var definitions: [String: Any]!

    override func setUpWithError() throws {
        let url = Self.repoRoot.appendingPathComponent("packages/contracts/report_model.schema.json")
        let data = try Data(contentsOf: url)
        schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                               "report_model.schema.json is not a JSON object")
        definitions = (schema["definitions"] as? [String: Any]) ?? [:]
    }

    // MARK: - Sample models

    private let tz = "UTC"
    private let now = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07-14 03:33 UTC, ISO 2026-W29

    /// A model exercising every section kind, so every `$ref` in the contract is walked.
    private func fullModel() -> ReportModel {
        let period = ReportPeriod.week(containing: now, tz: tz)
        let prior = ReportPeriod.prior(period, tz: tz)
        func dv(_ metric: String, _ day: String, _ v: Double) -> DerivedValue {
            DerivedValue(id: ULID.newID(), metricId: metric, value: v, unit: "score_0_100",
                         periodKey: "day:" + day, algorithmId: "t", algorithmVersion: "1",
                         computedAt: now, updatedAt: now, originDeviceId: "d")
        }
        let cur = period.dayKeys.prefix(4).map { dv(MetricID.readinessScore, $0, 80) }
        let pri = prior.dayKeys.prefix(4).map { dv(MetricID.readinessScore, $0, 60) }
        let sleep = period.dayKeys.prefix(3).map { dv(MetricID.sleepPerformance, $0, 70) }
        let effort = period.dayKeys.prefix(3).map { dv(MetricID.effortDay, $0, 55) }
        let events = [
            AdherenceEvent(id: ULID.newID(), regimenId: "r", kind: .taken, occurredAt: period.start,
                           tzId: tz, updatedAt: now, originDeviceId: "d"),
        ]
        return ReportBuilder.build(.init(
            period: period, prior: prior,
            currentByMetric: [MetricID.readinessScore: Array(cur),
                              MetricID.sleepPerformance: Array(sleep),
                              MetricID.effortDay: Array(effort)],
            priorByMetric: [MetricID.readinessScore: Array(pri)],
            adherence: events, generatedAt: now))
    }

    private func emptyModel() -> ReportModel {
        let period = ReportPeriod.week(containing: now, tz: tz)
        return ReportBuilder.build(.init(period: period, prior: ReportPeriod.prior(period, tz: tz),
                                         currentByMetric: [:], priorByMetric: [:],
                                         adherence: [], generatedAt: now))
    }

    private func encoded(_ model: ReportModel) throws -> [String: Any] {
        let data = try JSONCoding.encoder.encode(model)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Conformance

    func testFullModelConformsToTheContract() throws {
        let model = fullModel()
        // The sample must actually exercise every section kind, or "walks every $ref" is a lie.
        XCTAssertEqual(Set(model.sectionsIncluded),
                       Set(ReportSectionKind.allCases.map { $0.rawValue }),
                       "the schema sample must cover every section kind")
        try validate(try encoded(model), against: schema, at: "<root>")
    }

    func testEmptyModelConformsToTheContract() throws {
        let object = try encoded(emptyModel())
        XCTAssertEqual(object["hasSufficientData"] as? Bool, false)
        XCTAssertEqual((object["sections"] as? [Any])?.count, 0)
        try validate(object, against: schema, at: "<root>")
    }

    /// The version the model stamps and the version the contract declares are one fact in two files.
    func testSchemaVersionAgreesWithTheContract() throws {
        let declared = try XCTUnwrap((schema["properties"] as? [String: Any])
            .flatMap { $0["schemaVersion"] as? [String: Any] }
            .flatMap { $0["const"] as? String })
        XCTAssertEqual(ReportModel.schemaVersionValue, declared,
                       "ReportModel.schemaVersionValue must equal the contract's schemaVersion const")
    }

    /// Instants are epoch millis in the contract; a date encoded any other way would still "validate"
    /// as a number, so the wholeness of the value is what is actually asserted.
    func testInstantsAreWholeEpochMillis() throws {
        let object = try encoded(fullModel())
        for key in ["periodStart", "periodEnd", "generatedAt"] {
            let value = try XCTUnwrap(object[key] as? Double, "\(key) must be a number")
            XCTAssertEqual(value, value.rounded(.down), "\(key) must be whole epoch millis")
            XCTAssertGreaterThan(value, 1_000_000_000_000, "\(key) must be millis, not seconds")
        }
    }

    // MARK: - Tiny validator (the subset this contract uses)

    private func validate(_ value: Any, against node: [String: Any], at path: String) throws {
        var node = node
        if let ref = node["$ref"] as? String {
            node = try resolve(ref)
        }
        // `oneOf` is used only for "this object or null" (the optional adherence summary).
        if let options = node["oneOf"] as? [[String: Any]] {
            if value is NSNull { return }
            for option in options where (option["type"] as? String) != "null" {
                try validate(value, against: option, at: path)
                return
            }
            return
        }

        switch node["type"] as? String {
        case "object":
            let object = try XCTUnwrap(value as? [String: Any], "\(path): expected an object")
            let properties = (node["properties"] as? [String: Any]) ?? [:]
            for key in (node["required"] as? [String]) ?? [] {
                XCTAssertNotNil(object[key], "\(path): contract requires `\(key)`, model omitted it")
            }
            if (node["additionalProperties"] as? Bool) == false {
                for key in object.keys {
                    XCTAssertNotNil(properties[key],
                                    "\(path): model emitted `\(key)`, which the contract does not declare")
                }
            }
            for (key, child) in object {
                guard let childSchema = properties[key] as? [String: Any] else { continue }
                try validate(child, against: childSchema, at: "\(path).\(key)")
            }
        case "array":
            let array = try XCTUnwrap(value as? [Any], "\(path): expected an array")
            if let items = node["items"] as? [String: Any] {
                for (i, element) in array.enumerated() {
                    try validate(element, against: items, at: "\(path)[\(i)]")
                }
            }
        case "string":
            let string = try XCTUnwrap(value as? String, "\(path): expected a string")
            if let const = node["const"] as? String {
                XCTAssertEqual(string, const, "\(path): must be the contract's const")
            }
            if let allowed = node["enum"] as? [String] {
                XCTAssertTrue(allowed.contains(string), "\(path): `\(string)` is not in the contract's enum \(allowed)")
            }
            if let pattern = node["pattern"] as? String {
                XCTAssertNotNil(string.range(of: pattern, options: .regularExpression),
                                "\(path): `\(string)` does not match the contract's pattern \(pattern)")
            }
        case "integer", "number":
            XCTAssertTrue(value is NSNumber, "\(path): expected a number")
        case "boolean":
            XCTAssertTrue(value is NSNumber, "\(path): expected a boolean")
        default:
            break   // ["number", "null"] unions and untyped nodes: nothing further to assert.
        }
    }

    private func resolve(_ ref: String) throws -> [String: Any] {
        let name = String(ref.dropFirst("#/definitions/".count))
        return try XCTUnwrap(definitions[name] as? [String: Any], "unresolvable $ref \(ref)")
    }
}
