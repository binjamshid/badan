import Foundation

/// When a telemetry batch may be sent, and what goes in it (ADR-0011 / D-37).
///
/// ## Why the delay is randomised and decoupled from the tap
///
/// Timing is a side channel. If a submission followed the tenth "doesn't match" tap, the moment of
/// transmission would itself say when a user disagreed with a number — which is information the
/// payload deliberately does not carry, arriving by another route. So a submission is scheduled for
/// a random point 24–72 hours after the batch became eligible, and nothing about a feedback tap
/// advances it.
///
/// The randomisation is per-schedule, not per-install, so two devices that became eligible at the
/// same instant do not submit together.
struct FootprintScheduler {
    private let defaults: UserDefaults
    private static let dueKey = "badan.telemetry.nextSubmissionDue"
    private static let failuresKey = "badan.telemetry.consecutiveFailures"

    static let minimumDelay: TimeInterval = 24 * 3600
    static let maximumDelay: TimeInterval = 72 * 3600

    /// The first retry window after a failed submission, and the ceiling it doubles toward.
    ///
    /// One hour is the floor because nginx rate-limits `POST /v1/footprints` to 2r/h per address
    /// (`infra/nginx/badan-api.conf`), and a failure that retried on every background wake would
    /// sit against that limit indefinitely — turning one install's broken submission into a share
    /// of the whole route's budget. A day is the ceiling because the ordinary cadence is 24-72h
    /// anyway: past that point, backing off further would only delay a submission the user opted
    /// into, without sparing the server anything it would notice.
    static let minimumRetryDelay: TimeInterval = 3600
    static let maximumRetryDelay: TimeInterval = 24 * 3600

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Arrange a submission for a random point in the window, unless one is already pending.
    ///
    /// Idempotent on purpose: called whenever feedback is recorded, and re-rolling the due date on
    /// every tap would let a burst of feedback push submission indefinitely into the future — the
    /// opposite of the decoupling this exists for, and a way to never send at all.
    func scheduleIfNeeded(now: Date, randomIn: (ClosedRange<TimeInterval>) -> TimeInterval = { Double.random(in: $0) }) {
        guard dueAt() == nil else { return }
        let delay = randomIn(Self.minimumDelay...Self.maximumDelay)
        defaults.set(now.addingTimeInterval(delay).timeIntervalSince1970, forKey: Self.dueKey)
    }

    func dueAt() -> Date? {
        guard defaults.object(forKey: Self.dueKey) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: Self.dueKey))
    }

    func isDue(now: Date) -> Bool {
        guard let due = dueAt() else { return false }
        return now >= due
    }

    /// How many submissions in a row have failed. Zero once one succeeds.
    func consecutiveFailures() -> Int { defaults.integer(forKey: Self.failuresKey) }

    /// The delay a submission owes after `failures` consecutive failures: one hour, doubling, capped
    /// at a day.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return minimumRetryDelay }
        // `min(_, 16)` before the `pow` rather than after: the cap makes anything beyond that
        // irrelevant, and an unbounded exponent on a `Double` reaches `infinity`, which would then
        // be written into `UserDefaults` as a due date.
        let scaled = minimumRetryDelay * pow(2, Double(min(failures - 1, 16)))
        return min(scaled, maximumRetryDelay)
    }

    /// A submission was attempted and did not land. Push the due date out rather than leaving it in
    /// the past.
    ///
    /// This is the difference between "retries on a later wake" and "retries on EVERY wake". The
    /// schedule is still not cleared — a failed batch is not dropped — but it stops being due until
    /// the backoff elapses. The new due moment derives from the previous (randomised) one, so no
    /// timing side channel opens: nothing here is a function of when a user tapped "doesn't match".
    func recordFailure(now: Date) {
        let failures = consecutiveFailures() + 1
        defaults.set(failures, forKey: Self.failuresKey)
        defaults.set(now.addingTimeInterval(Self.retryDelay(afterFailures: failures)).timeIntervalSince1970,
                     forKey: Self.dueKey)
    }

    /// Called only after a submission actually succeeds. Drops the schedule AND the failure count,
    /// so the next batch starts from the ordinary 24-72h window rather than inheriting a backoff
    /// earned by a problem that is over.
    func clear() {
        defaults.removeObject(forKey: Self.dueKey)
        defaults.removeObject(forKey: Self.failuresKey)
    }
}

/// Turns stored feedback into the footprints for a batch.
///
/// Reads counts and identifiers only — it is handed a `FeedbackRepository` but never a
/// `DerivedValue`, so a reading is not merely omitted from the payload, it is never in scope.
struct FootprintCollector {
    let feedback: FeedbackRepository
    let registry: AlgorithmRegistry
    /// Whether the user has calibration switched on, read at collection time.
    ///
    /// A closure and not a stored `Bool` for the reason `ReadinessEngine` takes one: collection
    /// runs on a background wake and must not touch `@Observable` profile state. Defaulted so the
    /// composition root and the tests construct this unchanged.
    var calibrationEnabled: () -> Bool = { MethodChoiceStore.calibrationEnabled() }

    /// One footprint per (metric, method, direction) group that clears the floor.
    ///
    /// Grouping by direction rather than netting them out is deliberate: "14 people said over and
    /// 12 said under" is a different fact from "net +2", and the netted version cannot be recovered
    /// from the aggregate later.
    func collect(metricIds: [String], floor: Int) -> [FootprintBuilder.Source] {
        var sources: [FootprintBuilder.Source] = []
        for metricId in metricIds {
            for method in MethodResolver.selectableMethods(for: metricId, registry: registry) {
                guard let events = try? feedback.feedback(metricId: metricId,
                                                          algorithmId: method.algorithmId),
                      !events.isEmpty else { continue }
                // A STORED CALIBRATION IS NOT AN APPLIED ONE. This used to be "a row exists in
                // `metric_calibrations`", which for sleep.score — the other metric the batch
                // collects — was always false as a statement about methodology: the row is written
                // by `CalibrationCoordinator` for any metric, and only `ReadinessEngine` ever reads
                // one back (`CalibrationConsumers`). The server was being told a calibration was in
                // force for a number computed without reference to it.
                //
                // Three conditions, all of which the engine itself requires before an offset
                // reaches a value: an engine that consumes calibrations for this metric, the
                // feature switched on, and a row for THIS method. ADR-0011's closed schema keeps
                // health data out of the payload; it cannot keep an untrue field out, and a false
                // methodology claim is the one thing this route is for.
                let calibrated = CalibrationConsumers.adjustsFutureValues(of: metricId)
                    && calibrationEnabled()
                    && (try? feedback.latestCalibration(
                        metricId: metricId, algorithmId: method.algorithmId)) != nil

                for direction in FeedbackDirection.allCases {
                    let count = events.filter { $0.direction == direction }.count
                    // Below the floor this contributes nothing at all — not a smaller bucket.
                    guard count >= floor else { continue }
                    sources.append(FootprintBuilder.Source(
                        metricId: metricId, algorithmId: method.algorithmId,
                        algorithmSemver: method.semver, direction: direction,
                        eventCount: count, calibrationApplied: calibrated))
                }
            }
        }
        return sources
    }
}
