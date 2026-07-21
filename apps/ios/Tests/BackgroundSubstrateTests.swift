import HealthKit
import XCTest
@testable import BADAN

/// EPIC-04. The background substrate is mostly untestable off-device — `HKObserverQuery` needs a
/// real HealthKit store, `BGTaskScheduler` needs the OS to decide to wake us, and a locked store
/// needs a locked phone. `docs/runbooks/background-soak.md` covers that half on hardware.
///
/// What is testable is everything BADAN decides, and this file covers it: the
/// completion-handler-first ordering that the three-strikes rule turns on, the shape and
/// value-freeness of what lands in `background_runs`, 90-day pruning, the locked-store outcome
/// mapping, and checkpoint/resume across an expired processing run.
final class BackgroundSubstrateTests: XCTestCase {
    private var tempDir: URL!
    private var conn: SQLiteConnection!
    private var runs: BackgroundRunRepository!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-background-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        conn = try SQLiteConnection(path: tempDir.appendingPathComponent("badan.db").path)
        try Database.migrate(conn, Schema.mainMigrations)
        runs = BackgroundRunRepository(conn)
        suiteName = "badan.background.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    private func makeCoordinator(ingest: FakeIngest,
                                 protectedDataAvailable: Bool = true,
                                 clock: Clock? = nil) -> BackgroundCoordinator {
        BackgroundCoordinator(
            runs: runs,
            clock: clock ?? FixedClock(now),
            ingest: ingest,
            protectedData: FakeProtectedData(isAvailable: protectedDataAvailable),
            checkpoints: BackgroundCheckpointStore(defaults: defaults),
            dispatcher: ImmediateWorkDispatcher())
    }

    private func onlyRun() throws -> BackgroundRun {
        let rows = try runs.recent()
        XCTAssertEqual(rows.count, 1, "expected exactly one recorded run")
        return try XCTUnwrap(rows.first)
    }

    // MARK: - The three-strikes rule (the whole game)

    /// HealthKit silently disables background delivery after 3 wakes whose completion handler is
    /// not called promptly, tells the app nothing, and offers no way to detect or reverse it. So
    /// the ordering below is not a style preference: if `onWake` (which leads to ingestion) ever
    /// ran before the handler, the feature would die in the field and every test would still pass.
    /// This is the assertion that stops that.
    func testCompletionHandlerIsCalledBeforeAnyFollowUpWorkIsScheduled() {
        var events: [String] = []
        let registrar = HealthKitObserverRegistrar(clock: FixedClock(now)) { _ in
            events.append("followUp")
        }

        registrar.handleWake(platformType: "HKQuantityTypeIdentifierHeartRate",
                             completionHandler: { events.append("completionHandler") },
                             error: nil)

        XCTAssertEqual(events, ["completionHandler", "followUp"],
                       "HealthKit's completion handler must be called before any follow-up work "
                           + "is scheduled — see ObserverCompletionGate")
    }

    /// A wake that arrives carrying an error still spends a strike if the handler is not called.
    /// "Bail out early on error" is the natural instinct here and it is exactly wrong.
    func testCompletionHandlerIsCalledEvenWhenTheWakeReportsAnError() {
        var completed = false
        let registrar = HealthKitObserverRegistrar(clock: FixedClock(now)) { _ in }

        registrar.handleWake(platformType: "HKCategoryTypeIdentifierSleepAnalysis",
                             completionHandler: { completed = true },
                             error: NSError(domain: "test", code: 1))

        XCTAssertTrue(completed, "an errored wake still costs a strike if the handler is skipped")
    }

    /// The belt-and-braces `defer` in `handleWake` must never be able to double-invoke HealthKit's
    /// handler, or the defence would itself be the bug.
    func testCompletionGateCallsTheHandlerExactlyOnce() {
        var calls = 0
        let clock = FixedClock(now)
        let gate = ObserverCompletionGate(handler: { calls += 1 }, wokeAt: now, clock: clock)

        let first = gate.complete()
        clock.advance(by: 5)
        let second = gate.complete()

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(first, second, "a repeat complete() must report the first call's latency, "
                       + "never a later one that would understate how fast we really were")
    }

    func testCompletionLatencyIsMeasuredFromTheWakeInstant() {
        let clock = FixedClock(now)
        let gate = ObserverCompletionGate(handler: {}, wokeAt: now.addingTimeInterval(-0.25), clock: clock)
        XCTAssertEqual(gate.complete(), 250)
    }

    /// Every observer wake must record the latency, because a budget nobody measures is a budget
    /// nobody notices spending.
    func testObserverWakeRecordsHandlerLatencyOnTheRun() throws {
        let ingest = FakeIngest()
        let coordinator = makeCoordinator(ingest: ingest)

        coordinator.performObserverFollowUp(
            HealthKitWakeSignal(platformType: "HKQuantityTypeIdentifierHeartRate",
                                wokeAt: now, completionHandlerCalledInMs: 7))

        let run = try onlyRun()
        XCTAssertEqual(run.kind, .hkObserverWake)
        XCTAssertEqual(run.completionHandlerCalledInMs, 7)
    }

    // MARK: - An observer wake is a signal, never a payload

    func testObserverWakeFollowsWithAnAnchoredRequeryThroughTheExistingPath() throws {
        let ingest = FakeIngest()
        ingest.nextCounts = BackgroundWorkCounts(samples: 12, intervals: 3, sessions: 1)
        let coordinator = makeCoordinator(ingest: ingest)

        coordinator.performObserverFollowUp(
            HealthKitWakeSignal(platformType: "HKQuantityTypeIdentifierHeartRate",
                                wokeAt: now, completionHandlerCalledInMs: 2))

        XCTAssertEqual(ingest.tryIngestCallCount, 1,
                       "the wake says only \"something changed\"; the re-query is what finds out what")
        let run = try onlyRun()
        XCTAssertEqual(run.outcome, .completed)
        XCTAssertEqual(run.workDone?.samples, 12)
    }

    /// A wake landing on top of an in-flight sync is not an error and must not run a second pass —
    /// the run already holding the lock is about to do the identical work.
    func testWakeThatCannotTakeTheIngestLockIsThrottledNotFailed() throws {
        let ingest = FakeIngest()
        ingest.lockIsHeld = true
        let coordinator = makeCoordinator(ingest: ingest)

        coordinator.performObserverFollowUp(
            HealthKitWakeSignal(platformType: "HKQuantityTypeIdentifierHeartRate",
                                wokeAt: now, completionHandlerCalledInMs: 1))

        XCTAssertEqual(try onlyRun().outcome, .throttled)
    }

    func testWakeThatThrowsIsRecordedAsErrorWithNoWorkClaimed() throws {
        let ingest = FakeIngest()
        ingest.error = NSError(domain: "test", code: 42)
        let coordinator = makeCoordinator(ingest: ingest)

        coordinator.performObserverFollowUp(
            HealthKitWakeSignal(platformType: "HKQuantityTypeIdentifierHeartRate",
                                wokeAt: now, completionHandlerCalledInMs: 1))

        let run = try onlyRun()
        XCTAssertEqual(run.outcome, .error)
        XCTAssertNil(run.workDone, "a failed run must not report counts it did not achieve")
    }

    // MARK: - Locked store is the platform working, not a failure

    func testLockedStoreWakeIsRecordedAsStoreLockedAndReadsNothing() throws {
        let ingest = FakeIngest()
        let coordinator = makeCoordinator(ingest: ingest, protectedDataAvailable: false)

        coordinator.performObserverFollowUp(
            HealthKitWakeSignal(platformType: "HKQuantityTypeIdentifierHeartRate",
                                wokeAt: now, completionHandlerCalledInMs: 3))

        let run = try onlyRun()
        XCTAssertEqual(run.outcome, .storeLocked)
        XCTAssertEqual(ingest.tryIngestCallCount, 0,
                       "a locked store must not be retried; the next wake handles it")
        XCTAssertEqual(run.completionHandlerCalledInMs, 3,
                       "a skipped wake still spent a strike, so its latency still matters")
    }

    /// Prose in plan §13.3 and ADR-0009 calls this outcome `skippedLocked`; §9.8's entity spec —
    /// what Android mirrors — calls it `storeLocked`. They must be the same case, not two.
    func testSkippedLockedIsTheSameOutcomeAsStoreLocked() {
        XCTAssertEqual(BackgroundRunOutcome.skippedLocked, .storeLocked)
        XCTAssertEqual(BackgroundRunOutcome.allCases.count, 5,
                       "an extra outcome here means the prose/spec naming split became a real fork")
    }

    /// Reporting a locked store as a task failure would train the system's scheduling heuristics
    /// against a condition BADAN cannot influence and that is not a malfunction.
    func testLockedStoreDoesNotReportTaskFailureToTheScheduler() throws {
        let coordinator = makeCoordinator(ingest: FakeIngest(), protectedDataAvailable: false)
        XCTAssertTrue(coordinator.runAppRefresh(isExpired: { false }))
        XCTAssertEqual(try onlyRun().outcome, .storeLocked)
    }

    // MARK: - BGAppRefresh: top up only when anchors are actually stale

    func testAppRefreshSkipsIngestWhenAnchorsAreFresh() throws {
        let ingest = FakeIngest()
        ingest.stubAnchorAge = 60 * 60
        let coordinator = makeCoordinator(ingest: ingest)

        XCTAssertTrue(coordinator.runAppRefresh(isExpired: { false }))

        XCTAssertEqual(ingest.tryIngestCallCount, 0,
                       "a wake minutes after a foreground sync has nothing to fetch")
        XCTAssertEqual(try onlyRun().outcome, .completed)
    }

    func testAppRefreshTopsUpWhenAnchorsAreStalerThanSixHours() throws {
        let ingest = FakeIngest()
        ingest.stubAnchorAge = BackgroundCoordinator.staleAnchorThreshold + 1
        ingest.nextCounts = BackgroundWorkCounts(samples: 4)
        let coordinator = makeCoordinator(ingest: ingest)

        XCTAssertTrue(coordinator.runAppRefresh(isExpired: { false }))

        XCTAssertEqual(ingest.tryIngestCallCount, 1)
        XCTAssertEqual(try onlyRun().workDone?.samples, 4)
    }

    func testAppRefreshTreatsNeverSyncedAsStale() throws {
        let ingest = FakeIngest()
        ingest.stubAnchorAge = nil
        let coordinator = makeCoordinator(ingest: ingest)

        XCTAssertTrue(coordinator.runAppRefresh(isExpired: { false }))

        XCTAssertEqual(ingest.tryIngestCallCount, 1,
                       "no anchor at all is the stalest state there is")
    }

    func testAppRefreshThatExpiresRecordsExpiredAndReportsFailureToTheScheduler() throws {
        let ingest = FakeIngest()
        ingest.stubAnchorAge = nil
        let coordinator = makeCoordinator(ingest: ingest)

        XCTAssertFalse(coordinator.runAppRefresh(isExpired: { true }))
        XCTAssertEqual(try onlyRun().outcome, .expired)
    }

    // MARK: - BGProcessing: checkpoint, exit cleanly, resume

    func testProcessingRunsEveryStepAndClearsItsCheckpoint() throws {
        let ingest = FakeIngest()
        ingest.needsBackfill = true
        ingest.nextCounts = BackgroundWorkCounts(samples: 900)
        let checkpoints = BackgroundCheckpointStore(defaults: defaults)
        let coordinator = makeCoordinator(ingest: ingest)

        XCTAssertTrue(coordinator.runProcessing(isExpired: { false }))

        XCTAssertEqual(ingest.resumeBackfillCallCount, 1)
        XCTAssertEqual(try onlyRun().outcome, .completed)
        XCTAssertEqual(checkpoints.resumeStep(), BackgroundProcessingStep.allCases[0],
                       "a completed run leaves nothing to resume from")
    }

    func testProcessingSkipsBackfillWhenTheStoreSaysThereIsNoneToResume() throws {
        let ingest = FakeIngest()
        ingest.needsBackfill = false
        let coordinator = makeCoordinator(ingest: ingest)

        XCTAssertTrue(coordinator.runProcessing(isExpired: { false }))

        XCTAssertEqual(ingest.resumeBackfillCallCount, 0,
                       "whether backfill work remains is re-derived from the store, never assumed")
    }

    /// EPIC-26: an HR-max/zone edit queues a score backfill, which the checkpointed processing run
    /// drains as its own step — after the ingest backfill, before the prune.
    func testProcessingRunsAPendingScoreBackfill() throws {
        let ingest = FakeIngest()
        ingest.needsBackfill = false
        ingest.pendingScoreBackfill = true
        let coordinator = makeCoordinator(ingest: ingest)

        XCTAssertTrue(coordinator.runProcessing(isExpired: { false }))

        XCTAssertEqual(ingest.scoreBackfillCallCount, 1, "a queued score backfill must run")
        XCTAssertEqual(try onlyRun().outcome, .completed)
    }

    func testProcessingSkipsScoreBackfillWhenNoneIsQueued() throws {
        let ingest = FakeIngest()
        ingest.needsBackfill = false
        ingest.pendingScoreBackfill = false
        let coordinator = makeCoordinator(ingest: ingest)

        XCTAssertTrue(coordinator.runProcessing(isExpired: { false }))

        XCTAssertEqual(ingest.scoreBackfillCallCount, 0,
                       "no marker, no work — the step is a no-op when nothing is queued")
    }

    // MARK: - Score-backfill request store (EPIC-26)

    func testScoreBackfillRequestRoundTripsAndClears() throws {
        let store = ScoreBackfillRequestStore(defaults: defaults)
        XCTAssertNil(store.pending(), "no request queued initially")

        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_000_000 + 90 * 86_400)
        store.request(from: from, to: to)
        let pending = try XCTUnwrap(store.pending())
        XCTAssertEqual(pending.from.epochMillis, from.epochMillis)
        XCTAssertEqual(pending.to.epochMillis, to.epochMillis)

        store.clear()
        XCTAssertNil(store.pending(), "cleared request reads as nothing pending")
    }

    /// Two edits before the job runs collapse into one job whose window is the UNION — the later edit
    /// must not narrow the earlier one's range and leave days stale against the new max.
    func testScoreBackfillRequestsWidenToTheirUnion() {
        let store = ScoreBackfillRequestStore(defaults: defaults)
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let mid = Date(timeIntervalSince1970: 1_700_000_000 + 30 * 86_400)
        let late = Date(timeIntervalSince1970: 1_700_000_000 + 60 * 86_400)

        store.request(from: mid, to: late)
        store.request(from: early, to: mid) // widens `from` backward

        let pending = store.pending()
        XCTAssertEqual(pending?.from.epochMillis, early.epochMillis, "union keeps the earliest from")
        XCTAssertEqual(pending?.to.epochMillis, late.epochMillis, "union keeps the latest to")
    }

    /// The expiration contract (plan §13.4): checkpoint and exit cleanly, log `expired`, resume on
    /// the next wake. Mirrors `SeedController.needsBackfillResume()`'s pattern — the marker only
    /// skips ahead; the store still has the final say on whether work remains.
    func testExpiredProcessingCheckpointsAndTheNextRunResumesWhereItStopped() throws {
        let ingest = FakeIngest()
        ingest.needsBackfill = true
        let checkpoints = BackgroundCheckpointStore(defaults: defaults)

        // First run: expires before it can start anything.
        let first = makeCoordinator(ingest: ingest)
        XCTAssertFalse(first.runProcessing(isExpired: { true }))
        XCTAssertEqual(try runs.recent().first?.outcome, .expired)
        XCTAssertEqual(checkpoints.resumeStep(), .backfillResume,
                       "an expired run must leave a resume point, not start over next time")
        XCTAssertEqual(ingest.resumeBackfillCallCount, 0)

        // Second run: resumes from the checkpoint and finishes. Its clock is advanced so the two
        // runs sort deterministically — `recent()` orders by `started_at DESC`, and two rows
        // sharing an instant would leave which one comes back first up to SQLite.
        let second = makeCoordinator(ingest: ingest, clock: FixedClock(now.addingTimeInterval(60)))
        XCTAssertTrue(second.runProcessing(isExpired: { false }))
        XCTAssertEqual(ingest.resumeBackfillCallCount, 1)
        XCTAssertEqual(try runs.recent().first?.outcome, .completed)
    }

    func testProcessingResumesAtTheStepAfterOneThatAlreadyCompleted() throws {
        let ingest = FakeIngest()
        ingest.needsBackfill = true
        let checkpoints = BackgroundCheckpointStore(defaults: defaults)
        checkpoints.save(nextStep: .prune, at: now)

        let coordinator = makeCoordinator(ingest: ingest)
        XCTAssertTrue(coordinator.runProcessing(isExpired: { false }))

        XCTAssertEqual(ingest.resumeBackfillCallCount, 0,
                       "the checkpoint said backfill was already done; redoing it wastes the wake")
    }

    /// A step that throws must be retried, not consumed — a transient failure that silently
    /// advanced the checkpoint would strand the backfill forever.
    func testFailedProcessingStepCheckpointsAtTheStepThatFailed() throws {
        let ingest = FakeIngest()
        ingest.needsBackfill = true
        ingest.error = NSError(domain: "test", code: 7)
        let checkpoints = BackgroundCheckpointStore(defaults: defaults)

        let coordinator = makeCoordinator(ingest: ingest)
        XCTAssertFalse(coordinator.runProcessing(isExpired: { false }))

        XCTAssertEqual(try onlyRun().outcome, .error)
        XCTAssertEqual(checkpoints.resumeStep(), .backfillResume)
    }

    func testRemainingStepsStartsAtTheCheckpoint() {
        let checkpoints = BackgroundCheckpointStore(defaults: defaults)
        XCTAssertEqual(checkpoints.remainingSteps(), BackgroundProcessingStep.allCases)
        checkpoints.save(nextStep: .prune, at: now)
        XCTAssertEqual(checkpoints.remainingSteps(), [.prune])
        checkpoints.clear()
        XCTAssertEqual(checkpoints.remainingSteps(), BackgroundProcessingStep.allCases)
    }

    // MARK: - Row shape and value-freeness

    func testRunRoundTripsThroughTheV4Table() throws {
        let run = BackgroundRun(id: ULID.newID(), kind: .bgProcessing, startedAt: now,
                                durationMs: 4_200, outcome: .completed,
                                workDone: BackgroundWorkCounts(samples: 5, intervals: 2, sessions: 1,
                                                               suppressed: 1, insightDays: 14, pruned: 3),
                                completionHandlerCalledInMs: nil)
        try runs.insert(run)
        XCTAssertEqual(try runs.recent().first, run)
    }

    /// `background_runs` is value-free by contract (plan §9.8). The type makes a health value
    /// unrepresentable; this asserts that the *encoding* keeps that promise, since the column is
    /// free-form TEXT and nothing else would catch a `Double` creeping in.
    func testWorkDoneJSONContainsOnlyIntegerCounts() throws {
        let counts = BackgroundWorkCounts(samples: 5, intervals: 2, sessions: 1, suppressed: 1,
                                          insightDays: 14, pruned: 3, automationsEvaluated: 0)
        let json = JSONCoding.encode(counts)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])

        XCTAssertFalse(parsed.isEmpty)
        for (key, value) in parsed {
            let number = try XCTUnwrap(value as? NSNumber, "\(key) is not a number")
            XCTAssertEqual(Double(number.intValue), number.doubleValue, accuracy: 0,
                           "\(key) carries a fractional value — counts only, never measurements")
        }
    }

    /// An all-zero payload on every idle wake would be 90 days of noise in the one column meant
    /// to say what actually happened.
    func testIdleRunStoresNoWorkPayload() throws {
        let coordinator = makeCoordinator(ingest: FakeIngest())
        coordinator.performObserverFollowUp(
            HealthKitWakeSignal(platformType: "HKQuantityTypeIdentifierHeartRate",
                                wokeAt: now, completionHandlerCalledInMs: 1))
        XCTAssertNil(try onlyRun().workDone)
    }

    func testForegroundSyncIsRecordedSoDiagnosticsCanTellTheTwoFailuresApart() throws {
        let ingest = FakeIngest()
        ingest.nextCounts = BackgroundWorkCounts(samples: 3)
        let coordinator = makeCoordinator(ingest: ingest)

        XCTAssertNil(coordinator.runForegroundSync(now: now))

        let run = try onlyRun()
        XCTAssertEqual(run.kind, .foregroundSync)
        XCTAssertNil(run.completionHandlerCalledInMs,
                     "only observer wakes spend the three-strikes budget")
    }

    // MARK: - Pruning

    func testPruneDropsRunsPastNinetyDaysAndKeepsTheRest() throws {
        let old = now.addingTimeInterval(-Double(BackgroundRunRepository.retentionDays + 1) * 86_400)
        let recent = now.addingTimeInterval(-3 * 86_400)
        try runs.insert(BackgroundRun(id: "old", kind: .hkObserverWake, startedAt: old,
                                      durationMs: 1, outcome: .completed, workDone: nil,
                                      completionHandlerCalledInMs: 1))
        try runs.insert(BackgroundRun(id: "recent", kind: .hkObserverWake, startedAt: recent,
                                      durationMs: 1, outcome: .completed, workDone: nil,
                                      completionHandlerCalledInMs: 1))

        XCTAssertEqual(try runs.prune(now: now), 1)
        XCTAssertEqual(try runs.recent().map(\.id), ["recent"])
    }

    func testProcessingRunReportsWhatItPruned() throws {
        let old = now.addingTimeInterval(-200 * 86_400)
        for index in 0..<3 {
            try runs.insert(BackgroundRun(id: "old-\(index)", kind: .bgAppRefresh, startedAt: old,
                                          durationMs: 1, outcome: .completed, workDone: nil,
                                          completionHandlerCalledInMs: nil))
        }
        let coordinator = makeCoordinator(ingest: FakeIngest())

        XCTAssertTrue(coordinator.runProcessing(isExpired: { false }))

        let run = try XCTUnwrap(try runs.recent().first)
        XCTAssertEqual(run.workDone?.pruned, 3,
                       "a prune that silently does nothing is otherwise invisible")
    }

    // MARK: - Diagnostics rollup

    func testSummaryReportsOutcomeMixAndHandlerLatency() throws {
        for (index, latency) in [1, 2, 3, 90].enumerated() {
            try runs.insert(BackgroundRun(id: "wake-\(index)", kind: .hkObserverWake,
                                          startedAt: now.addingTimeInterval(Double(-index) * 60),
                                          durationMs: 10, outcome: .completed, workDone: nil,
                                          completionHandlerCalledInMs: latency))
        }
        try runs.insert(BackgroundRun(id: "locked", kind: .hkObserverWake,
                                      startedAt: now.addingTimeInterval(-600), durationMs: 1,
                                      outcome: .storeLocked, workDone: nil,
                                      completionHandlerCalledInMs: 2))

        let summary = try runs.summary(now: now)

        XCTAssertEqual(summary.totalRuns, 5)
        XCTAssertEqual(summary.outcomeCounts,
                       [.init(outcome: .completed, count: 4), .init(outcome: .storeLocked, count: 1)])
        XCTAssertEqual(summary.handlerLatencyMaxMs, 90)
        XCTAssertEqual(summary.lastRunOutcome, .completed)
    }

    func testSummaryIgnoresRunsOlderThanItsWindow() throws {
        try runs.insert(BackgroundRun(id: "ancient", kind: .bgAppRefresh,
                                      startedAt: now.addingTimeInterval(-60 * 86_400),
                                      durationMs: 1, outcome: .completed, workDone: nil,
                                      completionHandlerCalledInMs: nil))
        let summary = try runs.summary(now: now)
        XCTAssertEqual(summary.totalRuns, 0)
        XCTAssertEqual(summary.lastRunAt?.timeIntervalSince1970,
                       now.addingTimeInterval(-60 * 86_400).timeIntervalSince1970,
                       "\"last run\" is unbounded on purpose — \"nothing for two months\" is the "
                           + "answer someone reading this screen most needs")
    }

    /// Nearest-rank, not interpolated: the soak criterion is "p99 under 5s", and every figure it
    /// is judged on has to be a latency some wake really experienced.
    func testPercentilesReportRealObservedValues() {
        let ascending = Array(1...100)
        XCTAssertEqual(BackgroundRunRepository.percentile(ascending, 0.50), 50)
        XCTAssertEqual(BackgroundRunRepository.percentile(ascending, 0.99), 99)
        XCTAssertEqual(BackgroundRunRepository.percentile([7], 0.99), 7)
        XCTAssertNil(BackgroundRunRepository.percentile([], 0.5))
    }

    // MARK: - Info.plist configuration (BUG-BG-01)

    /// The `UIBackgroundModes` entry each permitted task identifier needs before
    /// `BGTaskScheduler.submit(_:)` will accept its request. One row per identifier, keyed by the
    /// request class the identifier is submitted as.
    private static let requiredBackgroundModes: [String: String] = [
        BackgroundTaskIdentifier.refresh: "fetch",          // BGAppRefreshTaskRequest
        BackgroundTaskIdentifier.processing: "processing",  // BGProcessingTaskRequest
    ]

    /// **This is the assertion BUG-BG-01 was missing.** The app shipped with
    /// `BGTaskSchedulerPermittedIdentifiers` declared and no `UIBackgroundModes` at all, so
    /// `register(forTaskWithIdentifier:)` succeeded, every `submit(_:)` threw
    /// `BGTaskSchedulerError.unavailable` on device, and no BG task could ever run. Nothing caught
    /// it: `submit` cannot be called meaningfully from a unit test, and every other test in this
    /// file drives `runAppRefresh`/`runProcessing` directly with fakes, which is downstream of the
    /// step that was broken.
    ///
    /// So this asserts the *configuration* instead — the invariant that was actually violated:
    /// permitting an identifier without declaring its background mode is a build that cannot run
    /// its own background work. Read from `Bundle.main`, i.e. the generated, built `Info.plist`
    /// inside `BADAN.app`, not from `project.yml`: the built plist is the artifact the OS reads,
    /// and a stale one (edited plist, `xcodegen generate` not re-run) is itself a defect worth
    /// failing on.
    func testEveryPermittedTaskIdentifierHasItsBackgroundMode() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary, "no Info.plist in the test host bundle")
        let permitted = try XCTUnwrap(info["BGTaskSchedulerPermittedIdentifiers"] as? [String],
                                      "BGTaskSchedulerPermittedIdentifiers is missing from the "
                                          + "built Info.plist — registration would raise at launch")
        let modes = Set(info["UIBackgroundModes"] as? [String] ?? [])

        XCTAssertFalse(permitted.isEmpty)
        for identifier in permitted {
            let required = try XCTUnwrap(
                Self.requiredBackgroundModes[identifier],
                "\(identifier) is permitted in Info.plist but this test does not know which "
                    + "UIBackgroundModes entry it needs — add it to requiredBackgroundModes")
            XCTAssertTrue(modes.contains(required),
                          "\(identifier) is permitted but UIBackgroundModes is missing "
                              + "\"\(required)\" — every submit for it throws "
                              + "BGTaskSchedulerError.unavailable on device and the task never runs")
        }
    }

    /// The other half of the same unit: an identifier BADAN registers but never permits raises at
    /// launch, and one it permits but never registers is a declared capability with no code behind
    /// it. `project.yml` and `BackgroundTaskIdentifier` have to agree exactly.
    func testPermittedIdentifiersMatchTheRegisteredConstants() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let permitted = Set(try XCTUnwrap(info["BGTaskSchedulerPermittedIdentifiers"] as? [String]))
        XCTAssertEqual(permitted,
                       [BackgroundTaskIdentifier.refresh, BackgroundTaskIdentifier.processing],
                       "project.yml and BackgroundTaskIdentifier have drifted; "
                           + "register(forTaskWithIdentifier:) raises for an unpermitted identifier")
    }

    // MARK: - A declined submit is visible, not silent (BUG-BG-01)

    /// A submit that `BGTaskScheduler` refuses used to be swallowed at `.info` level, which is why
    /// the missing background mode was invisible for the life of the change set. A decline must
    /// leave a row, because "the scheduler will not take our requests" and "the scheduler takes
    /// them and never runs them" look identical from inside the app otherwise.
    func testDeclinedSubmitIsRecordedAsAnErrorRun() throws {
        let coordinator = makeCoordinator(ingest: FakeIngest())

        coordinator.recordSubmitDecline(identifier: BackgroundTaskIdentifier.refresh,
                                        reason: .unavailable)

        let run = try onlyRun()
        XCTAssertEqual(run.kind, .bgAppRefresh)
        XCTAssertEqual(run.outcome, .error)
        XCTAssertEqual(run.durationMs, 0, "no work ran; a zero duration is what tells a declined "
                       + "submit apart from a failed run (see the soak runbook §6)")
        XCTAssertNil(run.workDone, "a submit that was never accepted achieved nothing")
    }

    func testDeclinedProcessingSubmitIsRecordedAgainstTheProcessingKind() throws {
        let coordinator = makeCoordinator(ingest: FakeIngest())
        coordinator.recordSubmitDecline(identifier: BackgroundTaskIdentifier.processing,
                                        reason: .transient)
        XCTAssertEqual(try onlyRun().kind, .bgProcessing)
    }

    /// An identifier with no run kind must not be filed under a plausible-looking wrong one — the
    /// whole point of the row is that someone reading Diagnostics can trust what it says.
    func testDeclineForAnUnknownIdentifierRecordsNothing() throws {
        let coordinator = makeCoordinator(ingest: FakeIngest())
        coordinator.recordSubmitDecline(identifier: "net.albayyan.badan.nonexistent",
                                        reason: .unavailable)
        XCTAssertEqual(try runs.recent().count, 0)
    }

    // MARK: - Observed types

    /// A type BADAN ingests but never observes simply never wakes the app, which presents as
    /// "background sync is unreliable" rather than as a missing line — so the two sets are tied
    /// together here rather than by convention.
    func testEveryIngestedQuantityTypeIsObserved() {
        let observed = Set(HealthKitObserverRegistrar.observedTypes().map { $0.type.identifier })
        for entry in HKTypeMap.table where entry.metricId != nil {
            XCTAssertTrue(observed.contains(entry.identifier.rawValue),
                          "\(entry.platformType) is ingested but never observed")
        }
    }

    /// Types requested for authorization but not yet ingested must NOT be observed: every wake
    /// they cost is a strike risk spent re-querying data nothing stores.
    func testAuthorizationOnlyTypesAreNotObserved() {
        let observed = Set(HealthKitObserverRegistrar.observedTypes().map { $0.type.identifier })
        for entry in HKTypeMap.table where entry.metricId == nil {
            XCTAssertFalse(observed.contains(entry.identifier.rawValue),
                           "\(entry.platformType) produces no rows, so observing it spends wakes for nothing")
        }
    }

    func testHeartRateFamilyGetsHourlyDeliveryAndEverythingElseDaily() {
        for (type, frequency) in HealthKitObserverRegistrar.observedTypes() {
            let isHeartFamily = HealthKitObserverRegistrar.hourlyIdentifiers
                .contains(where: { $0.rawValue == type.identifier })
            XCTAssertEqual(frequency, isHeartFamily ? .hourly : .daily,
                           "\(type.identifier) has the wrong background-delivery ceiling")
        }
    }
}

