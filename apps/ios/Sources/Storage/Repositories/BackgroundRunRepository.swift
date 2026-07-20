import Foundation

// MARK: - Domain (plan §9.8 `BackgroundRun`)
//
// These types live in this file rather than under `Sources/Domain/` because `BackgroundRun` is
// not a health entity: it carries no provenance, no measured value, and no metric id, and I1/I5
// have nothing to say about it. It is substrate telemetry about BADAN's own scheduling — the
// same category of thing as `ExportRun` — and it is only ever read back by Diagnostics and the
// soak runbook. Keeping it next to its one repository keeps `Domain/` meaning "the canonical
// health model" rather than "every struct we persist".

/// What woke BADAN (plan §9.8 `kind`).
///
/// `workManagerPeriodic` is Android's and is deliberately present here even though iOS never
/// writes it: migration v4 declares one `background_runs` table shape for both platforms so a
/// cross-platform fixture can diff two devices' run logs column-for-column, and an enum that
/// silently can't represent the other platform's rows would make that diff impossible the first
/// time anyone tried it.
enum BackgroundRunKind: String, Codable, CaseIterable {
    /// An `HKObserverQuery` fired: "something changed", never a payload (plan §13.3).
    case hkObserverWake
    /// `BGAppRefreshTask` — light top-up (`net.albayyan.badan.refresh`).
    case bgAppRefresh
    /// `BGProcessingTask` — heavy, checkpointed work (`net.albayyan.badan.processing`).
    case bgProcessing
    /// Android only. iOS never writes this; see the type doc.
    case workManagerPeriodic
    /// The app was opened and `syncIfStale()` ran. Recorded so Diagnostics can distinguish
    /// "background never fires on this device" from "nothing ever syncs at all".
    case foregroundSync
}

/// How a run ended (plan §9.8 `outcome`).
enum BackgroundRunOutcome: String, Codable, CaseIterable {
    /// Work ran to completion. Zero counts is still `completed` — "nothing changed" is a
    /// successful outcome, not a failure.
    case completed
    /// The OS reclaimed the task before the work finished. The expiration handler checkpointed
    /// and exited cleanly; the next run resumes. See `BackgroundCheckpointStore`.
    case expired
    /// The HealthKit store was unreadable because the device was locked.
    ///
    /// **This is not a failure.** It is iOS Data Protection working exactly as designed: some
    /// HealthKit data is `.complete`-class and simply is not readable while the device is locked,
    /// so a wake that lands in that window has nothing it can legitimately read. The correct
    /// response is to record this and wait for the next wake — never to retry in a loop, never
    /// to surface it to the user as an error, and never to count it against anything. A future
    /// reader will be tempted to "fix" this by escalating it; don't.
    case storeLocked
    /// A run was skipped because another ingest was already in flight (see
    /// `BackgroundIngestBridge`'s lock). Also not a failure — the in-flight run does the work.
    case throttled
    /// The work threw. The error itself is deliberately not persisted: a thrown SQLite/HealthKit
    /// error can carry row content in its message, and this table is value-free by contract.
    ///
    /// BUG-BG-01 gave this case a second meaning: a `BGTaskScheduler.submit(_:)` that was
    /// *declined*, where no work ran at all. The two are told apart by shape, not by outcome — a
    /// declined submit has `durationMs == 0` and `workDone == nil`, and its cause is in the OSLog
    /// line from `BackgroundCoordinator.recordSubmitDecline`. It is folded in here rather than
    /// given a sixth case because this enum is the cross-platform contract Android mirrors (plan
    /// §9.8), and because `error` carries the right severity: the soak passes only at `error = 0`,
    /// and a build that cannot schedule its own background work is not passing anything.
    case error

    /// Plan §13.3 and ADR-0009 §A2 call this outcome `skippedLocked` in prose, while §9.8's
    /// entity spec — the cross-platform schema contract Android mirrors — names it `storeLocked`.
    /// They are the same outcome. The persisted value follows §9.8 so the two platforms' rows
    /// diff cleanly; this alias exists so code written against the prose name still resolves to
    /// the one canonical case instead of someone quietly adding a sixth outcome.
    static let skippedLocked = BackgroundRunOutcome.storeLocked
}

/// What a background run actually did — **counts only, never values** (plan §9.8: "workDone JSON
/// (counts only)").
///
/// Deliberately a struct of `Int` fields rather than a `[String: Any]` or `[String: Double]` bag.
/// The type is the enforcement: there is no field a health reading could be assigned to, so
/// "42 samples" can be logged and "42 bpm" cannot be, and that stays true without anyone having
/// to remember the rule at each call site.
/// `BackgroundSubstrateTests.testWorkDoneJSONContainsOnlyIntegerCounts` asserts the encoded JSON
/// contains only integers, which is the same rule stated where it can actually fail. (That
/// pointer previously named a `BackgroundRunRepositoryTests` class that has never existed —
/// a citation to a non-existent test reads as coverage and is worse than no citation at all.)
struct BackgroundWorkCounts: Codable, Equatable {
    var samples: Int = 0
    var intervals: Int = 0
    var sessions: Int = 0
    /// Rows dedup marked suppressed this run (I3 — suppressed, never deleted).
    var suppressed: Int = 0
    /// Days of insights regenerated.
    var insightDays: Int = 0
    /// `background_runs` rows dropped by the 90-day prune.
    var pruned: Int = 0
    /// Due automations evaluated. Always 0 until EPIC-15 lands its `AutomationSchedule`
    /// evaluator; the field is here now so the JSON shape does not change under the first
    /// device that has already written a fortnight of rows.
    var automationsEvaluated: Int = 0

