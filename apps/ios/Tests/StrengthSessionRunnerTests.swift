import XCTest
@testable import BADAN

/// EPIC-42/28 — the strength-set ledger and its live-session runner: crash-safe persist-after-
/// every-set, the append-first revision chain (mirrors `HydrationTests`' hydration-ledger
/// coverage), superset grouping, and the exercise-swap guarantee that a movement change mid-session
/// can never lose or renumber sets already logged. `RestTimer`'s pure duration/state arithmetic is
/// covered separately at the bottom since it needs no database at all.
final class StrengthSessionRunnerTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-strength-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func repo() -> StrengthSetRepository { StrengthSetRepository(main: db.main) }
    private func runner() -> StrengthSessionRunner {
        StrengthSessionRunner(repository: repo(), clock: clock, deviceId: device)
    }

    // MARK: - Pure ledger: seq is session-scoped, never movement-scoped (I2/§9.18)

    func testNextSeqIsOnePastTheHighestSeqRegardlessOfMovement() {
        let t = clock.now()
        let a = StrengthSetLedger.makeSet(id: "A", sessionId: "s1", movementId: "squat", kind: .working,
                                          seq: 1, reps: 5, weightValue: 100, weightUnit: .kg,
                                          recordedAt: t, updatedAt: t, originDeviceId: device)
        let b = StrengthSetLedger.makeSet(id: "B", sessionId: "s1", movementId: "bench_press", kind: .working,
                                          seq: 2, reps: 5, weightValue: 60, weightUnit: .kg,
                                          recordedAt: t, updatedAt: t, originDeviceId: device)
        XCTAssertEqual(StrengthSetLedger.nextSeq(existing: []), 1, "an empty session starts at seq 1")
        XCTAssertEqual(StrengthSetLedger.nextSeq(existing: [a]), 2)
        XCTAssertEqual(StrengthSetLedger.nextSeq(existing: [a, b]), 3,
                       "a DIFFERENT movement's set still advances the SAME session-wide counter")
    }

    // MARK: - Revision chain (I2: append, never mutate)

    func testReviseSetAppendsARevisionAndNeverMutatesTheOriginal() {
        let t = clock.now()
        let original = StrengthSetLedger.makeSet(id: "A", sessionId: "s1", movementId: "squat",
                                                 kind: .working, seq: 1, reps: 5, weightValue: 95,
                                                 weightUnit: .kg, recordedAt: t, updatedAt: t,
                                                 originDeviceId: device)
        let revision = StrengthSetLedger.makeRevision(of: original, id: "A2", weightValue: 100,
                                                      updatedAt: t, originDeviceId: device)
        XCTAssertEqual(revision.originalId, "A", "the chain's stable identity carries over")
        XCTAssertEqual(revision.supersedes, "A")
        XCTAssertEqual(revision.revision, 2)
        XCTAssertEqual(revision.seq, original.seq, "a correction never moves the set's position")
        XCTAssertEqual(revision.weightValue, 100)
        XCTAssertEqual(revision.reps, original.reps, "an unspecified field carries over from the live row")

        let live = StrengthSetLedger.liveSets([original, revision])
        XCTAssertEqual(live.map(\.id), ["A2"], "only the revision is live; the original is superseded, not deleted")
    }

    func testUndoingARevisionRevertsToThePriorVersion() {
        let t = clock.now()
        let a = StrengthSetLedger.makeSet(id: "A", sessionId: "s1", movementId: "squat", kind: .working,
                                          seq: 1, reps: 5, weightValue: 95, weightUnit: .kg,
                                          recordedAt: t, updatedAt: t, originDeviceId: device)
        var a2 = StrengthSetLedger.makeRevision(of: a, id: "A2", weightValue: 100, updatedAt: t, originDeviceId: device)
        a2.deletedAt = t   // undo the revision
        let live = StrengthSetLedger.liveSets([a, a2])
        XCTAssertEqual(live.map(\.id), ["A"], "undoing a revision reverts to the prior version, exactly like hydration")
        XCTAssertEqual(live.first?.weightValue, 95)
    }

    // MARK: - `is_warm_up` is computed from `set_kind`, never independently settable

    /// Arabic/RTL readiness is a first-order concern (CLAUDE.md) — mirrors
    /// `WorkoutStateMachineTests.testEveryLifecycleStateHasBilingualCopy` exactly.
    func testEverySetKindHasBilingualCopy() {
        for kind in StrengthSetKind.allCases {
            let label = kind.displayLabel
            XCTAssertFalse(label.en.isEmpty, "\(kind.rawValue) has no English label")
            XCTAssertFalse(label.ar.isEmpty, "\(kind.rawValue) has no Arabic label")
            XCTAssertNotEqual(label.en, label.ar, "\(kind.rawValue) is untranslated")
            XCTAssertTrue(label.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(kind.rawValue)'s Arabic label contains no Arabic script")
        }
    }

    func testIsWarmUpIsComputedFromSetKindOnly() {
        let t = clock.now()
        let warmUp = StrengthSetLedger.makeSet(id: "A", sessionId: "s1", kind: .warmUp, seq: 1,
                                               recordedAt: t, updatedAt: t, originDeviceId: device)
        let working = StrengthSetLedger.makeSet(id: "B", sessionId: "s1", kind: .working, seq: 2,
                                                recordedAt: t, updatedAt: t, originDeviceId: device)
        XCTAssertTrue(warmUp.isWarmUp)
        XCTAssertFalse(working.isWarmUp)
    }

    // MARK: - DB-backed runner: crash-safe persist-after-every-set

    func testEachRecordedSetIsPersistedImmediatelyNotBatched() throws {
        let r = runner()
        let s1 = try r.recordSet(sessionId: "session-1", movementId: "squat", kind: .working,
                                 reps: 5, weightValue: 100, weightUnit: .kg)
        // Read back through a FRESH repository instance (same connection, but simulates "what would
        // survive a crash right now") without any explicit "finish session" call.
        let afterOneSet = try repo().liveSets(sessionId: "session-1")
        XCTAssertEqual(afterOneSet.map(\.id), [s1.id], "the first set is durable the instant it's recorded")

        clock.advance(by: 60)
        let s2 = try r.recordSet(sessionId: "session-1", movementId: "squat", kind: .working,
                                 reps: 5, weightValue: 102.5, weightUnit: .kg)
        let afterTwoSets = try repo().liveSets(sessionId: "session-1")
        XCTAssertEqual(afterTwoSets.map(\.id), [s1.id, s2.id])
        XCTAssertEqual(afterTwoSets.map(\.seq), [1, 2])
    }

    func testASimulatedCrashBetweenSetsLosesNothingAlreadyRecorded() throws {
        let r = runner()
        try r.recordSet(sessionId: "session-1", movementId: "squat", kind: .working,
                        reps: 5, weightValue: 100, weightUnit: .kg)
        try r.recordSet(sessionId: "session-1", movementId: "squat", kind: .working,
                        reps: 5, weightValue: 102.5, weightUnit: .kg)
        // "Crash" here: simply never call a third recordSet / never wrap the two calls in one
        // transaction. Because `recordSet` persists immediately, both prior sets must already be
        // durable — there is no pending batch a crash could roll back.
        let sets = try repo().liveSets(sessionId: "session-1")
        XCTAssertEqual(sets.count, 2, "no set is lost to an interrupted session")
    }

    func testReviseSetPersistsAppendedRevisionAndPreservesHistory() throws {
        let r = runner()
        let original = try r.recordSet(sessionId: "session-1", movementId: "squat", kind: .working,
                                       reps: 5, weightValue: 95, weightUnit: .kg)
        clock.advance(by: 30)
        let revised = try r.reviseSet(originalId: original.id, weightValue: 100)
        XCTAssertEqual(revised.supersedes, original.id)
        XCTAssertEqual(revised.revision, 2)

        let live = try repo().liveSets(sessionId: "session-1")
        XCTAssertEqual(live.map(\.id), [revised.id], "only the revision is live")
        XCTAssertEqual(live.first?.weightValue, 100)

        let history = try repo().history(originalId: original.id)
        XCTAssertEqual(history.map(\.id), [original.id, revised.id], "the original stays in the audit chain")
        XCTAssertEqual(history.first?.weightValue, 95, "the superseded row is never mutated")
    }

    func testRevisingAChainWithNothingLiveThrows() throws {
        let r = runner()
        let original = try r.recordSet(sessionId: "session-1", movementId: "squat", kind: .working,
                                       reps: 5, weightValue: 95, weightUnit: .kg)
        try repo().deleteChain(originalId: original.id, at: clock.now())
        XCTAssertThrowsError(try r.reviseSet(originalId: original.id, weightValue: 100)) { error in
            XCTAssertEqual(error as? StrengthSessionError, .noLiveSet(originalId: original.id))
        }
    }

    // MARK: - Exercise swap PRESERVES already-completed sets (plan §9.18)

    /// The central guarantee: swapping the movement mid-session is nothing more than passing a
    /// different `movementId` to the next `recordSet` call. Nothing about a prior set — its id, its
    /// seq, its movementId, its superset group — is touched. If `seq` were ever scoped per movement
    /// instead of per session, this test would catch it as either a seq COLLISION (two sets sharing
    /// `(session_id, seq)`) or a silent renumbering.
    func testSwappingTheMovementMidSessionPreservesPriorSetsAndDoesNotRenumber() throws {
        let r = runner()
        let bench1 = try r.recordSet(sessionId: "session-1", movementId: "bench_press", kind: .working,
                                     reps: 8, weightValue: 60, weightUnit: .kg)
        let bench2 = try r.recordSet(sessionId: "session-1", movementId: "bench_press", kind: .working,
                                     reps: 8, weightValue: 62.5, weightUnit: .kg)
        // Swap: the lifter switches to overhead press for the rest of the session.
        let ohp1 = try r.recordSet(sessionId: "session-1", movementId: "overhead_press", kind: .working,
                                   reps: 8, weightValue: 40, weightUnit: .kg)

        let all = try repo().liveSets(sessionId: "session-1")
        XCTAssertEqual(all.map(\.id), [bench1.id, bench2.id, ohp1.id],
                       "no prior set is lost or reordered by the swap")
        XCTAssertEqual(all.map(\.movementId), ["bench_press", "bench_press", "overhead_press"],
                       "each set keeps the movement it was actually logged under")
        XCTAssertEqual(all.map(\.seq), [1, 2, 3], "seq keeps advancing session-wide across the swap")
        XCTAssertEqual(Set(all.map(\.seq)).count, 3, "no seq collision between the two movements")
    }

    // MARK: - Superset flow: `superset_group` groups sets across (possibly different) movements

    func testSupersetGroupIdGroupsSetsAcrossDifferentMovements() throws {
        let r = runner()
        let group = r.startSuperset()
        let a1 = try r.recordSet(sessionId: "session-1", movementId: "bench_press", kind: .working,
                                 supersetGroup: group, reps: 8, weightValue: 60, weightUnit: .kg)
        let b1 = try r.recordSet(sessionId: "session-1", movementId: "barbell_row", kind: .working,
                                 supersetGroup: group, reps: 8, weightValue: 50, weightUnit: .kg)
        let standalone = try r.recordSet(sessionId: "session-1", movementId: "plank", kind: .timed,
                                         reps: nil, weightValue: nil, weightUnit: nil)

        let all = try repo().liveSets(sessionId: "session-1")
        let grouped = all.filter { $0.supersetGroup == group }
        XCTAssertEqual(Set(grouped.map(\.id)), [a1.id, b1.id])
        XCTAssertNil(all.first(where: { $0.id == standalone.id })?.supersetGroup)
    }

    // MARK: - RestTimer: pure duration/state, no UI, no wall clock

    func testRestTimerCountsDownAndClampsAtZero() {
        let start = Date(timeIntervalSince1970: 0)
        let idle = RestTimer(targetSeconds: 90)
        XCTAssertFalse(idle.isRunning)
        XCTAssertEqual(idle.remaining(at: start), 90, "an unstarted timer reads as its full target")

        let running = idle.started(at: start)
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.remaining(at: start.addingTimeInterval(30)), 60, accuracy: 1e-9)
        XCTAssertFalse(running.isComplete(at: start.addingTimeInterval(30)))
        XCTAssertEqual(running.remaining(at: start.addingTimeInterval(200)), 0,
                      "remaining never goes negative once the countdown passes")
        XCTAssertTrue(running.isComplete(at: start.addingTimeInterval(200)))
    }

    func testRestTimerStoppedClearsTheRunningState() {
        let start = Date(timeIntervalSince1970: 0)
        let running = RestTimer(targetSeconds: 60).started(at: start)
        let stopped = running.stopped()
        XCTAssertFalse(stopped.isRunning)
        XCTAssertEqual(stopped.remaining(at: start.addingTimeInterval(999)), 60,
                      "a stopped timer reads as its full target again, not as whatever it had left")
    }
}
