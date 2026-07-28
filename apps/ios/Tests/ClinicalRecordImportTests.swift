import XCTest
@testable import BADAN

/// LAB-11. A provider's FHIR is not a contract BADAN controls, and a mis-parse here writes a wrong
/// number into someone's medical record — so these tests lean hard on the refusal paths: what gets
/// SKIPPED, and what is never invented.
final class FHIRObservationParserTests: XCTestCase {
    private func parse(_ json: String) -> [FHIRLabObservation] {
        FHIRObservationParser.parse(Data(json.utf8))
    }

    // MARK: - The ordinary case

    func testANumericObservationParsesValueUnitAndDate() throws {
        let observations = parse("""
        {"resourceType":"Observation","status":"final",
         "code":{"text":"Hemoglobin A1c","coding":[{"system":"http://loinc.org","code":"4548-4","display":"Hemoglobin A1c"}]},
         "valueQuantity":{"value":5.4,"unit":"%"},
         "effectiveDateTime":"2026-03-14T09:00:00Z",
         "referenceRange":[{"low":{"value":4.0},"high":{"value":5.6}}],
         "interpretation":[{"coding":[{"code":"N"}]}],
         "id":"obs-1"}
        """)

        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observation.displayName, "Hemoglobin A1c")
        XCTAssertEqual(observation.loincCode, "4548-4")
        XCTAssertEqual(observation.numericValue, 5.4)
        XCTAssertEqual(observation.rawUnit, "%")
        XCTAssertEqual(observation.rawValueText, "5.4")
        XCTAssertEqual(observation.resultType, .numeric)
        XCTAssertEqual(observation.sourceRangeLow, 4.0)
        XCTAssertEqual(observation.sourceRangeHigh, 5.6)
        XCTAssertEqual(observation.interpretationCode, "N")
        XCTAssertEqual(observation.sourceIdentifier, "obs-1")
        XCTAssertNotNil(observation.effectiveAt)
    }

    /// A whole number should read like the lab printed it, not as "12.0".
    func testAWholeNumberIsRenderedWithoutAFakeDecimal() throws {
        let observation = try XCTUnwrap(parse("""
        {"resourceType":"Observation","status":"final","code":{"text":"Platelets"},
         "valueQuantity":{"value":250,"unit":"10*3/uL"},"effectiveDateTime":"2026-03-14"}
        """).first)
        XCTAssertEqual(observation.rawValueText, "250")
    }

    func testADetectionLimitComparatorIsPreserved() throws {
        let observation = try XCTUnwrap(parse("""
        {"resourceType":"Observation","status":"final","code":{"text":"Troponin I"},
         "valueQuantity":{"value":0.1,"unit":"ng/mL","comparator":"<"},
         "effectiveDateTime":"2026-03-14"}
        """).first)
        XCTAssertEqual(observation.comparator, .lessThan)
        XCTAssertEqual(observation.rawValueText, "<0.1", "the printed value keeps its comparator")
    }

    func testAQualitativeResultParses() throws {
        let observation = try XCTUnwrap(parse("""
        {"resourceType":"Observation","status":"final","code":{"text":"Strep A antigen"},
         "valueCodeableConcept":{"text":"Negative"},"effectiveDateTime":"2026-03-14"}
        """).first)
        XCTAssertEqual(observation.rawValueText, "Negative")
        XCTAssertEqual(observation.resultType, .qualitative)
        XCTAssertNil(observation.numericValue, "a qualitative result carries no magnitude")
    }

    // MARK: - Refusals

    /// A retracted result must never enter the notebook. The lab has explicitly withdrawn it.
    func testAnEnteredInErrorObservationIsSkipped() {
        XCTAssertTrue(parse("""
        {"resourceType":"Observation","status":"entered-in-error","code":{"text":"Potassium"},
         "valueQuantity":{"value":9.9,"unit":"mmol/L"},"effectiveDateTime":"2026-03-14"}
        """).isEmpty)
    }

    /// Preliminary results change. Importing one and never updating it would leave a stale value
    /// presented as final.
    func testAPreliminaryObservationIsSkipped() {
        XCTAssertTrue(parse("""
        {"resourceType":"Observation","status":"preliminary","code":{"text":"Culture"},
         "valueString":"No growth at 24h","effectiveDateTime":"2026-03-14"}
        """).isEmpty)
    }

    func testAnObservationWithNoNameIsSkipped() {
        XCTAssertTrue(parse("""
        {"resourceType":"Observation","status":"final","valueQuantity":{"value":5.4,"unit":"%"},
         "effectiveDateTime":"2026-03-14"}
        """).isEmpty, "a value with no marker name cannot be filed")
    }

    func testAnObservationWithNoValueIsSkipped() {
        XCTAssertTrue(parse("""
        {"resourceType":"Observation","status":"final","code":{"text":"Sodium"},
         "effectiveDateTime":"2026-03-14"}
        """).isEmpty)
    }

    /// Garbage must not take down an import. Returning empty beats throwing.
    func testUnparseableInputReturnsEmptyRatherThanThrowing() {
        XCTAssertTrue(FHIRObservationParser.parse(Data("not json at all".utf8)).isEmpty)
        XCTAssertTrue(parse("""
        {"resourceType":"Patient","id":"p1"}
        """).isEmpty)
    }

    // MARK: - Panels

    func testADiagnosticReportYieldsItsContainedObservations() {
        let observations = parse("""
        {"resourceType":"DiagnosticReport","status":"final","code":{"text":"CBC"},
         "contained":[
           {"resourceType":"Observation","status":"final","code":{"text":"Hemoglobin"},
            "valueQuantity":{"value":14.1,"unit":"g/dL"},"effectiveDateTime":"2026-03-14"},
           {"resourceType":"Observation","status":"final","code":{"text":"Hematocrit"},
            "valueQuantity":{"value":42,"unit":"%"},"effectiveDateTime":"2026-03-14"}]}
        """)

        XCTAssertEqual(observations.map(\.displayName), ["Hemoglobin", "Hematocrit"])
    }

    /// `result` holds REFERENCES to observations stored on a FHIR server this build cannot reach.
    /// Importing them as empty rows would be worse than skipping them.
    func testUnresolvableReferencesAreIgnoredRatherThanImportedEmpty() {
        XCTAssertTrue(parse("""
        {"resourceType":"DiagnosticReport","status":"final","code":{"text":"CBC"},
         "result":[{"reference":"Observation/123"},{"reference":"Observation/456"}]}
        """).isEmpty)
    }

    // MARK: - Dates

    func testDatesParseInEveryShapeProvidersActuallySend() {
        XCTAssertNotNil(FHIRObservationParser.date(from: "2026-03-14T09:00:00Z"))
        XCTAssertNotNil(FHIRObservationParser.date(from: "2026-03-14T09:00:00.123Z"))
        XCTAssertNotNil(FHIRObservationParser.date(from: "2026-03-14"), "a bare day is valid FHIR")
    }

    /// An unreadable date must stay nil. Defaulting to "now" would file an old result under today
    /// and silently corrupt the timeline the notebook is organised around.
    func testAnUnreadableDateStaysNilRatherThanDefaultingToNow() {
        XCTAssertNil(FHIRObservationParser.date(from: "sometime last spring"))
        XCTAssertNil(FHIRObservationParser.date(from: ""))
        XCTAssertNil(FHIRObservationParser.date(from: nil))
    }
}

