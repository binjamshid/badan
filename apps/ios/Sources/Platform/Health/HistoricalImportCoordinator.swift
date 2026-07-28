import Foundation

/// How far a historical import has got, for the screen watching it.
///
/// Copies `AppleHealthImportProgress`'s phase-enum-plus-callback shape rather than inventing a
/// second progress vocabulary for the same kind of work.
struct HistoricalImportProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case probing
        /// Month `index` of `total`, 1-based.
        case fetching(index: Int, total: Int)
        case deriving
        case done
    }
    var phase: Phase
    /// DTOs Health handed over, across every chunk so far. Tracked SEPARATELY from `written`
    /// because the difference between them is the whole of the honesty story: zero DTOs means
    /// Health returned nothing (and BADAN cannot know whether that is "no data then" or "no
    /// permission"), whereas DTOs with nothing written means "already up to date".
    var dtosReturned: Int = 0
    var written: Int = 0
}

/// What a finished import can honestly say. Three outcomes, never conflated.
enum HistoricalImportOutcome: Sendable, Equatable {
    /// Health handed over nothing at all for the window. Deliberately does NOT claim to know why:
    /// HealthKit never tells an app that a READ was denied (only whether the sheet completed), so
    /// "no data was recorded then" and "BADAN was not granted these types" are indistinguishable
    /// from here. The copy says so.
    case nothingReturned
    /// Rows came back and every one of them was already stored — the summary was all zeros. This is
    /// what a re-import looks like, and it is a success.
    case alreadyUpToDate
    case imported(written: Int)
    /// Stopped by the user. Whatever was fetched is kept and scored; the window is truncated to
    /// what completed.
    case cancelled(written: Int)
    case failed(message: String)
}

/// Walks a historical window month by month, oldest first, through the ordinary ingestion pipeline.
///
/// ## Why one calendar month per `ingest()` call
///
/// `IngestionPipeline.ingest` phase 1 buffers every DTO for its range in memory before opening a
/// write transaction. That is the real reason a five-year single call is wrong — not query cost.
/// A month is small enough to buffer comfortably and large enough that a decade is ~120 calls.
///
/// Oldest→newest matches `DerivationCoordinator.backfill`'s resume idiom and lets one high-water
/// mark express all progress: everything before the cursor is done, everything after is not.
///
/// ## Idempotency
///
/// Upsert identity is `(metric_id, external_id, source_id)` with `ON CONFLICT … DO UPDATE`, and the
/// historical reader emits the same external ids as the anchored path (see `HKSampleMapping`), so a
/// re-import returns an all-zero summary rather than doubling rows. The `DO UPDATE SET` column list
/// excludes `ingestion_path` and `batch_id`, so re-importing over rows an archive import wrote
/// refreshes their values without stealing their batch lineage — which is what keeps `undo(batchId:)`
/// coherent, and why this path offers no undo of its own.
///
/// ## No undo, deliberately
///
/// This is platform-store data: re-import is idempotent and removal is the existing disconnect
/// purge. Wiring it as a batch import to gain an undo would poison the well — an overlap-reimport
/// cannot restamp existing rows' batch ids, so "undo" would take back an unpredictable subset.
struct HistoricalImportCoordinator {
    let pipeline: IngestionPipeline
    let derivation: DerivationCoordinator
    let requests: HistoricalImportRequestStore
    let tz: String

    /// Runs the pending import to completion (or to cancellation), then derives over what landed.
    ///
    /// - Parameter isCancelled: checked between chunks, the same seam `AppleHealthArchiveImporter`
    ///   uses. Cancelling keeps every month already ingested, truncates the window to the cursor,
    ///   and STILL runs derivation — otherwise the fetched months would sit unscored, which is a
    ///   worse state than not having imported them.
    func run(makeReader: () -> HealthStorePort,
             isCancelled: () -> Bool = { false },
             progress: (HistoricalImportProgress) -> Void = { _ in }) -> HistoricalImportOutcome {
        guard let window = requests.resumePoint() else { return .alreadyUpToDate }

        let months = Self.monthChunks(from: window.from, to: window.to, tz: tz)
        guard !months.isEmpty else {
            requests.clear()
            return .nothingReturned
        }

        var state = HistoricalImportProgress(phase: .probing)
        progress(state)

        var written = 0
        var dtos = 0
        var cancelled = false

        for (index, chunk) in months.enumerated() {
            if isCancelled() { cancelled = true; break }
            state.phase = .fetching(index: index + 1, total: months.count)
            progress(state)

            // Counting decorator rather than a second pass: `ingest` reads every DTO in its own
            // phase 1, so asking the store separately would double the HealthKit round trips for
            // every chunk. This observes the reads the pipeline already makes.
            let reader = CountingHealthStore(wrapping: makeReader())
            let range = HealthDateRange(start: chunk.start, end: chunk.end)

            do {
                let summary = try pipeline.ingest(from: reader, range: range, origin: .liveSync)
                // Tracked separately from `written` because the difference IS the honesty story:
                // zero DTOs means Health handed over nothing, whereas DTOs with nothing written
                // means everything was already stored.
                dtos += reader.dtosReturned
                state.dtosReturned = dtos
                written += summary.totalWritten
                state.written = written
            } catch {
                // The cursor is not advanced, so a resume re-fetches this month.
                return .failed(message: String(describing: error))
            }

            // Only now, after both the fetch and the write have succeeded for this month.
            requests.markCompleted(through: chunk.end)
            progress(state)
        }

        // Derivation runs whether or not the walk completed — see `isCancelled`'s doc.
        state.phase = .deriving
        progress(state)
        // `to:` is NOW, not the window's end: a 2019 import shifts the baselines today's scores are
        // read against, so stopping at the imported window would leave today computed against a
        // history that no longer matches what is stored.
        _ = try? derivation.backfill(from: window.from, to: Date(), tz: tz)

        state.phase = .done
        progress(state)

        if cancelled { return .cancelled(written: written) }
        requests.clear()
        if dtos == 0 { return .nothingReturned }
        return written == 0 ? .alreadyUpToDate : .imported(written: written)
    }

    /// `[from, to]` split into calendar months, oldest first, clamped to the window at both ends.
    ///
    /// Stepped with `DayAttribution`'s calendar rather than by adding 30 days, so a multi-year walk
    /// neither drifts across DST nor mis-sizes February.
    static func monthChunks(from: Date, to: Date, tz: String) -> [(start: Date, end: Date)] {
        guard from < to else { return [] }
        let cal = DayAttribution.calendar(tz: tz)
        var out: [(start: Date, end: Date)] = []
        var cursor = from
        while cursor < to {
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: cursor)) ?? cursor
            let next = cal.date(byAdding: .month, value: 1, to: monthStart) ?? to
            let chunkEnd = min(next, to)
            // `max` keeps the first chunk starting at the window's own start rather than at the
            // start of that month, so an import never quietly widens the range the user chose.
            out.append((start: max(cursor, from), end: chunkEnd))
            guard chunkEnd > cursor else { break }
            cursor = chunkEnd
        }
        return out
    }
}
