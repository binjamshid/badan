import XCTest
@testable import BADAN

/// EPIC-42's interval/HIIT engine. The assertions that matter most are the two places an interval
/// timer is classically wrong: the trailing recovery after the final round, and what happens when
/// the app was backgrounded across several segments.
final class IntervalEngineTests: XCTestCase {
    /// 4 rounds of 30s work / 20s recovery, 60s warm-up, 60s cool-down.
    private var plan: IntervalPlan {
        IntervalPlan.hiit(workSeconds: 30, recoverySeconds: 20, rounds: 4,
                          warmUpSeconds: 60, coolDownSeconds: 60)
    }

    // MARK: - Layout

    /// The classic off-by-one: "4 × 30s with 20s recovery" is 3 recoveries, not 4. A trailing
    /// recovery would leave the person standing still before a cool-down that is itself rest.
    func testTheFinalRoundHasNoTrailingRecovery() {
        let steps = plan.steps

        XCTAssertEqual(steps.map(\.kind),
                       [.warmUp, .work, .recovery, .work, .recovery, .work, .recovery, .work, .coolDown])
        XCTAssertEqual(steps.filter { $0.kind == .work }.count, 4)
        XCTAssertEqual(steps.filter { $0.kind == .recovery }.count, 3, "one fewer recovery than rounds")
    }

    func testTotalSecondsMatchesTheLaidOutTimeline() {
        // 60 warm-up + 4x30 work + 3x20 recovery + 60 cool-down
        XCTAssertEqual(plan.totalSeconds, 60 + 120 + 60 + 60)
        XCTAssertEqual(plan.totalSeconds, plan.steps.reduce(0) { $0 + $1.durationSeconds })
    }

    /// Every round needs its own identity, or `workout_intervals` rows collide on the primary key
    /// and eight rounds persist as one.
    func testEachRoundGetsADistinctStepId() {
        let ids = plan.steps.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no two segments may share an id")
    }

    func testAPlanWithNoRecoveryOrWarmUpIsJustTheWorkRounds() {
        let bare = IntervalPlan.hiit(workSeconds: 45, recoverySeconds: 0, rounds: 3,
                                     warmUpSeconds: 0, coolDownSeconds: 0)
        XCTAssertEqual(bare.steps.map(\.kind), [.work, .work, .work])
        XCTAssertEqual(bare.totalSeconds, 135)
    }

    /// Degenerate inputs are clamped at construction rather than defended against everywhere.
    func testZeroOrNegativeInputsAreClamped() {
        let step = IntervalStep(kind: .work, durationSeconds: 0)
        XCTAssertEqual(step.durationSeconds, 1)
        XCTAssertEqual(IntervalPlan(work: step, repeats: 0).repeats, 1)
    }

    // MARK: - Position

    func testPositionResolvesTheWarmUpFirst() throws {
        let position = try XCTUnwrap(IntervalEngine.position(in: plan, elapsed: 10))
        XCTAssertEqual(position.step.kind, .warmUp)
        XCTAssertEqual(position.remainingInStep, 50)
        XCTAssertEqual(position.nextStep?.kind, .work)
        XCTAssertNil(position.workRound, "a warm-up belongs to no round")
    }

    func testPositionNumbersWorkRoundsFromOne() throws {
        // 60 warm-up, then work[0..30), recovery[30..50), work[50..80) — so 115s in is round 3's work
        // (60 + 30 + 20 + 30 + 20 = 160 covers rounds 1-3 plus recoveries; 115 lands inside round 2's
        // second half... resolve it explicitly rather than by arithmetic in the comment).
        let atRoundOne = try XCTUnwrap(IntervalEngine.position(in: plan, elapsed: 70))
        XCTAssertEqual(atRoundOne.step.kind, .work)
        XCTAssertEqual(atRoundOne.workRound, 1)

        let atRoundTwo = try XCTUnwrap(IntervalEngine.position(in: plan, elapsed: 120))
        XCTAssertEqual(atRoundTwo.step.kind, .work)
        XCTAssertEqual(atRoundTwo.workRound, 2)
    }

    func testFractionCompleteTracksProgressWithinASegment() throws {
        let position = try XCTUnwrap(IntervalEngine.position(in: plan, elapsed: 30))
        XCTAssertEqual(position.step.kind, .warmUp)
        XCTAssertEqual(position.fractionComplete, 0.5, accuracy: 1e-9)
    }

