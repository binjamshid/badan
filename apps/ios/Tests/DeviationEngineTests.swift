import XCTest
@testable import BADAN

/// EPIC-27 — the DeviationEngine behind the Health Monitor.
///
/// The pure-core tests (`makeTile`, `tempDirection`, `buildSparkline`, `resolveSourceQuality`, and
/// the authored copy) mirror `DeviationEngineTest.kt` on Android exactly — the tile a given input
/// produces, and the bilingual copy it carries, must be byte-identical across platforms. The
/// DB-backed tests cover what the pure core cannot: latest-reading + band + source assembled into a
/// read model, no-data/stale states, and per-source sensor-quality attribution — Android has no
/// DB-backed harness, so those run here only (same split as `BaselineEngineTests`).
final class DeviationEngineTests: XCTestCase {
    let registry = MetricRegistry.shared
    let quality = SensorQualityMap.shared

    private func rhrDef() -> MetricDefinition { registry.definitionOrFallback(MetricID.restingHeartRate) }
    private func tempDef() -> MetricDefinition { registry.definitionOrFallback(MetricID.wristTempDeviation) }

    private func band(center: Double, low: Double, high: Double, provisional: Bool,
                      metricId: String = MetricID.restingHeartRate, unit: String = "bpm") -> Baseline {
        Baseline(id: "baseline-1", metricId: metricId, windowDays: 14, center: center, spread: 2,
                 bandLow: low, bandHigh: high, nPoints: provisional ? 4 : 14, provisional: provisional,
                 algorithmVersion: "baseline.rolling_median_mad@2.0.0", validFrom: Date(),
                 computedAt: Date(), unit: unit)
    }

    // MARK: - Pure: band classification (mirror of DeviationEngineTest.kt)

    func testWithinBandProducesNoAnnotation() {
        let tile = DeviationEngine.makeTile(
            def: rhrDef(), latest: DayValue(day: "2026-07-20", value: 57),
            band: band(center: 55, low: 50, high: 60, provisional: false),
            sparkline: [], sourceQuality: nil, staleCutoffDay: "2026-07-18")
        XCTAssertEqual(tile.state, .withinBand)
        XCTAssertNil(tile.annotation, "within the band is calm silence, not a note")
        XCTAssertFalse(tile.isStale)
        XCTAssertEqual(tile.reading, .absolute(57))
        XCTAssertEqual(tile.band?.low, 50)
        XCTAssertEqual(tile.band?.baselineId, "baseline-1", "band carries provenance for the anatomy sheet")
    }

    func testAboveBandProducesCalmAnnotation() {
        let tile = DeviationEngine.makeTile(
            def: rhrDef(), latest: DayValue(day: "2026-07-20", value: 65),
            band: band(center: 55, low: 50, high: 60, provisional: false),
            sparkline: [], sourceQuality: nil, staleCutoffDay: "2026-07-18")
        XCTAssertEqual(tile.state, .aboveBand)
        XCTAssertEqual(tile.annotation, DeviationEngine.bandAnnotation(.above))
        XCTAssertNotNil(tile.annotation)
    }

    func testBelowBandProducesCalmAnnotation() {
        let tile = DeviationEngine.makeTile(
            def: rhrDef(), latest: DayValue(day: "2026-07-20", value: 45),
            band: band(center: 55, low: 50, high: 60, provisional: false),
            sparkline: [], sourceQuality: nil, staleCutoffDay: "2026-07-18")
        XCTAssertEqual(tile.state, .belowBand)
        XCTAssertEqual(tile.annotation, DeviationEngine.bandAnnotation(.below))
    }

    func testProvisionalBandIsCalibratingNotClassified() {
        let tile = DeviationEngine.makeTile(
            def: rhrDef(), latest: DayValue(day: "2026-07-20", value: 65),
            band: band(center: 55, low: 50, high: 60, provisional: true),
            sparkline: [], sourceQuality: nil, staleCutoffDay: "2026-07-18")
        XCTAssertEqual(tile.state, .calibrating, "a provisional band never yields an in/out verdict")
        XCTAssertNil(tile.annotation)
        XCTAssertEqual(tile.band?.provisional, true, "the band is still surfaced so the UI can show calibration")
    }

