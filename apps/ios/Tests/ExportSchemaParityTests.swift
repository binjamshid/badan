import CryptoKit
import Foundation
import XCTest
@testable import BADAN

/// The iOS half of the cross-platform export-schema fixture (Phase-1 exit criterion: "the same
/// store and scope produce byte-identical output on both platforms").
///
/// What this pins is the *serialization contract* at export schema 1.0.0: given one frozen set of
/// records, what exact bytes does BADAN write? That is the layer where the two platforms diverge
/// silently and expensively — `JSONEncoder` sorts keys while kotlinx emits them in declaration
/// order, Swift prints an integral `Double` as `512` and Kotlin as `512.0`, one platform escapes a
/// zero UTC offset as `Z` and the other as `+00:00` — and none of it is visible from inside one
/// platform, because each file parses perfectly well on the machine that wrote it. Before EPIC-08
/// three of those divergences were live simultaneously and both suites were green.
///
/// The golden artifacts are `packages/fixtures/export/bundle-v1.json`, `raw-v1.csv` and
/// `derived-v1.csv`, read from the repo. The Android half is
/// `apps/android/app/src/test/java/net/albayyan/badan/ExportSchemaParityTest.kt`, which reads the
/// SAME files, builds the SAME records from `export-input-v1.json`, and must produce the same bytes
/// through its own writers. Neither test is sufficient alone: a shared misunderstanding still
/// round-trips within one platform.
///
/// Fixtures are read from disk rather than copied into either platform's test sources — same
/// reasoning, same shape, as `CanonicalizationParityTests` and `ExportEncryptionTests`.
final class ExportSchemaParityTests: XCTestCase {

    // MARK: - The acceptance criterion

    /// The JSON bundle, byte for byte.
    ///
    /// Compared as raw bytes rather than as parsed JSON on purpose. A parsed comparison passes when
    /// key order, number spelling and escaping all differ — which is precisely the set of things
    /// schema 1.0.0 promises are identical, and precisely what a downstream consumer checksumming
    /// the file cares about. `manifest.checksums` exists because BADAN tells people these files are
    /// verifiable; two platforms producing different bytes for the same data makes that vacuous.
    func testJSONBundleMatchesTheSharedGoldenByte() throws {
        let input = try Self.fixture()
        let produced = try JSONBundleWriter().data(
            manifest: try Self.manifest(input),
            rawSamples: try Self.rawSamples(input),
            intervalRecords: try Self.intervalRecords(input),
            sessions: try Self.sessions(input),
            derivedValues: try Self.derivedValues(input),
            baselines: try Self.baselines(input),
            symptoms: try Self.symptoms(input),
            adherence: try Self.adherence(input),
            workouts: try Self.workoutLogs(input),
            nutrition: try Self.nutrition(input),
            // Routes stay off: `route_ref` must be absent from a golden that represents a normal
            // export, so a regression that starts leaking route references fails here loudly.
            includeRoutes: false
        )
        try Self.assertGolden("bundle-v1.json", produced)
    }

    /// The two CSV files, byte for byte, including the CRLF line endings and the trailing newline.
    ///
    /// Raw and derived rows are written to SEPARATE files (I5) — the split is asserted rather than
    /// assumed, because "raw and derived never share a file" is a product guarantee, not an
    /// implementation detail.
    func testCSVFilesMatchTheSharedGoldensByte() throws {
        let rows = try Self.csvRows(try Self.fixture())
        let writer = CSVWriter()
        try Self.assertGolden("raw-v1.csv", Data(writer.render(rows.filter { !$0.isDerived }).utf8))
        try Self.assertGolden("derived-v1.csv", Data(writer.render(rows.filter { $0.isDerived }).utf8))
    }

