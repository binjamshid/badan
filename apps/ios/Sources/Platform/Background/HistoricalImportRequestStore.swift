import Foundation

/// A durable "fetch Health history over this window" request, with a resume cursor (D-35 item 2b).
///
/// Mirrors `ScoreBackfillRequestStore`'s discipline exactly — a small marker in `UserDefaults`,
/// window as epoch-millis, both-keys-or-nothing so a half-written marker reads as "nothing pending"
/// rather than an epoch-0 window, and cleared only after the work has actually finished.
///
/// The one addition is `completedThrough`, and it is the reason this is a separate type rather than
/// a second `ScoreBackfillRequestStore`. That store deliberately has no cursor: re-running a score
/// backfill from scratch is cheap and idempotent, so an interrupted run simply redoes the window.
/// A historical fetch is not cheap — it is one HealthKit query per type per month, potentially over
/// years — so an interrupted import must resume where it stopped rather than re-querying everything
/// it already has. The rows themselves are still idempotent (upsert by
/// `(metric_id, external_id, source_id)`), so the cursor is a performance guarantee, not a
/// correctness one; losing it costs time, never data.
///
/// `completedThrough` is written after each month is BOTH fetched and written, never before, so a
/// crash mid-chunk re-fetches that chunk rather than skipping it.
final class HistoricalImportRequestStore {
    private let defaults: UserDefaults
    private static let fromKey = "badan.background.historicalImportFromMillis"
    private static let toKey = "badan.background.historicalImportToMillis"
    private static let cursorKey = "badan.background.historicalImportCompletedThroughMillis"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Queue an import over `[from, to]`.
    ///
    /// Unlike `ScoreBackfillRequestStore.request`, this REPLACES any pending window rather than
    /// unioning with it, and resets the cursor. Two score-backfill requests are two consequences of
    /// edits and should collapse into one covering job; two history requests are two deliberate user
    /// choices, and the second is a correction of the first. Unioning them would silently fetch a
    /// range the user did not ask for the moment they narrowed their mind.
    func request(from: Date, to: Date) {
        defaults.set(Int(from.epochMillis), forKey: Self.fromKey)
        defaults.set(Int(to.epochMillis), forKey: Self.toKey)
        defaults.removeObject(forKey: Self.cursorKey)
    }

    /// The queued window, or `nil` when nothing is pending.
    func pending() -> (from: Date, to: Date)? {
        guard defaults.object(forKey: Self.fromKey) != nil,
              defaults.object(forKey: Self.toKey) != nil else { return nil }
        return (Date(epochMillis: Int64(defaults.integer(forKey: Self.fromKey))),
                Date(epochMillis: Int64(defaults.integer(forKey: Self.toKey))))
    }

    /// The high-water mark: everything at or before this instant has been fetched AND written.
    /// `nil` means no chunk has completed yet, so a resume starts at the window's `from`.
    func completedThrough() -> Date? {
        guard defaults.object(forKey: Self.cursorKey) != nil else { return nil }
        return Date(epochMillis: Int64(defaults.integer(forKey: Self.cursorKey)))
    }

    /// Record that everything through `date` is done. Monotonic: an out-of-order or stale write
    /// cannot move the cursor backwards and cause a re-fetch of work already finished.
    func markCompleted(through date: Date) {
        if let existing = completedThrough(), existing >= date { return }
        defaults.set(Int(date.epochMillis), forKey: Self.cursorKey)
    }

    /// Where a run should start: just after the cursor, or the window's start if there is none.
    /// `nil` when nothing is pending, or when the cursor has already reached the window's end.
    func resumePoint() -> (from: Date, to: Date)? {
        guard let window = pending() else { return nil }
        guard let cursor = completedThrough() else { return window }
        guard cursor < window.to else { return nil }
        return (cursor, window.to)
    }

    /// Clear the request and its cursor. Called only after the fetch AND the derivation that
    /// follows it have both completed — clearing after the fetch alone would leave imported months
    /// unscored with nothing left to say they need scoring.
    func clear() {
        defaults.removeObject(forKey: Self.fromKey)
        defaults.removeObject(forKey: Self.toKey)
        defaults.removeObject(forKey: Self.cursorKey)
    }
}
