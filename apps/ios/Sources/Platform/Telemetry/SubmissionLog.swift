import Foundation

/// One recorded submission: exactly what left the device, and when.
struct RecordedSubmission: Codable, Hashable, Sendable, Identifiable {
    let id: String
    /// When BADAN sent it. A local timestamp on the user's own device, which is a different thing
    /// from a timestamp in the payload — the payload carries none, and the server records only a
    /// date. This exists so the user can see "you sent this on Tuesday".
    let sentAt: Date
    /// The batch verbatim. Stored as the payload type rather than as rendered text, so the screen
    /// shows what was actually encoded rather than a description someone wrote of it.
    let batch: FootprintBatch
}

protocol SubmissionLogWriting: Sendable {
    func record(_ batch: FootprintBatch)
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
struct SubmissionLog: SubmissionLogWriting {
    private let defaults: UserDefaults
    private static let key = "badan.telemetry.submissionLog"

    /// Bounded so the log cannot grow without limit. At a randomised 24-72h cadence this is
    /// roughly two years of submissions, which is longer than the server's own 400-day retention —
    /// so the user's copy outlives BADAN's.
    static let maxEntries = 400

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(_ batch: FootprintBatch) {
        var entries = all()
        entries.insert(RecordedSubmission(id: UUID().uuidString, sentAt: Date(), batch: batch), at: 0)
        if entries.count > Self.maxEntries { entries = Array(entries.prefix(Self.maxEntries)) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Newest first. Empty when nothing has ever been sent, which is the state of every install
    /// that never opted in — and the screen says exactly that rather than implying data is hidden.
    func all() -> [RecordedSubmission] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([RecordedSubmission].self, from: data)
        else { return [] }
        return entries
    }

    /// Clearing the log does NOT unsend anything, and the surface says so. It is offered because a
    /// user who turns telemetry off may reasonably not want a local record of it either.
    func clear() { defaults.removeObject(forKey: Self.key) }
}
