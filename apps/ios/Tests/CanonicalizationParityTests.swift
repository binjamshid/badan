import CryptoKit
import Foundation
import XCTest
@testable import BADAN

/// The iOS half of the cross-platform canonical-output fixture (Phase-0 exit criterion, plan §19:
/// "widened ingestion fixtures pass identically both platforms").
///
/// This file is the assertion whose absence the Phase-0 audit found. The shared golden already
/// existed in spirit — fourteen rows hardcoded inside Android's
/// `HealthConnectCanonicalParityTest`, under a docstring stating that "iOS's equivalent fixture
/// feeds the same as-received values through its own `Units` and must produce a byte-identical
/// block". There was no iOS equivalent. Nothing here compared against those rows, nothing would
/// have failed if this platform's `Units` had diverged, and the exit criterion was asserted on
/// one platform while being written as if it were asserted on two.
///
/// The rows now live in `packages/fixtures/canonicalization/canonical-rows-v1.json`, read from the
/// repo by both suites. `HealthConnectCanonicalParityTest.kt` is the mirror. Neither test is
/// sufficient alone: a shared misunderstanding of a unit would still round-trip within one
/// platform, which is exactly how a kcal/kJ or percent/fraction divergence stays invisible — both
/// numbers render plausibly on their own screen.
///
/// What is pinned is the *canonicalization contract*: given a reading as a source reported it
/// (metric id + value + unit), what value, in what unit, does BADAN store? That is the layer where
/// the platforms can diverge silently, and it is reachable in a pure unit test on both sides,
/// which the database layer is not.
final class CanonicalizationParityTests: XCTestCase {

    // MARK: - The shared fixture (the acceptance criterion)

    /// Every row's as-received value, through this platform's `Units`, lands on the fixture's
    /// canonical pair — the exact conversion `IngestionPipeline.canonicalValue` performs.
    ///
    /// Both `convert` and `toCanonical` are asserted, and the `convert` leg is the load-bearing
    /// one. `toCanonical` swallows an unknown or incompatible unit and returns the value unchanged
    /// (right for ingestion — a bad unit must not crash the pipeline, it is flagged `.estimate`
    /// upstream), so for every identity row an entirely *missing* unit produces the same number as
    /// a correct conversion. A fixture asserted through `toCanonical` alone would pass while a
    /// platform's table had lost the dimension — the `vo2max-lowercase-litre` row is a promoted
    /// example: it read correctly through `toCanonical` on Android for a whole round while
    /// `ml/kg/min` was absent from that table entirely, and only the `convert` leg caught it.
    ///
    /// Values are compared for exact equality, not with an accuracy tolerance. The fixture records
    /// what is genuinely stored, residue included — `Units.table` holds the kJ leg as `0.239005736`
    /// and divides by it, so 500 kcal canonicalizes to 2092.0000012049923 rather than 2092. Both
    /// platforms perform the identical IEEE-754 operations on the identical inputs; a tolerance
    /// here would let one of them reorder the arithmetic and still pass, which is the divergence
    /// this fixture exists to catch.
    func testEveryFixtureRowCanonicalizesToTheSharedGolden() throws {
        let canonical = try Self.registryCanonicalUnits()

        for row in try Self.fixtureRows() {
            XCTAssertEqual(canonical[row.metricId], row.canonicalUnit,
                           """
                           \(row.id): registry.json says \(row.metricId)'s canonical unit is \
                           '\(canonical[row.metricId] ?? "nil")', the fixture says \
                           '\(row.canonicalUnit)' — the contract moved under the golden
                           """)
            // The bundled mirror too, not just the contract file: `BundleJSON` loads
            // `Sources/Resources/registry.json`, and a stale mirror means the app canonicalizes
            // against a registry this test never looked at.
            XCTAssertEqual(MetricRegistry.shared.definition(row.metricId)?.canonicalUnit, row.canonicalUnit,
                           "\(row.id): the bundled registry mirror disagrees — run scripts/sync_ios_resources.sh")

            let converted: Double
            do {
                converted = try Units.convert(row.value, from: row.unit, to: row.canonicalUnit)
            } catch {
                XCTFail("""
                        \(row.id): Units cannot convert '\(row.unit)' to '\(row.canonicalUnit)' \
                        (\(error)). Android can — see the row's `emittedBy`. An unknown unit is not \
                        a crash at runtime, it is worse: the value is stored unconverted and \
                        stamped .estimate.
                        """)
                continue
            }

            XCTAssertEqual(converted, row.canonicalValue, "\(row.id): canonical value")
            XCTAssertEqual(Units.toCanonical(row.value, from: row.unit, canonical: row.canonicalUnit),
                           row.canonicalValue,
                           """
                           \(row.id): Units.toCanonical (the path IngestionPipeline actually takes) \
                           disagrees with Units.convert
                           """)
        }
    }

