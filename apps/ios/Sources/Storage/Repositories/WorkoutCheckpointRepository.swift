import Foundation

/// Storage for `workout_checkpoints` (migration 9) — the crash-recovery persistence layer behind
/// `WorkoutStateMachine`. This is the ONE table in migration 9 that is UPDATED IN PLACE rather
/// than appended to (see that migration's comment): a live session's checkpoint describes hot,
/// in-progress state for exactly the session currently recording, and every write here has to be
/// cheap enough to call on every tick the plan's "frequent checkpoints, draft always recoverable"
/// requirement (§7A.5) asks for.
///
/// `save` is a plain `INSERT OR REPLACE` keyed on `session_id` (the table's PK) — that replace-on
/// conflict IS the "update in place" this table exists for, the same mechanism
/// `ReadAnchorRepository.setAnchor` already uses for its own single-row-per-key hot state.
/// `clear` is a real `DELETE`, never a tombstone: once a session finalizes into `sessions`, the
/// finalized row is the durable record, and a lingering checkpoint would be actively misleading to
/// a crash-recovery scan that is supposed to mean "something is still live".
final class WorkoutCheckpointRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    private static let columns =
        "session_id, activity_type, state, started_at, state_history, hot_state, last_checkpoint_at, origin_device_id"
    private static let placeholders = "?, ?, ?, ?, ?, ?, ?, ?"

    /// Writes (or overwrites in place) the one checkpoint row for `checkpoint.sessionId`. Safe to
    /// call frequently — a plain `INSERT OR REPLACE` on the PK, no read-before-write, no revision
    /// chain (unlike every append-only table migration 9 also added).
    func save(_ checkpoint: WorkoutCheckpoint) throws {
        try db.run("""
            INSERT OR REPLACE INTO workout_checkpoints (\(Self.columns))
            VALUES (\(Self.placeholders));
            """,
            [.text(checkpoint.sessionId), .text(checkpoint.activityType), .text(checkpoint.state.rawValue),
             .date(checkpoint.startedAt), .text(JSONCoding.encode(checkpoint.stateHistory)),
             .text(JSONCoding.encode(checkpoint.hotState)), .date(checkpoint.lastCheckpointAt),
             .text(checkpoint.originDeviceId)])
    }

    /// The checkpoint for one session, if a live/recoverable one still exists.
    func load(sessionId: String) throws -> WorkoutCheckpoint? {
        try db.query("SELECT * FROM workout_checkpoints WHERE session_id = ?;", [.text(sessionId)])
            .first.flatMap(Self.decode)
    }

    /// Every checkpoint currently on disk, newest first. In normal operation there is at most one
    /// (one live workout at a time), but this is read defensively — a stray second row (e.g. two
    /// crashes in a row before either was resolved) must surface as a recoverable draft too,
    /// never be silently dropped by a caller that only ever looked for one.
    func loadAll() throws -> [WorkoutCheckpoint] {
        try db.query("SELECT * FROM workout_checkpoints ORDER BY last_checkpoint_at DESC;")
            .compactMap(Self.decode)
    }

    /// Deletes the row outright (not a tombstone — see this type's doc). Called once a session
    /// reaches `.persisted` (or the user confirms discarding a `.recoveryDraft`), so a finalized or
    /// abandoned session never lingers as a false "still recording" signal.
    func clear(sessionId: String) throws {
        try db.run("DELETE FROM workout_checkpoints WHERE session_id = ?;", [.text(sessionId)])
    }

    // MARK: - Reader

    private static func decode(_ r: SQLiteRow) -> WorkoutCheckpoint? {
        guard let state = WorkoutLifecycleState(rawValue: r.requireString("state")),
              let stateHistory = JSONCoding.decode([WorkoutStateTransition].self, from: r.string("state_history")),
              let hotState = JSONCoding.decode(WorkoutHotState.self, from: r.string("hot_state"))
        else { return nil }
        return WorkoutCheckpoint(
            sessionId: r.requireString("session_id"), activityType: r.requireString("activity_type"),
            state: state, startedAt: r.requireDate("started_at"), stateHistory: stateHistory,
            hotState: hotState, lastCheckpointAt: r.requireDate("last_checkpoint_at"),
            originDeviceId: r.requireString("origin_device_id"))
    }
}
