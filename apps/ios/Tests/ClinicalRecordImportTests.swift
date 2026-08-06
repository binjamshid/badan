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

    /// The interval's own unit, kept apart from the value's. A lab occasionally prints the two
    /// differently, and `LabRangeEvaluation` refuses to compare across units — a unit inferred from
    /// the value would disarm that guard exactly when it matters.
    func testTheReferenceIntervalsOwnUnitIsCaptured() throws {
        let observation = try XCTUnwrap(parse("""
        {"resourceType":"Observation","status":"final","code":{"text":"Glucose"},
         "valueQuantity":{"value":5.3,"unit":"mmol/L"},"effectiveDateTime":"2026-03-14",
         "referenceRange":[{"low":{"value":70,"unit":"mg/dL"},"high":{"value":99,"unit":"mg/dL"}}]}
        """).first)
        XCTAssertEqual(observation.sourceRangeUnit, "mg/dL")
        XCTAssertEqual(observation.rawUnit, "mmol/L", "the value's unit is untouched by the range's")
    }

    /// Not defaulted to the value's unit when the resource stayed silent.
    func testAnIntervalWithNoStatedUnitStaysNil() throws {
        let observation = try XCTUnwrap(parse("""
        {"resourceType":"Observation","status":"final","code":{"text":"Glucose"},
         "valueQuantity":{"value":5.3,"unit":"mmol/L"},"effectiveDateTime":"2026-03-14",
         "referenceRange":[{"low":{"value":3.9},"high":{"value":5.5}}]}
        """).first)
        XCTAssertNil(observation.sourceRangeUnit)
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
    private var ranges: ReferenceRangeRepository { ReferenceRangeRepository(sensitive: db.sensitive) }

    /// A stand-in for the two `analytes.json` entries whose names overlap — the pair that used to
    /// mis-file HbA1c. Ordered as the real file orders them (`hemoglobin` first), because that
    /// order is precisely what the old first-hit-wins matcher got wrong.
    private var matcher: AnalyteNameMatcher {
        AnalyteNameMatcher(entries: [
            (id: "hemoglobin", loincCode: "718-7", names: ["Hemoglobin", "الهيموغلوبين"]),
            (id: "hba1c", loincCode: "4548-4", names: ["Hemoglobin A1c", "الهيموغلوبين السكري"]),
            (id: "ldl", loincCode: "13457-7", names: ["LDL cholesterol"]),
            (id: "ldl_calculated", loincCode: nil, names: ["LDL cholesterol (calculated)"]),
        ])
    }

    private func observation(_ name: String, value: Double, at day: String,
                             identifier: String? = nil) -> FHIRLabObservation {
        FHIRLabObservation(displayName: name, rawValueText: String(value), numericValue: value,
                           rawUnit: "mmol/L", resultType: .numeric,
                           effectiveAt: FHIRObservationParser.date(from: day),
                           sourceIdentifier: identifier)
    }

    @discardableResult
    private func runImport(_ observations: [FHIRLabObservation],
                           source: String = "Muscat Labs",
                           analyteMatcher: AnalyteNameMatcher? = nil) throws -> ClinicalRecordImporter.Outcome {
        try ClinicalRecordImporter.import(
            ClinicalRecordImporter.Batch(sourceName: source, observations: observations),
            reports: reports, results: results, ranges: ranges, analyteMatcher: analyteMatcher,
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

    // MARK: - Concepts 1 and 2 — the provider's own interval and flag
    //
    // These were parsed correctly and then dropped on the floor: the importer wrote no
    // `ReferenceRange` row at all, so the marker screen said "not printed on this report" about an
    // interval the provider had printed, and the notebook summary counted a provider-flagged result
    // as inside its range. The import screen promises the opposite in as many words.

    private func ranged(_ name: String, value: Double, low: Double?, high: Double?,
                        unit: String? = "mmol/L", flag: String? = nil,
                        at day: String = "2026-03-14") -> FHIRLabObservation {
        FHIRLabObservation(displayName: name, rawValueText: String(value), numericValue: value,
                           rawUnit: "mmol/L", resultType: .numeric,
                           effectiveAt: FHIRObservationParser.date(from: day),
                           sourceRangeLow: low, sourceRangeHigh: high, sourceRangeUnit: unit,
                           interpretationCode: flag)
    }

    func testTheProvidersPrintedIntervalIsPersisted() throws {
        try runImport([ranged("LDL cholesterol", value: 3.4, low: 0, high: 3.0)])

        let result = try XCTUnwrap(results.allLiveResults().first)
        let range = try XCTUnwrap(ranges.range(resultId: result.id),
                                  "the interval the provider printed must survive the import")
        XCTAssertEqual(range.sourceIntervalLow, 0)
        XCTAssertEqual(range.sourceIntervalHigh, 3.0)
        XCTAssertEqual(range.sourceIntervalUnit, "mmol/L")
    }

    /// Concept 2 is the lab's own words, never BADAN's arithmetic. A lab that flags a value we
    /// would not have flagged is telling us something.
    func testTheProvidersOwnFlagIsPersistedVerbatim() throws {
        try runImport([ranged("LDL cholesterol", value: 3.4, low: 0, high: 3.0, flag: "H")])

        let result = try XCTUnwrap(results.allLiveResults().first)
        XCTAssertEqual(try ranges.range(resultId: result.id)?.sourceFlag, "H")
    }

    /// The inverse, and the more important direction: a value OUTSIDE the printed interval that the
    /// lab chose not to flag must not acquire a flag on the way in.
    func testAnUnflaggedOutOfIntervalResultIsNotGivenAFlag() throws {
        try runImport([ranged("LDL cholesterol", value: 9.9, low: 0, high: 3.0)])

        let result = try XCTUnwrap(results.allLiveResults().first)
        XCTAssertNil(try ranges.range(resultId: result.id)?.sourceFlag,
                     "the flag is the lab's to give, never derived from the interval")
    }

    /// No row at all, rather than a row of nulls — `range(resultId:)` returning nil is how the rest
    /// of the app asks "did the source print anything for this result?"
    func testAResultWithNeitherIntervalNorFlagGetsNoRangeRow() throws {
        try runImport([ranged("Sodium", value: 140, low: nil, high: nil, unit: nil)])

        let result = try XCTUnwrap(results.allLiveResults().first)
        XCTAssertNil(try ranges.range(resultId: result.id))
    }

    /// The whole reason the interval's unit is carried separately from the value's: without it,
    /// `LabRangeEvaluation` cannot tell a comparable interval from an incomparable one, and its
    /// unit guard silently passes.
    func testAnIntervalPrintedInADifferentUnitKeepsThatUnit() throws {
        try runImport([ranged("Glucose", value: 95, low: 70, high: 99, unit: "mg/dL")])

        let result = try XCTUnwrap(results.allLiveResults().first)
        XCTAssertEqual(try ranges.range(resultId: result.id)?.sourceIntervalUnit, "mg/dL",
                       "not overwritten with the value's own mmol/L")
    }

    // MARK: - Marker identity

    /// The defect this pair was written for: "Hemoglobin A1c" contains "Hemoglobin", and
    /// `hemoglobin` sorts first in `analytes.json`, so first-substring-hit filed an HbA1c result
    /// under Hemoglobin — a wrong marker on a medical record, and one that then pollutes that
    /// marker's whole trend.
    func testHbA1cIsNotFiledUnderHemoglobin() throws {
        try runImport([observation("Hemoglobin A1c", value: 5.4, at: "2026-03-14")],
                      analyteMatcher: matcher)

        XCTAssertEqual(try results.allLiveResults().first?.analyteId, "hba1c")
    }

    /// A LOINC code outranks the name entirely — it is the provider's own identifier for the
    /// marker, and it cannot be confused by wording.
    func testALoincCodeDecidesTheMarkerEvenWhenTheNameIsAmbiguous() throws {
        let observation = FHIRLabObservation(
            displayName: "Hemoglobin", loincCode: "4548-4", rawValueText: "5.4",
            numericValue: 5.4, rawUnit: "%", resultType: .numeric,
            effectiveAt: FHIRObservationParser.date(from: "2026-03-14"))

        try runImport([observation], analyteMatcher: matcher)

        XCTAssertEqual(try results.allLiveResults().first?.analyteId, "hba1c",
                       "the code says HbA1c even though the printed name says Hemoglobin")
    }

    /// The mirror case, and the reason the ranking is closest-length rather than longest-name: a
    /// bare "LDL" must not be captured by the longer `ldl_calculated` entry.
    func testABareMarkerNameResolvesToTheClosestEntryNotTheLongestOne() throws {
        try runImport([observation("LDL", value: 3.4, at: "2026-03-14")], analyteMatcher: matcher)

        XCTAssertEqual(try results.allLiveResults().first?.analyteId, "ldl")
    }

    /// LAB-06 unchanged: an unknown marker is still a first-class free-text row, and the catalog
    /// never renames what it didn't recognize.
    func testAnUnknownMarkerStillImportsUnderTheProvidersOwnName() throws {
        try runImport([observation("Serum unobtainium", value: 1.2, at: "2026-03-14")],
                      analyteMatcher: matcher)

        let result = try XCTUnwrap(results.allLiveResults().first)
        XCTAssertNil(result.analyteId)
        XCTAssertEqual(result.customLabel, "Serum unobtainium")
    }
}