    /// The rows that claim to arrive through HealthKit must still match what `HKTypeMap` actually
    /// reads them out in. The two platforms deliberately receive different units for some metrics
    /// — Health Connect hands back kilojoules and `%`, HealthKit kilocalories and a 0–1 fraction —
    /// so the fixture carries both spellings and each suite checks its own table against them.
    /// Without this, the fixture could drift into describing units no adapter emits.
    func testFixtureRowsAgreeWithTheUnitsHKTypeMapReads() throws {
        for row in try Self.fixtureRows() {
            for platformType in row.healthKitTypes {
                let entry = try XCTUnwrap(HKTypeMap.table.first { $0.platformType == platformType },
                                          "\(row.id): fixture names HKTypeMap type '\(platformType)', which no longer exists")
                XCTAssertEqual(entry.metricId, row.metricId, "\(row.id): \(platformType)'s metric id")
                XCTAssertEqual(entry.badanUnit, row.unit,
                               """
                               \(row.id): \(platformType) reads out in '\(entry.badanUnit)' but the \
                               fixture was written against '\(row.unit)' — update the fixture and \
                               re-run BOTH suites
                               """)
            }
        }
    }

    /// Coverage, stated as an assertion rather than assumed: every HealthKit type that produces a
    /// measurement row has a golden. "Widened ingestion fixtures" is the exit criterion; a widened
    /// read set with an un-widened fixture set meets it only on paper.
    ///
    /// Filtered to entries with a metric id, because the `.authorizationOnly` types (height,
    /// sleeping wrist temperature) deliberately store nothing and have no canonical value to pin —
    /// see `HKTypeMap.NoIngestReason`.
    func testEveryIngestedHealthKitTypeHasAFixtureRow() throws {
        let covered = Set(try Self.fixtureRows().flatMap(\.healthKitTypes))
        let uncovered = HKTypeMap.table
            .filter { $0.metricId != nil }
            .map(\.platformType)
            .filter { !covered.contains($0) }
            .sorted()

        XCTAssertTrue(uncovered.isEmpty,
                      """
                      HealthKit types that produce rows but have no fixture row: \(uncovered) — add \
                      one to packages/fixtures/canonicalization/canonical-rows-v1.json (with the \
                      Health Connect spelling too, if HcTypeMap reads the same metric in a \
                      different unit)
                      """)
    }

    /// The divergences the fixture declares must still describe THIS platform. Stated as a test so
    /// a known gap cannot quietly become a stale note: whoever closes a gap gets a failure here
    /// telling them to promote the entry into `rows`, and if a platform ever *loses* a unit it
    /// already had, this fails too.
    ///
    /// `knownDivergences` is currently empty — `brpm` and `ml/kg/min` were both promoted once
    /// Android's `Units.kt` caught up with EPIC-01 — so this test asserts nothing today. It is
    /// deliberately kept: it is the mechanism, not the two entries that happened to need it, and
    /// an empty loop here is the honest representation of "the platforms agree on every unit in
    /// the fixture". A divergence that gets fixed and stays listed is a lie with a longer
    /// half-life than the bug was, which is why these are declared rather than silently omitted.
    func testKnownDivergencesStillDescribeThisPlatform() throws {
        for divergence in try Self.fixtureDivergences() {
            var outcome = "converts"
            do {
                _ = try Units.convert(divergence.value, from: divergence.unit, to: divergence.canonicalUnit)
            } catch Units.ConversionError.unknownUnit {
                outcome = "unknownUnit"
            } catch Units.ConversionError.incompatible {
                outcome = "incompatible"
            }
            XCTAssertEqual(outcome, divergence.ios,
                           """
                           known divergence '\(divergence.id)' says iOS does '\(divergence.ios)' with \
                           '\(divergence.unit)', but it now does '\(outcome)'. If you just changed \
                           Units.swift: \(divergence.fix)
                           """)
        }
    }