    var isEmpty: Bool { self == BackgroundWorkCounts() }
}

/// One substrate-level run (plan §9.8). Append-only and device-local: rows are never updated
/// after insert and never merged across devices — a run log describes what happened on *this*
/// phone, and importing another device's would produce a history the user never observed here.
struct BackgroundRun: Equatable {
    var id: String
    var kind: BackgroundRunKind
    var startedAt: Date
    var durationMs: Int?
    var outcome: BackgroundRunOutcome
    var workDone: BackgroundWorkCounts?
    /// How long after an `HKObserverQuery` wake BADAN called HealthKit's completion handler.
    ///
    /// This is the whole reason the column exists. HealthKit silently disables background
    /// delivery for an app after 3 wakes where the handler is not called promptly, tells the app
    /// nothing, and offers no way to detect or reverse it — the feature just stops working in the
    /// field. Recording the latency on every wake is the only way that budget is ever measurable.
    /// `nil` for every kind except `hkObserverWake`, which is why the column is nullable.
    var completionHandlerCalledInMs: Int?
}

/// The value-free rollup Diagnostics and the soak runbook read (see `docs/runbooks/
/// background-soak.md`). Counts, durations and enum labels only — nothing here can carry a
/// health reading, which is what makes the diagnostics report safe to paste into a support
/// message unweighed.
struct BackgroundHealthSummary: Equatable {
    /// One outcome and how often it occurred. A named struct rather than a labeled tuple so
    /// `Equatable` synthesizes and tests can compare summaries whole.
    struct OutcomeCount: Equatable {
        var outcome: BackgroundRunOutcome
        var count: Int
    }

    var windowDays: Int
    var totalRuns: Int
    var lastRunAt: Date?
    var lastRunKind: BackgroundRunKind?
    var lastRunOutcome: BackgroundRunOutcome?
    /// Runs per outcome over the window, in `BackgroundRunOutcome.allCases` order. Outcomes with
    /// no runs are omitted.
    var outcomeCounts: [OutcomeCount]
    var handlerLatencyP50Ms: Int?
    var handlerLatencyP99Ms: Int?
    var handlerLatencyMaxMs: Int?

    /// Compact, fixed-label text for the shareable diagnostics report. Same convention as
    /// `DiagnosticsReport.plainText`: English labels regardless of app language, because this is
    /// pasted into a support conversation and has to be legible to whoever reads it there.
    func plainTextLines(dateFormatter: DateFormatter) -> [String] {
        var lines: [String] = []
        lines.append("background_last_run: \(lastRunAt.map { dateFormatter.string(from: $0) } ?? "none")")
        lines.append("background_last_kind: \(lastRunKind?.rawValue ?? "none")")
        lines.append("background_last_outcome: \(lastRunOutcome?.rawValue ?? "none")")
        lines.append("background_runs_\(windowDays)d: \(totalRuns)")
        let mix = outcomeCounts.map { "\($0.outcome.rawValue)=\($0.count)" }.joined(separator: ",")
        lines.append("background_outcomes_\(windowDays)d: \(mix.isEmpty ? "none" : mix)")
        lines.append("background_handler_ms_p50: \(handlerLatencyP50Ms.map(String.init) ?? "n/a")")
        lines.append("background_handler_ms_p99: \(handlerLatencyP99Ms.map(String.init) ?? "n/a")")
        lines.append("background_handler_ms_max: \(handlerLatencyMaxMs.map(String.init) ?? "n/a")")
        return lines
    }
}

// MARK: - Repository