    /// Raw and derived rows never share a file, and every row says which it is.
    func testRawAndDerivedNeverShareAFile() throws {
        let raw = String(decoding: try Self.readVerified("raw-v1.csv"), as: UTF8.self)
        let derived = String(decoding: try Self.readVerified("derived-v1.csv"), as: UTF8.self)
        XCTAssertFalse(raw.contains(",derived,true,"), "raw-v1.csv must not contain a derived row")
        XCTAssertFalse(derived.contains(",raw,false,"), "derived-v1.csv must not contain a raw row")
        for text in [raw, derived] {
            let header = (text.components(separatedBy: CSVWriter.newline).first ?? "").components(separatedBy: ",")
            XCTAssertTrue(header.contains("value_type"), "value_type must be present in every file")
            XCTAssertTrue(header.contains("is_derived"), "is_derived must be present in every file")
        }
    }

    // MARK: - The primitives the goldens are built out of

    /// Number formatting, pinned case by case.
    ///
    /// The single highest-value assertion in this file. Every number in every CSV cell and every
    /// JSON value goes through `CSVWriter.decimal`, so one disagreement here diverges an entire
    /// export — and the disagreements were not hypothetical: Android's implementation fell back to
    /// `Double.toString()`, which renders 1e-9 as `1.0E-9` where this one renders `0`.
    func testDecimalFormattingMatchesTheSharedCases() throws {
        for entry in try Self.array(try Self.fixture(), "decimalCases") {
            let id = try XCTUnwrap(entry["id"] as? String)
            let value = try XCTUnwrap(Double(try XCTUnwrap(entry["value"] as? String)))
            XCTAssertEqual(CSVWriter.decimal(value), entry["expected"] as? String, id)
        }
    }

    /// Timestamp rendering, pinned case by case — including the zero-offset case, which is what
    /// changed at 1.0.0 (`Z` -> `+00:00`, §22.1 "numeric offset") and what an unknown tz id falls
    /// back to.
    func testTimestampFormattingMatchesTheSharedCases() throws {
        for entry in try Self.array(try Self.fixture(), "timestampCases") {
            let id = try XCTUnwrap(entry["id"] as? String)
            let date = try Self.date(entry, "epochMillis")
            let tz = try XCTUnwrap(entry["tzId"] as? String)
            XCTAssertEqual(CSVWriter.iso8601(date, tzId: tz), entry["expected"] as? String, id)
        }
    }