    // MARK: - Fixture model

    private struct Row {
        let id: String
        let metricId: String
        /// Parsed from a string with `Double(_:)` rather than read as a JSON number: the values
        /// are compared for exact IEEE-754 equality, so the parse has to be the correctly-rounded
        /// one on both platforms rather than whatever each platform's JSON number handling decides
        /// a bare numeric literal is. See the fixture README.
        let value: Double
        let unit: String
        let canonicalUnit: String
        let canonicalValue: Double
        let emittedBy: [String]

        /// The `HKTypeMap` platform types (an `HKQuantityTypeIdentifier` raw value) this row
        /// claims to arrive through, if any.
        var healthKitTypes: [String] {
            emittedBy.filter { $0.hasPrefix(hkPrefix) }.map { String($0.dropFirst(hkPrefix.count)) }
        }
    }

    private struct Divergence {
        let id: String
        let value: Double
        let unit: String
        let canonicalUnit: String
        let ios: String
        let fix: String
    }

    private static let fixtureId = "canonical-rows-v1"
    private static let hkPrefix = "HKTypeMap:"

    // MARK: - Shared fixture loading

    /// The repo root, located relative to `#filePath` (this file's own compile-time path) rather
    /// than through `Bundle`.
    ///
    /// The fixture is deliberately outside the app bundle, and adding a resources rule to
    /// `project.yml` to copy it into the test bundle would put a build-system step between the
    /// artifact and the assertion — the copy could then go stale while both suites stayed green,
    /// which is the whole failure mode this fixture set exists to close. Simulator test processes
    /// run on the host and can read the checkout directly. If this ever fails on a machine or CI
    /// runner where that is not true, the fix is to bundle the fixture as a test resource, NOT to
    /// re-embed the rows as a literal here. Same reasoning, same shape, as
    /// `ExportEncryptionTests.loadFixture`.
    private static let repoRoot = URL(fileURLWithPath: #filePath) // apps/ios/Tests/CanonicalizationParityTests.swift
        .deletingLastPathComponent()  // apps/ios/Tests
        .deletingLastPathComponent()  // apps/ios
        .deletingLastPathComponent()  // apps
        .deletingLastPathComponent()  // <repo root>

    /// Reads the shared fixture and checks its SHA-256 against the manifest before parsing.
    ///
    /// A missing file or a bad digest FAILS here; it never skips. Without the digest check, a
    /// fixture mangled in transit (a text-mode checkout, a bad merge, a well-meaning reformat)
    /// would surface as a canonicalization mismatch — technically true, and exactly the wrong
    /// thing to hand someone debugging a cross-platform disagreement.
    /// `scripts/check_fixture_hashes.sh` is the out-of-band version of this check.
    private static func fixtureData() throws -> Data {
        let directory = repoRoot.appendingPathComponent("packages/fixtures/canonicalization", isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw FixtureError.unreadable("""
                missing fixture manifest at \(manifestURL.path) — see \
                packages/fixtures/canonicalization/README.md
                """)
        }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                                 "fixture manifest is not a JSON object: \(manifestURL.path)")
        let files = try XCTUnwrap(root["files"] as? [[String: Any]],
                                  "fixture manifest has no `files` array")
        let entry = try XCTUnwrap(files.first { $0["id"] as? String == fixtureId },
                                  "fixture manifest has no entry '\(fixtureId)'")

        let fileURL = directory.appendingPathComponent(try XCTUnwrap(entry["file"] as? String))
        guard let data = try? Data(contentsOf: fileURL) else {
            throw FixtureError.unreadable("missing fixture at \(fileURL.path)")
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, entry["sha256"] as? String,
                       """
                       fixture '\(fixtureId)' does not match the SHA-256 recorded in manifest.json — \
                       the shared artifact changed underneath this test. Do NOT run \
                       scripts/check_fixture_hashes.sh --update to make this pass unless you meant \
                       to change the fixture; see packages/fixtures/canonicalization/README.md
                       """)
        return data
    }