    func testAbsentBandIsCalibrating() {
        let tile = DeviationEngine.makeTile(
            def: rhrDef(), latest: DayValue(day: "2026-07-20", value: 65),
            band: nil, sparkline: [], sourceQuality: nil, staleCutoffDay: "2026-07-18")
        XCTAssertEqual(tile.state, .calibrating)
        XCTAssertNil(tile.band)
    }

    func testNoReadingIsNoDataNotZero() {
        let tile = DeviationEngine.makeTile(
            def: rhrDef(), latest: nil,
            band: band(center: 55, low: 50, high: 60, provisional: false),
            sparkline: [], sourceQuality: nil, staleCutoffDay: "2026-07-18")
        XCTAssertEqual(tile.state, .noData)
        XCTAssertNil(tile.reading, "no data is a first-class state, never a fake zero")
        XCTAssertNil(tile.asOfDay)
        XCTAssertFalse(tile.isStale)
        XCTAssertNotNil(tile.band, "the band is still context even with no recent reading")
    }

    func testStaleReadingKeepsPositionButSuppressesAnnotation() {
        let tile = DeviationEngine.makeTile(
            def: rhrDef(), latest: DayValue(day: "2026-07-17", value: 65),
            band: band(center: 55, low: 50, high: 60, provisional: false),
            sparkline: [], sourceQuality: nil, staleCutoffDay: "2026-07-20")
        XCTAssertTrue(tile.isStale, "a reading older than the freshness horizon is stale")
        XCTAssertEqual(tile.state, .aboveBand, "the last known position is still shown")
        XCTAssertNil(tile.annotation, "the 'latest reading' note is suppressed on a stale tile — 'as of' carries it")
        XCTAssertEqual(tile.asOfDay, "2026-07-17")
    }

    // MARK: - Pure: temperature is deviation-only by construction

    func testTemperatureIsAlwaysDeviationNeverAbsolute() {
        // Even handed a band, a deviation vital gets no band and a `.deviation` reading — the read
        // model has no field that could carry an absolute skin temperature.
        let tile = DeviationEngine.makeTile(
            def: tempDef(), latest: DayValue(day: "2026-07-20", value: 0.3),
            band: band(center: 36.5, low: 36, high: 37, provisional: false,
                       metricId: MetricID.wristTempDeviation, unit: "degC"),
            sparkline: [], sourceQuality: nil, staleCutoffDay: "2026-07-18")
        XCTAssertEqual(tile.reading, .deviation(0.3))
        XCTAssertNil(tile.band, "temperature never carries a band, even if one is passed in")
        XCTAssertEqual(tile.state, .deviation(.aboveUsual))
        XCTAssertEqual(tile.annotation, DeviationEngine.tempAnnotation(.aboveUsual))
        if case .absolute = tile.reading! { XCTFail("temperature must never be an absolute reading") }
    }

    func testTemperatureDirectionFromSign() {
        XCTAssertEqual(DeviationEngine.tempDirection(0.3), .aboveUsual)
        XCTAssertEqual(DeviationEngine.tempDirection(-0.2), .belowUsual)
        XCTAssertEqual(DeviationEngine.tempDirection(0), .atUsual)

        let atUsual = DeviationEngine.makeTile(
            def: tempDef(), latest: DayValue(day: "2026-07-20", value: 0),
            band: nil, sparkline: [], sourceQuality: nil, staleCutoffDay: "2026-07-18")
        XCTAssertEqual(atUsual.state, .deviation(.atUsual))
        XCTAssertNil(atUsual.annotation, "at the usual level carries no note")
    }

    // MARK: - Pure: sparkline gaps are holes, not zeros

    func testSparklinePreservesGapsAsNil() {
        let points = DeviationEngine.buildSparkline(
            axisDays: ["2026-07-18", "2026-07-19", "2026-07-20"],
            byDay: ["2026-07-18": 50, "2026-07-20": 52])
        XCTAssertEqual(points.map(\.value), [50, nil, 52], "the missing day is a gap, not a zero")
        XCTAssertEqual(points.map(\.day), ["2026-07-18", "2026-07-19", "2026-07-20"])
    }

    // MARK: - Pure: per-source sensor quality resolves from the contract

