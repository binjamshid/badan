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

    static let minimumDelay: TimeInterval = 24 * 3600
    static let maximumDelay: TimeInterval = 72 * 3600

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

    /// Cleared only after a submission actually succeeds, so a failed send retries on the next
    /// wake rather than being silently dropped.
    func clear() { defaults.removeObject(forKey: Self.dueKey) }
}

/// Turns stored feedback into the footprints for a batch.
///
/// Reads counts and identifiers only — it is handed a `FeedbackRepository` but never a
/// `DerivedValue`, so a reading is not merely omitted from the payload, it is never in scope.
struct FootprintCollector {
    let feedback: FeedbackRepository
    let registry: AlgorithmRegistry

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
                let calibrated = (try? feedback.latestCalibration(
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
