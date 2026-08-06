import CryptoKit
import XCTest
@testable import BADAN

/// ADR-0011 / D-37 — consent, timing, collection, the wire, and the local record.
///
/// The payload boundary itself is `TelemetryPayloadSchemaTests`. What is covered HERE is everything
/// around it: that nothing sends without an explicit opt-in, that the moment of transmission cannot
/// be read back to the moment of disagreement, that the floor holds at collection as well as at
/// serialisation, that the bytes a real client puts on the wire are the bytes the server decodes,
/// and that the user's own record says what actually happened to each submission.
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

    // MARK: - The wire
    //
    // Everything below this line exists because nothing above it did. The key id shipped
    // double-base64-encoded — `Data(keyId.utf8).base64EncodedString()`, base64 of the 44 ASCII
    // characters of a base64 string — so the server decoded 44 bytes, hexed them, and the
    // `attested_keys` primary-key lookup could never hit. EVERY submission from EVERY install 401'd
    // for the life of the feature, and no test on either side ever exercised the encoding a real
    // client produces. These do.

    /// The one that would have caught it: base64-decode the wire field the way the server does and
    /// assert the raw 32 bytes come back.
    func testTheWireKeyIdIsWhatTheServerLooksUp() async throws {
        let transport = MockFootprintTransport(responses: [.status(200)])
        try await makeClient(transport: transport).submit(sampleBatch())

        let wire = try wireObject(from: transport)
        let keyIdField = try XCTUnwrap(wire["keyId"] as? String)

        // `_decode_base64(body.keyId)` on the server, then `raw.hex()` as the primary key.
        XCTAssertEqual(Data(base64Encoded: keyIdField), Self.rawKeyId, """
            The wire key id does not decode to the raw App Attest key id, so the server's \
            attested_keys lookup cannot hit and every submission answers 401. \
            DCAppAttestService vends the key id already base64-encoded — it goes out unchanged, \
            exactly as AICoachClient sends it to /v2/register.
            """)
        XCTAssertEqual(keyIdField, Self.sampleKeyId, "the key id must go out verbatim")
        XCTAssertNotEqual(keyIdField, Data(Self.sampleKeyId.utf8).base64EncodedString(),
                          "this is the shipped bug: base64 of the base64 string")
    }

    /// The assertion is over the exact bytes of `clientData`, and `clientData` is the batch itself
    /// — that binding is what stops a captured assertion vouching for different content, and the
    /// server re-derives it, so both halves have to be on the wire in the form it expects.
    func testTheAssertionAndClientDataAreBase64OfTheExactBatchBytes() async throws {
        let transport = MockFootprintTransport(responses: [.status(200)])
        let attestor = MockAICoachAttestor(keyId: Self.sampleKeyId)
        let batch = sampleBatch()
        try await makeClient(transport: transport, attestor: attestor).submit(batch)

        let wire = try wireObject(from: transport)
        let clientData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(wire["clientData"] as? String)))
        XCTAssertEqual(try JSONDecoder().decode(FootprintBatch.self, from: clientData), batch,
                       "clientData must be the batch's own bytes, not a nonce")
        XCTAssertEqual(attestor.capturedClientDataHash, Data(SHA256.hash(data: clientData)),
                       "the assertion must be over the bytes actually sent")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(wire["assertion"] as? String)),
                       attestor.stubAssertion)
    }

    /// `FootprintBatchRequest` on the server is `extra="forbid"`, so an extra field is a rejected
    /// request rather than an ignored one — and a missing one is a 422. Pin the set.
    func testTheWireObjectCarriesExactlyTheFieldsTheServerAccepts() async throws {
        let transport = MockFootprintTransport(responses: [.status(200)])
        try await makeClient(transport: transport).submit(sampleBatch())

        XCTAssertEqual(Set(try wireObject(from: transport).keys),
                       ["schemaVersion", "appVersion", "contractVersion", "footprints",
                        "keyId", "assertion", "clientData"],
                       "backend/api's FootprintBatchRequest forbids extra fields and requires "
                       + "all of these")
    }

    // MARK: - The local record

    /// The "What has been sent" screen can never be less complete than what actually left, which is
    /// why the attempt is written BEFORE the request rather than after a success.
    func testTheSubmissionLogRecordsTheBatchVerbatim() throws {
        let log = SubmissionLog(defaults: defaults)
        let batch = FootprintBatch(appVersion: "1.1", contractVersion: "0.2.0", footprints: [
            Footprint(metricId: "readiness.score", algorithmId: "composite.readiness_score",
                      algorithmSemver: "2.0.0", direction: .under,
                      eventCountBucket: .twentyToFortyNine, calibrationApplied: false),
        ])
        log.recordAttempt(batch)

        let entries = log.all()
        XCTAssertEqual(entries.count, 1)
        // Verbatim: the stored batch must equal what was handed over, field for field, because the
        // screen re-encodes THIS to show the user what left.
        XCTAssertEqual(entries.first?.batch, batch)
    }

    func testTheSubmissionLogIsNewestFirstAndBounded() {
        let log = SubmissionLog(defaults: defaults)
        for index in 0..<(SubmissionLog.maxEntries + 25) {
            log.recordAttempt(FootprintBatch(appVersion: "1.\(index)", contractVersion: "0.2.0",
                                             footprints: [sampleFootprint()]))
        }
        let entries = log.all()
        XCTAssertEqual(entries.count, SubmissionLog.maxEntries, "the log must be bounded")
        XCTAssertEqual(entries.first?.batch.appVersion, "1.\(SubmissionLog.maxEntries + 24)",
                       "newest first")
    }

    func testClearingTheLogEmptiesIt() {
        let log = SubmissionLog(defaults: defaults)
        log.recordAttempt(FootprintBatch(appVersion: "1.1", contractVersion: "0.2.0",
                                         footprints: [sampleFootprint()]))
        XCTAssertFalse(log.all().isEmpty)
        log.clear()
        XCTAssertTrue(log.all().isEmpty)
    }

    /// A submission the server answered 2xx to is the only one that may be called sent.
    func testAnAcceptedSubmissionIsRecordedAsConfirmed() async throws {
        let log = SubmissionLog(defaults: defaults)
        try await makeClient(transport: MockFootprintTransport(responses: [.status(200)])).submit(sampleBatch())

        XCTAssertEqual(log.all().count, 1)
        XCTAssertEqual(log.all().first?.state, .confirmed)
        XCTAssertEqual(log.all().first?.attempts, 1)
    }

    /// The transparency bug: the log was written before the send and never corrected, so a batch
    /// the server refused was listed on "What has been sent" as though it had been.
    func testASubmissionTheServerRefusedIsNotReportedAsSent() async {
        let log = SubmissionLog(defaults: defaults)
        let client = makeClient(transport: MockFootprintTransport(responses: [.status(401)]))

        do {
            try await client.submit(sampleBatch())
            XCTFail("expected .serverError(401)")
        } catch FootprintClientError.serverError(let status) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(log.all().isEmpty, """
            A batch the server refused was listed under "What has been sent". Nothing was stored on \
            the other end, so claiming it as sent is the same class of untruth as omitting one that \
            was — see ADR-0011.
            """)
        // Not deleted, though: the attempt happened and the device's own record keeps it.
        XCTAssertEqual(log.allIncludingRejected().first?.state, .rejected)
    }

    /// Without a response there is no way to know whether the bytes arrived, so the entry stays
    /// `pending` and is still shown — guessing "rejected" would understate what left the device.
    func testATransportFailureLeavesTheRecordPendingRatherThanGuessing() async {
        let log = SubmissionLog(defaults: defaults)
        let client = makeClient(transport: MockFootprintTransport(responses: [.throwing]))

        do {
            try await client.submit(sampleBatch())
            XCTFail("expected the transport error to propagate")
        } catch {
            // expected
        }
        XCTAssertEqual(log.all().first?.state, .pending)
    }

    /// The unbounded half of the same defect: under a permanent rejection the identical batch was
    /// re-submitted on every background wake and wrote a fresh phantom record each time.
    func testRetryingTheSameBatchUpdatesOneRecordRatherThanAppendingOnePerWake() async {
        let log = SubmissionLog(defaults: defaults)
        let client = makeClient(transport: MockFootprintTransport(responses: [], fallback: .status(401)))

        for _ in 0..<5 { _ = try? await client.submit(sampleBatch()) }

        XCTAssertEqual(log.allIncludingRejected().count, 1,
                       "five attempts at one batch are one submission, retried — not five")
        XCTAssertEqual(log.allIncludingRejected().first?.attempts, 5)
        XCTAssertTrue(log.all().isEmpty, "and none of them may be reported as sent")
    }

    /// Builds up to v1.1(5) wrote entries with no `state` and no `attempts`. `all()` decodes the
    /// whole array or nothing, so a strict decoder would have emptied the user's record of every
    /// submission the moment they updated.
    func testALegacyLogEntryWrittenBeforeStateExistedStillReads() throws {
        let legacy: [[String: Any]] = [[
            "id": "legacy-1",
            "sentAt": 700_000_000.0,
            "batch": try JSONSerialization.jsonObject(with: JSONEncoder().encode(sampleBatch())),
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy),
                     forKey: "badan.telemetry.submissionLog")

        let entries = SubmissionLog(defaults: defaults).all()
        XCTAssertEqual(entries.count, 1, "an older log must survive the upgrade")
        XCTAssertEqual(entries.first?.state, .pending,
                       "nothing ever reconciled it, so 'we do not know' is what is true of it")
        XCTAssertEqual(entries.first?.batch, sampleBatch())
    }

    // MARK: - Retry backoff

    /// A failure used to leave the due date in the past, so the next wake — and every wake after it
    /// — re-sent immediately. nginx allows `/v1/footprints` 2r/h.
    func testAFailedSubmissionIsNotDueAgainOnTheVeryNextWake() {
        let scheduler = FootprintScheduler(defaults: defaults)
        scheduler.scheduleIfNeeded(now: clock.now(), randomIn: { $0.lowerBound })
        let due = clock.now().addingTimeInterval(FootprintScheduler.minimumDelay)
        XCTAssertTrue(scheduler.isDue(now: due))

        scheduler.recordFailure(now: due)
        XCTAssertFalse(scheduler.isDue(now: due.addingTimeInterval(60)),
                       "a wake a minute later must not re-send")
        XCTAssertTrue(scheduler.isDue(now: due.addingTimeInterval(FootprintScheduler.minimumRetryDelay + 1)))
        XCTAssertNotNil(scheduler.dueAt(), "backing off must not drop the batch")
    }

    func testTheRetryBackoffDoublesAndIsCappedAtADay() {
        XCTAssertEqual(FootprintScheduler.retryDelay(afterFailures: 1), 3600)
        XCTAssertEqual(FootprintScheduler.retryDelay(afterFailures: 2), 2 * 3600)
        XCTAssertEqual(FootprintScheduler.retryDelay(afterFailures: 3), 4 * 3600)
        XCTAssertEqual(FootprintScheduler.retryDelay(afterFailures: 6), 24 * 3600)
        XCTAssertEqual(FootprintScheduler.retryDelay(afterFailures: 500),
                       FootprintScheduler.maximumRetryDelay,
                       "an unbounded exponent reaches infinity, which would be written as a date")
    }

    func testASuccessfulSubmissionResetsTheBackoffRatherThanInheritingIt() {
        let scheduler = FootprintScheduler(defaults: defaults)
        scheduler.recordFailure(now: clock.now())
        scheduler.recordFailure(now: clock.now())
        XCTAssertEqual(scheduler.consecutiveFailures(), 2)

        scheduler.clear()
        XCTAssertEqual(scheduler.consecutiveFailures(), 0)
        XCTAssertNil(scheduler.dueAt())
    }

    // MARK: - The background wake's step

    /// End to end for the wake: a batch the server will never accept must be tried once, then left
    /// alone until the backoff elapses.
    func testAPermanentlyRejectedBatchIsNotResubmittedOnEveryWake() async {
        let transport = MockFootprintTransport(responses: [], fallback: .status(401))
        let scheduler = FootprintScheduler(defaults: defaults)
        scheduler.scheduleIfNeeded(now: clock.now(), randomIn: { $0.lowerBound })
        let runner = TelemetrySubmissionRunner(client: makeClient(transport: transport),
                                               scheduler: scheduler, makeBatch: { self.sampleBatch() })

        var now = clock.now().addingTimeInterval(FootprintScheduler.minimumDelay)
        var outcomes: [TelemetrySubmissionRunner.Outcome] = []
        // Ten wakes over the next five hours, which is roughly what an active device gets.
        for _ in 0..<10 {
            outcomes.append(await runner.run(now: now))
            now = now.addingTimeInterval(30 * 60)
        }

        XCTAssertEqual(outcomes.first, .failed)
        XCTAssertEqual(transport.captured.count, 3, """
            A permanently failing submission must not re-send on every wake: nginx rate-limits \
            /v1/footprints to 2r/h, and this batch is never going to be accepted. Expected the \
            1h/2h/4h backoff to allow three attempts in five hours.
            """)
    }

    /// N-5: the send used to be an unawaited `Task` fired from a `BGTask` body, so suspension could
    /// kill it after the log had recorded the attempt and before anything reconciled the answer.
    /// A delayed transport is what makes "did the caller actually wait" observable.
    func testRunBlockingDoesNotReturnBeforeTheSubmissionIsReconciled() {
        let transport = MockFootprintTransport(responses: [.status(200)], delayMilliseconds: 80)
        let scheduler = FootprintScheduler(defaults: defaults)
        scheduler.scheduleIfNeeded(now: clock.now(), randomIn: { $0.lowerBound })
        let log = SubmissionLog(defaults: defaults)
        let runner = TelemetrySubmissionRunner(client: makeClient(transport: transport),
                                               scheduler: scheduler, makeBatch: { self.sampleBatch() })

        let outcome = runner.runBlocking(now: clock.now().addingTimeInterval(FootprintScheduler.minimumDelay))

        XCTAssertEqual(outcome, .sent)
        XCTAssertNil(scheduler.dueAt(), "the schedule must be cleared before the wake returns")
        XCTAssertEqual(log.all().first?.state, .confirmed,
                       "the record must be reconciled before the wake returns — after it, iOS may "
                       + "have suspended the process")
    }

    func testTheWakeSendsNothingBeforeTheBatchIsDue() async {
        let transport = MockFootprintTransport(responses: [.status(200)])
        let scheduler = FootprintScheduler(defaults: defaults)
        scheduler.scheduleIfNeeded(now: clock.now(), randomIn: { $0.lowerBound })
        let runner = TelemetrySubmissionRunner(client: makeClient(transport: transport),
                                               scheduler: scheduler, makeBatch: { self.sampleBatch() })

        let outcome = await runner.run(now: clock.now())
        XCTAssertEqual(outcome, .notDue)
        XCTAssertTrue(transport.captured.isEmpty)
    }

    // MARK: - Helpers

    /// The raw 32-byte App Attest key id, and the base64 string `DCAppAttestService.generateKey`
    /// vends for it. The server decodes the wire field and looks up `raw.hex()`, so these two are
    /// the whole of what `testTheWireKeyIdIsWhatTheServerLooksUp` is about.
    private static let rawKeyId = Data((0..<32).map { UInt8(($0 &* 7 &+ 3) % 251) })
    private static let sampleKeyId = rawKeyId.base64EncodedString()

    private func makeClient(transport: FootprintTransporting,
                            attestor: MockAICoachAttestor? = nil) -> FootprintClient {
        FootprintClient(transport: transport,
                        attestor: attestor ?? MockAICoachAttestor(keyId: Self.sampleKeyId),
                        attestKeys: InMemoryAICoachAttestKeyStore(Self.sampleKeyId),
                        baseURL: URL(string: "https://telemetry.test")!,
                        log: SubmissionLog(defaults: defaults))
    }

    private func wireObject(from transport: MockFootprintTransport) throws -> [String: Any] {
        let request = try XCTUnwrap(transport.captured.first)
        XCTAssertEqual(request.url?.absoluteString, "https://telemetry.test/v1/footprints")
        XCTAssertEqual(request.httpMethod, "POST")
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func sampleBatch() -> FootprintBatch {
        FootprintBatch(appVersion: "1.1", contractVersion: "0.2.0", footprints: [sampleFootprint()])
    }

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

/// Scripted `FootprintTransporting`, the telemetry twin of `MockAICoachTransport`.
///
/// Two differences earn their keep. `fallback` repeats after the script runs out, because "the
/// server refuses this forever" is exactly the condition the retry path exists for and a script
/// that ends can't express it. `delayMilliseconds` makes "did the caller actually wait for the
/// answer" observable, which is the whole of the N-5 fix.
final class MockFootprintTransport: FootprintTransporting, @unchecked Sendable {
    enum Response {
        case status(Int)
        case throwing
    }

    private let lock = NSLock()
    private var responses: [Response]
    private let fallback: Response
    private let delayMilliseconds: Int
    private var requests: [URLRequest] = []

    var captured: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    init(responses: [Response], fallback: Response = .throwing, delayMilliseconds: Int = 0) {
        self.responses = responses
        self.fallback = fallback
        self.delayMilliseconds = delayMilliseconds
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if delayMilliseconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
        }
        lock.lock()
        requests.append(request)
        let response = responses.isEmpty ? fallback : responses.removeFirst()
        lock.unlock()

        switch response {
        case .status(let status):
            let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
            return (Data("{\"accepted\":1}".utf8), http)
        case .throwing:
            throw URLError(.notConnectedToInternet)
        }
    }
}