    func testSourceQualityResolvesPerSourceAndFamily() {
        let watch = Source(id: "src-watch", type: .healthkit, displayName: "Apple Watch",
                           updatedAt: Date(), originDeviceId: "d")
        let device = Device(id: "dev-1", sourceId: "src-watch", name: "Apple Watch",
                            firstSeen: Date(), lastSeen: Date(), updatedAt: Date(), originDeviceId: "d")
        // Wrist wearable is `high` for heart (the appropriate instrument) and `low` for body
        // (wrist temperature is inferred) — the contract's own values, resolved per family.
        let heart = DeviationEngine.resolveSourceQuality(source: watch, devices: [device], family: .heart, map: quality)
        XCTAssertEqual(heart?.sourceClassId, "wrist_wearable")
        XCTAssertEqual(heart?.level, .high)
        XCTAssertEqual(heart?.sourceDisplayName, "Apple Watch")

        let body = DeviationEngine.resolveSourceQuality(source: watch, devices: [device], family: .body, map: quality)
        XCTAssertEqual(body?.level, .low, "wrist temperature is a `low` (inferred) label for this class")

        XCTAssertNil(DeviationEngine.resolveSourceQuality(source: nil, devices: [], family: .heart, map: quality),
                     "no source to attribute → no label, never a guess")
    }

    // MARK: - Copy: the mandatory footer exists and the notes stay wellness-safe

    func testDisclaimerIsThePersistentMedicalFooter() {
        XCTAssertTrue(DeviationEngine.disclaimer.en.contains("not a medical evaluation"),
                      "the persistent 'not a medical evaluation' footer is mandatory")
        XCTAssertTrue(DeviationEngine.disclaimer.ar.contains("تقييماً طبياً"))
        XCTAssertFalse(DeviationEngine.disclaimer.en.isEmpty)
        XCTAssertFalse(DeviationEngine.disclaimer.ar.isEmpty)
    }

    /// A concrete copy lint over the authored annotations: they must never carry alarm or diagnosis
    /// frames. This is the "assert the copy exists and is linted" acceptance made mechanical.
    func testAnnotationsCarryNoAlarmOrDiagnosisFrames() {
        let bannedEn = ["you may have", "signs of", "abnormal", "diagnos", "disease",
                        "do not", "don't", "stop ", "risk", "warning", "danger", "urgent"]
        let bannedAr = ["تشخيص", "مرض", "خطر", "توقف", "تحذير", "عاجل"]
        let annotations: [LocalizedString] = [
            DeviationEngine.bandAnnotation(.above)!, DeviationEngine.bandAnnotation(.below)!,
            DeviationEngine.tempAnnotation(.aboveUsual)!, DeviationEngine.tempAnnotation(.belowUsual)!,
        ]
        for a in annotations {
            let en = a.en.lowercased()
            for phrase in bannedEn {
                XCTAssertFalse(en.contains(phrase), "annotation \"\(a.en)\" contains banned frame \"\(phrase)\"")
            }
            for phrase in bannedAr {
                XCTAssertFalse(a.ar.contains(phrase), "annotation \"\(a.ar)\" contains banned frame \"\(phrase)\"")
            }
        }
        XCTAssertNil(DeviationEngine.bandAnnotation(.within))
        XCTAssertNil(DeviationEngine.tempAnnotation(.atUsual))
    }

    // MARK: - DB-backed: full read model assembly

    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-deviation-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReadModelShapeCoversEveryTrackedVital() throws {
        let engine = makeEngine(asOf: asOf)
        let model = try engine.buildReadModel(asOf: asOf, tz: tz)
        XCTAssertEqual(model.vitals.map(\.metricId), DeviationEngine.vitals, "one tile per tracked vital, in order")
        XCTAssertTrue(model.disclaimer.en.contains("not a medical evaluation"))
        // With an empty store every tile is honest no-data, never a crash and never a fake zero.
        XCTAssertTrue(model.vitals.allSatisfy { $0.state == .noData })
        XCTAssertTrue(model.vitals.allSatisfy { $0.reading == nil })
    }