/// `background_runs` (migration v4). Append-only, device-local, pruned at 90 days — the same
/// posture as `export_runs`, and for the same reason: this is a record of what BADAN's own
/// scheduling did, not user data, so it neither syncs nor accumulates forever.
final class BackgroundRunRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    /// Plan §9.8: "`(started_at DESC)` with a 90-day pruning job."
    static let retentionDays = 90

    /// How much history the Diagnostics rollup and the soak protocol look at. 14 days matches
    /// `docs/runbooks/background-soak.md`'s soak window, so what a tester reads on the screen is
    /// the same window the runbook's pass/fail criteria are stated against.
    static let summaryWindowDays = 14

    func insert(_ run: BackgroundRun) throws {
        // Plain INSERT, not INSERT OR REPLACE: a run id is a fresh ULID per run and a collision
        // would mean an id-generation bug, which should surface as a failed write rather than
        // silently overwriting an earlier run's record.
        try db.run("""
            INSERT INTO background_runs
              (id, kind, started_at, duration_ms, outcome, work_done, completion_handler_called_in_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(run.id), .text(run.kind.rawValue), .date(run.startedAt), .int(run.durationMs),
             .text(run.outcome.rawValue),
             .string(run.workDone.map { JSONCoding.encode($0) }),
             .int(run.completionHandlerCalledInMs)])
    }

    func recent(limit: Int = 50) throws -> [BackgroundRun] {
        try db.query("SELECT * FROM background_runs ORDER BY started_at DESC LIMIT ?;", [.int(limit)])
            .map(Self.read)
    }

    /// Drop runs older than `retentionDays`, returning how many rows went. Returns a count rather
    /// than `Void` so the run that performed the prune can record it in its own `workDone` —
    /// a prune that silently does nothing (wrong column, wrong units) is otherwise invisible.
    @discardableResult
    func prune(now: Date, retentionDays: Int = BackgroundRunRepository.retentionDays) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return try db.run("DELETE FROM background_runs WHERE started_at < ?;", [.date(cutoff)])
    }

    /// The value-free rollup behind Diagnostics' background section.
    ///
    /// Three narrow queries against `idx_background_runs_started` rather than one materializing
    /// read: the outcome mix and the last run are pure SQL aggregates, and only the latency
    /// percentiles need rows in memory (SQLite has no percentile function without an extension).
    /// That last query is bounded by the window and by `completion_handler_called_in_ms IS NOT
    /// NULL`, i.e. observer wakes only — at HealthKit's hourly ceiling for the HR family that is
    /// low thousands of `Int64`s at worst, which is cheap enough for a screen that already
    /// gathers off the main actor.
    func summary(now: Date, windowDays: Int = BackgroundRunRepository.summaryWindowDays) throws -> BackgroundHealthSummary {
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400)

        let last = try db.query("SELECT * FROM background_runs ORDER BY started_at DESC LIMIT 1;")
            .first.map(Self.read)

        var counts: [BackgroundRunOutcome: Int] = [:]
        for row in try db.query("""
            SELECT outcome, COUNT(*) AS c FROM background_runs WHERE started_at >= ? GROUP BY outcome;
            """, [.date(since)]) {
            guard let outcome = BackgroundRunOutcome(rawValue: row.requireString("outcome")) else { continue }
            counts[outcome] = row.intValue("c") ?? 0
        }

        let latencies = try db.query("""
            SELECT completion_handler_called_in_ms AS ms FROM background_runs
            WHERE started_at >= ? AND completion_handler_called_in_ms IS NOT NULL
            ORDER BY completion_handler_called_in_ms ASC;
            """, [.date(since)]).compactMap { $0.intValue("ms") }

        return BackgroundHealthSummary(
            windowDays: windowDays,
            totalRuns: counts.values.reduce(0, +),
            lastRunAt: last?.startedAt,
            lastRunKind: last?.kind,
            lastRunOutcome: last?.outcome,
            outcomeCounts: BackgroundRunOutcome.allCases.compactMap { outcome in
                counts[outcome].map { BackgroundHealthSummary.OutcomeCount(outcome: outcome, count: $0) }
            },
            handlerLatencyP50Ms: Self.percentile(latencies, 0.50),
            handlerLatencyP99Ms: Self.percentile(latencies, 0.99),
            handlerLatencyMaxMs: latencies.last)
    }

    /// Nearest-rank percentile over an already-ascending array. Nearest-rank (not interpolated)
    /// on purpose: the soak criterion is "p99 handler latency under 5s", and an interpolated p99
    /// over a handful of samples reports a number that no wake actually experienced — the whole
    /// value of this metric is that every figure in it is a real observed latency.
    static func percentile(_ ascending: [Int], _ fraction: Double) -> Int? {
        guard !ascending.isEmpty else { return nil }
        let rank = Int((fraction * Double(ascending.count)).rounded(.up))
        return ascending[min(max(rank, 1), ascending.count) - 1]
    }

    static func read(_ r: SQLiteRow) -> BackgroundRun {
        BackgroundRun(
            id: r.requireString("id"),
            // A row whose kind/outcome no longer parses can only come from a downgrade or a
            // hand-edited database. Falling back keeps the whole log readable instead of
            // dropping the row (and with it, the very evidence someone is reading this table to
            // find); the fallbacks are the two most conservative labels available.
            kind: BackgroundRunKind(rawValue: r.requireString("kind")) ?? .foregroundSync,
            startedAt: r.requireDate("started_at"),
            durationMs: r.intValue("duration_ms"),
            outcome: BackgroundRunOutcome(rawValue: r.requireString("outcome")) ?? .error,
            workDone: JSONCoding.decode(BackgroundWorkCounts.self, from: r.string("work_done")),
            completionHandlerCalledInMs: r.intValue("completion_handler_called_in_ms"))
    }
}