    /// The 26 columns, in contract order, with the two 1.0.0 additions last (A1).
    func testCSVColumnsAreTheContractOrder() throws {
        let url = Self.repoRoot.appendingPathComponent("packages/export-schemas/csv_columns.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["version"] as? String, "1.0.0")
        XCTAssertEqual(root["version"] as? String, ExportSchema.version,
                       "the contract file and the constant the writers emit must not drift")
        let expected = try XCTUnwrap(root["csvColumns"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertEqual(CSVWriter.columns, expected)
        XCTAssertEqual(CSVWriter.columns.count, 26)
        XCTAssertEqual(Array(CSVWriter.columns.suffix(2)), ["granularity", "aggregation_method"])
    }

    /// The divergences the fixture declares must still describe THIS platform. Stated as a test so
    /// a known gap cannot quietly become a stale note — whoever closes one gets a failure here
    /// telling them to delete the entry.
    ///
    /// `hrSeriesRef` and `energyKcal` are referenced by name rather than described in a comment: if
    /// someone mirrors the field onto Android and renames these to match, this file stops
    /// compiling, which is the loudest possible reminder that the entry and the golden both need
    /// updating.
    func testDeclaredDivergencesStillDescribeThisPlatform() throws {
        let ids = try Self.array(try Self.fixture(), "knownDivergences").compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains("workout-totals-energy-unit"))
        XCTAssertEqual(WorkoutTotals(energyKcal: 512).energyKcal, 512,
                       "this platform stores workout energy in kilocalories")
        XCTAssertTrue(ids.contains("workout-hr-series-ref"))
        XCTAssertEqual(WorkoutDetail(activityType: "running", sourceWorkoutUUID: "x",
                                     hrSeriesRef: "heart.hr").hrSeriesRef, "heart.hr",
                       "this platform can record an HR-series linkage; Android cannot yet")
        XCTAssertTrue(ids.contains("manifest-sample-data-row-count"))
    }

    // MARK: - Fixture loading

    /// The repo root, located relative to `#filePath` rather than through `Bundle` — the fixture is
    /// deliberately outside the app bundle so no build-system copy step can sit between the
    /// artifact and the assertion. Same reasoning as `CanonicalizationParityTests.repoRoot`.
    static let repoRoot = URL(fileURLWithPath: #filePath) // apps/ios/Tests/ExportSchemaParityTests.swift
        .deletingLastPathComponent()  // apps/ios/Tests
        .deletingLastPathComponent()  // apps/ios
        .deletingLastPathComponent()  // apps
        .deletingLastPathComponent()  // <repo root>

    private static let fixtureDir = repoRoot.appendingPathComponent("packages/fixtures/export", isDirectory: true)

    /// Reads a shared fixture and checks its SHA-256 against the manifest before parsing.
    ///
    /// A missing file or a bad digest FAILS here; it never skips. Without the digest check, a
    /// fixture mangled in transit (a text-mode checkout, a bad merge, a well-meaning reformat)
    /// surfaces as a byte mismatch in the goldens — technically true, and exactly the wrong thing
    /// to hand someone debugging a cross-platform disagreement.
    static func readVerified(_ fileName: String) throws -> Data {
        let manifestURL = fixtureDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw FixtureError.unreadable("""
                missing fixture manifest at \(manifestURL.path) — see packages/fixtures/export/README.md
                """)
        }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let files = try XCTUnwrap(root["files"] as? [[String: Any]], "fixture manifest has no `files` array")
        let entry = try XCTUnwrap(files.first { $0["file"] as? String == fileName },
                                  "fixture manifest has no entry for '\(fileName)'")

        let fileURL = fixtureDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw FixtureError.unreadable("missing fixture at \(fileURL.path)")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, entry["sha256"] as? String,
                       """
                       fixture '\(fileName)' does not match the SHA-256 in manifest.json — the shared \
                       artifact changed underneath this test. Do NOT run \
                       scripts/check_fixture_hashes.sh --update to make this pass unless you meant to \
                       change the fixture; see packages/fixtures/export/README.md
                       """)
        return data
    }

    /// Byte comparison, or a rewrite when `BADAN_REGENERATE_EXPORT_GOLDENS=true`.
    ///
    /// The switch exists on both platforms deliberately. A golden only one platform can rewrite
    /// makes that platform the silent authority, and the next disagreement gets "fixed" by
    /// regenerating from whichever side happens to be convenient. Either side may regenerate; a
    /// regenerated golden is not a verified golden until the OTHER side passes against it
    /// unchanged. The regenerating run always fails so it can never be mistaken for a pass.
    static func assertGolden(_ fileName: String, _ produced: Data) throws {
        if ProcessInfo.processInfo.environment["BADAN_REGENERATE_EXPORT_GOLDENS"] == "true" {
            try produced.write(to: fixtureDir.appendingPathComponent(fileName))
            XCTFail("""
                    regenerated \(fileName) from this platform's output. Run \
                    scripts/check_fixture_hashes.sh --update, then run BOTH suites with the switch \
                    OFF. A golden verified on one platform is not a parity fixture.
                    """)
            return
        }
        let expected = try readVerified(fileName)
        guard expected != produced else { return }
        // Diffed as text, not as two opaque blobs: a byte-count-only failure on an 11 KB JSON file
        // tells whoever is debugging a cross-platform disagreement nothing at all.
        XCTAssertEqual(String(decoding: expected, as: UTF8.self), String(decoding: produced, as: UTF8.self),
                       "\(fileName) is not byte-identical to what this platform's writer produced")
    }

    private static func fixture() throws -> [String: Any] {
        let data = try readVerified("export-input-v1.json")
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "shared fixture is not a JSON object")
    }

    // MARK: - Fixture -> domain

    private static func array(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(object[key] as? [[String: Any]], "shared fixture has no `\(key)` array")
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(object[key] as? String, "missing `\(key)`")
    }

