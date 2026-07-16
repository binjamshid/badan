import XCTest
@testable import BADAN

/// The `goals` table, `Goal`, and `ProfileRepository`'s goal CRUD have existed since migration
/// v1 with nothing ever reading or writing them from the UI — dead scaffolding on both platforms.
/// These cover the rule that makes the feature mean something, and the round-trip that makes it
/// persist.
final class GoalsTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-goals-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Evaluation

    func testAtLeastIsOnTrackAtOrAboveTarget() {
        XCTAssertEqual(GoalEvaluation.evaluate(value: 8000, target: 8000, direction: .atLeast), .onTrack,
                       "exactly meeting the target must count as met")
        XCTAssertEqual(GoalEvaluation.evaluate(value: 9000, target: 8000, direction: .atLeast), .onTrack)
        XCTAssertEqual(GoalEvaluation.evaluate(value: 7999, target: 8000, direction: .atLeast), .offTrack)
    }

    func testAtMostIsOnTrackAtOrBelowTarget() {
        XCTAssertEqual(GoalEvaluation.evaluate(value: 2000, target: 2000, direction: .atMost), .onTrack)
        XCTAssertEqual(GoalEvaluation.evaluate(value: 1500, target: 2000, direction: .atMost), .onTrack)
        XCTAssertEqual(GoalEvaluation.evaluate(value: 2001, target: 2000, direction: .atMost), .offTrack)
    }

    /// `around` needs a tolerance or it would essentially never match a float.
    func testAroundUsesAProportionalTolerance() {
        // 5% of 25200s (7h) is 1260s (21 min).
        XCTAssertEqual(GoalEvaluation.evaluate(value: 25200, target: 25200, direction: .around), .onTrack)
        XCTAssertEqual(GoalEvaluation.evaluate(value: 26000, target: 25200, direction: .around), .onTrack,
                       "within ~5% above must be on track")
        XCTAssertEqual(GoalEvaluation.evaluate(value: 24000, target: 25200, direction: .around), .onTrack,
                       "within ~5% below must be on track")
        XCTAssertEqual(GoalEvaluation.evaluate(value: 30000, target: 25200, direction: .around), .offTrack)
    }

    /// Proportional, not a fixed epsilon — the same rule has to behave for a 7-hour sleep goal and
    /// an 8000-step one.
    func testAroundToleranceScalesWithTheTarget() {
        // 5% of 8000 is 400; 5% of 300 is 15. The same absolute distance must therefore land on
        // opposite sides of the band depending on the target — that is the whole point of a
        // proportional tolerance rather than a fixed epsilon.
        XCTAssertEqual(GoalEvaluation.evaluate(value: 8300, target: 8000, direction: .around), .onTrack,
                       "300 is inside 5% of 8000")
        XCTAssertEqual(GoalEvaluation.evaluate(value: 600, target: 300, direction: .around), .offTrack,
                       "300 is far outside 5% of 300 — tolerance must scale with the target")
    }

    func testNoReadingIsNoDataRatherThanOffTrack() {
        XCTAssertEqual(GoalEvaluation.evaluate(value: nil, target: 8000, direction: .atLeast), .noData,
                       "a metric with no readings must not be reported as missing the goal — the "
                           + "user hasn't fallen short of anything, BADAN just has nothing to say")
    }

    // MARK: - Persistence

    private func goal(id: String = "g1", metricId: String = MetricID.steps, target: Double = 8000,
                      direction: GoalDirection = .atLeast, active: Bool = true) -> Goal {
        Goal(id: id, metricId: metricId, target: target, unit: "count",
             direction: direction, active: active, createdAt: clock.now())
    }

    func testGoalRoundTripsThroughTheRepository() throws {
        let repo = ProfileRepository(db.main)
        try repo.upsertGoal(goal())

        let stored = try repo.goals()
        XCTAssertEqual(stored.count, 1)
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.metricId, MetricID.steps)
        XCTAssertEqual(row.target, 8000)
        XCTAssertEqual(row.direction, .atLeast)
        XCTAssertTrue(row.active)
    }

    func testUpsertingTheSameGoalIdUpdatesRatherThanDuplicates() throws {
        let repo = ProfileRepository(db.main)
        try repo.upsertGoal(goal(target: 8000))
        try repo.upsertGoal(goal(target: 10000, direction: .atMost))

        let stored = try repo.goals()
        XCTAssertEqual(stored.count, 1, "editing a goal must not leave the old one behind")
        XCTAssertEqual(stored.first?.target, 10000)
        XCTAssertEqual(stored.first?.direction, .atMost)
    }

    func testPausedGoalIsPersistedAsInactiveAndStillReadable() throws {
        let repo = ProfileRepository(db.main)
        try repo.upsertGoal(goal(active: false))

        let stored = try XCTUnwrap(try repo.goals().first)
        XCTAssertFalse(stored.active, "pausing must survive a round trip — it is not a delete")
    }

    func testDeletingAGoalRemovesOnlyThatGoal() throws {
        let repo = ProfileRepository(db.main)
        try repo.upsertGoal(goal(id: "g1"))
        try repo.upsertGoal(goal(id: "g2", metricId: MetricID.weight))

        try repo.deleteGoal(id: "g1")

        let stored = try repo.goals()
        XCTAssertEqual(stored.map(\.id), ["g2"])
    }

    /// Goals survive "connect Apple Health" — they are the user's own intentions, not ingested
    /// data, and `purgeIngestedData` must not touch them (the same principle as F2's manual logs).
    func testGoalsSurviveConnectingAHealthSource() throws {
        let repo = ProfileRepository(db.main)
        try repo.upsertGoal(goal())

        try db.purgeIngestedData()

        XCTAssertEqual(try repo.goals().count, 1,
                       "a goal is something the user decided, not something a source delivered")
    }
}