    func testBandedVitalClassifiesLatestReadingAndAttributesSource() throws {
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        let catalog = CatalogRepository(db.main)
        try seedWatchSource(catalog)

        // 14 days of RHR around 50, then a high latest reading today so it lands above the band.
        for daysAgo in 1...14 {
            try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: daysAgo,
                       value: 50 + Double(daysAgo % 3), sourceId: "src-watch")
        }
        try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: 0, value: 95, sourceId: "src-watch")
        try BaselineEngine(derivation: derivation, measurements: measurements, registry: .shared,
                           clock: FixedClock(asOf), deviceId: deviceId).recompute(metricId: MetricID.restingHeartRate, asOf: asOf, tz: tz)

        let model = try makeEngine(asOf: asOf).buildReadModel(asOf: asOf, tz: tz)
        let rhr = try XCTUnwrap(model.vitals.first { $0.metricId == MetricID.restingHeartRate })
        XCTAssertEqual(rhr.reading, .absolute(95))
        XCTAssertEqual(rhr.state, .aboveBand, "today's 95 sits above the personal band built from ~50")
        XCTAssertNotNil(rhr.annotation)
        XCTAssertFalse(rhr.isStale)
        XCTAssertEqual(rhr.sourceQuality?.sourceClassId, "wrist_wearable")
        XCTAssertEqual(rhr.sourceQuality?.level, .high, "RHR from a wrist wearable is a `high` label")
        XCTAssertNotNil(rhr.band, "the personal band is projected for the anatomy sheet")
        XCTAssertFalse(rhr.sparkline.isEmpty)
    }

    func testStaleReadingIsFirstClass() throws {
        let measurements = MeasurementRepository(db.main)
        // Only an old reading (10 days ago), nothing recent → shown stale, not collapsed to no-data.
        try insert(measurements, metricId: MetricID.hrv, daysAgo: 10, value: 55, sourceId: "src-watch")
        let model = try makeEngine(asOf: asOf).buildReadModel(asOf: asOf, tz: tz)
        let hrv = try XCTUnwrap(model.vitals.first { $0.metricId == MetricID.hrv })
        XCTAssertEqual(hrv.reading, .absolute(55))
        XCTAssertTrue(hrv.isStale, "a 10-day-old reading is stale, not absent")
        XCTAssertNil(hrv.annotation, "annotation suppressed while stale")
    }

    func testTemperatureTileIsDeviationOnlyEndToEnd() throws {
        let measurements = MeasurementRepository(db.main)
        try insert(measurements, metricId: MetricID.wristTempDeviation, daysAgo: 0, value: -0.4,
                   sourceId: "src-watch", unit: "degC")
        let model = try makeEngine(asOf: asOf).buildReadModel(asOf: asOf, tz: tz)
        let temp = try XCTUnwrap(model.vitals.first { $0.metricId == MetricID.wristTempDeviation })
        XCTAssertEqual(temp.reading, .deviation(-0.4))
        XCTAssertNil(temp.band, "temperature never renders a band")
        XCTAssertEqual(temp.state, .deviation(.belowUsual))
        if case .absolute = temp.reading! { XCTFail("temperature must never surface as an absolute") }
    }

    // MARK: - DB fixtures

    let tz = "UTC"
    let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEngine(asOf: Date) -> DeviationEngine {
        DeviationEngine(derivation: DerivationRepository(db.main), measurements: MeasurementRepository(db.main),
                        catalog: CatalogRepository(db.main), registry: .shared, sensorQuality: .shared,
                        clock: FixedClock(asOf))
    }

    private func seedWatchSource(_ catalog: CatalogRepository) throws {
        try catalog.upsertSource(Source(id: "src-watch", type: .healthkit, displayName: "Apple Watch",
                                        updatedAt: asOf, originDeviceId: deviceId))
        try catalog.upsertDevice(Device(id: "dev-watch", sourceId: "src-watch", name: "Apple Watch",
                                        firstSeen: asOf, lastSeen: asOf, updatedAt: asOf, originDeviceId: deviceId))
    }

    private func insert(_ measurements: MeasurementRepository, metricId: String, daysAgo: Int,
                        value: Double, sourceId: String, unit: String = "unit") throws {
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        let day = DayAttribution.addingDays(-daysAgo, to: dayStart, tz: tz)
        let dayKey = DayAttribution.localDayKey(day, tz: tz)
        let record = IntervalRecord(
            id: ULID.newID(), metricId: metricId, value: value, unit: unit,
            startAt: day, endAt: DayAttribution.addingDays(1, to: day, tz: tz), tzId: tz, aggregation: .mean,
            provenance: Provenance(sourceId: sourceId, ingestionPath: .platformStore, externalId: "\(metricId)#\(dayKey)",
                                   measuredAt: day, measuredTimezone: tz, recordedAt: day, ingestedAt: day),
            updatedAt: day, originDeviceId: deviceId)
        _ = try measurements.upsertIntervalRecord(record)
    }
}