    /// Running past the end of the plan is ordinary. It must not read as "the workout is over" —
    /// the session keeps recording until the person ends it.
    func testPositionIsNilOnceThePlanIsExhausted() {
        XCTAssertNil(IntervalEngine.position(in: plan, elapsed: TimeInterval(plan.totalSeconds)))
        XCTAssertNil(IntervalEngine.position(in: plan, elapsed: 9_999))
    }

    func testTheLastSegmentReportsNoNextStep() throws {
        let position = try XCTUnwrap(IntervalEngine.position(in: plan, elapsed: TimeInterval(plan.totalSeconds - 1)))
        XCTAssertEqual(position.step.kind, .coolDown)
        XCTAssertNil(position.nextStep)
    }

    // MARK: - Transitions

    func testATransitionIsReportedOnlyWhenTheSegmentActuallyChanges() {
        XCTAssertNil(IntervalEngine.transition(in: plan, from: 10, to: 11), "still in the warm-up")

        let crossed = IntervalEngine.transition(in: plan, from: 59, to: 60)
        XCTAssertEqual(crossed?.step.kind, .work, "60s is the first instant of round 1")
    }

    /// The backgrounded case. Away for 45 seconds, the app wakes several segments later — a naive
    /// "did the remaining time hit zero" check would miss every transition in between and could
    /// leave the screen showing a segment that ended long ago.
    func testAGapAcrossSeveralSegmentsReportsTheSegmentThatIsCurrentNow() throws {
        let after = try XCTUnwrap(IntervalEngine.transition(in: plan, from: 62, to: 145))

        let independent = try XCTUnwrap(IntervalEngine.position(in: plan, elapsed: 145))
        XCTAssertEqual(after.stepIndex, independent.stepIndex,
                       "the reported segment is simply the one current at the new time")
        XCTAssertEqual(after.step.kind, independent.step.kind)
    }

    func testNoTransitionIsReportedOnceThePlanIsOver() {
        XCTAssertNil(IntervalEngine.transition(in: plan, from: TimeInterval(plan.totalSeconds - 1),
                                               to: TimeInterval(plan.totalSeconds + 10)))
    }

    // MARK: - Persisted segments

    /// A plan abandoned partway records what actually happened, not what was planned.
    func testOnlyFinishedSegmentsAreRecorded() {
        let started = Date(timeIntervalSince1970: 1_783_000_000)

        // 145s in: warm-up (60) + work (30) + recovery (20) + work (30) = 140 complete; the next
        // recovery is still running.
        let segments = IntervalEngine.completedSegments(in: plan, elapsed: 145, sessionId: "s1",
                                                         startedAt: started, originDeviceId: "dev")

        XCTAssertEqual(segments.map(\.kind), [.warmUp, .work, .recovery, .work])
        XCTAssertEqual(segments.count, 4, "the segment still in progress is not recorded")
        XCTAssertEqual(segments.map(\.seq), [0, 1, 2, 3], "seq matches the plan's own step order")
    }

    func testRecordedSegmentsCarryRealStartAndEndInstants() throws {
        let started = Date(timeIntervalSince1970: 1_783_000_000)
        let segments = IntervalEngine.completedSegments(in: plan, elapsed: 145, sessionId: "s1",
                                                         startedAt: started, originDeviceId: "dev")

        let warmUp = try XCTUnwrap(segments.first)
        XCTAssertEqual(warmUp.startAt, started)
        XCTAssertEqual(warmUp.endAt, started.addingTimeInterval(60))
        XCTAssertEqual(warmUp.durationSeconds, 60)

        let firstWork = segments[1]
        XCTAssertEqual(firstWork.startAt, started.addingTimeInterval(60),
                       "each segment begins exactly where the previous one ended — no gaps")
    }

    /// No adherence grade is invented. With no pace or power on this path there is nothing to
    /// compare against, and a "met target" flag nothing checked would be a fabricated assessment.
    func testSegmentsRecordCompletionNotAnAdherenceVerdict() {
        let segments = IntervalEngine.completedSegments(in: plan, elapsed: 145, sessionId: "s1",
                                                         startedAt: Date(), originDeviceId: "dev")
        XCTAssertTrue(segments.allSatisfy { $0.result == "completed" })
        XCTAssertTrue(segments.allSatisfy { $0.target == nil }, "no target was set, so none is claimed")
    }

