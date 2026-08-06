import Foundation

/// One recorded submission: exactly what left the device, when it last left, and how it ended.
struct RecordedSubmission: Codable, Hashable, Sendable, Identifiable {
    /// How far a submission got.
    ///
    /// Three states rather than two, because "we do not know" is a real outcome and rounding it to
    /// either neighbour is a lie in one direction or the other: a request whose response never
    /// arrived may well have landed, so calling it rejected would understate what left the device,
    /// and calling it confirmed would claim an acceptance nobody saw.
    enum State: String, Codable, Hashable, Sendable {
        /// Written before the request left and never reconciled — still in flight, or the process
        /// was suspended before the answer came back, or the transport failed with no response at
        /// all. The bytes may or may not have arrived.
        case pending
        /// The server answered 2xx. This batch is in the aggregate.
        case confirmed
        /// The server answered and refused it (an unknown attestation key, a replayed assertion, a
        /// rate limit). Nothing was stored on the other end, so this is NOT something that has been
        /// sent in the sense the transparency screen means — see `all()`.
        case rejected
    }

    let id: String
    /// When BADAN last tried to send it. A local timestamp on the user's own device, which is a
    /// different thing from a timestamp in the payload — the payload carries none, and the server
    /// records only a date. This exists so the user can see "you sent this on Tuesday".
    let sentAt: Date
    /// The batch verbatim. Stored as the payload type rather than as rendered text, so the screen
    /// shows what was actually encoded rather than a description someone wrote of it.
    let batch: FootprintBatch
    let state: State
    /// How many times this same batch has been attempted.
    ///
    /// Retries update this entry rather than appending a new one. Before that, a permanently
    /// failing submission wrote a fresh "sent" record on every background wake, without bound —
    /// the screen filled with copies of one batch that had in fact never been accepted once.
    let attempts: Int

    init(id: String, sentAt: Date, batch: FootprintBatch, state: State, attempts: Int) {
        self.id = id
        self.sentAt = sentAt
        self.batch = batch
        self.state = state
        self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey {
        case id, sentAt, batch, state, attempts
    }

    /// Decoded by hand so a log written by an older build still reads.
    ///
    /// Builds up to v1.1(5) stored entries with neither `state` nor `attempts`, and `all()` decodes
    /// the whole array or nothing — a synthesised initialiser would throw on the first legacy entry
    /// and silently empty the user's own record of what was sent, which is the one thing this log
    /// exists to keep. A legacy entry resolves to `.pending`: it was written before its request
    /// left and nothing ever reconciled it, so "we do not know" is precisely true of it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        batch = try container.decode(FootprintBatch.self, forKey: .batch)
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .pending
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 1
    }
}

/// Write side of the log, as `FootprintClient` needs it: one call before the request leaves and one
/// to reconcile it against what came back.
protocol SubmissionLogWriting: Sendable {
    /// Record an attempt that is ABOUT to leave, returning the id its outcome is reconciled by.
    /// Re-attempting a batch already in the log updates that entry instead of adding another.
    @discardableResult
    func recordAttempt(_ batch: FootprintBatch) -> String
    /// The server answered 2xx.
    func confirm(_ id: String)
    /// The server answered and refused it.
    func reject(_ id: String)
}

/// A local, verbatim record of every telemetry submission (ADR-0011 / D-37).
///
/// This is the anti-dark-pattern move, and it only works if it is verbatim: the "What has been
/// sent" screen renders the stored `FootprintBatch` as JSON, so a user reads precisely what left
/// their device rather than a reassuring summary of it. A description could drift from the payload;
/// the payload cannot drift from itself.
///
/// `UserDefaults` rather than SQLite: this is a small, bounded, non-health record that must survive
/// a database purge — "what did BADAN send" should remain answerable after someone clears their
/// health data, because the two are different questions.
///
/// ## Why an attempt is written before the request and reconciled after
///
/// Both orderings lose something on their own. Writing only after a success means a log write lost
/// to a process kill leaves the user's record less complete than what actually left the device.
/// Writing only before means a refused batch is reported as sent — which is what shipped, and under
/// a permanent server-side rejection it re-wrote that phantom on every background wake, unbounded.
/// So the attempt is written first (nothing that left can go unrecorded) and its state is corrected
/// from the response (nothing that was refused is claimed as sent).
struct SubmissionLog: SubmissionLogWriting {
    private let defaults: UserDefaults
    private static let key = "badan.telemetry.submissionLog"

    /// Bounded so the log cannot grow without limit. At a randomised 24-72h cadence this is
    /// roughly two years of submissions, which is longer than the server's own 400-day retention —
    /// so the user's copy outlives BADAN's.
    static let maxEntries = 400

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func recordAttempt(_ batch: FootprintBatch) -> String {
        var entries = allIncludingRejected()
        // Keyed by content, not by a handle held in memory: a retry after a process restart is the
        // ordinary case here (the scheduler is durable, the client is not), and it must land on the
        // same entry.
        if let index = entries.firstIndex(where: { $0.batch == batch && $0.state != .confirmed }) {
            let existing = entries.remove(at: index)
            entries.insert(RecordedSubmission(id: existing.id, sentAt: Date(), batch: batch,
                                              state: .pending, attempts: existing.attempts + 1),
                           at: 0)
            save(entries)
            return existing.id
        }
        let fresh = RecordedSubmission(id: UUID().uuidString, sentAt: Date(), batch: batch,
                                       state: .pending, attempts: 1)
        entries.insert(fresh, at: 0)
        save(entries)
        return fresh.id
    }

    func confirm(_ id: String) { reconcile(id, to: .confirmed) }

    func reject(_ id: String) { reconcile(id, to: .rejected) }

    /// What the "What has been sent" screen shows: newest first, and everything that either landed
    /// or may have.
    ///
    /// Refused submissions are excluded rather than deleted. Excluded because the server answered
    /// and stored nothing, so listing one under that heading would claim a transmission the user
    /// can act on when there is none; kept because deleting the device's own record of an attempt
    /// is not this type's call to make, and `allIncludingRejected()` is one line away for anything
    /// that wants the whole picture.
    ///
    /// Empty when nothing has ever been sent, which is the state of every install that never opted
    /// in — and the screen says exactly that rather than implying data is hidden.
    func all() -> [RecordedSubmission] {
        allIncludingRejected().filter { $0.state != .rejected }
    }

    /// Every entry, refusals included. The stored truth, before any presentation decision.
    func allIncludingRejected() -> [RecordedSubmission] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([RecordedSubmission].self, from: data)
        else { return [] }
        return entries
    }

    /// Clearing the log does NOT unsend anything, and the surface says so. It is offered because a
    /// user who turns telemetry off may reasonably not want a local record of it either.
    func clear() { defaults.removeObject(forKey: Self.key) }

    private func reconcile(_ id: String, to state: RecordedSubmission.State) {
        var entries = allIncludingRejected()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let existing = entries[index]
        entries[index] = RecordedSubmission(id: existing.id, sentAt: existing.sentAt,
                                            batch: existing.batch, state: state,
                                            attempts: existing.attempts)
        save(entries)
    }

    private func save(_ entries: [RecordedSubmission]) {
        let bounded = entries.count > Self.maxEntries
            ? Array(entries.prefix(Self.maxEntries)) : entries
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
