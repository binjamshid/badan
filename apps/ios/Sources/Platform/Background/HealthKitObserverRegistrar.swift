import Foundation
import HealthKit
import os

/// One `HKObserverQuery` wake, as handed to `BackgroundCoordinator`.
///
/// It carries no samples, because an observer wake carries no samples: HealthKit's contract is
/// "something you observe changed", full stop (plan §13.3, ADR-0009 §A2). Everything downstream
/// must re-query through the existing anchored ingestion path to find out *what* changed. The
/// type is shaped this way deliberately — there is no field a payload could be smuggled into, so
/// nobody can accidentally build a second, observer-fed ingest path that diverges from the one
/// `IngestionPipeline` owns.
struct HealthKitWakeSignal: Equatable {
    /// The HealthKit identifier that woke us (e.g. `HKQuantityTypeIdentifierHeartRate`), for the
    /// run log only — the follow-up re-query is not scoped to it. HealthKit coalesces wakes, so
    /// treating one type's wake as "only this type changed" would drop the others' deltas.
    var platformType: String
    var wokeAt: Date
    /// Milliseconds from entering the update handler to calling HealthKit's completion handler.
    /// The three-strikes budget, measured. See `ObserverCompletionGate`.
    var completionHandlerCalledInMs: Int
}

/// Calls an `HKObserverQuery` completion handler **exactly once, as early as possible**, and
/// reports how long that took.
///
/// This tiny type exists because of the single worst failure mode in the whole background
/// substrate. HealthKit silently disables background delivery for an app after 3 wakes where the
/// completion handler is not called promptly. It does not tell the app, there is no API to query
/// the state, and there is no way to re-enable it beyond `enableBackgroundDelivery` (which
/// happily reports success while delivering nothing). So the failure is: background sync quietly
/// stops working on a real user's phone, forever, and no test on any machine ever catches it.
///
/// The defence is structural rather than disciplinary:
/// - `complete()` is idempotent, so a second call (from the belt-and-braces `defer` in
///   `handleWake`) can never double-invoke HealthKit's handler.
/// - `complete()` returns the latency, so the number that guards the budget comes from the same
///   call that spends it and cannot drift from it.
/// - Nothing in this file awaits ingestion before completing. The update handler is a
///   synchronous closure, so *making* it wait would take a deliberate `DispatchSemaphore` or
///   `.sync` hop. If you are reading this because you are about to add one: don't. Schedule the
///   work and return.
///
/// Not internally locked: an instance is created inside one update-handler invocation, used on
/// that thread, and released when it returns. It is never shared across wakes or captured by the
/// follow-up work.
final class ObserverCompletionGate {
    private let handler: HKObserverQueryCompletionHandler
    private let wokeAt: Date
    private let clock: Clock
    private var latencyMs: Int?

    init(handler: @escaping HKObserverQueryCompletionHandler, wokeAt: Date, clock: Clock) {
        self.handler = handler
        self.wokeAt = wokeAt
        self.clock = clock
    }

    /// Tell HealthKit we are done being notified. Idempotent; returns the latency of the *first*
    /// call, so a later no-op call cannot inflate the recorded number.
    @discardableResult
    func complete() -> Int {
        if let latencyMs { return latencyMs }
        let elapsed = Int((clock.now().timeIntervalSince(wokeAt) * 1000).rounded())
        // Clamped at 0: `Clock` is injectable and a test clock can legitimately be frozen, which
        // would otherwise make a negative latency representable in a column whose entire purpose
        // is to be compared against a budget.
        latencyMs = max(0, elapsed)
        handler()
        return latencyMs ?? 0
    }
}