    func testNothingIsRecordedForASessionAbandonedInsideTheFirstSegment() {
        let segments = IntervalEngine.completedSegments(in: plan, elapsed: 30, sessionId: "s1",
                                                         startedAt: Date(), originDeviceId: "dev")
        XCTAssertTrue(segments.isEmpty, "the warm-up never finished")
    }
}

/// The storage half — `workout_intervals` finally has a writer (migration 9 created the table in
/// Phase 3C slice 1 and nothing had used it since).
final class WorkoutIntervalRepositoryTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let started = Date(timeIntervalSince1970: 1_783_000_000)

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-intervals-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var repo: WorkoutIntervalRepository { WorkoutIntervalRepository(main: db.main) }

    private func segments() -> [WorkoutInterval] {
        IntervalEngine.completedSegments(
            in: IntervalPlan.hiit(workSeconds: 30, recoverySeconds: 20, rounds: 4,
                                  warmUpSeconds: 60, coolDownSeconds: 60),
            elapsed: 145, sessionId: "session-1", startedAt: started, originDeviceId: "dev")
    }

    func testSegmentsRoundTripInOrder() throws {
        try repo.insertAll(segments())

        let stored = try repo.intervals(sessionId: "session-1")

        XCTAssertEqual(stored.map(\.kind), [.warmUp, .work, .recovery, .work])
        XCTAssertEqual(stored.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(stored.first?.startAt, started)
        XCTAssertEqual(stored.first?.endAt, started.addingTimeInterval(60))
    }

    /// `completedSegments` recomputes the whole completed prefix every call, so writing round 3
    /// necessarily re-offers rounds 1 and 2. Re-inserting must not duplicate them.
    ///
    /// Note that `segments()` builds a FRESH `IntervalPlan` on each call — deliberately, because
    /// that is the case that used to break: segment ids were derived from the plan object's own
    /// step ids, so two plans built from identical numbers produced different ids and wrote eight
    /// rows instead of four. Ids now come from (sessionId, seq), which is a property of the fact
    /// being recorded rather than of the object that happened to describe it.
    func testReinsertingTheSameSegmentsIsIdempotent() throws {
        try repo.insertAll(segments())
        try repo.insertAll(segments())

        XCTAssertEqual(try repo.intervals(sessionId: "session-1").count, 4)
    }

    /// Two different sessions running the identical plan must not collide.
    func testSegmentIdsAreUniquePerSession() throws {
        let planned = IntervalPlan.hiit(workSeconds: 30, recoverySeconds: 20, rounds: 4,
                                        warmUpSeconds: 60, coolDownSeconds: 60)
        try repo.insertAll(IntervalEngine.completedSegments(
            in: planned, elapsed: 145, sessionId: "session-1", startedAt: started, originDeviceId: "dev"))
        try repo.insertAll(IntervalEngine.completedSegments(
            in: planned, elapsed: 145, sessionId: "session-2", startedAt: started, originDeviceId: "dev"))

        XCTAssertEqual(try repo.intervals(sessionId: "session-1").count, 4)
        XCTAssertEqual(try repo.intervals(sessionId: "session-2").count, 4)
    }

    /// I3: a discarded session's segments are tombstoned, never hard-deleted — and they leave the
    /// live view.
    func testTombstonedSegmentsDropOutOfTheLiveRead() throws {
        try repo.insertAll(segments())

        try repo.tombstoneAll(sessionId: "session-1", at: started.addingTimeInterval(500))

        XCTAssertTrue(try repo.intervals(sessionId: "session-1").isEmpty)
        let raw = try db.main.query("SELECT COUNT(*) AS n FROM workout_intervals;").first?.intValue("n")
        XCTAssertEqual(raw, 4, "the rows are still there — tombstoned, not deleted")
    }

    func testSegmentsAreScopedToTheirOwnSession() throws {
        try repo.insertAll(segments())
        XCTAssertTrue(try repo.intervals(sessionId: "a-different-session").isEmpty)
    }
}
