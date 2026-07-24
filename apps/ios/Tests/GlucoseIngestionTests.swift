import XCTest
@testable import BADAN

/// A21/ADR-0010, D-26 — platform-written blood glucose (HealthKit `bloodGlucose` only), widened
/// through the exact same `IngestionPipeline`/`HealthKitAdapter` seam every other metric uses. See
/// `HealthAdapterFixTests` for the `HKTypeMap` row itself; this file covers the DB-level behavior:
/// the row actually lands in `badan.db` via the general pipeline (not a bespoke sensitive-DB
/// path — see the D-26 scope note in `docs/DECISIONS.md`), the reconciliation-v2 conflict path
/// applies to it exactly like weight/RHR/HRV, a manual fingerstick does NOT automatically outrank
/// a device reading the way it does for weight (I4), and the export gate excludes it from a
/// default (non-sensitive) export while including it once the person opts in.
final class GlucoseIngestionTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-glucose-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var range: HealthDateRange {
        HealthDateRange(start: clock.now().addingTimeInterval(-90 * 86_400), end: clock.now())
    }

    /// Plain pipeline, no reconciliation-v2 wiring — mirrors `PipelineTests.makeIngestion()`.
    private func makeIngestion() -> IngestionPipeline {
        IngestionPipeline(measurements: MeasurementRepository(db.main),
                          catalog: CatalogRepository(db.main),
                          reconciliation: ReconciliationRepository(db.main),
                          registry: MetricRegistry.shared, clock: clock, deviceId: deviceId)
    }

    /// The fully-wired shape `AppEnvironment` actually constructs (`dataConflicts` +
    /// `sourcePriorityRules`), needed for the reconciliation-v2 tests below.
    private func makeIngestionWithConflicts() -> IngestionPipeline {
        IngestionPipeline(measurements: MeasurementRepository(db.main),
                          catalog: CatalogRepository(db.main),
                          reconciliation: ReconciliationRepository(db.main),
                          registry: MetricRegistry.shared, clock: clock, deviceId: deviceId,
                          dataConflicts: DataConflictRepository(main: db.main),
                          sourcePriorityRules: SourcePriorityRuleRepository(main: db.main))
    }

    /// A minimal `HealthStorePort` that hands back exactly the glucose fixture a test wants —
    /// deliberately NOT `FakeHealthStore` (which produces no glucose data and whose deterministic
    /// generator/cache is shared by every other test in the suite; extending it is a materially
    /// bigger, riskier change than this file needs).
    private struct GlucoseStubHealthStore: HealthStorePort {
        let samples: [SampleDTO]
        let descriptors: [SourceDescriptor]

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] { descriptors }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
            samples.filter { $0.start >= range.start && $0.start <= range.end }
        }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] { [] }
    }

    // MARK: - The widened type ingests correctly

    func testGlucoseSamplesIngestIntoRawSamplesViaTheGeneralPipeline() throws {
        let pipeline = makeIngestion()
        let at = clock.now().addingTimeInterval(-3_600)
        let store = GlucoseStubHealthStore(
            samples: [SampleDTO(metricId: MetricID.glucose, value: 5.4, unit: "mmol/L", start: at,
                                tz: "UTC", sourceId: "cgm-1", externalId: "hk-glucose-1")],
            descriptors: [SourceDescriptor(id: "cgm-1", displayName: "Connected sensor",
                                           type: .healthkit, priority: 0)])

        let summary = try pipeline.ingest(from: store, range: range)
        XCTAssertEqual(summary.samples, 1)

        // Queried against `db.main` specifically — the D-26 scope note's claim, made concrete: a
        // sensitivePlus-classed metric still lands in the MAIN database via the general pipeline,
        // not a second sensitive-backed repository set.
        let rows = try MeasurementRepository(db.main).rawSamples(metricId: MetricID.glucose)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.value, 5.4, accuracy: 1e-9,
                       "mmol/L is the registry canonical, so this is an identity write")
        XCTAssertEqual(row.unit, "mmol/L")
        XCTAssertFalse(row.provenance.qualityFlags.contains(.estimate),
                       "a clean mmol/L write must never be stamped as an estimate")
        XCTAssertEqual(row.provenance.ingestionPath, .platformStore)
    }

    /// Re-ingesting the same range must not duplicate the row — the same upsert-by-identity
    /// guarantee every other widened metric gets, exercised here rather than assumed.
    func testReIngestingGlucoseIsIdempotent() throws {
        let pipeline = makeIngestion()
        let at = clock.now().addingTimeInterval(-3_600)
        let store = GlucoseStubHealthStore(
            samples: [SampleDTO(metricId: MetricID.glucose, value: 6.1, unit: "mmol/L", start: at,
                                tz: "UTC", sourceId: "cgm-1", externalId: "hk-glucose-1")],
            descriptors: [SourceDescriptor(id: "cgm-1", displayName: "Connected sensor",
                                           type: .healthkit, priority: 0)])

        _ = try pipeline.ingest(from: store, range: range)
        let second = try pipeline.ingest(from: store, range: range)
        XCTAssertEqual(second.samples, 0, "an unchanged re-ingest must write nothing new")
        XCTAssertEqual(try MeasurementRepository(db.main).rawSamples(metricId: MetricID.glucose).count, 1)
    }

    // MARK: - Dedup / source-priority behavior (reconciliation-v2)

    /// Two sources meaningfully disagreeing on the same day, with no `SourcePriorityRule` saved,
    /// must surface an UNRESOLVED conflict for the person to see — never a silent guess, and never
    /// an automatic winner (glucose is deliberately NOT in `ConflictDecisionEngine
    /// .manualWinsMetrics`, unlike weight).
    func testTwoDisagreeingDeviceSourcesLeaveAnUnresolvedConflictWithNoSavedRule() throws {
        let pipeline = makeIngestionWithConflicts()
        let day = clock.now().addingTimeInterval(-3_600)
        let store = GlucoseStubHealthStore(
            samples: [
                SampleDTO(metricId: MetricID.glucose, value: 5.0, unit: "mmol/L", start: day,
                         tz: "UTC", sourceId: "cgm-a", externalId: "hk-glucose-a"),
                SampleDTO(metricId: MetricID.glucose, value: 7.0, unit: "mmol/L",
                         start: day.addingTimeInterval(60), tz: "UTC",
                         sourceId: "cgm-b", externalId: "hk-glucose-b"),
            ],
            descriptors: [
                SourceDescriptor(id: "cgm-a", displayName: "Sensor A", type: .healthkit, priority: 0),
                SourceDescriptor(id: "cgm-b", displayName: "Sensor B", type: .healthkit, priority: 0),
            ])

        _ = try pipeline.ingest(from: store, range: range)

        let dataConflicts = DataConflictRepository(main: db.main)
        let conflicts = try dataConflicts.conflicts(scopeKey: ConflictScope.metric(id: MetricID.glucose).storageKey)
        XCTAssertEqual(conflicts.count, 1,
                       "two materially disagreeing sources on the same day must be flagged")
        XCTAssertEqual(conflicts.first?.status, .unresolved)

        let rows = try MeasurementRepository(db.main).rawSamples(metricId: MetricID.glucose, includeSuppressed: true)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.provenance.suppressedBy == nil },
                      "an unresolved conflict must not suppress either candidate")
    }

    /// Once a `SourcePriorityRule` for `body.glucose` exists, the engine resolves deterministically
    /// — proving the general priority-order path (rule 5) applies to glucose exactly like any other
    /// metric, per the blueprint's own "store point > vendor API > fingerstick" ordering.
    func testSourcePriorityRuleResolvesAGlucoseConflictDeterministically() throws {
        let now = clock.now()
        try SourcePriorityRuleRepository(main: db.main).insert(SourcePriorityRule(
            id: ULID.newID(), metricId: MetricID.glucose,
            priorityOrder: [SourcePriorityRule.ClassificationKey.wristOpticalHR,
                           SourcePriorityRule.ClassificationKey.bleChestStrapHR],
            isUserOverride: true, createdAt: now, updatedAt: now, originDeviceId: deviceId))

        let pipeline = makeIngestionWithConflicts()
        let day = now.addingTimeInterval(-3_600)
        let store = GlucoseStubHealthStore(
            samples: [
                SampleDTO(metricId: MetricID.glucose, value: 5.0, unit: "mmol/L", start: day,
                         tz: "UTC", sourceId: "cgm-watch", externalId: "hk-glucose-watch"),
                SampleDTO(metricId: MetricID.glucose, value: 7.0, unit: "mmol/L",
                         start: day.addingTimeInterval(60), tz: "UTC",
                         sourceId: "cgm-strap", externalId: "hk-glucose-strap"),
            ],
            descriptors: [
                SourceDescriptor(id: "cgm-watch", displayName: "My Watch", type: .healthkit,
                                 deviceId: "watch-dev", deviceName: "My Watch", deviceModel: "Watch", priority: 0),
                SourceDescriptor(id: "cgm-strap", displayName: "Chest strap", type: .healthkit,
                                 deviceId: "strap-dev", deviceName: "Chest strap", deviceModel: "HRM", priority: 0),
            ])

        _ = try pipeline.ingest(from: store, range: range)

        let measurements = MeasurementRepository(db.main)
        let rows = try measurements.rawSamples(metricId: MetricID.glucose, includeSuppressed: true)
        let winner = try XCTUnwrap(rows.first { $0.provenance.sourceId == "cgm-watch" })
        let loser = try XCTUnwrap(rows.first { $0.provenance.sourceId == "cgm-strap" })
        XCTAssertNil(winner.provenance.suppressedBy, "the higher-ranked classification must survive")
        XCTAssertEqual(loser.provenance.suppressedBy, winner.id)

        let decision = try XCTUnwrap(ReconciliationRepository(db.main).forSuppressed(loser.id))
        XCTAssertEqual(decision.keptRecordId, winner.id)
        XCTAssertEqual(decision.rule, ConflictDecisionEngine.priorityOrderRuleId)
    }

    /// The negative half of I4's absence for glucose: a manually-entered reading must NOT
    /// automatically outrank a device reading the way it does for weight — it only wins if a
    /// `SourcePriorityRule` explicitly ranks it above the device class it's disagreeing with.
    /// (No manual-entry UI ships for glucose in this slice; the manual row is written directly to
    /// exercise the reconciliation mechanism, which is agnostic to how a row was authored.)
    func testManualFingerstickDoesNotAutomaticallyOutrankADeviceReading() throws {
        let measurements = MeasurementRepository(db.main)
        let now = clock.now()
        let day = now.addingTimeInterval(-3_600)

        let manual = RawSample(
            id: ULID.newID(), metricId: MetricID.glucose, value: 5.0, unit: "mmol/L",
            originalValue: 5.0, originalUnit: "mmol/L", startAt: day, endAt: day, tzId: "UTC",
            provenance: Provenance(sourceId: "manual-entry", ingestionPath: .manual,
                                   externalId: "manual-glucose-1", measuredAt: day,
                                   measuredTimezone: "UTC", recordedAt: day, ingestedAt: day),
            updatedAt: day, originDeviceId: deviceId)
        _ = try measurements.upsertRawSample(manual)

        let pipeline = makeIngestionWithConflicts()
        let store = GlucoseStubHealthStore(
            samples: [SampleDTO(metricId: MetricID.glucose, value: 7.0, unit: "mmol/L",
                                start: day.addingTimeInterval(60), tz: "UTC",
                                sourceId: "cgm-device", externalId: "hk-glucose-device")],
            descriptors: [SourceDescriptor(id: "cgm-device", displayName: "Connected sensor",
                                           type: .healthkit, priority: 0)])

        _ = try pipeline.ingest(from: store, range: range)

        let rows = try measurements.rawSamples(metricId: MetricID.glucose, includeSuppressed: true)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.provenance.suppressedBy == nil },
                      "with no rule ranking it, the manual reading must not win by default (unlike weight's I4 rule)")

        let dataConflicts = DataConflictRepository(main: db.main)
        let conflicts = try dataConflicts.conflicts(scopeKey: ConflictScope.metric(id: MetricID.glucose).storageKey)
        XCTAssertEqual(conflicts.count, 1, "the disagreement is still surfaced, just not auto-resolved")
    }

    // MARK: - Export inclusion

    /// `sensitiveClass: sensitivePlus` gates export the same way it already does for cycle.*/lab.*
    /// — excluded by default, included once the person opts in — regardless of which physical
    /// database the row lives in (see `ExportRunner.metricAllowed`).
    func testGlucoseExcludedFromDefaultExportButIncludedWhenSensitiveOptedIn() throws {
        let pipeline = makeIngestion()
        let at = clock.now().addingTimeInterval(-3_600)
        let store = GlucoseStubHealthStore(
            samples: [SampleDTO(metricId: MetricID.glucose, value: 5.6, unit: "mmol/L", start: at,
                                tz: "UTC", sourceId: "cgm-1", externalId: "hk-glucose-export")],
            descriptors: [SourceDescriptor(id: "cgm-1", displayName: "Connected sensor",
                                           type: .healthkit, priority: 0)])
        _ = try pipeline.ingest(from: store, range: range)

        let runner = ExportRunner(measurements: MeasurementRepository(db.main),
                                  derivation: DerivationRepository(db.main),
                                  logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
                                  exportJobs: ExportJobRepository(db.main), registry: .shared,
                                  clock: clock, appVersion: "test", deviceId: deviceId)

        let withoutSensitive = try runner.run(scope: ExportScope(includeSensitive: false), format: .csv)
        let rawURLWithout = try XCTUnwrap(withoutSensitive.fileURLs.first { $0.lastPathComponent == "raw.csv" })
        let textWithout = try String(contentsOf: rawURLWithout, encoding: .utf8)
        XCTAssertFalse(textWithout.contains(MetricID.glucose),
                       "glucose is sensitivePlus and must be excluded from a default export")

        let passphrase = "correct horse battery staple"
        let withSensitive = try runner.run(scope: ExportScope(includeSensitive: true), format: .json,
                                           passphrase: passphrase)
        let containerURL = try XCTUnwrap(withSensitive.fileURLs.first)
        let decrypted = try ExportEncryptor.decrypt(Data(contentsOf: containerURL), passphrase: passphrase)
        let bundleFile = try XCTUnwrap(decrypted.first { $0.name == "bundle.json" })
        let includedText = try XCTUnwrap(String(data: bundleFile.data, encoding: .utf8))
        XCTAssertTrue(includedText.contains(MetricID.glucose),
                      "an includeSensitive export must carry glucose rows")
    }
}
