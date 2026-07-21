import XCTest
@testable import BADAN

/// EPIC-42 (plan §7A.5 / §9.18, migration 9) — `WorkoutCheckpointRepository`'s round trip through
/// real SQLite. `WorkoutStateMachineTests` covers the state machine in isolation; this file covers
/// the one thing that only a real database can prove: that a `WorkoutCheckpoint` (including its
/// JSON-encoded `stateHistory`/`hotState`) survives `save` → `load` byte-for-byte, and that `save`
/// genuinely updates in place rather than accumulating rows (the one exception to append-only
/// migration 9 documents).
final class WorkoutCheckpointRepositoryTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    var repo: WorkoutCheckpointRepository!
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-workout-checkpoint-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
        repo = WorkoutCheckpointRepository(db.main)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleCheckpoint(sessionId: String = "s1") -> WorkoutCheckpoint {
        WorkoutCheckpoint(
            sessionId: sessionId, activityType: "cycling", state: .manuallyPaused, startedAt: base,
            stateHistory: [
                WorkoutStateTransition(state: .idle, at: base),
                WorkoutStateTransition(state: .preparing, at: base.addingTimeInterval(1)),
                WorkoutStateTransition(state: .active, at: base.addingTimeInterval(4)),
                WorkoutStateTransition(state: .manuallyPaused, at: base.addingTimeInterval(304),
                                      note: "user tapped pause"),
            ],
            hotState: WorkoutHotState(degradedConditions: [.sensorDegraded, .lowBattery],
                                      stateBeforeInterruption: .active, activeSeconds: 300, pausedSeconds: 0),
            lastCheckpointAt: base.addingTimeInterval(310), originDeviceId: "device-a")
    }

    /// The core crash-recovery contract: everything written comes back exactly, including the
    /// JSON-encoded history and hot-state blob.
    func testSaveThenLoadRoundTripsExactly() throws {
        let checkpoint = sampleCheckpoint()
        try repo.save(checkpoint)

        let loaded = try XCTUnwrap(repo.load(sessionId: "s1"))
        XCTAssertEqual(loaded, checkpoint)
    }

    func testLoadReturnsNilWhenNoCheckpointExists() throws {
        XCTAssertNil(try repo.load(sessionId: "does-not-exist"))
    }

    /// `save` on the SAME session id must overwrite in place — the PK on `session_id` is what
    /// makes this table the one exception to append-only, and a second write must never leave two
    /// rows behind.
    func testSaveOverwritesInPlaceRatherThanAccumulating() throws {
        try repo.save(sampleCheckpoint())

        var updated = sampleCheckpoint()
        updated.state = .active
        updated.hotState.activeSeconds = 500
        updated.lastCheckpointAt = base.addingTimeInterval(500)
        try repo.save(updated)

        let all = try repo.loadAll()
        XCTAssertEqual(all.count, 1, "A second save for the same session must replace, not append")
        let onlyRow = try XCTUnwrap(all.first)
        XCTAssertEqual(onlyRow.state, .active)
        XCTAssertEqual(onlyRow.hotState.activeSeconds, 500, accuracy: 0.001)
    }

    /// `clear` is a real DELETE — the row must be gone outright, not merely tombstoned, matching
    /// migration 9's doc for why this table alone has no `deleted_at`.
    func testClearDeletesTheRowOutright() throws {
        try repo.save(sampleCheckpoint())
        try repo.clear(sessionId: "s1")

        XCTAssertNil(try repo.load(sessionId: "s1"))
        XCTAssertTrue(try repo.loadAll().isEmpty)
    }

    /// `loadAll` is the defensive read a recovery-scan-on-launch calls: it must surface every
    /// stray checkpoint, not just the first one found.
    func testLoadAllReturnsEveryCheckpointNewestFirst() throws {
        var older = sampleCheckpoint(sessionId: "s-older")
        older.lastCheckpointAt = base
        var newer = sampleCheckpoint(sessionId: "s-newer")
        newer.lastCheckpointAt = base.addingTimeInterval(100)

        try repo.save(older)
        try repo.save(newer)

        let all = try repo.loadAll()
        XCTAssertEqual(all.map(\.sessionId), ["s-newer", "s-older"])
    }

    /// A machine's own `checkpoint()` snapshot must persist and reload into an equivalent machine
    /// (the actual end-to-end path a real adapter drives), not just a hand-built fixture.
    func testMachineCheckpointPersistsAndRestoresACrashedSession() throws {
        let clock = FixedClock(base)
        let machine = WorkoutStateMachine(sessionId: "s1", activityType: "running", clock: clock)
        _ = try machine.apply(.begin)
        _ = try machine.apply(.countdownFinished)
        clock.advance(by: 120)

        try repo.save(machine.checkpoint(originDeviceId: "device-a"))

        clock.advance(by: 999)   // the process is dead for a while
        let loaded = try XCTUnwrap(repo.load(sessionId: "s1"))
        let recovered = WorkoutStateMachine(restoringFrom: loaded, clock: clock)

        XCTAssertEqual(recovered.state, .recoveryDraft)
        XCTAssertEqual(recovered.accumulatedActiveSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(try recovered.apply(.resumeFromRecovery), .active)
    }
}
