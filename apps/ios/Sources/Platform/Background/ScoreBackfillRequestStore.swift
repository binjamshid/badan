import Foundation

/// A durable "re-derive scores over this window" request — the trigger side of the EPIC-26
/// HR-max/zone-edit backfill (editing the max changes every effort score, so the whole window must
/// be re-derived). Mirrors `BackgroundCheckpointStore`: a small marker in `UserDefaults`, written by
/// the composition root when the edit lands and read at the head of a `BGProcessingTask`'s
/// score-backfill step.
///
/// It stores a WINDOW (not a bare flag) so the job knows exactly what to re-derive and can be
/// reasoned about — as epoch-millis, the same representation the run log uses. Cleared only after the
/// backfill completes, so an interrupted run (an expired BGTask) re-runs the whole window on the next
/// wake — which is safe precisely because derivation is append-only and skip-if-identical (I2): a
/// re-run appends nothing for the days it already wrote.
final class ScoreBackfillRequestStore {
    private let defaults: UserDefaults
    private static let fromKey = "badan.background.scoreBackfillFromMillis"
    private static let toKey = "badan.background.scoreBackfillToMillis"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Queue a backfill over `[from, to]`. A second request arriving before the first has run WIDENS
    /// the window to the union of the two, so two quick edits collapse into one job that covers both
    /// rather than the later one narrowing the earlier one's range.
    func request(from: Date, to: Date) {
        let existing = pending()
        let unionFrom = min(from, existing?.from ?? from)
        let unionTo = max(to, existing?.to ?? to)
        defaults.set(Int(unionFrom.epochMillis), forKey: Self.fromKey)
        defaults.set(Int(unionTo.epochMillis), forKey: Self.toKey)
    }

    /// The queued window, or `nil` when nothing is pending. `from`/`to` are only read when BOTH keys
    /// are present, so a half-written marker reads as "nothing pending" rather than an epoch-0 window.
    func pending() -> (from: Date, to: Date)? {
        guard defaults.object(forKey: Self.fromKey) != nil,
              defaults.object(forKey: Self.toKey) != nil else { return nil }
        let from = Date(epochMillis: Int64(defaults.integer(forKey: Self.fromKey)))
        let to = Date(epochMillis: Int64(defaults.integer(forKey: Self.toKey)))
        return (from, to)
    }

    /// Clear the request. Called only after the backfill actually completed — never at the head of a
    /// run, so an interrupted run's window survives to the next wake.
    func clear() {
        defaults.removeObject(forKey: Self.fromKey)
        defaults.removeObject(forKey: Self.toKey)
    }
}