/// Registers one `HKObserverQuery` per read type and keeps HealthKit background delivery enabled
/// for them (EPIC-04, plan §13.3).
///
/// Owns HealthKit and nothing else: it does not touch the database, does not decide what a wake
/// means, and does not run ingestion. It hands a `HealthKitWakeSignal` to its `onWake` callback
/// and lets `BackgroundCoordinator` own the consequences — which is what makes the
/// completion-handler discipline above readable in one screen instead of buried in sync logic.
final class HealthKitObserverRegistrar {
    typealias WakeHandler = (HealthKitWakeSignal) -> Void

    private let store: HKHealthStore
    private let clock: Clock
    private let onWake: WakeHandler
    private var activeQueries: [HKObserverQuery] = []
    private let lock = NSLock()

    init(store: HKHealthStore = HKHealthStore(), clock: Clock, onWake: @escaping WakeHandler) {
        self.store = store
        self.clock = clock
        self.onWake = onWake
    }

    // MARK: - Observed types

    /// The heart-rate family, which gets `.hourly` background delivery. Everything else gets
    /// `.daily`, per the EPIC-04 card.
    ///
    /// The split is not arbitrary. HealthKit treats the frequency as a *ceiling* on how often it
    /// will wake the app for a type: a daily ceiling on heart rate would make the freshness
    /// promise (plan §13.3, "within a few hours") unachievable for exactly the metrics users
    /// notice going stale first, while asking for hourly wakes on daily-granularity data spends
    /// wakes — a scarce, system-rationed budget shared with every other app — re-checking deltas
    /// that cannot have changed since the last one.
    static let hourlyIdentifiers: Set<HKQuantityTypeIdentifier> = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
    ]

    /// The types BADAN observes, with each one's background-delivery frequency.
    ///
    /// Derived from `HKTypeMap.table` rather than hand-listed, for the same reason the adapter
    /// iterates it: a type added to the read set but missing an observer would simply never wake
    /// the app in the background, which presents as "background sync is unreliable on my phone"
    /// rather than as a missing line in a list, and nothing would fail.
    ///
    /// `.authorizationOnly` rows are excluded deliberately. Those types are in the authorization
    /// bundle so a later epic inherits granted permission (see `HKTypeMap.NoIngestReason`), but
    /// they produce no rows today — observing them would spend real wakes to re-query data
    /// nothing stores, and every wake spent is one that counts against the three-strikes budget
    /// for no possible benefit. They start being observed on the day they start being ingested,
    /// which is the same day this filter stops excluding them, with no edit here.
    static func observedTypes() -> [(type: HKSampleType, frequency: HKUpdateFrequency)] {
        var out: [(HKSampleType, HKUpdateFrequency)] = []
        for entry in HKTypeMap.table {
            guard entry.metricId != nil, let quantityType = entry.quantityType else { continue }
            out.append((quantityType,
                        hourlyIdentifiers.contains(entry.identifier) ? .hourly : .daily))
        }
        // Sleep and workouts are not quantity types and so are not in `HKTypeMap.table`; they are
        // added to the authorization bundle by `HKTypeMap.authorizationReadTypes` the same way.
        // Both are written in whole-episode batches long after the fact (a watch syncs the night
        // when it next connects), so `.daily` matches how the data actually arrives — an hourly
        // ceiling would not make a night appear any sooner than the watch delivers it.
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            out.append((sleep, .daily))
        }
        out.append((HKObjectType.workoutType(), .daily))
        return out
    }

    // MARK: - Lifecycle

    /// Start observing. Safe to call repeatedly — the second and later calls skip query
    /// registration and only re-run `enableBackgroundDelivery`, which is exactly what the
    /// every-app-open defensive path wants.
    func activate() {
        guard HKHealthStore.isHealthDataAvailable() else {
            Log.logger.info("HealthKit unavailable on this device; observers not registered")
            return
        }
        lock.lock()
        let alreadyRegistered = !activeQueries.isEmpty
        lock.unlock()

        if !alreadyRegistered {
            registerObserverQueries()
        }
        enableBackgroundDelivery()
    }

    private func registerObserverQueries() {
        var registered: [HKObserverQuery] = []
        for (type, _) in Self.observedTypes() {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
                guard let self else {
                    // The registrar is gone (app tearing down). HealthKit still needs its handler
                    // called or this wake counts against the three-strikes budget that the *next*
                    // launch inherits — the budget belongs to the app, not to this object.
                    completionHandler()
                    return
                }
                self.handleWake(platformType: type.identifier,
                                completionHandler: completionHandler, error: error)
            }
            store.execute(query)
            registered.append(query)
        }
        lock.lock()
        activeQueries = registered
        lock.unlock()
        Log.logger.info("Registered \(registered.count, privacy: .public) HealthKit observer queries")
    }

    /// Ask HealthKit to wake BADAN when the observed types change.
    ///
    /// Called on **every app open**, not once at first connect (ADR-0009 §A2, plan §13.3). The
    /// OS may have disabled delivery without telling us — the three-strikes revocation above,
    /// but also a restore-from-backup, a HealthKit database migration, or a permission change —
    /// and re-enabling is idempotent and cheap. There is no API that reports the current state,
    /// so re-registering unconditionally is the only available repair, and skipping it because
    /// "we already did that at launch" is how the feature dies quietly.
    func enableBackgroundDelivery() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        for (type, frequency) in Self.observedTypes() {
            store.enableBackgroundDelivery(for: type, frequency: frequency) { success, error in
                // Never surfaced to the user and never retried in a loop. The common failure is
                // "this type was never authorized", which HealthKit deliberately refuses to
                // distinguish from a denial (see `HealthKitAdapter`'s type doc) — there is
                // nothing honest to say about it in the UI, and the next app open tries again.
                if !success {
                    Log.logger.info("""
                        enableBackgroundDelivery declined for \(type.identifier, privacy: .public): \
                        \(error.map { String(describing: $0) } ?? "no error reported", privacy: .public)
                        """)
                }
            }
        }
    }

    // MARK: - Wake handling

    /// One observer wake. **The first thing this does is call HealthKit's completion handler.**
    ///
    /// Read `ObserverCompletionGate`'s doc before changing anything in this method. The ordering
    /// below is the feature: complete first, then schedule. `error` is deliberately not a reason
    /// to skip completing — a wake that arrives with an error still spends a strike if the
    /// handler is not called, which makes "fail fast on error" precisely the wrong instinct here.
    ///
    /// Internal rather than private for one reason: `BackgroundSubstrateTests` calls it with a
    /// stub handler to assert the ordering — that the handler runs *before* `onWake` — which is
    /// the only half of the three-strikes contract verifiable anywhere but a real device. Do not
    /// narrow the visibility without moving that assertion somewhere it still holds.
    func handleWake(platformType: String,
                    completionHandler: @escaping HKObserverQueryCompletionHandler,
                    error: Error?) {
        let wokeAt = clock.now()
        let gate = ObserverCompletionGate(handler: completionHandler, wokeAt: wokeAt, clock: clock)
        // Belt and braces. `gate.complete()` on the next line is the real call; this `defer`
        // exists so that if someone later inserts an early `return` above it — a `guard` on
        // `error`, a feature flag, a "let's skip this when unauthorized" — HealthKit still gets
        // its handler and the app still does not lose background delivery. `complete()` is
        // idempotent, so in the ordinary path this is a no-op.
        defer { gate.complete() }
        let latencyMs = gate.complete()

        if let error {
            // Value-free by contract: the identifier and the error's type, never sample content.
            Log.logger.error("""
                Observer wake for \(platformType, privacy: .public) reported an error: \
                \(String(describing: type(of: error)), privacy: .public)
                """)
        }

        onWake(HealthKitWakeSignal(platformType: platformType, wokeAt: wokeAt,
                                   completionHandlerCalledInMs: latencyMs))
    }

    private enum Log {
        static let logger = Logger(subsystem: "net.binjamshid.badan", category: "HealthKitObservers")
    }
}