    private static func optionalString(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    /// Doubles and epoch-millis arrive as strings and are parsed with `Double(_:)`/`Int64(_:)` — see
    /// the fixture README. A bare JSON number would go through each platform's own number handling,
    /// which is a difference in the harness rather than in the thing under test.
    private static func double(_ object: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(Double(try string(object, key)), "`\(key)` is not a Double")
    }

    private static func optionalDouble(_ object: [String: Any], _ key: String) -> Double? {
        (object[key] as? String).flatMap(Double.init)
    }

    private static func date(_ object: [String: Any], _ key: String) throws -> Date {
        Date(timeIntervalSince1970: try double(object, key) / 1000.0)
    }

    private static func optionalDate(_ object: [String: Any], _ key: String) -> Date? {
        optionalDouble(object, key).map { Date(timeIntervalSince1970: $0 / 1000.0) }
    }

    private static func provenance(_ object: [String: Any]) throws -> Provenance {
        Provenance(
            sourceId: try string(object, "sourceId"),
            deviceId: optionalString(object, "deviceId"),
            ingestionPath: try XCTUnwrap(IngestionPath(rawValue: try string(object, "ingestionPath"))),
            externalId: optionalString(object, "externalId"),
            importBatchId: optionalString(object, "importBatchId"),
            measuredAt: try date(object, "measuredAtMillis"),
            measuredTimezone: try string(object, "measuredTimezone"),
            recordedAt: try date(object, "recordedAtMillis"),
            ingestedAt: try date(object, "ingestedAtMillis"),
            algorithmVersionId: optionalString(object, "algorithmVersionId"),
            qualityFlags: try XCTUnwrap(object["qualityFlags"] as? [String]).compactMap(QualityFlag.init(rawValue:)),
            suppressedBy: optionalString(object, "suppressedBy")
        )
    }

    private static func manifest(_ input: [String: Any]) throws -> ExportManifest {
        let m = try XCTUnwrap(input["bundleManifest"] as? [String: Any])
        let s = try XCTUnwrap(m["scope"] as? [String: Any])
        let scope = ExportScope(
            metricIds: s["metricIds"] as? [String],
            families: s["families"] as? [String],
            startDate: optionalDate(s, "startDateMillis"),
            endDate: optionalDate(s, "endDateMillis"),
            sourceIds: s["sourceIds"] as? [String],
            includeRaw: try XCTUnwrap(s["includeRaw"] as? Bool),
            includeDerived: try XCTUnwrap(s["includeDerived"] as? Bool),
            includeSuppressed: try XCTUnwrap(s["includeSuppressed"] as? Bool),
            includeSensitive: try XCTUnwrap(s["includeSensitive"] as? Bool),
            unitProfile: try XCTUnwrap(UnitProfileMode(rawValue: try string(s, "unitProfile"))),
            language: try XCTUnwrap(AppLanguage(rawValue: try string(s, "language")))
        )
        return ExportManifest(
            exportId: try string(m, "exportId"),
            // Deliberately the OLD version: the bundle's own `export_schema_version` must come from
            // the writer's constant, not from whatever a stored manifest happens to carry. If the
            // writer ever starts echoing this field instead, the golden breaks here.
            schemaVersion: "0.1.0",
            appVersion: try string(m, "appVersion"),
            platform: try string(m, "platform"),
            generatedAt: try date(m, "generatedAtMillis"),
            scope: scope,
            dateRange: try string(m, "dateRange"),
            displayLanguage: try string(m, "displayLanguage"),
            unitProfile: try string(m, "unitProfile"),
            timezonePolicy: try string(m, "timezonePolicy"),
            dedupPolicy: try string(m, "dedupPolicy"),
            perMetricRowCounts: try XCTUnwrap(m["perMetricRowCounts"] as? [String: Int]),
            checksums: try XCTUnwrap(m["checksums"] as? [String: String]),
            dataQualityNote: try string(m, "dataQualityNote"),
            sampleDataRowCount: try XCTUnwrap(m["sampleDataRowCount"] as? Int),
            encrypted: try XCTUnwrap(m["encrypted"] as? Bool)
        )
    }

    private static func rawSamples(_ input: [String: Any]) throws -> [RawSample] {
        try array(input, "rawSamples").map { row in
            RawSample(id: try string(row, "id"), metricId: try string(row, "metricId"),
                      value: try double(row, "value"), unit: try string(row, "unit"),
                      originalValue: try double(row, "originalValue"),
                      originalUnit: try string(row, "originalUnit"),
                      startAt: try date(row, "startAtMillis"), endAt: optionalDate(row, "endAtMillis"),
                      tzId: try string(row, "tzId"),
                      provenance: try provenance(try XCTUnwrap(row["provenance"] as? [String: Any])),
                      updatedAt: try date(row, "updatedAtMillis"),
                      originDeviceId: try string(row, "originDeviceId"),
                      deletedAt: optionalDate(row, "deletedAtMillis"))
        }
    }

    private static func intervalRecords(_ input: [String: Any]) throws -> [IntervalRecord] {
        try array(input, "intervalRecords").map { row in
            IntervalRecord(id: try string(row, "id"), metricId: try string(row, "metricId"),
                           value: try double(row, "value"), unit: try string(row, "unit"),
                           startAt: try date(row, "startAtMillis"), endAt: try date(row, "endAtMillis"),
                           tzId: try string(row, "tzId"),
                           aggregation: try XCTUnwrap(Aggregation(rawValue: try string(row, "aggregation"))),
                           coverage: try double(row, "coverage"),
                           provenance: try provenance(try XCTUnwrap(row["provenance"] as? [String: Any])),
                           updatedAt: try date(row, "updatedAtMillis"),
                           originDeviceId: try string(row, "originDeviceId"),
                           deletedAt: optionalDate(row, "deletedAtMillis"))
        }
    }

    private static func sessions(_ input: [String: Any]) throws -> [Session] {
        try array(input, "sessions").map { row in
            let d = try XCTUnwrap(row["detail"] as? [String: Any])
            var workout: WorkoutDetail?
            if let w = d["workout"] as? [String: Any] {
                let t = try XCTUnwrap(w["totals"] as? [String: Any])
                workout = WorkoutDetail(
                    activityType: try string(w, "activityType"),
                    // No energy total: the two platforms store this in different units, which is a
                    // declared divergence the fixture routes around rather than hides. No
                    // `hrSeriesRef` either, for the same reason.
                    totals: WorkoutTotals(distanceMeters: optionalDouble(t, "distanceM"),
                                          avgHeartRateBpm: optionalDouble(t, "avgHr"),
                                          maxHeartRateBpm: optionalDouble(t, "maxHr"),
                                          elevationGainMeters: optionalDouble(t, "elevationGainM")),
                    sourceWorkoutUUID: try string(w, "sourceWorkoutId"),
                    routeRef: optionalString(w, "routeRef")
                )
            }
            let stages = try XCTUnwrap(d["stageSummarySeconds"] as? [String: String])
            return Session(
                id: try string(row, "id"),
                kind: try XCTUnwrap(SessionKind(rawValue: try string(row, "kind"))),
                subtype: optionalString(row, "subtype"),
                startAt: try date(row, "startAtMillis"), endAt: try date(row, "endAtMillis"),
                tzId: try string(row, "tzId"), localNight: optionalString(row, "localNight"),
                detail: SessionDetail(
                    mergedFrom: try XCTUnwrap(d["mergedFrom"] as? [String]),
                    timeAsleepSeconds: optionalDouble(d, "timeAsleepSeconds"),
                    timeInBedSeconds: optionalDouble(d, "timeInBedSeconds"),
                    stageSummarySeconds: stages.compactMapValues(Double.init),
                    workout: workout
                ),
                provenance: try provenance(try XCTUnwrap(row["provenance"] as? [String: Any])),
                updatedAt: try date(row, "updatedAtMillis"),
                originDeviceId: try string(row, "originDeviceId"),
                deletedAt: optionalDate(row, "deletedAtMillis"))
        }
    }

    private static func derivedValues(_ input: [String: Any]) throws -> [DerivedValue] {
        try array(input, "derivedValues").map { row in
            DerivedValue(id: try string(row, "id"), metricId: try string(row, "metricId"),
                         value: try double(row, "value"), unit: try string(row, "unit"),
                         periodKey: try string(row, "periodKey"),
                         confidence: optionalDouble(row, "confidence"),
                         provisional: try XCTUnwrap(row["provisional"] as? Bool),
                         algorithmId: try string(row, "algorithmId"),
                         algorithmVersion: try string(row, "algorithmVersion"),
                         inputManifestId: optionalString(row, "inputManifestId"),
                         computedAt: try date(row, "computedAtMillis"),
                         updatedAt: try date(row, "updatedAtMillis"),
                         originDeviceId: try string(row, "originDeviceId"),
                         deletedAt: optionalDate(row, "deletedAtMillis"))
        }
    }

    private static func baselines(_ input: [String: Any]) throws -> [Baseline] {
        try array(input, "baselines").map { row in
            Baseline(id: try string(row, "id"), metricId: try string(row, "metricId"),
                     covariateContext: try string(row, "covariateContext"),
                     windowDays: try XCTUnwrap(row["windowDays"] as? Int),
                     method: try XCTUnwrap(BaselineMethod(rawValue: try string(row, "method"))),
                     center: try double(row, "center"), spread: try double(row, "spread"),
                     bandLow: try double(row, "bandLow"), bandHigh: try double(row, "bandHigh"),
                     nPoints: try XCTUnwrap(row["nPoints"] as? Int),
                     provisional: try XCTUnwrap(row["provisional"] as? Bool),
                     algorithmVersion: try string(row, "algorithmVersion"),
                     validFrom: try date(row, "validFromMillis"),
                     computedAt: try date(row, "computedAtMillis"),
                     unit: try string(row, "unit"))
        }
    }

    private static func symptoms(_ input: [String: Any]) throws -> [SymptomEntry] {
        try array(input, "symptoms").map { row in
            SymptomEntry(id: try string(row, "id"), symptomId: optionalString(row, "symptomId"),
                         customLabel: optionalString(row, "customLabel"),
                         severity: try XCTUnwrap(row["severity"] as? Int),
                         occurredAt: try date(row, "occurredAtMillis"), tzId: try string(row, "tzId"),
                         durationSeconds: optionalDouble(row, "durationSeconds"),
                         bodyLocation: optionalString(row, "bodyLocation"),
                         triggers: try XCTUnwrap(row["triggers"] as? [String]),
                         note: optionalString(row, "note"),
                         updatedAt: try date(row, "updatedAtMillis"),
                         originDeviceId: try string(row, "originDeviceId"),
                         deletedAt: optionalDate(row, "deletedAtMillis"))
        }
    }

    private static func adherence(_ input: [String: Any]) throws -> [AdherenceEvent] {
        try array(input, "adherence").map { row in
            AdherenceEvent(id: try string(row, "id"), regimenId: try string(row, "regimenId"),
                           kind: try XCTUnwrap(AdherenceKind(rawValue: try string(row, "kind"))),
                           scheduledFor: optionalDate(row, "scheduledForMillis"),
                           occurredAt: try date(row, "occurredAtMillis"), tzId: try string(row, "tzId"),
                           skipReason: optionalString(row, "skipReason").flatMap(SkipReason.init(rawValue:)),
                           skipNote: optionalString(row, "skipNote"),
                           updatedAt: try date(row, "updatedAtMillis"),
                           originDeviceId: try string(row, "originDeviceId"),
                           deletedAt: optionalDate(row, "deletedAtMillis"))
        }
    }

    private static func workoutLogs(_ input: [String: Any]) throws -> [WorkoutEntry] {
        try array(input, "workoutLogs").map { row in
            WorkoutEntry(id: try string(row, "id"), activityType: try string(row, "activityType"),
                         startAt: try date(row, "startAtMillis"), endAt: try date(row, "endAtMillis"),
                         tzId: try string(row, "tzId"), energyKcal: optionalDouble(row, "energyKcal"),
                         distanceM: optionalDouble(row, "distanceM"), avgHr: optionalDouble(row, "avgHr"),
                         maxHr: optionalDouble(row, "maxHr"), perceivedEffort: row["perceivedEffort"] as? Int,
                         note: optionalString(row, "note"),
                         ingestionPath: try XCTUnwrap(IngestionPath(rawValue: try string(row, "ingestionPath"))),
                         updatedAt: try date(row, "updatedAtMillis"),
                         originDeviceId: try string(row, "originDeviceId"),
                         deletedAt: optionalDate(row, "deletedAtMillis"))
        }
    }

    private static func nutrition(_ input: [String: Any]) throws -> [NutritionEntry] {
        try array(input, "nutrition").map { row in
            NutritionEntry(id: try string(row, "id"), description: try string(row, "description"),
                           mealType: try XCTUnwrap(MealType(rawValue: try string(row, "mealType"))),
                           energyKcal: optionalDouble(row, "energyKcal"),
                           proteinG: optionalDouble(row, "proteinG"),
                           carbsG: optionalDouble(row, "carbsG"), fatG: optionalDouble(row, "fatG"),
                           fiberG: optionalDouble(row, "fiberG"), waterMl: optionalDouble(row, "waterMl"),
                           caffeineMg: optionalDouble(row, "caffeineMg"),
                           lowDetail: try XCTUnwrap(row["lowDetail"] as? Bool),
                           occurredAt: try date(row, "occurredAtMillis"), tzId: try string(row, "tzId"),
                           note: optionalString(row, "note"),
                           updatedAt: try date(row, "updatedAtMillis"),
                           originDeviceId: try string(row, "originDeviceId"),
                           deletedAt: optionalDate(row, "deletedAtMillis"))
        }
    }

    private static func csvRows(_ input: [String: Any]) throws -> [ExportRow] {
        try array(input, "csvRows").map { row in
            ExportRow(recordId: try string(row, "recordId"), recordKind: try string(row, "recordKind"),
                      metricId: try string(row, "metricId"), metricDisplay: try string(row, "metricDisplay"),
                      value: try string(row, "value"), unit: try string(row, "unit"),
                      canonicalValue: try string(row, "canonicalValue"),
                      canonicalUnit: try string(row, "canonicalUnit"),
                      valueType: try string(row, "valueType"),
                      isDerived: try XCTUnwrap(row["isDerived"] as? Bool),
                      timestampStart: try string(row, "timestampStart"),
                      timestampEnd: optionalString(row, "timestampEnd"),
                      timezone: try string(row, "timezone"), recordedAt: try string(row, "recordedAt"),
                      sourceApp: optionalString(row, "sourceApp"),
                      sourceDevice: optionalString(row, "sourceDevice"),
                      ingestionPath: try string(row, "ingestionPath"),
                      sourceExternalId: optionalString(row, "sourceExternalId"),
                      importBatchId: optionalString(row, "importBatchId"),
                      qualityFlags: optionalString(row, "qualityFlags"),
                      confidence: optionalString(row, "confidence"),
                      algorithmId: optionalString(row, "algorithmId"),
                      algorithmVersion: optionalString(row, "algorithmVersion"),
                      suppressedBy: optionalString(row, "suppressedBy"),
                      granularity: optionalString(row, "granularity")
                          .flatMap(ExportSchema.Granularity.init(rawValue:)),
                      aggregationMethod: optionalString(row, "aggregationMethod")
                          .flatMap(ExportSchema.AggregationMethod.init(rawValue:)))
        }
    }

    /// A read failure is thrown rather than asserted so it aborts with the diagnostic attached,
    /// instead of failing and then continuing into a loop over zero rows.
    private enum FixtureError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self {
            case .unreadable(let message): return message
            }
        }
    }
}