    /// Each step is bound to a `let` before the next one uses it, rather than nested inside a
    /// `try XCTUnwrap(...)`. `XCTUnwrap` reports a throw from inside its autoclosure under ITS
    /// OWN message, so nesting these turns "missing fixture at <path>" into "shared fixture is
    /// not a JSON object" — a diagnostic that names the wrong problem, on the exact failure this
    /// loader exists to make legible.
    private static func fixtureObject() throws -> [String: Any] {
        let data = try fixtureData()
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "shared fixture is not a JSON object")
    }

    private static func fixtureRows() throws -> [Row] {
        let object = try fixtureObject()
        let raw = try XCTUnwrap(object["rows"] as? [[String: Any]], "shared fixture has no `rows` array")
        let rows: [Row] = try raw.map { row in
            let id = try XCTUnwrap(row["id"] as? String, "a row in the shared fixture has no `id`")
            return Row(id: id,
                       metricId: try XCTUnwrap(row["metricId"] as? String, "\(id): no `metricId`"),
                       value: try Self.double(row["value"], field: "value", of: id),
                       unit: try XCTUnwrap(row["unit"] as? String, "\(id): no `unit`"),
                       canonicalUnit: try XCTUnwrap(row["canonicalUnit"] as? String, "\(id): no `canonicalUnit`"),
                       canonicalValue: try Self.double(row["canonicalValue"], field: "canonicalValue", of: id),
                       emittedBy: try XCTUnwrap(row["emittedBy"] as? [String], "\(id): no `emittedBy`"))
        }
        // An empty read reads as "everything passed" to every loop above. The floor is the
        // fourteen rows this fixture started life with, so a truncated file fails rather than
        // vacuously succeeding.
        XCTAssertGreaterThanOrEqual(rows.count, 14, "shared fixture parsed to only \(rows.count) rows")
        return rows
    }

    private static func fixtureDivergences() throws -> [Divergence] {
        let object = try fixtureObject()
        let raw = try XCTUnwrap(object["knownDivergences"] as? [[String: Any]],
                                "shared fixture has no `knownDivergences` array")
        return try raw.map { entry in
            let id = try XCTUnwrap(entry["id"] as? String, "a knownDivergences entry has no `id`")
            return Divergence(id: id,
                              value: try Self.double(entry["value"], field: "value", of: id),
                              unit: try XCTUnwrap(entry["unit"] as? String, "\(id): no `unit`"),
                              canonicalUnit: try XCTUnwrap(entry["canonicalUnit"] as? String,
                                                           "\(id): no `canonicalUnit`"),
                              ios: try XCTUnwrap(entry["ios"] as? String, "\(id): no `ios`"),
                              fix: try XCTUnwrap(entry["fix"] as? String, "\(id): no `fix`"))
        }
    }

    /// Parses one of the fixture's string-encoded numbers. `Double(String)` is the
    /// correctly-rounded path, which is the whole reason the fixture stores these as strings
    /// rather than as JSON numbers — see the fixture README.
    private static func double(_ raw: Any?, field: String, of id: String) throws -> Double {
        let text = try XCTUnwrap(raw as? String,
                                 "\(id): `\(field)` must be a STRING, not a JSON number — see the fixture README")
        return try XCTUnwrap(Double(text), "\(id): `\(field)` is '\(text)', which is not a Double")
    }

    /// The registry's canonical unit per metric, read from the contract file both platforms build
    /// against rather than from the bundled mirror — so a registry change breaks this test instead
    /// of quietly making the goldens describe a unit BADAN no longer stores in. The mirror is
    /// checked separately, per row, against this.
    private static func registryCanonicalUnits() throws -> [String: String] {
        let url = repoRoot.appendingPathComponent("packages/metric-ontology/registry.json")
        guard let data = try? Data(contentsOf: url) else {
            throw FixtureError.unreadable("contract registry must be readable at \(url.path)")
        }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try XCTUnwrap(root["metrics"] as? [[String: Any]])
        return metrics.reduce(into: [String: String]()) { result, metric in
            if let id = metric["metricId"] as? String, let unit = metric["canonicalUnit"] as? String {
                result[id] = unit
            }
        }
    }

    /// A read failure is thrown rather than asserted so it aborts the test with the diagnostic
    /// attached, instead of failing and then continuing into a loop over zero rows — which would
    /// print one error and a pile of vacuous passes.
    private enum FixtureError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self {
            case .unreadable(let message): return message
            }
        }
    }
}
