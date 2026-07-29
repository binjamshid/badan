import XCTest
@testable import BADAN

/// ADR-0011 / D-37 — consent, timing, collection and the local record.
///
/// The payload boundary itself is `TelemetryPayloadSchemaTests`. What is covered HERE is everything
/// around it: that nothing sends without an explicit opt-in, that the moment of transmission cannot
/// be read back to the moment of disagreement, that the floor holds at collection as well as at
/// serialisation, and that the user's own record of what left is written before it leaves.
final class TelemetrySubmissionTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    var defaults: UserDefaults!
    var suiteName: String!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-telemetry-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
        suiteName = "badan.tests.telemetry.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        db = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Consent

    /// Default off, and off is what a missing key means. This is the one value a corrupt or absent
    /// preference must never silently invert for a flag that authorises transmission.
    func testTelemetryIsOffByDefaultAndOffWhenTheKeyIsAbsent() throws {
        XCTAssertFalse(CustomizationProfile().methodologyTelemetryEnabled)
        XCTAssertFalse(TelemetryConsentStore.isEnabled(defaults: defaults),
                       "an unwritten mirror must read as OFF")

        var profile = CustomizationProfile()
        profile.methodologyTelemetryEnabled = true
        let encoded = try JSONEncoder().encode(profile)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["methodologyTelemetryEnabled"], "precondition: the key is encoded")
        json.removeValue(forKey: "methodologyTelemetryEnabled")

        let decoded = try JSONDecoder().decode(
            CustomizationProfile.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.methodologyTelemetryEnabled,
                       "silence on the question is read as 'no', never as consent")
    }

    func testTheConsentMirrorRoundTrips() {
        TelemetryConsentStore.write(true, defaults: defaults)
        XCTAssertTrue(TelemetryConsentStore.isEnabled(defaults: defaults))
        TelemetryConsentStore.write(false, defaults: defaults)
        XCTAssertFalse(TelemetryConsentStore.isEnabled(defaults: defaults))
    }

    // MARK: - Timing is a side channel

    /// The delay is what stops the transmission moment reporting the disagreement moment. Asserted
    /// across many rolls so a degenerate implementation (a constant, or a zero) cannot pass.
    func testSubmissionIsScheduledBetweenOneAndThreeDaysAway() {
        for _ in 0..<50 {
            let scheduler = FootprintScheduler(defaults: defaults)
            scheduler.clear()
            scheduler.scheduleIfNeeded(now: clock.now())
            let due = try! XCTUnwrap(scheduler.dueAt())
            let delay = due.timeIntervalSince(clock.now())
            XCTAssertGreaterThanOrEqual(delay, FootprintScheduler.minimumDelay)
            XCTAssertLessThanOrEqual(delay, FootprintScheduler.maximumDelay)
        }
    }

    func testTheDelayIsActuallyRandomisedNotConstant() {
        var seen = Set<Double>()
        for _ in 0..<40 {
            let scheduler = FootprintScheduler(defaults: defaults)
            scheduler.clear()
            scheduler.scheduleIfNeeded(now: clock.now())
            seen.insert(try! XCTUnwrap(scheduler.dueAt()).timeIntervalSince1970)
        }
        XCTAssertGreaterThan(seen.count, 1,
                             "a fixed delay would make the transmission moment a function of the "
                             + "eligibility moment, which is the side channel this exists to close")
    }

    /// Idempotent on purpose: a burst of feedback must not keep pushing the due date forward, which
    /// would be the opposite of decoupling and a way to never send at all.
    func testFurtherFeedbackDoesNotPushTheDueDateForward() {
        let scheduler = FootprintScheduler(defaults: defaults)
        scheduler.scheduleIfNeeded(now: clock.now())
        let first = try! XCTUnwrap(scheduler.dueAt())

        for hour in 1...10 {
            scheduler.scheduleIfNeeded(now: clock.now().addingTimeInterval(Double(hour) * 3600))
        }
        XCTAssertEqual(scheduler.dueAt(), first,
                       "re-scheduling on every tap would let an active user postpone submission "
                       + "indefinitely — and would re-couple timing to the taps")
    }

    func testNothingIsDueBeforeTheDelayElapses() {
        let scheduler = FootprintScheduler(defaults: defaults)
        scheduler.scheduleIfNeeded(now: clock.now(), randomIn: { $0.lowerBound })
        XCTAssertFalse(scheduler.isDue(now: clock.now()))
        XCTAssertFalse(scheduler.isDue(now: clock.now().addingTimeInterval(23 * 3600)))
        XCTAssertTrue(scheduler.isDue(now: clock.now().addingTimeInterval(25 * 3600)))
    }

    func testNothingIsEverDueWhenNoSubmissionWasScheduled() {
        let scheduler = FootprintScheduler(defaults: defaults)
        XCTAssertNil(scheduler.dueAt())
        XCTAssertFalse(scheduler.isDue(now: clock.now().addingTimeInterval(365 * 86_400)),
                       "an install that never opted in must never become due")
    }

    // MARK: - Collection

    /// The floor holds at collection, not only at serialisation. Nine answers must contribute
    /// nothing at all — not a smaller bucket, not a zero.
    func testNothingIsCollectedBelowTheFloor() throws {
        let repo = FeedbackRepository(db.main)
        try record(repo, count: 9, direction: .over)

        let sources = FootprintCollector(feedback: repo, registry: .shared)
            .collect(metricIds: [MetricID.readinessScore], floor: 10)
        XCTAssertTrue(sources.isEmpty)
    }

    func testFeedbackAtTheFloorIsCollectedWithItsBucket() throws {
        let repo = FeedbackRepository(db.main)
        try record(repo, count: 12, direction: .over)

        let sources = FootprintCollector(feedback: repo, registry: .shared)
            .collect(metricIds: [MetricID.readinessScore], floor: 10)
        let source = try XCTUnwrap(sources.first { $0.direction == .over })
        XCTAssertEqual(source.metricId, MetricID.readinessScore)
        XCTAssertEqual(source.algorithmId, "composite.readiness_score")
        XCTAssertEqual(source.eventCount, 12)
    }

    /// Directions are grouped, never netted. "14 over and 12 under" is a different fact from
    /// "net +2", and the netted form cannot be recovered from an aggregate later.
    func testDirectionsAreReportedSeparatelyRatherThanNetted() throws {
        let repo = FeedbackRepository(db.main)
        try record(repo, count: 14, direction: .over, dayOffset: 0)
        try record(repo, count: 12, direction: .under, dayOffset: 100)

        let sources = FootprintCollector(feedback: repo, registry: .shared)
            .collect(metricIds: [MetricID.readinessScore], floor: 10)
        XCTAssertEqual(sources.filter { $0.direction == .over }.first?.eventCount, 14)
        XCTAssertEqual(sources.filter { $0.direction == .under }.first?.eventCount, 12)
    }

    /// Collection is per (metric, method), matching how calibration is keyed — feedback about one
    /// weighting must not be reported under another.
    func testFeedbackIsCollectedPerMethodNotPooledAcrossMethods() throws {
        let repo = FeedbackRepository(db.main)
        try record(repo, count: 12, direction: .over, algorithmId: "composite.readiness_score")
        try record(repo, count: 11, direction: .under, dayOffset: 100,
                   algorithmId: "composite.readiness_score_autonomic")

        let sources = FootprintCollector(feedback: repo, registry: .shared)
            .collect(metricIds: [MetricID.readinessScore], floor: 10)
        XCTAssertEqual(sources.filter { $0.algorithmId == "composite.readiness_score" }.count, 1)
        XCTAssertEqual(sources.filter { $0.algorithmId == "composite.readiness_score_autonomic" }.count, 1)
        XCTAssertEqual(sources.filter { $0.algorithmId == "composite.readiness_score" }.first?.eventCount, 12)
    }

    // MARK: - The local record

    /// The "What has been sent" screen can never be less complete than what actually left, which is
    /// why the log is written BEFORE the request rather than after a success.
    func testTheSubmissionLogRecordsTheBatchVerbatim() throws {
        let log = SubmissionLog(defaults: defaults)
        let batch = FootprintBatch(appVersion: "1.1", contractVersion: "0.2.0", footprints: [
            Footprint(metricId: "readiness.score", algorithmId: "composite.readiness_score",
                      algorithmSemver: "2.0.0", direction: .under,
                      eventCountBucket: .twentyToFortyNine, calibrationApplied: false),
        ])
        log.record(batch)

        let entries = log.all()
        XCTAssertEqual(entries.count, 1)
        // Verbatim: the stored batch must equal what was handed over, field for field, because the
        // screen re-encodes THIS to show the user what left.
        XCTAssertEqual(entries.first?.batch, batch)
    }

    func testTheSubmissionLogIsNewestFirstAndBounded() {
        let log = SubmissionLog(defaults: defaults)
        for index in 0..<(SubmissionLog.maxEntries + 25) {
            log.record(FootprintBatch(appVersion: "1.\(index)", contractVersion: "0.2.0",
                                      footprints: [sampleFootprint()]))
        }
        let entries = log.all()
        XCTAssertEqual(entries.count, SubmissionLog.maxEntries, "the log must be bounded")
        XCTAssertEqual(entries.first?.batch.appVersion, "1.\(SubmissionLog.maxEntries + 24)",
                       "newest first")
    }

    func testClearingTheLogEmptiesIt() {
        let log = SubmissionLog(defaults: defaults)
        log.record(FootprintBatch(appVersion: "1.1", contractVersion: "0.2.0",
                                  footprints: [sampleFootprint()]))
        XCTAssertFalse(log.all().isEmpty)
        log.clear()
        XCTAssertTrue(log.all().isEmpty)
    }

    // MARK: - Helpers

    private func sampleFootprint() -> Footprint {
        Footprint(metricId: "readiness.score", algorithmId: "composite.readiness_score",
                  algorithmSemver: "2.0.0", direction: .over,
                  eventCountBucket: .tenToNineteen, calibrationApplied: true)
    }

    private func record(_ repo: FeedbackRepository, count: Int, direction: FeedbackDirection,
                        dayOffset: Int = 0,
                        algorithmId: String = "composite.readiness_score") throws {
        for index in 0..<count {
            try repo.record(DerivedFeedback(
                id: ULID.newID(), metricId: MetricID.readinessScore,
                periodKey: "day:offset-\(dayOffset + index)", derivedValueId: "dv-\(index)",
                algorithmId: algorithmId, algorithmVersion: "2.0.0",
                direction: direction, createdAt: clock.now()))
        }
    }
}
