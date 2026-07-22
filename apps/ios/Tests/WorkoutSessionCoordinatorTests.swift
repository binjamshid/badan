import XCTest
@testable import BADAN

/// EPIC-42 slice 2 — `WorkoutSessionCoordinator`'s end-to-end behavior against a real SQLite
/// database: the happy path (start → active → pause → resume → stop → finalize) persists a real
/// `sessions` row; discard persists nothing; a crash-recovered checkpoint populates
/// `recoverableDraft` and resumes correctly; a strength session's finalize computes and returns new
/// PRs; the adapter-wiring closures (`degradedConditions`/`liveHeartRateBpm`) never fabricate a
/// value; and `WorkoutSession.assemble` correctly joins the read-time view this slice repurposed
/// `WorkoutSessionDetail`/`WorkoutChildTableRefs` for.
@MainActor
final class WorkoutSessionCoordinatorTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    var checkpointRepository: WorkoutCheckpointRepository!
    var strengthSetRepository: StrengthSetRepository!
    var measurementRepository: MeasurementRepository!
    var derivationRepository: DerivationRepository!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
    let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-workout-coordinator-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
        checkpointRepository = WorkoutCheckpointRepository(db.main)
        strengthSetRepository = StrengthSetRepository(main: db.main)
        measurementRepository = MeasurementRepository(db.main)
        derivationRepository = DerivationRepository(db.main)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeCoordinator(healthStore: HealthStorePort? = nil) -> WorkoutSessionCoordinator {
        WorkoutSessionCoordinator(
            checkpointRepository: checkpointRepository, strengthSetRepository: strengthSetRepository,
            measurementRepository: measurementRepository, derivationRepository: derivationRepository,
            healthStore: healthStore, deviceId: device, clock: clock)
    }

    // MARK: - Happy path

    func testStartActivePauseResumeStopFinalizePersistsARealSessionRow() async throws {
        let coordinator = makeCoordinator()

        try coordinator.start(activityType: "running")
        XCTAssertEqual(coordinator.lifecycleState, .preparing)
        try coordinator.confirmCountdownFinished()
        XCTAssertEqual(coordinator.lifecycleState, .active)
        XCTAssertEqual(coordinator.activityType, "running")

        clock.advance(by: 300)
        try coordinator.requestPause()
        XCTAssertEqual(coordinator.lifecycleState, .manuallyPaused)

        clock.advance(by: 60)   // this time must NOT count toward duration
        try coordinator.requestResume()
        XCTAssertEqual(coordinator.lifecycleState, .active)

        clock.advance(by: 120)
        try coordinator.requestStop()
        XCTAssertEqual(coordinator.lifecycleState, .stopping)

        let summary = try await coordinator.finalize()
        XCTAssertEqual(coordinator.lifecycleState, .persisted)
        XCTAssertEqual(summary.activityType, "running")
        XCTAssertEqual(summary.durationSeconds, 420, accuracy: 0.001, "60 paused seconds must be excluded")
        XCTAssertEqual(summary.strengthSetCount, 0)
        XCTAssertTrue(summary.newPersonalRecords.isEmpty)

        let stored = try XCTUnwrap(measurementRepository.session(id: summary.sessionId))
        XCTAssertEqual(stored.kind, .workout)
        XCTAssertEqual(stored.subtype, "running")
        XCTAssertEqual(stored.detail.workout?.activityType, "running")
        // I8/PERSISTENCE: no platform id exists for a BADAN-tracked live session — the session's
        // own ULID fills `sourceWorkoutUUID`.
        XCTAssertEqual(stored.detail.workout?.sourceWorkoutUUID, summary.sessionId)
        XCTAssertEqual(stored.detail.workout?.routeRef, nil, "no GPS/route in this slice")
        XCTAssertEqual(stored.provenance.ingestionPath, .manual)
        XCTAssertEqual(stored.provenance.sourceId, device)
        XCTAssertFalse(stored.detail.workout?.stateHistory?.isEmpty ?? true,
                       "the finalized lifecycle audit trail must be persisted")

        XCTAssertNil(try checkpointRepository.load(sessionId: summary.sessionId),
                    "finalize must clear the checkpoint")
    }

    // MARK: - Preparing/countdown split (FIX 4)

    /// `start(activityType:)` alone must leave the machine at `.preparing` — never fast-forward to
    /// `.active` — and must NOT start the adapter's tick loop. Only `confirmCountdownFinished()`
    /// (called by the UI once its real ~3s countdown elapses) moves to `.active` and starts it.
    func testStartAloneLeavesLifecycleAtPreparingWithoutStartingTheAdapter() throws {
        let coordinator = makeCoordinator()

        try coordinator.start(activityType: "running")

        XCTAssertEqual(coordinator.lifecycleState, .preparing)
        XCTAssertFalse(coordinator.adapter.isTicking,
                       "adapter.start() must not run until confirmCountdownFinished() is called")

        try coordinator.confirmCountdownFinished()

        XCTAssertEqual(coordinator.lifecycleState, .active)
        XCTAssertTrue(coordinator.adapter.isTicking, "confirmCountdownFinished() must start the adapter")
    }

    func testConfirmCountdownFinishedThrowsWhenNotPreparing() {
        let coordinator = makeCoordinator()
        XCTAssertThrowsError(try coordinator.confirmCountdownFinished()) { error in
            XCTAssertEqual(error as? WorkoutStateMachineError,
                          .illegalTransition(from: .idle, event: .countdownFinished))
        }
    }

    // MARK: - Discard

    func testDiscardPathPersistsNothing() throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "cycling")
        clock.advance(by: 30)

        try coordinator.discard()

        XCTAssertEqual(coordinator.lifecycleState, .discarded)
        XCTAssertTrue(try measurementRepository.sessions(kind: .workout).isEmpty,
                     "a discarded session must never reach `sessions`")
        XCTAssertTrue(try checkpointRepository.loadAll().isEmpty)
    }

    // MARK: - Crash recovery

    func testCrashRecoveryPopulatesRecoverableDraftAndResumeRestores() async throws {
        let first = makeCoordinator()
        try first.start(activityType: "running")
        try first.confirmCountdownFinished()
        clock.advance(by: 50)
        // Forces an immediate checkpoint save (matches what a real tick would have persisted)
        // rather than waiting on the real ~5s timer — `adapter` is `internal` for exactly this.
        await first.adapter.tick()
        first.adapter.stop()   // simulate the process dying — nothing more should be written

        let savedSessionId = try XCTUnwrap(try checkpointRepository.loadAll().first?.sessionId)

        // "Relaunch": a brand-new coordinator over the SAME repositories/database.
        let second = makeCoordinator()
        XCTAssertEqual(second.lifecycleState, .recoveryDraft)
        let draft = try XCTUnwrap(second.recoverableDraft)
        XCTAssertEqual(draft.sessionId, savedSessionId)
        XCTAssertEqual(draft.activityType, "running")
        XCTAssertEqual(second.activityType, "running")
        XCTAssertEqual(second.elapsedActiveSeconds, 50, accuracy: 0.001)

        try second.resumeFromRecoverableDraft()
        XCTAssertEqual(second.lifecycleState, .active)
        XCTAssertNil(second.recoverableDraft, "resuming must consume the draft")

        clock.advance(by: 10)
        try second.requestStop()
        let summary = try await second.finalize()
        XCTAssertEqual(summary.sessionId, savedSessionId)
        XCTAssertEqual(summary.durationSeconds, 60, accuracy: 0.001)
    }

    func testDiscardRecoverableDraftClearsItWithoutResuming() async throws {
        let first = makeCoordinator()
        try first.start(activityType: "walking")
        await first.adapter.tick()
        first.adapter.stop()

        let second = makeCoordinator()
        XCTAssertNotNil(second.recoverableDraft)

        try second.discardRecoverableDraft()

        XCTAssertNil(second.recoverableDraft)
        XCTAssertTrue(try checkpointRepository.loadAll().isEmpty)
        XCTAssertTrue(try measurementRepository.sessions(kind: .workout).isEmpty)
    }

    // MARK: - Strength quality + PRs

    func testStrengthSessionFinalizeComputesAndReturnsNewPersonalRecords() async throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "strength_training")
        try coordinator.confirmCountdownFinished()

        try coordinator.recordStrengthSet(movementId: "squat", customLabel: nil, kind: .working,
                                          weightValue: 100, reps: 5, unit: .kg, supersetGroup: nil)
        XCTAssertEqual(coordinator.strengthSets.count, 1, "the live ledger must reflect the logged set")

        try coordinator.requestStop()
        let summary = try await coordinator.finalize()

        XCTAssertEqual(summary.strengthSetCount, 1)
        XCTAssertEqual(summary.newPersonalRecords.count, 1)
        let record = try XCTUnwrap(summary.newPersonalRecords.first)
        XCTAssertEqual(record.movementId, "squat")
        XCTAssertEqual(record.weightKg, 100, accuracy: 0.001)
        XCTAssertEqual(record.reps, 5)

        let qualityRows = try checkpointRepository.qualityRows(sessionId: summary.sessionId)
        XCTAssertEqual(qualityRows.count, 1)
        XCTAssertEqual(qualityRows.first?.metricFamily, "strength")

        let stored = try XCTUnwrap(measurementRepository.session(id: summary.sessionId))
        XCTAssertNotNil(stored.detail.workout?.qualitySummaryRef)
    }

    /// FIX 3 — the corrected contract: a set is stored in the unit it was ACTUALLY logged in, never
    /// silently pre-converted to kilograms before storage. `StrengthSet.weightKg` (computed) still
    /// re-derives the correct canonical kilograms on demand, so PR/e1RM math (which reads
    /// `weightKg`, never `weightValue` directly) is unaffected either way — only the STORED,
    /// REDISPLAYED value changes.
    func testRecordStrengthSetStoresTheAsLoggedUnitAndValueNeverPreConverted() throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "strength_training")
        try coordinator.confirmCountdownFinished()

        // 220 lb ~= 99.79 kg — logged in lb, must be STORED in lb, not silently converted to kg.
        try coordinator.recordStrengthSet(movementId: "deadlift", customLabel: nil, kind: .working,
                                          weightValue: 220, reps: 3, unit: .lb, supersetGroup: nil)

        let set = try XCTUnwrap(coordinator.strengthSets.first)
        XCTAssertEqual(set.weightUnit, .lb, "the set must be stored in the unit it was actually logged in")
        XCTAssertEqual(set.weightValue ?? -1, 220, accuracy: 0.001,
                       "the as-entered lb number must be stored verbatim, never pre-converted to kg")
        XCTAssertEqual(set.weightKg ?? -1, WeightUnit.lb.toKilograms(220), accuracy: 0.001,
                       "canonical kilograms must still be correctly DERIVABLE on read, via the computed property")

        // Redisplay (StrengthLoggingScreen.setRow reads weightValue/weightUnit directly) must show
        // the ORIGINAL unit — "220.0 lb" — never a silently converted "99.8 kg".
        XCTAssertEqual(String(format: "%.1f", set.weightValue ?? -1), "220.0",
                       "redisplay must show the original as-entered number")
        XCTAssertEqual(set.weightUnit, .lb, "redisplay must show the original unit, never a silently converted one")
    }

    func testRecordStrengthSetThrowsWhenNoActiveRecordingSession() {
        let coordinator = makeCoordinator()
        XCTAssertThrowsError(
            try coordinator.recordStrengthSet(movementId: "squat", customLabel: nil, kind: .working,
                                              weightValue: 50, reps: 5, unit: .kg, supersetGroup: nil)
        ) { error in
            XCTAssertEqual(error as? WorkoutSessionCoordinatorError,
                          .noActiveRecordingSession(state: .idle))
        }
    }

    // MARK: - Illegal transitions

    func testRequestPauseThrowsIllegalTransitionWhenIdle() {
        let coordinator = makeCoordinator()
        XCTAssertThrowsError(try coordinator.requestPause()) { error in
            XCTAssertEqual(error as? WorkoutStateMachineError,
                          .illegalTransition(from: .idle, event: .userPaused))
        }
    }

    func testStartWhileAlreadyActiveThrows() throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "running")
        XCTAssertThrowsError(try coordinator.start(activityType: "cycling"))
    }

    func testFinalizeThrowsWhenNotYetStopped() async throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "running")
        do {
            _ = try await coordinator.finalize()
            XCTFail("finalize() must require .stopping (call requestStop() first)")
        } catch {
            // expected
        }
    }

    // MARK: - Atomic finalize + retry (FIX 2 + FIX 5)

    /// Simulates `measurementRepository.upsertSession` failing (mid-`finalize()`, AFTER the
    /// PR-append and quality-row-insert already ran in the same call) by renaming the `sessions`
    /// table out from under it — a real SQL failure through the real repository, not a mock, so the
    /// `strength_sets`/`derived_values`/`workout_quality` tables stay fully intact and writable
    /// throughout (a targeted failure of exactly the write FIX 2's atomicity claim is about, not a
    /// broken connection that would fail everything before the transaction even begins).
    ///
    /// Confirms: (1) the PR-append and quality-row-insert roll back TOGETHER with the failed session
    /// upsert — no orphaned `workout_quality`/PR row survives; (2) the machine is left at
    /// `.finalizing`, with its checkpoint intact (nothing was actually persisted); and (3) a SECOND
    /// `finalize()` call — now legal per the relaxed entry guard — succeeds once the failure
    /// condition is removed, and recomputes a correct summary (including the PR, which must not be
    /// blocked by the rolled-back first attempt's discarded derived-value row).
    func testFinalizeIsAtomicAndRetryableAfterAPartialFailure() async throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "strength_training")
        try coordinator.confirmCountdownFinished()
        // Deterministic checkpoint (rather than racing the real ~5s tick timer) so the session id
        // below is readable without depending on `WorkoutSessionSummary`, which a failed finalize()
        // never returns.
        await coordinator.adapter.tick()
        let sessionId = try XCTUnwrap(try checkpointRepository.loadAll().first?.sessionId)

        try coordinator.recordStrengthSet(movementId: "squat", customLabel: nil, kind: .working,
                                          weightValue: 100, reps: 5, unit: .kg, supersetGroup: nil)
        try coordinator.requestStop()

        try db.main.execute("ALTER TABLE sessions RENAME TO sessions_disabled_for_test;")

        do {
            _ = try await coordinator.finalize()
            XCTFail("finalize() must throw while the sessions table is unavailable")
        } catch {
            // expected
        }

        XCTAssertEqual(coordinator.lifecycleState, .finalizing,
                      "a failed finalize() must leave the machine at .finalizing, not stranded past it")
        XCTAssertTrue(try derivationRepository.allDerived(metricId: "workout.strength.pr").isEmpty,
                     "the PR append must roll back together with the failed session upsert — no orphaned PR row")
        XCTAssertTrue(try checkpointRepository.qualityRows(sessionId: sessionId).isEmpty,
                     "the quality-row insert must roll back together with the failed session upsert")
        XCTAssertNotNil(try checkpointRepository.load(sessionId: sessionId),
                        "a failed finalize() must not clear the checkpoint — nothing was actually persisted")

        // Remove the injected failure and retry — legal now that finalize() accepts `.finalizing`.
        try db.main.execute("ALTER TABLE sessions_disabled_for_test RENAME TO sessions;")

        let summary = try await coordinator.finalize()
        XCTAssertEqual(coordinator.lifecycleState, .persisted)
        XCTAssertEqual(summary.sessionId, sessionId)
        XCTAssertEqual(summary.strengthSetCount, 1)
        XCTAssertEqual(summary.newPersonalRecords.count, 1,
                      "the retry recomputes the PR fresh — the rolled-back attempt must not block it")

        let stored = try XCTUnwrap(measurementRepository.session(id: sessionId))
        XCTAssertEqual(stored.detail.workout?.activityType, "strength_training")
        XCTAssertNotNil(stored.detail.workout?.qualitySummaryRef)
        XCTAssertNil(try checkpointRepository.load(sessionId: sessionId),
                    "a successful finalize() clears the checkpoint")
    }

    // MARK: - Adapter wiring never fabricates a value

    func testHeartRateReadReturningNilNeverBecomesFakeZeroOnLiveHeartRateBpm() async throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "running")

        await coordinator.adapter.onHeartRateUpdate?(72)
        XCTAssertEqual(coordinator.liveHeartRateBpm, 72)

        await coordinator.adapter.onHeartRateUpdate?(nil)
        XCTAssertNil(coordinator.liveHeartRateBpm,
                    "a nil HR read must clear the tile, never leave/produce a fabricated 0")
    }

    func testLowBatteryWiringAppliesDegradedConditionThroughTheMachine() async throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "running")
        XCTAssertTrue(coordinator.degradedConditions.isEmpty)

        await coordinator.adapter.onDegradedConditionBegan?(.lowBattery)
        XCTAssertTrue(coordinator.degradedConditions.contains(.lowBattery))

        await coordinator.adapter.onDegradedConditionEnded?(.lowBattery)
        XCTAssertFalse(coordinator.degradedConditions.contains(.lowBattery))
    }

    /// FIX 6 — `WorkoutDetail.degradedConditions` exercised through a REAL encode/DB-write/decode
    /// round trip with a non-empty value (previously only `stateHistory`/`qualitySummaryRef` were).
    func testFinalizePersistsDegradedConditionsThroughARealEncodeDecodeRoundTrip() async throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "running")
        try coordinator.confirmCountdownFinished()

        await coordinator.adapter.onDegradedConditionBegan?(.lowBattery)
        XCTAssertTrue(coordinator.degradedConditions.contains(.lowBattery))

        try coordinator.requestStop()
        let summary = try await coordinator.finalize()
        XCTAssertTrue(summary.degradedConditions.contains(.lowBattery))

        let stored = try XCTUnwrap(measurementRepository.session(id: summary.sessionId))
        XCTAssertEqual(stored.detail.workout?.degradedConditions, [.lowBattery],
                      "a degraded condition begun mid-session must round-trip through a real encode/DB-write/decode, not just the in-memory summary")
    }

    // MARK: - Read-time assembly (EPIC-42 slice 2's repurposing of WorkoutSessionDetail)

    func testWorkoutSessionAssembleJoinsSessionQualityAndStrengthSetsAtReadTime() async throws {
        let coordinator = makeCoordinator()
        try coordinator.start(activityType: "strength_training")
        try coordinator.confirmCountdownFinished()
        try coordinator.recordStrengthSet(movementId: "bench_press", customLabel: nil, kind: .working,
                                          weightValue: 60, reps: 8, unit: .kg, supersetGroup: nil)
        try coordinator.requestStop()
        let summary = try await coordinator.finalize()

        let session = try XCTUnwrap(measurementRepository.session(id: summary.sessionId))
        let qualityRows = try checkpointRepository.qualityRows(sessionId: summary.sessionId)
        let sets = try strengthSetRepository.sets(sessionId: summary.sessionId)

        let assembled = try XCTUnwrap(
            WorkoutSession.assemble(session: session, qualityRows: qualityRows, strengthSets: sets))

        XCTAssertEqual(assembled.id, summary.sessionId)
        XCTAssertEqual(assembled.activityType, "strength_training")
        XCTAssertFalse(assembled.isLive, "a persisted session is never still live")
        XCTAssertEqual(assembled.detail.childRefs.strengthSetCount, 1)
        XCTAssertEqual(assembled.detail.childRefs.qualityRecordCount, qualityRows.count)
        XCTAssertFalse(assembled.detail.stateHistory.isEmpty)
        XCTAssertNotNil(assembled.detail.qualitySummaryRef)
    }

    func testWorkoutSessionAssembleReturnsNilForANonWorkoutSession() {
        let session = Session(
            id: "s1", kind: .sleepPrimary, startAt: clock.now(), endAt: clock.now(),
            tzId: "UTC", detail: SessionDetail(),
            provenance: Provenance(sourceId: device, ingestionPath: .platformStore,
                                  measuredAt: clock.now(), measuredTimezone: "UTC",
                                  recordedAt: clock.now(), ingestedAt: clock.now()),
            updatedAt: clock.now(), originDeviceId: device)

        XCTAssertNil(WorkoutSession.assemble(session: session, qualityRows: [], strengthSets: []))
    }
}