/// The mapping half: parsed observations becoming real lab-notebook rows in the sensitive DB.
final class ClinicalRecordImporterTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-clinical-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var reports: LabReportRepository { LabReportRepository(sensitive: db.sensitive) }
    private var results: LabResultRepository { LabResultRepository(sensitive: db.sensitive) }

    private func observation(_ name: String, value: Double, at day: String,
                             identifier: String? = nil) -> FHIRLabObservation {
        FHIRLabObservation(displayName: name, rawValueText: String(value), numericValue: value,
                           rawUnit: "mmol/L", resultType: .numeric,
                           effectiveAt: FHIRObservationParser.date(from: day),
                           sourceIdentifier: identifier)
    }

    @discardableResult
    private func runImport(_ observations: [FHIRLabObservation],
                           source: String = "Muscat Labs") throws -> ClinicalRecordImporter.Outcome {
        try ClinicalRecordImporter.import(
            ClinicalRecordImporter.Batch(sourceName: source, observations: observations),
            reports: reports, results: results, analyteMatcher: nil,
            clock: clock, deviceId: "dev")
    }

    // MARK: - Filing

    /// A provider hands back a flat list; a person thinks in reports. Observations from one day
    /// become one report.
    func testObservationsFromTheSameDayBecomeOneReport() throws {
        let outcome = try runImport([
            observation("Sodium", value: 140, at: "2026-03-14"),
            observation("Potassium", value: 4.1, at: "2026-03-14"),
        ])

        XCTAssertEqual(outcome.reportsCreated, 1)
        XCTAssertEqual(outcome.resultsImported, 2)
        XCTAssertEqual(try reports.liveReports().count, 1)
    }

    func testObservationsFromDifferentDaysBecomeSeparateReports() throws {
        let outcome = try runImport([
            observation("Sodium", value: 140, at: "2026-03-14"),
            observation("Sodium", value: 139, at: "2026-05-02"),
        ])

        XCTAssertEqual(outcome.reportsCreated, 2)
    }

    /// The provider's name is preserved, not flattened to "Apple Health" — provenance is the point
    /// of the whole notebook.
    func testTheProvidersNameIsKeptAsTheSource() throws {
        try runImport([observation("Sodium", value: 140, at: "2026-03-14")], source: "Royal Hospital")

        XCTAssertEqual(try reports.liveReports().first?.sourceLabName, "Royal Hospital")
    }

    /// The one path in the app where a value arrives needing no human review — and saying so is the
    /// point. Asking someone to proof-read their own lab's structured output would be noise.
    func testImportedResultsAreMarkedVerifiedStructuredNotNeedsReview() throws {
        try runImport([observation("Sodium", value: 140, at: "2026-03-14")])

        let report = try XCTUnwrap(reports.liveReports().first)
        XCTAssertEqual(report.reviewState, .verifiedStructured)
        XCTAssertEqual(report.ingestionPath, .platformStore)
        let result = try XCTUnwrap(results.results(reportId: report.id).first)
        XCTAssertEqual(result.reviewState, .verifiedStructured)
    }

    /// Sensitivity is raised, never guessed downward: nothing in a FHIR observation reliably says
    /// "this is an HIV test", so assuming `.standard` would under-protect exactly the results that
    /// most need protecting.
    func testImportedRowsCarryARaisedSensitivityTier() throws {
        try runImport([observation("Sodium", value: 140, at: "2026-03-14")])

        XCTAssertEqual(try reports.liveReports().first?.sensitivityTier, .high)
    }

    /// An unmatched marker is a first-class free-text row (LAB-06), never a blocked import and
    /// never a wrong dictionary entry substituted for what the lab actually printed.
    func testAnUnrecognisedMarkerIsImportedAsFreeText() throws {
        try runImport([observation("Some Very Obscure Assay", value: 1.2, at: "2026-03-14")])

        let report = try XCTUnwrap(reports.liveReports().first)
        let result = try XCTUnwrap(results.results(reportId: report.id).first)
        XCTAssertNil(result.analyteId)
        XCTAssertEqual(result.customLabel, "Some Very Obscure Assay")
    }

    /// Unit conversion is gated on an analyte's safety class, which this path cannot evaluate — so
    /// the as-reported value and unit are kept and nothing canonical is invented.
    func testNoUnitConversionIsInventedOnImport() throws {
        try runImport([observation("Glucose", value: 5.4, at: "2026-03-14")])

        let report = try XCTUnwrap(reports.liveReports().first)
        let result = try XCTUnwrap(results.results(reportId: report.id).first)
        XCTAssertEqual(result.rawUnit, "mmol/L")
        XCTAssertNil(result.canonicalValue, "conversion needs the analyte's safety class, absent here")
        XCTAssertNil(result.canonicalUnit)
    }

    // MARK: - Re-import

    /// Tapping "check for new results" is the normal case, not the exception. It must not duplicate
    /// the entire history every time.
    func testReimportingTheSameRecordsAddsNothing() throws {
        let batch = [observation("Sodium", value: 140, at: "2026-03-14"),
                     observation("Potassium", value: 4.1, at: "2026-03-14")]
        try runImport(batch)

        let second = try runImport(batch)

        XCTAssertEqual(second.resultsImported, 0)
        XCTAssertEqual(second.duplicatesSkipped, 2)
        XCTAssertEqual(second.reportsCreated, 0, "no empty report is left behind for a fully-duplicate day")
        XCTAssertEqual(try reports.liveReports().count, 1)
    }

    /// A genuinely new result on a day already imported still lands.
    func testANewResultOnAnAlreadyImportedDayIsStillAdded() throws {
        try runImport([observation("Sodium", value: 140, at: "2026-03-14")])

        let second = try runImport([observation("Sodium", value: 140, at: "2026-03-14"),
                                    observation("Creatinine", value: 74, at: "2026-03-14")])

        XCTAssertEqual(second.resultsImported, 1)
        XCTAssertEqual(second.duplicatesSkipped, 1)
    }

    /// Duplicate detection keys on marker+day+value, deliberately not the provider's identifier —
    /// providers regenerate those between fetches, which would duplicate everything.
    func testDuplicateDetectionSurvivesAChangedProviderIdentifier() throws {
        try runImport([observation("Sodium", value: 140, at: "2026-03-14", identifier: "abc-1")])

        let second = try runImport([observation("Sodium", value: 140, at: "2026-03-14", identifier: "totally-different")])

        XCTAssertEqual(second.duplicatesSkipped, 1, "same marker, same day, same value — same result")
    }

    // MARK: - Refusals

    func testAnObservationWithNoDateIsSkippedAndCounted() throws {
        let undated = FHIRLabObservation(displayName: "Sodium", rawValueText: "140",
                                         numericValue: 140, resultType: .numeric, effectiveAt: nil)

        let outcome = try runImport([undated])

        XCTAssertEqual(outcome.resultsImported, 0)
        XCTAssertEqual(outcome.skippedMissingDate, 1, "reported, not silently dropped")
        XCTAssertTrue(try reports.liveReports().isEmpty)
    }

    // MARK: - Placement

    /// Clinical records are the most sensitive data BADAN ingests. They must land in the encrypted
    /// namespace and be removed by the sensitive purge — checked against the physical file rather
    /// than through the repository that decides placement.
    func testImportedRecordsLiveInTheSensitiveDatabaseAndArePurged() throws {
        try runImport([observation("Sodium", value: 140, at: "2026-03-14")])

        let sensitiveCount = try db.sensitive.query("SELECT COUNT(*) AS n FROM lab_results;")
            .first?.intValue("n")
        XCTAssertEqual(sensitiveCount, 1, "in badan_sensitive.db, not badan.db")

        try db.purgeSensitiveNamespace()

        XCTAssertTrue(try results.allLiveResults().isEmpty,
                      "erase sensitive records must remove imported clinical results too")
    }
}
