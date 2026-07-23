import XCTest
@testable import BADAN

/// EPIC-43 ACC-005 — the GPX/TCX/CSV file importers.
///
/// Mirrors `AppleHealthImportTests`'s own posture: these assert the properties the feature exists
/// to guarantee (every row goes through `IngestionPipeline`, never a direct write; a re-import is a
/// no-op; a malformed file fails without crashing and leaves the batch `.failed`; undo reverses
/// exactly what one import wrote), not merely that the parsers produce the right DTOs in isolation
/// — though that is covered too, since a wrong DTO would make every other property meaningless.
final class FileImportersTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-fileimport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Harness

    private func makePipeline() -> IngestionPipeline {
        IngestionPipeline(measurements: MeasurementRepository(db.main),
                          catalog: CatalogRepository(db.main),
                          reconciliation: ReconciliationRepository(db.main),
                          registry: .shared, clock: clock, deviceId: deviceId,
                          routes: RouteRepository(db.main),
                          logging: LoggingRepository(main: db.main, sensitive: db.sensitive))
    }

    private func makeImporter(routeConsent: RouteConsentProviding = DeniedRouteConsent()) -> FileImporter {
        FileImporter(pipeline: makePipeline(), batches: ImportBatchRepository(db.main), clock: clock,
                    routeConsent: routeConsent)
    }

    private func count(_ table: String, where clause: String = "1=1") throws -> Int {
        Int(try db.main.query("SELECT COUNT(*) AS c FROM \(table) WHERE \(clause);").first?.int("c") ?? 0)
    }

    private func writeFile(_ contents: String, named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A stub route-consent provider that always answers granted — used only where a test needs to
    /// prove route rows ARE written; every other test uses the honest default (`DeniedRouteConsent`)
    /// so it never depends on this process's ambient `UserDefaults` state.
    private struct GrantedRouteConsent: RouteConsentProviding {
        func routeConsent() -> RouteConsent {
            RouteConsent(granted: true, policyVersion: RouteConsent.currentPolicyVersion, decidedAt: Date())
        }
    }

    // MARK: - Fixtures

    private func gpxFixture(lat: Double = 24.7136, lon: Double = 46.6753) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>ignored metadata name</name></metadata>
          <trk>
            <name>Morning Run</name>
            <type>running</type>
            <trkseg>
              <trkpt lat="\(lat)" lon="\(lon)">
                <ele>620.0</ele>
                <time>2024-03-01T06:00:00Z</time>
              </trkpt>
              <trkpt lat="\(lat + 0.001)" lon="\(lon + 0.001)">
                <ele>622.0</ele>
                <time>2024-03-01T06:05:00Z</time>
              </trkpt>
              <trkpt lat="\(lat + 0.002)" lon="\(lon + 0.002)">
                <ele>624.0</ele>
                <time>2024-03-01T06:10:00Z</time>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
    }

    private func tcxFixture() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>2024-03-02T07:00:00Z</Id>
              <Lap StartTime="2024-03-02T07:00:00Z">
                <TotalTimeSeconds>600</TotalTimeSeconds>
                <DistanceMeters>1500</DistanceMeters>
                <Calories>110</Calories>
                <AverageHeartRateBpm><Value>140</Value></AverageHeartRateBpm>
                <MaximumHeartRateBpm><Value>160</Value></MaximumHeartRateBpm>
                <Track>
                  <Trackpoint>
                    <Time>2024-03-02T07:00:00Z</Time>
                    <Position><LatitudeDegrees>24.71</LatitudeDegrees><LongitudeDegrees>46.67</LongitudeDegrees></Position>
                    <AltitudeMeters>620</AltitudeMeters>
                    <DistanceMeters>0</DistanceMeters>
                    <HeartRateBpm><Value>120</Value></HeartRateBpm>
                    <Cadence>82</Cadence>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2024-03-02T07:05:00Z</Time>
                    <Position><LatitudeDegrees>24.72</LatitudeDegrees><LongitudeDegrees>46.68</LongitudeDegrees></Position>
                    <AltitudeMeters>625</AltitudeMeters>
                    <DistanceMeters>750</DistanceMeters>
                    <HeartRateBpm><Value>150</Value></HeartRateBpm>
                    <Extensions>
                      <TPX xmlns="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
                        <Watts>210</Watts>
                      </TPX>
                    </Extensions>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2024-03-02T07:10:00Z</Time>
                    <Position><LatitudeDegrees>24.73</LatitudeDegrees><LongitudeDegrees>46.69</LongitudeDegrees></Position>
                    <AltitudeMeters>630</AltitudeMeters>
                    <DistanceMeters>1500</DistanceMeters>
                    <HeartRateBpm><Value>160</Value></HeartRateBpm>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """
    }

    private func csvFixture() -> String {
        """
        metric_id,value,unit,measured_at,tz
        body.weight,70.5,kg,2024-03-01T08:00:00+03:00,Asia/Riyadh
        heart.rhr,55,bpm,2024-03-01T07:00:00+03:00,Asia/Riyadh
        activity.steps,4200,count,2024-03-01T09:00:00+03:00,Asia/Riyadh
        """
    }

    // MARK: - 1. GPX parses into the right DTOs and commits through the pipeline

    func testGPXImportsAWorkoutWithARouteUnderRouteConsent() throws {
        let url = try writeFile(gpxFixture(), named: "route.gpx")
        let importer = makeImporter(routeConsent: GrantedRouteConsent())

        let result = try importer.importFile(format: .gpx, fileURL: url, fileName: "route.gpx")

        let workouts = try MeasurementRepository(db.main).sessions(kind: .workout)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.detail.workout?.activityType, "running")
        XCTAssertEqual(workouts.first?.provenance.ingestionPath, .fileImport)
        XCTAssertEqual(workouts.first?.provenance.importBatchId, result.batchId)
        XCTAssertGreaterThan(workouts.first?.detail.workout?.totals.distanceMeters ?? 0, 0,
                             "distance is derivable from the trace itself even though GPX carries no total")

        let routes = try RouteRepository(db.main).routes(sessionId: workouts.first!.id)
        XCTAssertEqual(routes.count, 1, "route consent was granted, so the trace is stored")
        let points = try RouteRepository(db.main).points(routeId: routes.first!.id)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.first?.altitudeMeters, 620.0)

        let batch = try ImportBatchRepository(db.main).find(id: result.batchId)
        XCTAssertEqual(batch?.state, ImportBatch.stateCompleted)
        XCTAssertEqual(batch?.sourceKind, ImportBatch.gpxSourceKind)
        XCTAssertEqual(batch?.fileName, "route.gpx")
    }

    /// The two-gates model (EPIC-03): without route consent, the workout still imports but its
    /// GPS trace is honestly dropped rather than written over a toggle nobody agreed to.
    func testGPXWithoutRouteConsentImportsTheWorkoutButNotTheRoute() throws {
        let url = try writeFile(gpxFixture(), named: "route-noconsent.gpx")
        let importer = makeImporter(routeConsent: DeniedRouteConsent())

        _ = try importer.importFile(format: .gpx, fileURL: url, fileName: "route-noconsent.gpx")

        let workouts = try MeasurementRepository(db.main).sessions(kind: .workout)
        XCTAssertEqual(workouts.count, 1, "the workout itself still imports")
        let routes = try RouteRepository(db.main).routes(sessionId: workouts.first!.id)
        XCTAssertTrue(routes.isEmpty, "no consent, no stored GPS trace")
    }

    // MARK: - 2. TCX parses distance/calories/heart-rate/position/time; cadence+power are read but not stored

    func testTCXImportsWorkoutTotalsHeartRateSamplesAndRoute() throws {
        let url = try writeFile(tcxFixture(), named: "activity.tcx")
        let importer = makeImporter(routeConsent: GrantedRouteConsent())

        let result = try importer.importFile(format: .tcx, fileURL: url, fileName: "activity.tcx")

        let workouts = try MeasurementRepository(db.main).sessions(kind: .workout)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.detail.workout?.activityType, "running")
        XCTAssertEqual(workouts.first?.detail.workout?.totals.distanceMeters ?? 0, 1500, accuracy: 0.5)
        XCTAssertEqual(workouts.first?.detail.workout?.totals.energyKcal ?? 0, 110, accuracy: 0.5)
        XCTAssertEqual(workouts.first?.detail.workout?.totals.avgHeartRateBpm ?? 0, 140, accuracy: 0.5)
        XCTAssertEqual(workouts.first?.detail.workout?.totals.maxHeartRateBpm ?? 0, 160, accuracy: 0.5)

        // Heart rate lands as ordinary `heart.hr` samples, alongside every other HR source.
        let hrSamples = try MeasurementRepository(db.main).rawSamples(metricId: MetricID.heartRate)
        XCTAssertEqual(hrSamples.count, 3, "one HR sample per trackpoint that carried one")
        XCTAssertTrue(hrSamples.allSatisfy { $0.provenance.ingestionPath == .fileImport })

        let routes = try RouteRepository(db.main).routes(sessionId: workouts.first!.id)
        XCTAssertEqual(routes.count, 1)
        let points = try RouteRepository(db.main).points(routeId: routes.first!.id)
        XCTAssertEqual(points.count, 3)

        // Cadence and power (Garmin TPX extensions) are read but produce no rows anywhere — no
        // metric ontology id exists for them yet, and this importer documents that rather than
        // fabricating one. The only rows for this batch are the workout + its 3 HR samples.
        let batch = try XCTUnwrap(try ImportBatchRepository(db.main).find(id: result.batchId))
        XCTAssertEqual(batch.decodedCounts["samples"], 3)
        XCTAssertEqual(batch.decodedCounts["workouts"], 1)
    }

    // MARK: - 3. CSV parses samples against the documented column contract

    func testCSVImportsSamplesWithCorrectMetricValueUnitAndTimezone() throws {
        let url = try writeFile(csvFixture(), named: "measurements.csv")
        let importer = makeImporter()

        let result = try importer.importFile(format: .csv, fileURL: url, fileName: "measurements.csv")

        let weight = try MeasurementRepository(db.main).rawSamples(metricId: MetricID.weight)
        XCTAssertEqual(weight.first?.value ?? 0, 70.5, accuracy: 0.001)
        XCTAssertEqual(weight.first?.tzId, "Asia/Riyadh")
        XCTAssertEqual(weight.first?.provenance.ingestionPath, .fileImport)
        XCTAssertEqual(weight.first?.provenance.importBatchId, result.batchId)

        let rhr = try MeasurementRepository(db.main).rawSamples(metricId: MetricID.restingHeartRate)
        XCTAssertEqual(rhr.first?.value ?? 0, 55, accuracy: 0.001)

        let steps = try MeasurementRepository(db.main).rawSamples(metricId: MetricID.steps)
        XCTAssertEqual(steps.first?.value ?? 0, 4200, accuracy: 0.001)

        let batch = try ImportBatchRepository(db.main).find(id: result.batchId)
        XCTAssertEqual(batch?.sourceKind, ImportBatch.csvSourceKind)
        XCTAssertEqual(batch?.state, ImportBatch.stateCompleted)
    }

    func testCSVRejectsAHeaderMissingRequiredColumns() throws {
        let bad = "metric_id,value,unit\nbody.weight,70,kg\n"
        let url = try writeFile(bad, named: "bad-header.csv")

        XCTAssertThrowsError(try makeImporter().importFile(format: .csv, fileURL: url, fileName: "bad-header.csv")) { error in
            guard case FileImportError.missingColumns = error else {
                return XCTFail("expected .missingColumns, got \(error)")
            }
        }
        let batch = try XCTUnwrap(try ImportBatchRepository(db.main).all().first)
        XCTAssertEqual(batch.state, ImportBatch.stateFailed)
    }

    // MARK: - 4. Malformed/truncated files fail gracefully — never a crash, always `.failed`

    func testTruncatedGPXFailsGracefullyAndMarksTheBatchFailed() throws {
        // Deliberately broken: an unclosed <trk> and a dangling <gpx> with no closing tags at all —
        // XMLParser cannot finish, which is exactly the "truncated file" case.
        let broken = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"><trk><name>oops</name><trkseg><trkpt lat="24.0" lon="46.0"><time>2024-01-01T00:00:00Z
        """
        let url = try writeFile(broken, named: "broken.gpx")

        XCTAssertThrowsError(try makeImporter().importFile(format: .gpx, fileURL: url, fileName: "broken.gpx")) { error in
            guard case FileImportError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
        let batch = try XCTUnwrap(try ImportBatchRepository(db.main).all().first)
        XCTAssertEqual(batch.state, ImportBatch.stateFailed)
        XCTAssertEqual(try count("sessions"), 0, "nothing from a failed parse should land as a row")
    }

    func testTruncatedTCXFailsGracefullyAndMarksTheBatchFailed() throws {
        let broken = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase><Activities><Activity Sport="Running"><Id>2024-01-01T00:00:00Z</Id><Lap StartTime="2024-01-01T00:00:00Z"><Track><Trackpoint><Time>2024-01-01T00:00:00Z
        """
        let url = try writeFile(broken, named: "broken.tcx")

        XCTAssertThrowsError(try makeImporter().importFile(format: .tcx, fileURL: url, fileName: "broken.tcx")) { error in
            guard case FileImportError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
        let batch = try XCTUnwrap(try ImportBatchRepository(db.main).all().first)
        XCTAssertEqual(batch.state, ImportBatch.stateFailed)
    }

    func testMalformedCSVRowFailsGracefullyAndMarksTheBatchFailed() throws {
        let broken = """
        metric_id,value,unit,measured_at,tz
        body.weight,not-a-number,kg,2024-03-01T08:00:00Z,UTC
        """
        let url = try writeFile(broken, named: "broken.csv")

        XCTAssertThrowsError(try makeImporter().importFile(format: .csv, fileURL: url, fileName: "broken.csv")) { error in
            guard case FileImportError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
        let batch = try XCTUnwrap(try ImportBatchRepository(db.main).all().first)
        XCTAssertEqual(batch.state, ImportBatch.stateFailed)
        XCTAssertEqual(try count("raw_samples"), 0)
    }

    func testUnreadableFileSurfacesCannotReadFile() throws {
        let missing = tempDir.appendingPathComponent("does-not-exist.gpx")
        XCTAssertThrowsError(try makeImporter().importFile(format: .gpx, fileURL: missing, fileName: "does-not-exist.gpx")) { error in
            XCTAssertEqual(error as? FileImportError, .cannotReadFile)
        }
    }

    // MARK: - 5. Re-importing the identical file is idempotent

    func testReimportingTheIdenticalGPXWritesNothingNewAndKeepsOneBatch() throws {
        let url = try writeFile(gpxFixture(), named: "repeat.gpx")
        let importer = makeImporter(routeConsent: GrantedRouteConsent())

        let first = try importer.importFile(format: .gpx, fileURL: url, fileName: "repeat.gpx")
        let sessionsAfterFirst = try count("sessions")
        let routesAfterFirst = try count("workout_routes")
        let pointsAfterFirst = try count("route_points")
        XCTAssertEqual(sessionsAfterFirst, 1)

        let second = try importer.importFile(format: .gpx, fileURL: url, fileName: "repeat.gpx")

        XCTAssertEqual(second.batchId, first.batchId, "one batch per file, so undo still covers everything")
        XCTAssertEqual(try count("sessions"), sessionsAfterFirst, "re-import must not duplicate the workout")
        XCTAssertEqual(try count("workout_routes"), routesAfterFirst, "route replaces in place, never duplicates")
        XCTAssertEqual(try count("route_points"), pointsAfterFirst)
        XCTAssertEqual(try ImportBatchRepository(db.main).all().count, 1)
    }

    func testReimportingTheIdenticalCSVWritesNothingNew() throws {
        let url = try writeFile(csvFixture(), named: "repeat.csv")
        let importer = makeImporter()

        let first = try importer.importFile(format: .csv, fileURL: url, fileName: "repeat.csv")
        let samplesAfterFirst = try count("raw_samples")
        XCTAssertGreaterThan(samplesAfterFirst, 0)

        let second = try importer.importFile(format: .csv, fileURL: url, fileName: "repeat.csv")

        XCTAssertEqual(try count("raw_samples"), samplesAfterFirst, "re-import must not duplicate rows")
        XCTAssertEqual(second.batchId, first.batchId)
        XCTAssertEqual(second.counts["samples"], 0, "second pass creates no new sample rows")
    }

    func testReimportingTheIdenticalTCXWritesNothingNew() throws {
        let url = try writeFile(tcxFixture(), named: "repeat.tcx")
        let importer = makeImporter(routeConsent: GrantedRouteConsent())

        _ = try importer.importFile(format: .tcx, fileURL: url, fileName: "repeat.tcx")
        let samplesAfterFirst = try count("raw_samples")
        let sessionsAfterFirst = try count("sessions")

        let second = try importer.importFile(format: .tcx, fileURL: url, fileName: "repeat.tcx")

        XCTAssertEqual(try count("raw_samples"), samplesAfterFirst)
        XCTAssertEqual(try count("sessions"), sessionsAfterFirst)
        XCTAssertEqual(second.counts["samples"], 0)
        XCTAssertEqual(second.counts["workouts"], 0)
    }

    // MARK: - 6. Undo reverses a completed import's rows

    func testUndoReversesAGPXImportsWorkoutAndRoute() throws {
        let url = try writeFile(gpxFixture(), named: "undo-me.gpx")
        let importer = makeImporter(routeConsent: GrantedRouteConsent())
        let result = try importer.importFile(format: .gpx, fileURL: url, fileName: "undo-me.gpx")
        XCTAssertGreaterThan(try count("sessions", where: "batch_id = '\(result.batchId)'"), 0)
        XCTAssertGreaterThan(try count("workout_routes", where: "batch_id = '\(result.batchId)'"), 0)

        let undo = try importer.undo(batchId: result.batchId)

        XCTAssertEqual(try count("sessions", where: "batch_id = '\(result.batchId)' AND deleted_at IS NULL"), 0)
        XCTAssertEqual(try count("workout_routes", where: "batch_id = '\(result.batchId)' AND deleted_at IS NULL"), 0)
        XCTAssertGreaterThan(undo.removedSessions, 0)
        // Tombstoned, not erased (I3) — the batch row survives so a re-import lands back on these rows.
        XCTAssertGreaterThan(try count("sessions", where: "batch_id = '\(result.batchId)' AND deleted_at IS NOT NULL"), 0)
        let batch = try XCTUnwrap(try ImportBatchRepository(db.main).find(id: result.batchId))
        XCTAssertEqual(batch.state, ImportBatch.stateUndone)
        XCTAssertFalse(batch.isTerminal, "an undone import must not offer 'undo' again")
    }

    func testUndoReversesACSVImportsSamples() throws {
        let url = try writeFile(csvFixture(), named: "undo-me.csv")
        let importer = makeImporter()
        let result = try importer.importFile(format: .csv, fileURL: url, fileName: "undo-me.csv")
        let written = try count("raw_samples", where: "batch_id = '\(result.batchId)'")
        XCTAssertGreaterThan(written, 0)

        let undo = try importer.undo(batchId: result.batchId)

        XCTAssertEqual(try count("raw_samples", where: "batch_id = '\(result.batchId)' AND deleted_at IS NULL"), 0)
        XCTAssertEqual(undo.removedSamples, written)

        // Re-importing the same file afterward revives exactly those rows under the same batch.
        clock.advance(by: 60)
        let again = try makeImporter().importFile(format: .csv, fileURL: url, fileName: "undo-me.csv")
        XCTAssertEqual(again.batchId, result.batchId)
        XCTAssertEqual(try count("raw_samples", where: "deleted_at IS NULL"), written)
        XCTAssertEqual(try count("raw_samples"), written, "revived in place — never a second copy")
    }

    /// AUDIT FIX (test-coverage gap): TCX is the ONE format whose single import batch writes to
    /// ALL THREE tombstoned tables at once (`sessions`, `raw_samples` for its HR trackpoints, AND
    /// `workout_routes`) — `testUndoReversesAGPXImportsWorkoutAndRoute` only covers sessions+routes
    /// (its fixture carries no HR data) and `testUndoReversesACSVImportsSamples` only covers
    /// raw_samples (CSV writes no sessions/routes at all). `ImportBatchRepository.undo`'s mechanism
    /// is generic across tables and already exercised by those two, but nothing had directly
    /// re-queried the database after undoing a batch that spans all three together until this test.
    func testUndoReversesATCXImportsWorkoutSamplesAndRoute() throws {
        let url = try writeFile(tcxFixture(), named: "undo-me.tcx")
        let importer = makeImporter(routeConsent: GrantedRouteConsent())
        let result = try importer.importFile(format: .tcx, fileURL: url, fileName: "undo-me.tcx")

        XCTAssertGreaterThan(try count("sessions", where: "batch_id = '\(result.batchId)'"), 0)
        XCTAssertGreaterThan(try count("raw_samples", where: "batch_id = '\(result.batchId)'"), 0)
        XCTAssertGreaterThan(try count("workout_routes", where: "batch_id = '\(result.batchId)'"), 0)

        let undo = try importer.undo(batchId: result.batchId)

        XCTAssertEqual(try count("sessions", where: "batch_id = '\(result.batchId)' AND deleted_at IS NULL"), 0)
        XCTAssertEqual(try count("raw_samples", where: "batch_id = '\(result.batchId)' AND deleted_at IS NULL"), 0)
        XCTAssertEqual(try count("workout_routes", where: "batch_id = '\(result.batchId)' AND deleted_at IS NULL"), 0)
        XCTAssertGreaterThan(undo.removedSessions, 0)
        XCTAssertGreaterThan(undo.removedSamples, 0)

        // Tombstoned, not erased (I3) — every one of the three tables' rows survives for the batch.
        XCTAssertGreaterThan(try count("sessions", where: "batch_id = '\(result.batchId)' AND deleted_at IS NOT NULL"), 0)
        XCTAssertGreaterThan(try count("raw_samples", where: "batch_id = '\(result.batchId)' AND deleted_at IS NOT NULL"), 0)
        XCTAssertGreaterThan(try count("workout_routes", where: "batch_id = '\(result.batchId)' AND deleted_at IS NOT NULL"), 0)

        let batch = try XCTUnwrap(try ImportBatchRepository(db.main).find(id: result.batchId))
        XCTAssertEqual(batch.state, ImportBatch.stateUndone)
        XCTAssertFalse(batch.isTerminal, "an undone import must not offer 'undo' again")
    }

    func testASecondUndoIsANoOp() throws {
        let url = try writeFile(csvFixture(), named: "undo-twice.csv")
        let importer = makeImporter()
        let result = try importer.importFile(format: .csv, fileURL: url, fileName: "undo-twice.csv")

        let first = try importer.undo(batchId: result.batchId)
        XCTAssertGreaterThan(first.removedSamples, 0)

        clock.advance(by: 3_600)
        let second = try importer.undo(batchId: result.batchId)
        XCTAssertEqual(second.removedSamples, 0)
        XCTAssertNil(second.affectedRange)
    }

    // MARK: - 7. Different formats keep independent batch lineage even under the same file name

    func testTheSameFileNameUnderDifferentFormatsGetsIndependentBatches() throws {
        // Same literal name, two different formats/content — `existingBatch` is scoped by
        // `(source_kind, file_name)`, so this must not collide into one lineage.
        let gpxURL = try writeFile(gpxFixture(), named: "on-disk-1.gpx")
        let csvURL = try writeFile(csvFixture(), named: "on-disk-2.csv")   // different disk path...

        let importer = makeImporter()
        // ...but the SAME declared `fileName`, which is the identity `existingBatch` dedups on.
        let gpxResult = try importer.importFile(format: .gpx, fileURL: gpxURL, fileName: "same-name")
        let csvResult = try importer.importFile(format: .csv, fileURL: csvURL, fileName: "same-name")

        XCTAssertNotEqual(gpxResult.batchId, csvResult.batchId)
        let batches = try ImportBatchRepository(db.main).all()
        XCTAssertEqual(batches.count, 2)
    }
}
