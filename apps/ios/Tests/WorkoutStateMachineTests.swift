import XCTest
@testable import BADAN

/// EPIC-42 (plan §7A.5) — the workout OS's platform-neutral lifecycle state machine.
///
/// Pure domain code: no HealthKit, no BLE, no database, no simulator. Every test drives a
/// `WorkoutStateMachine` with a `FixedClock` so elapsed-time bookkeeping (`accumulatedActiveSeconds`/
/// `accumulatedPausedSeconds`) is exactly reproducible rather than flaky against the wall clock.
final class WorkoutStateMachineTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func makeClock() -> FixedClock { FixedClock(base) }

    // MARK: - Happy path: idle → … → persisted

    /// The full success sequence plan §7A.5 names: IDLE → preparing → active → stopping →
    /// finalizing → persisted, with the countdown and Apple's correct end sequence both
    /// represented as their own states rather than collapsed into "started"/"stopped".
    func testHappyPathReachesPersisted() throws {
        let clock = makeClock()
        let machine = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: clock)
        XCTAssertEqual(machine.state, .idle)

        XCTAssertEqual(try machine.apply(.begin), .preparing)
        XCTAssertEqual(try machine.apply(.countdownFinished), .active)
        XCTAssertEqual(try machine.apply(.stopRequested), .stopping)
        XCTAssertEqual(try machine.apply(.recordingStopped), .finalizing)
        XCTAssertEqual(try machine.apply(.persistCompleted), .persisted)

        XCTAssertTrue(machine.state.isTerminal)
        XCTAssertEqual(machine.stateHistory.map(\.state),
                       [.idle, .preparing, .active, .stopping, .finalizing, .persisted])
    }

    /// Cancelling during the countdown warm-up is a discard, not a "stop" — nothing was ever
    /// recorded, so there is nothing to end-sequence through.
    func testDiscardDuringCountdown() throws {
        let machine = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: makeClock())
        _ = try machine.apply(.begin)
        XCTAssertEqual(try machine.apply(.discardRequested), .discarded)
        XCTAssertTrue(machine.state.isTerminal)
    }

    // MARK: - Auto-pause / manual pause (plan §7A.5 "auto-pause")

    func testAutoPauseAndAutoResume() throws {
        let machine = try activeMachine()
        XCTAssertEqual(try machine.apply(.autoPauseDetected), .autoPaused)
        XCTAssertTrue(machine.state.isPaused)
        XCTAssertEqual(try machine.apply(.autoResumeDetected), .active)
    }

    func testManualPauseAndResume() throws {
        let machine = try activeMachine()
        XCTAssertEqual(try machine.apply(.userPaused), .manuallyPaused)
        XCTAssertEqual(try machine.apply(.userResumed), .active)
    }

    /// A deliberate tap wins over an automatic detection: pausing manually while already
    /// auto-paused must land on `.manuallyPaused`, not be ignored as "already paused" — the two
    /// are distinguishable states so a notebook can say which kind of pause happened.
    func testManualPauseOverridesAutoPause() throws {
        let machine = try activeMachine()
        _ = try machine.apply(.autoPauseDetected)
        XCTAssertEqual(try machine.apply(.userPaused), .manuallyPaused)
    }

    // MARK: - Interruption (plan §7A.5 "interruption")

    /// Ending an interruption restores the SPECIFIC state it interrupted, not a generic "active" —
    /// here, a manual pause.
    func testInterruptionRestoresTheSpecificPriorState() throws {
        let machine = try activeMachine()
        _ = try machine.apply(.userPaused)
        XCTAssertEqual(try machine.apply(.interruptionBegan), .interrupted)
        XCTAssertEqual(try machine.apply(.interruptionEnded), .manuallyPaused)
    }

    func testInterruptionFromActiveRestoresActive() throws {
        let machine = try activeMachine()
        _ = try machine.apply(.interruptionBegan)
        XCTAssertEqual(try machine.apply(.interruptionEnded), .active)
    }

    /// Giving up during an interruption (e.g. a long phone call) still reaches the ordinary end
    /// sequence rather than being a dead end.
    func testCanStopWhileInterrupted() throws {
        let machine = try activeMachine()
        _ = try machine.apply(.interruptionBegan)
        XCTAssertEqual(try machine.apply(.stopRequested), .stopping)
    }

    // MARK: - Degraded conditions are the OTHER axis (plan §7A.5 "sensor-degraded, route-degraded, low-battery")

    /// Degraded conditions never move the lifecycle phase, can coexist, and clear independently —
    /// a dropped HR strap does not stop a workout, and a battery warning clearing does not imply
    /// the sensor came back.
    func testDegradedConditionsAreIndependentOfLifecycleAndOfEachOther() throws {
        let machine = try activeMachine()
        XCTAssertEqual(try machine.apply(.degradedConditionBegan(.sensorDegraded)), .active)
        XCTAssertEqual(try machine.apply(.degradedConditionBegan(.lowBattery)), .active)
        XCTAssertEqual(machine.degradedConditions, [.sensorDegraded, .lowBattery])

        XCTAssertEqual(try machine.apply(.degradedConditionEnded(.sensorDegraded)), .active)
        XCTAssertEqual(machine.degradedConditions, [.lowBattery])
        // The lifecycle transitions recorded are unaffected by any of the above.
        XCTAssertEqual(machine.stateHistory.map(\.state), [.idle, .preparing, .active])
    }

    /// Degraded conditions can be raised even while paused/interrupted — they describe the
    /// SENSORS, not the recording phase.
    func testDegradedConditionCanBeRaisedWhilePaused() throws {
        let machine = try activeMachine()
        _ = try machine.apply(.userPaused)
        XCTAssertEqual(try machine.apply(.degradedConditionBegan(.routeDegraded)), .manuallyPaused)
        XCTAssertEqual(machine.degradedConditions, [.routeDegraded])
    }

    // MARK: - Illegal transitions fail loudly (never silently reclassify)

    func testIllegalTransitionsThrowRatherThanSilentlyIgnore() {
        let machine = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: makeClock())

        XCTAssertThrowsError(try machine.apply(.userResumed)) { error in
            XCTAssertEqual(error as? WorkoutStateMachineError,
                          .illegalTransition(from: .idle, event: .userResumed))
        }
        // The failed attempt must not have moved or recorded anything.
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.stateHistory.count, 1)
    }

    func testCannotSkipTheEndSequence() throws {
        let machine = try activeMachine()
        XCTAssertThrowsError(try machine.apply(.persistCompleted)) { error in
            XCTAssertEqual(error as? WorkoutStateMachineError,
                          .illegalTransition(from: .active, event: .persistCompleted))
        }
    }

    func testCannotResumeFromRecoveryWhenNotInRecovery() throws {
        let machine = try activeMachine()
        XCTAssertThrowsError(try machine.apply(.resumeFromRecovery))
    }

    // MARK: - Discard is reachable from every resumable state

    func testDiscardIsReachableFromEveryNonTerminalNonFinalizingState() throws {
        // `.idle` is deliberately excluded: no session exists yet at that point (nothing has been
        // created to discard) — see the next test.
        for state in WorkoutLifecycleState.allCases
        where !state.isTerminal && state != .idle && state != .stopping && state != .finalizing {
            let next = WorkoutStateMachine.nextState(from: state, event: .discardRequested,
                                                     stateBeforeInterruption: .active)
            XCTAssertEqual(next, .discarded, "\(state) should be able to discard directly")
        }
    }

    /// `.idle` has no legal `discardRequested` transition — there is nothing to discard before
    /// `.begin` has even been applied, so this must fail loudly like any other illegal event
    /// rather than silently no-op into `.discarded`.
    func testIdleHasNoDiscardTransition() {
        XCTAssertNil(WorkoutStateMachine.nextState(from: .idle, event: .discardRequested,
                                                    stateBeforeInterruption: .idle))
    }

    // MARK: - Elapsed-time accounting

    /// Active and paused seconds are banked from the FIXED clock, independent of which specific
    /// pause variant was in effect.
    func testActiveAndPausedSecondsAccumulateAcrossPhases() throws {
        let clock = makeClock()
        let machine = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: clock)
        _ = try machine.apply(.begin)
        _ = try machine.apply(.countdownFinished)      // enters .active at t=0

        clock.advance(by: 60)
        _ = try machine.apply(.userPaused)             // 60s active banked

        clock.advance(by: 30)
        _ = try machine.apply(.userResumed)             // 30s paused banked

        clock.advance(by: 45)
        _ = try machine.apply(.stopRequested)            // 45s more active banked

        XCTAssertEqual(machine.accumulatedActiveSeconds, 105, accuracy: 0.001)
        XCTAssertEqual(machine.accumulatedPausedSeconds, 30, accuracy: 0.001)
    }

    /// `checkpoint()` folds in time elapsed since the last transition WITHOUT mutating the
    /// machine — calling it twice in a row must report the same growing total, never double-bank.
    func testCheckpointReflectsInFlightTimeWithoutMutatingTheMachine() throws {
        let clock = makeClock()
        let machine = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: clock)
        _ = try machine.apply(.begin)
        _ = try machine.apply(.countdownFinished)

        clock.advance(by: 20)
        let checkpoint1 = machine.checkpoint(originDeviceId: "device-a")
        XCTAssertEqual(checkpoint1.hotState.activeSeconds, 20, accuracy: 0.001)

        clock.advance(by: 10)
        let checkpoint2 = machine.checkpoint(originDeviceId: "device-a")
        XCTAssertEqual(checkpoint2.hotState.activeSeconds, 30, accuracy: 0.001)

        // The machine itself never moved or re-banked anything from being checkpointed.
        XCTAssertEqual(machine.state, .active)
        XCTAssertEqual(machine.accumulatedActiveSeconds, 0, accuracy: 0.001)
    }

    // MARK: - Crash recovery — the core requirement

    /// The exact scenario the task requires: construct a machine, drive it to an in-progress
    /// state, snapshot a checkpoint (standing in for "the process died here"), then load a FRESH
    /// instance from that checkpoint — it must recover to a resumable draft, never lose the
    /// session or silently resume as if nothing happened.
    func testCrashMidSessionRecoversToAResumableDraft() throws {
        let clock = makeClock()
        let machine1 = WorkoutStateMachine(sessionId: "s1", activityType: "cycling", clock: clock)
        _ = try machine1.apply(.begin)
        _ = try machine1.apply(.countdownFinished)
        clock.advance(by: 300)
        _ = try machine1.apply(.userPaused)
        clock.advance(by: 15)

        let checkpoint = machine1.checkpoint(originDeviceId: "device-a")
        XCTAssertEqual(checkpoint.state, .manuallyPaused, "The checkpoint captures the true pre-crash state")

        // Simulate process death: a dead-time gap passes before the app relaunches.
        clock.advance(by: 3600)
        let machine2 = WorkoutStateMachine(restoringFrom: checkpoint, clock: clock)

        XCTAssertEqual(machine2.state, .recoveryDraft, "A relaunch must ask, never silently resume")
        XCTAssertEqual(machine2.sessionId, "s1")
        XCTAssertEqual(machine2.activityType, "cycling")
        // The session itself is not lost: its full pre-crash history rode along.
        XCTAssertEqual(machine2.stateHistory.map(\.state),
                       [.idle, .preparing, .active, .manuallyPaused, .recoveryDraft])

        // The user's explicit decision resumes into the SPECIFIC pre-crash state.
        XCTAssertEqual(try machine2.apply(.resumeFromRecovery), .manuallyPaused)
    }

    /// The hour the app spent dead between the crash and the relaunch must never be credited as
    /// active or paused workout time — dead time is dead time.
    func testDeadTimeDuringCrashIsNeverBankedAsActiveOrPaused() throws {
        let clock = makeClock()
        let machine1 = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: clock)
        _ = try machine1.apply(.begin)
        _ = try machine1.apply(.countdownFinished)
        clock.advance(by: 42)
        let checkpoint = machine1.checkpoint(originDeviceId: "device-a")
        XCTAssertEqual(checkpoint.hotState.activeSeconds, 42, accuracy: 0.001)

        clock.advance(by: 7200)   // two hours of process death
        let machine2 = WorkoutStateMachine(restoringFrom: checkpoint, clock: clock)

        XCTAssertEqual(machine2.accumulatedActiveSeconds, 42, accuracy: 0.001,
                       "Restoring must carry over exactly the pre-crash total, no more")
        // And resuming does not retroactively bank the dead gap either.
        _ = try machine2.apply(.resumeFromRecovery)
        XCTAssertEqual(machine2.accumulatedActiveSeconds, 42, accuracy: 0.001)
    }

    /// A crash that happens WHILE already interrupted (e.g. mid-phone-call) must recover to the
    /// state BEFORE the interruption, not to `.interrupted` itself (which is not a meaningful
    /// "resume into" target).
    func testCrashWhileInterruptedRecoversPastTheInterruption() throws {
        let clock = makeClock()
        let machine1 = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: clock)
        _ = try machine1.apply(.begin)
        _ = try machine1.apply(.countdownFinished)
        _ = try machine1.apply(.interruptionBegan)

        let checkpoint = machine1.checkpoint(originDeviceId: "device-a")
        XCTAssertEqual(checkpoint.state, .interrupted)
        XCTAssertEqual(checkpoint.hotState.stateBeforeInterruption, .active)

        let machine2 = WorkoutStateMachine(restoringFrom: checkpoint, clock: clock)
        XCTAssertEqual(machine2.state, .recoveryDraft)
        XCTAssertEqual(try machine2.apply(.resumeFromRecovery), .active,
                       "Recovery must resolve past .interrupted to what it actually interrupted")
    }

    /// Defensive case: a checkpoint that was itself already `.recoveryDraft` (a second crash
    /// before the first recovery was resolved) must still resolve back to the ORIGINAL
    /// pre-interruption state, not get stuck pointing at a non-resumable value.
    func testDoubleCrashStillResolvesToTheOriginalPreCrashState() throws {
        let clock = makeClock()
        let machine1 = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: clock)
        _ = try machine1.apply(.begin)
        _ = try machine1.apply(.countdownFinished)
        let firstCheckpoint = machine1.checkpoint(originDeviceId: "device-a")

        let machine2 = WorkoutStateMachine(restoringFrom: firstCheckpoint, clock: clock)
        XCTAssertEqual(machine2.state, .recoveryDraft)
        // Crash AGAIN before the user resolves the first recovery draft.
        let secondCheckpoint = machine2.checkpoint(originDeviceId: "device-a")
        XCTAssertEqual(secondCheckpoint.state, .recoveryDraft)

        let machine3 = WorkoutStateMachine(restoringFrom: secondCheckpoint, clock: clock)
        XCTAssertEqual(machine3.state, .recoveryDraft)
        XCTAssertEqual(try machine3.apply(.resumeFromRecovery), .active,
                       "Two crashes in a row must not lose track of the real pre-crash state")
    }

    /// Discarding a recovered draft is a real, supported end — the user gets to say "don't keep
    /// this one" instead of only ever being able to resume.
    func testRecoveryDraftCanBeDiscarded() throws {
        let clock = makeClock()
        let machine1 = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: clock)
        _ = try machine1.apply(.begin)
        _ = try machine1.apply(.countdownFinished)
        let checkpoint = machine1.checkpoint(originDeviceId: "device-a")

        let machine2 = WorkoutStateMachine(restoringFrom: checkpoint, clock: clock)
        XCTAssertEqual(try machine2.apply(.discardRequested), .discarded)
    }

    // MARK: - Bilingual copy (matches this codebase's universal rule for user-facing labels)

    func testEveryLifecycleStateHasBilingualCopy() {
        for state in WorkoutLifecycleState.allCases {
            let label = state.displayLabel
            XCTAssertFalse(label.en.isEmpty, "\(state.rawValue) has no English label")
            XCTAssertFalse(label.ar.isEmpty, "\(state.rawValue) has no Arabic label")
            XCTAssertNotEqual(label.en, label.ar, "\(state.rawValue) is untranslated")
            XCTAssertTrue(label.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(state.rawValue)'s Arabic label contains no Arabic script")
        }
    }

    func testEveryDegradedConditionHasBilingualCopy() {
        for condition in WorkoutDegradedCondition.allCases {
            let label = condition.displayLabel
            XCTAssertFalse(label.en.isEmpty)
            XCTAssertFalse(label.ar.isEmpty)
            XCTAssertNotEqual(label.en, label.ar)
            XCTAssertTrue(label.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(condition.rawValue)'s Arabic label contains no Arabic script")
        }
    }

    // MARK: - Fixtures

    private func activeMachine() throws -> WorkoutStateMachine {
        let machine = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: makeClock())
        _ = try machine.apply(.begin)
        _ = try machine.apply(.countdownFinished)
        return machine
    }
}