// MARK: - Fakes

private final class FakeIngest: BackgroundIngestPerforming {
    var isHealthKitConnected = true
    var stubAnchorAge: TimeInterval?
    var nextCounts = BackgroundWorkCounts()
    var needsBackfill = false
    var pendingScoreBackfill = false
    /// Simulates another caller holding the ingest lock: the `try*` entry points return `nil`.
    var lockIsHeld = false
    var error: Error?

    private(set) var ingestCallCount = 0
    private(set) var tryIngestCallCount = 0
    private(set) var resumeBackfillCallCount = 0
    private(set) var scoreBackfillCallCount = 0

    func anchorAge(now: Date) -> TimeInterval? { stubAnchorAge }

    func ingestAndDerive(now: Date) throws -> BackgroundWorkCounts {
        ingestCallCount += 1
        if let error { throw error }
        return nextCounts
    }

    func tryIngestAndDerive(now: Date) throws -> BackgroundWorkCounts? {
        guard !lockIsHeld else { return nil }
        tryIngestCallCount += 1
        if let error { throw error }
        return nextCounts
    }

    func needsBackfillResume() -> Bool { needsBackfill }

    func resumeBackfill(now: Date) throws -> BackgroundWorkCounts? {
        guard !lockIsHeld else { return nil }
        resumeBackfillCallCount += 1
        if let error { throw error }
        return nextCounts
    }

    func hasPendingScoreBackfill() -> Bool { pendingScoreBackfill }

    func runPendingScoreBackfill(now: Date) throws -> BackgroundWorkCounts? {
        guard !lockIsHeld else { return nil }
        scoreBackfillCallCount += 1
        if let error { throw error }
        pendingScoreBackfill = false
        return nextCounts
    }
}

private final class FakeProtectedData: ProtectedDataProviding {
    let isProtectedDataAvailable: Bool
    init(isAvailable: Bool) { isProtectedDataAvailable = isAvailable }
}
