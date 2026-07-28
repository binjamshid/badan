import Foundation
import UIKit
import os

// MARK: - Seams
//
// The substrate is mostly untestable on a Mac: `HKObserverQuery` needs a device with a real
// HealthKit store, `BGTaskScheduler` needs the OS to decide to wake us, and a locked store needs
// a locked phone. So everything the *decision* logic depends on — can we read, what happened
// when we tried, where did we get to — goes behind one of these three protocols, and
// `BackgroundSubstrateTests` drives `BackgroundCoordinator` through all of them with fakes. What
// is left untested is HealthKit's and the OS's half of the contract, which is what
// `docs/runbooks/background-soak.md` exists to cover on a real device.

/// The ingest→derive path, as the background substrate needs to call it.
///
/// Deliberately narrow, and deliberately *not* an ingestion API: there is exactly one ingestion
/// path in BADAN (`IngestionPipeline`, via `SeedController`), and plan §13.3 makes that a build
/// rule — an observer wake follows with an anchored re-query through the existing path, never a
/// second one. This protocol is a door onto that path, not a parallel implementation of it.
protocol BackgroundIngestPerforming: AnyObject {
    /// Whether the user has connected real HealthKit. No observers, no wakes, no runs otherwise.
    var isHealthKitConnected: Bool { get }

    /// How long since the freshest persisted read anchor was written; `nil` if none exists yet
    /// (never synced). Drives the app-refresh "top up if stale > 6h" rule.
    func anchorAge(now: Date) -> TimeInterval?

    /// Run the anchored incremental sync + derivation, waiting for the ingest lock if another
    /// caller holds it.
    func ingestAndDerive(now: Date) throws -> BackgroundWorkCounts

    /// As `ingestAndDerive`, but returns `nil` immediately rather than waiting when another
    /// ingest is already in flight. Background runs use this: a wake that queues behind a
    /// foreground sync would spend its short runtime budget blocked, and the in-flight run is
    /// about to do the identical work anyway.
    func tryIngestAndDerive(now: Date) throws -> BackgroundWorkCounts?

    /// Whether a prior 90-day backfill never completed (crash, or the app killed mid-ingest).
    /// Mirrors `SeedController.needsBackfillResume()` and is the heavy work `BGProcessingTask`
    /// exists to finish.
    func needsBackfillResume() -> Bool

    /// Resume the interrupted backfill. `nil` when another ingest holds the lock.
    func resumeBackfill(now: Date) throws -> BackgroundWorkCounts?

    /// Whether an HR-max/zone edit (EPIC-26) has queued a historical SCORE backfill — a pure
    /// re-derivation over already-ingested data (no HealthKit read), distinct from `needsBackfillResume`
    /// (an unfinished INGEST). A cheap marker read.
    func hasPendingScoreBackfill() -> Bool

    /// Run the queued score backfill over its recorded window, append-only (I2). `nil` when nothing is
    /// queued or another derivation holds the lock; clears the request on success. Idempotent, so an
    /// expired run that never cleared the request simply re-runs and skips the days it already wrote.
    func runPendingScoreBackfill(now: Date) throws -> BackgroundWorkCounts?

    /// Resume an interrupted "Fetch Health history" (D-35 item 2b) from its persisted cursor.
    /// `nil` when nothing is pending, the reader is not wired, or another ingest holds the lock —
    /// so the next wake retries rather than consuming the step.
    func resumeHistoricalImportIfPending(now: Date) throws -> BackgroundWorkCounts?
}

/// Whether iOS Data Protection currently lets us read protected files.
///
/// See `BackgroundRunOutcome.storeLocked` for why this matters and why an unavailable store is
/// not a failure.
protocol ProtectedDataProviding: AnyObject {
    var isProtectedDataAvailable: Bool { get }

    /// Begin tracking availability. Called on the main actor at every app activation; the real
    /// implementation samples UIKit and subscribes to its notifications, fakes do nothing.
    @MainActor func startMonitoring()
}

extension ProtectedDataProviding {
    @MainActor func startMonitoring() {}
}

/// How background work gets off the caller's thread. The real implementation holds a UIKit
/// background-task assertion for the duration; tests substitute an inline one.
protocol BackgroundWorkDispatching: AnyObject {
    func dispatch(reason: String, _ work: @escaping () -> Void)
}

// MARK: - Protected-data monitoring

/// Tracks `UIApplication.isProtectedDataAvailable` from a background-safe cache.
///
/// `UIApplication.shared` is main-actor-bound, and an observer wake arrives on an arbitrary
/// HealthKit queue — reading the property there would mean a synchronous main-thread hop from a
/// thread we do not control, which is a deadlock waiting to happen on the one code path that
/// must never stall. So the value is sampled once on the main actor at `start()` and thereafter
/// maintained from the two notifications UIKit posts for exactly this purpose, leaving the
/// background read a plain lock-guarded `Bool`.
///
/// `@unchecked Sendable` is earned, not asserted: every piece of mutable state below is guarded by
/// `lock`, and the notification blocks that mutate it are the only writers. Without it, the two
/// `addObserver` closures (which UIKit types as `@Sendable`) warn under Swift 6 checking about
/// capturing a non-Sendable `self` — and the honest answer to that warning is that this class is
/// in fact safe to touch from any thread, which is the whole point of it existing.
final class ProtectedDataMonitor: ProtectedDataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var cached = true
    private var isObserving = false

    /// Optimistic default (`true`) before the first sample or notification.
    ///
    /// Assuming *unavailable* would be worse than wrong: every wake before the first notification
    /// would record `storeLocked` and skip, so a device that never happens to lock while BADAN is
    /// resident would never sync in the background at all. Assuming available costs nothing when
    /// it is wrong — HealthKit returns empty results for protected data, ingestion writes
    /// nothing, and the run records honestly as a completed no-op.
    var isProtectedDataAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    @MainActor
    func startMonitoring() {
        lock.lock()
        let alreadyObserving = isObserving
        isObserving = true
        cached = UIApplication.shared.isProtectedDataAvailable
        lock.unlock()
        guard !alreadyObserving else { return }

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                           object: nil, queue: nil) { [weak self] _ in self?.set(true) }
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                           object: nil, queue: nil) { [weak self] _ in self?.set(false) }
    }

    private func set(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        cached = value
    }
}

// MARK: - Work dispatch

/// Runs background work on a serial utility queue while holding a UIKit background-task
/// assertion, so the OS does not suspend the app between "we told HealthKit we were done" and
/// "we finished writing what changed".
///
/// The assertion is acquired on the main actor because `UIApplication` requires it; the work
/// starts one hop later. That hop is harmless *specifically because* the HealthKit completion
/// handler has already been called by the time anything reaches here (see
/// `ObserverCompletionGate`) — the three-strikes budget is not waiting on it.
///
/// If the assertion expires mid-work the process may be killed. Nothing is lost when that
/// happens: ingestion writes inside a SQLite transaction (rolled back on kill) and HealthKit
/// anchors are two-phase committed after it (DATA-08), so an interrupted run replays cleanly on
/// the next wake rather than advancing past data it never stored.
final class AssertedWorkDispatcher: BackgroundWorkDispatching {
    /// Serial: two wakes must not run ingestion concurrently. `BackgroundIngestBridge`'s lock is
    /// the correctness guarantee (it also covers the foreground path); this is the cheap one that
    /// stops the contention from arising in the first place.
    private let queue = DispatchQueue(label: "net.binjamshid.badan.background", qos: .utility)

    func dispatch(reason: String, _ work: @escaping () -> Void) {
        Task { @MainActor in
            let token = BackgroundAssertionToken()
            token.identifier = UIApplication.shared.beginBackgroundTask(withName: reason) {
                token.end()
            }
            queue.async {
                work()
                Task { @MainActor in token.end() }
            }
        }
    }
}

/// Main-actor box for a `UIBackgroundTaskIdentifier` so the expiration handler and the
/// work-finished path can both release it exactly once.
@MainActor
private final class BackgroundAssertionToken {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Runs work inline on the calling thread. Tests only — see `BackgroundSubstrateTests`.
final class ImmediateWorkDispatcher: BackgroundWorkDispatching {
    func dispatch(reason: String, _ work: @escaping () -> Void) { work() }
}

// MARK: - Checkpointing

/// The ordered steps of a `BGProcessingTask` run.
///
/// Ordered by "what a user loses if it never runs": an unfinished backfill means their history is
/// missing, pruning a diagnostics table means nothing to them at all.
enum BackgroundProcessingStep: String, CaseIterable {
    case backfillResume
    /// Historical SCORE re-derivation queued by an HR-max/zone edit (EPIC-26). Ordered after
    /// `backfillResume` (ingesting the data a user is missing outranks re-scoring data they already
    /// have) and before `prune` (housekeeping is last).
    case scoreBackfill
    /// An interrupted "Fetch Health history" (D-35 item 2b), resumed from its persisted cursor.
    ///
    /// Ordered after `scoreBackfill` deliberately. The import runs in the FOREGROUND while the user
    /// watches — iOS will not grant a `BGProcessingTask` on demand — so this step exists only for
    /// the case where the app was backgrounded mid-walk. That makes it the least urgent of the
    /// three: the other two are the ordinary path, this one is recovery.
    ///
    /// Per this file's own copy rule, no surface may promise WHEN this happens. iOS decides whether
    /// a wake occurs at all, which is exactly why the import screen offers an explicit Resume.
    case historicalImportResume
    case prune
}

/// Where a checkpointed processing run got to, so expiration means "resume", not "start over".
///
/// Mirrors `SeedController.needsBackfillResume()`'s existing pattern rather than inventing a
/// second one: progress is a small durable marker in `UserDefaults`, read at the head of the next
/// run, and the *authoritative* answer for whether backfill work remains is still re-derived from
/// the store itself (`needsBackfillResume`), never trusted from the marker alone. A marker can be
/// stale — an interrupted run may have completed a step and died before writing — so it is used
/// only to skip ahead, never to claim work is done that the store says is not.
final class BackgroundCheckpointStore {
    private let defaults: UserDefaults
    private static let stepKey = "badan.background.processingResumeStep"
    private static let updatedAtKey = "badan.background.processingCheckpointAt"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The step a new processing run should start from.
    func resumeStep() -> BackgroundProcessingStep {
        guard let raw = defaults.string(forKey: Self.stepKey),
              let step = BackgroundProcessingStep(rawValue: raw) else {
            return BackgroundProcessingStep.allCases[0]
        }
        return step
    }

    func save(nextStep: BackgroundProcessingStep, at instant: Date) {
        defaults.set(nextStep.rawValue, forKey: Self.stepKey)
        defaults.set(instant.epochMillis, forKey: Self.updatedAtKey)
    }

    /// A run finished every step. The next run starts from the top.
    func clear() {
        defaults.removeObject(forKey: Self.stepKey)
        defaults.removeObject(forKey: Self.updatedAtKey)
    }

    /// Steps still to run, in order, starting at the checkpoint.
    func remainingSteps() -> [BackgroundProcessingStep] {
        let all = BackgroundProcessingStep.allCases
        guard let index = all.firstIndex(of: resumeStep()) else { return all }
        return Array(all[index...])
    }
}

// MARK: - Coordinator

/// The background substrate's decision layer (EPIC-04).
///
/// Owns what a wake *means*: whether the store is readable, whether work is already in flight,
/// what got done, and what to write to `background_runs`. It owns neither HealthKit nor
/// `BGTaskScheduler` (those are `HealthKitObserverRegistrar` and `BackgroundTaskRegistrar`) nor
/// ingestion (that is `BackgroundIngestPerforming` onto the existing pipeline), which is what
/// lets every rule below be exercised on a Mac.
///
/// **UI copy rule (plan §13.7):** nothing driven by this may promise a wall-clock time. iOS
/// decides when — or whether — a wake happens. The honest label is "best-effort background", and
/// the guaranteed-freshness story is "when you open BADAN". The word "cron" does not appear.
final class BackgroundCoordinator {
    private let runs: BackgroundRunRepository
    private let clock: Clock
    private let ingest: BackgroundIngestPerforming
    private let protectedData: ProtectedDataProviding
    private let checkpoints: BackgroundCheckpointStore
    private let dispatcher: BackgroundWorkDispatching
    /// EPIC-15. Optional and defaulted to nil so every Phase-0 construction site and test that does
    /// not care about automations compiles and behaves exactly as before (the step-2 automation
    /// evaluation in `runAppRefresh` is simply skipped when this is nil, which is the pre-EPIC-15
    /// no-op). The composition root (`AppEnvironment`) supplies the real engine.
    private let automation: AutomationEngine?
    /// EPIC-31. The weekly-report generator, evaluated on the light refresh wake alongside due
    /// automations. Optional and defaulted to nil for the same reason `automation` is: every test
    /// and pre-EPIC-31 construction site keeps compiling and behaving unchanged, and a build without
    /// it simply never auto-generates a weekly report (manual regeneration from the screen still
    /// works). Plan §13.7 honesty: this promises no wall-clock time — it generates the last
    /// *completed* week whenever a wake lands after that week ended, plus a bounded backfill for
    /// weeks a run of missed wakes skipped entirely (see `ReportTrigger`).
    private let reports: ReportGenerationService?
    /// Called after an ingest actually wrote something, so a producer that reacts to fresh data (the
    /// wake-triggered morning summary) can run without the user opening the app.
    ///
    /// Optional and defaulted to nil for exactly the reason `automation` and `reports` are: every
    /// existing construction site and test keeps compiling and behaving unchanged, and a build
    /// without it simply falls back to the foreground evaluation.
    ///
    /// A closure rather than a reference to `AppEnvironment`: this type is deliberately off the main
    /// actor — it is driven from HealthKit's and `BGTaskScheduler`'s own queues — and it holds no
    /// app state by design. The composition root supplies a closure that hops to the main actor
    /// itself, which keeps that hop in the one place that already knows about actor isolation.
    ///
    /// A `var` rather than a `let`, unlike its two sibling collaborators, for one concrete reason:
    /// the composition root's closure captures `AppEnvironment`, and this coordinator is assigned to
    /// one of that type's own stored properties — so at the point of construction `self` is not yet
    /// fully initialised and cannot be captured. It is set on the very next line instead. The
    /// constructor parameter is kept for tests, which have no such cycle.
    var onIngestCompleted: (() -> Void)?

    private let lock = NSLock()
    private var observers: HealthKitObserverRegistrar?
    private var tasks: BackgroundTaskRegistrar?

    /// Plan §13.4: "top-up sync if anchors stale >6h."
    static let staleAnchorThreshold: TimeInterval = 6 * 3600

    init(runs: BackgroundRunRepository,
         clock: Clock,
         ingest: BackgroundIngestPerforming,
         protectedData: ProtectedDataProviding,
         checkpoints: BackgroundCheckpointStore = BackgroundCheckpointStore(),
         dispatcher: BackgroundWorkDispatching = AssertedWorkDispatcher(),
         automation: AutomationEngine? = nil,
         reports: ReportGenerationService? = nil,
         onIngestCompleted: (() -> Void)? = nil) {
        self.runs = runs
        self.clock = clock
        self.ingest = ingest
        self.protectedData = protectedData
        self.checkpoints = checkpoints
        self.dispatcher = dispatcher
        self.automation = automation
        self.reports = reports
        self.onIngestCompleted = onIngestCompleted
    }

    // MARK: - App lifecycle wiring

    /// Register the two `BGTaskScheduler` launch handlers. Call from `BADANApp.init()` and
    /// nowhere else — see `BackgroundTaskRegistrar.registerLaunchHandlers()` for why the scene's
    /// `.task` is too late.
    func registerLaunchHandlers() {
        let registrar = BackgroundTaskRegistrar(
            runRefresh: { [weak self] isExpired in self?.runAppRefresh(isExpired: isExpired) ?? false },
            runProcessing: { [weak self] isExpired in self?.runProcessing(isExpired: isExpired) ?? false },
            onSubmitDeclined: { [weak self] identifier, reason in
                self?.recordSubmitDecline(identifier: identifier, reason: reason)
            })
        lock.lock()
        tasks = registrar
        lock.unlock()
        registrar.registerLaunchHandlers()
    }

    /// Register observer queries and (re-)enable HealthKit background delivery.
    ///
    /// Called on **every** app open, not once. ADR-0009 §A2 makes the defensive re-registration
    /// binding: the OS may have disabled delivery without telling us and offers no way to ask, so
    /// re-enabling unconditionally is the only repair available. Also prunes the run log, which
    /// is the one moment we are certain to have runtime to spare.
    @MainActor
    func activate() {
        protectedData.startMonitoring()

        guard ingest.isHealthKitConnected else {
            // Nothing to observe until the user connects Apple Health. `connectHealthKit()`
            // reaches back here (see `AppEnvironment`) so the observers start the moment they
            // can, rather than waiting for the next launch.
            return
        }

        lock.lock()
        if observers == nil {
            observers = HealthKitObserverRegistrar(clock: clock) { [weak self] signal in
                self?.handleObserverWake(signal)
            }
        }
        let registrar = observers
        lock.unlock()
        registrar?.activate()

        let now = clock.now()
        dispatcher.dispatch(reason: "badan.background.prune") { [weak self] in
            guard let self else { return }
            _ = try? self.runs.prune(now: now)
        }
    }

    /// Backgrounding: arm the next light wake, and ask for a heavy one only if heavy work is
    /// actually pending.
    func applicationDidEnterBackground() {
        lock.lock()
        let registrar = tasks
        lock.unlock()
        registrar?.scheduleAppRefresh()

        // `needsBackfillResume()` is a DB read; keep it off the scene-transition path. Ask for a heavy
        // wake when EITHER an ingest backfill is unfinished (needs HealthKit) OR a score backfill is
        // queued (an HR-max edit — a pure re-derivation that needs no connection), so an edit made just
        // before backgrounding still gets its BGProcessing wake.
        dispatcher.dispatch(reason: "badan.background.schedule") { [weak self] in
            guard let self else { return }
            let ingestPending = self.ingest.isHealthKitConnected && self.ingest.needsBackfillResume()
            guard ingestPending || self.ingest.hasPendingScoreBackfill() else { return }
            registrar?.scheduleProcessing()
        }
    }

    /// Ask for a heavy processing wake now, for a score backfill an HR-max/zone edit just queued
    /// (EPIC-26). Only expedites: the request is a durable marker, so if the submit is declined or the
    /// app is killed before the wake, the next `applicationDidEnterBackground` re-schedules it. The
    /// backfill is deferrable by design (plan §13.7 — no wall-clock promise); this just nudges iOS.
    func scheduleScoreBackfillProcessing() {
        lock.lock()
        let registrar = tasks
        lock.unlock()
        registrar?.scheduleProcessing()
    }

    // MARK: - Declined submissions

    /// `BGTaskScheduler` refused to accept a request (BUG-BG-01).
    ///
    /// Recorded as a run, not merely logged, because "the scheduler will not take our requests"
    /// and "the scheduler takes them and never runs them" are indistinguishable from inside the
    /// app *unless* the first one writes a row. Before this existed, a build with no
    /// `UIBackgroundModes` entry produced a `background_runs` log containing only `hkObserverWake`
    /// and `foregroundSync` — which is also exactly what a healthy phone-only device looks like
    /// after a quiet day, so nothing about the log said anything was wrong.
    ///
    /// The row is deliberately shaped so it cannot be misread as a failed *run*: `startedAt ==
    /// finishedAt` so `durationMs` is 0, and `workDone` is nil because no work was attempted. An
    /// `error` row on `bgAppRefresh`/`bgProcessing` with a zero duration is a declined submit;
    /// `docs/runbooks/background-soak.md` §6 says so and says what to check.
    ///
    /// Outcome is `error` rather than a sixth enum case on purpose: `background_runs`'s outcome
    /// set is the cross-platform contract Android mirrors (plan §9.8, five values), and forking it
    /// for a platform-specific cause would cost more than it buys. `error` is also the right
    /// severity — the soak's pass criterion is `error = 0`, and a build that cannot schedule its
    /// own background work must fail that.
    ///
    /// Written synchronously rather than through `dispatcher`: the common caller is
    /// `applicationDidEnterBackground()`, and an asynchronous write racing app suspension could
    /// lose precisely the evidence this method exists to leave behind. One INSERT is affordable
    /// there, and on a correctly configured device this never runs at all.
    func recordSubmitDecline(identifier: String, reason: BackgroundSubmitDecline) {
        guard let kind = BackgroundRunKind(taskIdentifier: identifier) else {
            // Unreachable while `BackgroundTaskRegistrar` builds only the two known requests, but
            // dropping it silently is the habit that produced this bug in the first place.
            Log.logger.error("""
                Declined BGTask submit for unmapped identifier \(identifier, privacy: .public)
                """)
            return
        }
        Log.logger.error("""
            BGTask scheduling unavailable for \(kind.rawValue, privacy: .public): \
            \(String(describing: reason), privacy: .public) — no wakes of this class will occur
            """)
        record(kind: kind, startedAt: clock.now(), outcome: .error, counts: BackgroundWorkCounts())
    }

    // MARK: - Observer wakes

    /// An `HKObserverQuery` fired. By the time this runs, HealthKit's completion handler has
    /// already been called (`HealthKitObserverRegistrar.handleWake`) — this method must never do
    /// anything that assumes otherwise, and must never be called before it.
    ///
    /// The wake says only "something changed" (plan §13.3), so the response is an anchored
    /// re-query through the existing pipeline, not an attempt to interpret `signal`.
    func handleObserverWake(_ signal: HealthKitWakeSignal) {
        dispatcher.dispatch(reason: "badan.background.observer") { [weak self] in
            self?.performObserverFollowUp(signal)
        }
    }

    /// Split out from `handleObserverWake` so tests can drive it directly with an inline
    /// dispatcher and assert on the row it writes.
    func performObserverFollowUp(_ signal: HealthKitWakeSignal) {
        var counts = BackgroundWorkCounts()
        let outcome: BackgroundRunOutcome

        if !protectedData.isProtectedDataAvailable {
            // The device is locked and HealthKit's store is not readable. This is iOS working as
            // designed, not an error: record it, do nothing else, wait for the next wake. Do not
            // retry, do not escalate, do not surface it. See `BackgroundRunOutcome.storeLocked`.
            outcome = .storeLocked
        } else {
            do {
                if let performed = try ingest.tryIngestAndDerive(now: clock.now()) {
                    counts = performed
                    outcome = .completed
                } else {
                    outcome = .throttled
                }
            } catch {
                Log.logger.error("""
                    Observer follow-up failed: \(String(describing: type(of: error)), privacy: .public)
                    """)
                outcome = .error
            }
        }

        record(kind: .hkObserverWake, startedAt: signal.wokeAt, outcome: outcome, counts: counts,
               completionHandlerCalledInMs: signal.completionHandlerCalledInMs)

        // Only on `.completed`: `.throttled` wrote nothing, and `.storeLocked` did not even read.
        // Note what this means for a watch-synced night on a LOCKED phone — the lock check above
        // returns before HealthKit is touched, so there is no ingest and no notification here. The
        // summary is produced at first unlock by the foreground evaluation instead. That is iOS
        // data protection, not a gap to work around.
        //
        // The counts cannot say whether SLEEP specifically changed — they are undifferentiated
        // totals, and `insightDays` is a constant — so this is a plain "something landed" signal and
        // the producer re-reads the sessions table to decide anything.
        if outcome == .completed { onIngestCompleted?() }
    }

    // MARK: - BGAppRefreshTask (light)

    /// Light top-up. Returns whether the run completed, for `setTaskCompleted(success:)`.
    ///
    /// Steps are checked against `isExpired` between each other rather than within: every step
    /// here is a single bounded operation, and a step that is interrupted internally rolls back
    /// with its transaction and simply reruns next time.
    @discardableResult
    func runAppRefresh(isExpired: () -> Bool) -> Bool {
        let startedAt = clock.now()
        var counts = BackgroundWorkCounts()

        guard protectedData.isProtectedDataAvailable else {
            record(kind: .bgAppRefresh, startedAt: startedAt, outcome: .storeLocked, counts: counts)
            // `true`, not `false`: the run reached a clean, expected terminal state. Reporting
            // failure would train the system's scheduling heuristics against a condition BADAN
            // cannot influence and that is not a malfunction.
            return true
        }

        var outcome = BackgroundRunOutcome.completed
        do {
            // 1. Top up sync only if the anchors have actually gone stale. A refresh wake that
            //    lands minutes after a foreground sync has nothing to fetch, and spending the
            //    wake on a HealthKit round-trip to learn that is how a background budget gets
            //    wasted.
            // `nil` age means no anchor has ever been persisted — never synced, which is the
            // stalest state there is, so it takes the same branch as an expired anchor.
            let isStale = ingest.anchorAge(now: clock.now()).map { $0 > Self.staleAnchorThreshold } ?? true
            if isStale {
                if let performed = try ingest.tryIngestAndDerive(now: clock.now()) {
                    counts = performed
                } else {
                    outcome = .throttled
                }
            }

            // 2. Evaluate due automations (EPIC-15). Plan §13.4: the light refresh wake is where
            //    due automations are evaluated. Skipped entirely when no engine is wired (the
            //    pre-EPIC-15 no-op), so `automationsEvaluated` stays honestly 0 on a build without
            //    it. The count recorded is `ran` — the due schedules actually executed — never the
            //    number merely examined, so the diagnostic means "automations that did work".
            if let automation {
                counts.automationsEvaluated = evaluateAutomationsBlocking(automation, now: clock.now())
            }

            // 2b. Generate every weekly report that is due (EPIC-31) — the last completed ISO week
            //     if it has none yet, plus the bounded gap backfill `ReportTrigger` returns when a
            //     run of wakes was missed entirely.
            //     Best-effort and self-contained: a failure here is logged and dropped, never
            //     allowed to fail the refresh — a report is a regenerable rollup, and the user can
            //     always regenerate from the screen. Only the model + metadata are persisted here;
            //     the PDF is rendered on demand (UIKit's print stack has no place on this queue).
            //     No `BackgroundWorkCounts` field fits "reports generated" and inventing one would
            //     misuse the cross-platform run ledger, so the evidence is the persisted row.
            if let reports {
                do {
                    _ = try reports.generateDueWeekly(now: clock.now())
                } catch {
                    Log.logger.error("""
                        Weekly report generation failed: \(String(describing: type(of: error)), privacy: .public)
                        """)
                }
            }

            if isExpired() {
                record(kind: .bgAppRefresh, startedAt: startedAt, outcome: .expired, counts: counts)
                return false
            }

            // 3. Prune the run log. Cheap, and this is a wake we already paid for.
            counts.pruned = try runs.prune(now: clock.now())
        } catch {
            Log.logger.error("""
                App refresh failed: \(String(describing: type(of: error)), privacy: .public)
                """)
            record(kind: .bgAppRefresh, startedAt: startedAt, outcome: .error, counts: counts)
            return false
        }

        record(kind: .bgAppRefresh, startedAt: startedAt, outcome: outcome, counts: counts)
        return true
    }

    // MARK: - BGProcessingTask (heavy, checkpointed)

    /// Heavy work, resumable. Returns whether the run completed.
    ///
    /// The expiration contract (plan §13.4): checkpoint and exit cleanly, log `expired`, resume
    /// on the next wake. Never fight the expiration handler and never try to squeeze one more
    /// step in — the alternative to a clean exit is being killed mid-step, which costs the run
    /// *and* the record of where it got to.
    @discardableResult
    func runProcessing(isExpired: () -> Bool) -> Bool {
        let startedAt = clock.now()
        var counts = BackgroundWorkCounts()

        guard protectedData.isProtectedDataAvailable else {
            record(kind: .bgProcessing, startedAt: startedAt, outcome: .storeLocked, counts: counts)
            return true
        }

        for step in checkpoints.remainingSteps() {
            if isExpired() {
                checkpoints.save(nextStep: step, at: clock.now())
                record(kind: .bgProcessing, startedAt: startedAt, outcome: .expired, counts: counts)
                return false
            }
            do {
                switch step {
                case .backfillResume:
                    // Re-derived from the store, not trusted from the checkpoint — see
                    // `BackgroundCheckpointStore`'s doc.
                    if ingest.needsBackfillResume(), let performed = try ingest.resumeBackfill(now: clock.now()) {
                        counts.add(performed)
                    }
                case .scoreBackfill:
                    // Whether a score backfill is queued is a durable marker (an HR-max/zone edit set
                    // it); the runner clears it only on success, so an expired run re-runs the window.
                    if ingest.hasPendingScoreBackfill(), let performed = try ingest.runPendingScoreBackfill(now: clock.now()) {
                        counts.add(performed)
                    }
                case .historicalImportResume:
                    // Same durable-marker discipline as `scoreBackfill`: the request and its cursor
                    // are cleared only after the fetch AND its derivation complete, so an expired
                    // run resumes from the last month it finished rather than starting over.
                    if let performed = try ingest.resumeHistoricalImportIfPending(now: clock.now()) {
                        counts.add(performed)
                    }
                case .prune:
                    counts.pruned += try runs.prune(now: clock.now())
                }
            } catch {
                // Checkpoint at the failing step so the next run retries it rather than skipping
                // past it: a transient failure (a locked DB, a HealthKit hiccup) must not silently
                // consume the step it failed on.
                checkpoints.save(nextStep: step, at: clock.now())
                Log.logger.error("""
                    Processing step \(step.rawValue, privacy: .public) failed: \
                    \(String(describing: type(of: error)), privacy: .public)
                    """)
                record(kind: .bgProcessing, startedAt: startedAt, outcome: .error, counts: counts)
                return false
            }
        }

        checkpoints.clear()
        record(kind: .bgProcessing, startedAt: startedAt, outcome: .completed, counts: counts)
        return true
    }

    // MARK: - Foreground sync

    /// The foreground incremental sync (BUG-02), routed through the same lock and the same run
    /// log as every background path.
    ///
    /// Two reasons this lives here rather than staying inline in `AppEnvironment.syncIfStale()`:
    /// the ingest lock is the only thing stopping a foreground sync and an observer wake from
    /// running the pipeline concurrently, and Diagnostics cannot otherwise tell "background never
    /// fires on this device" apart from "nothing ever syncs at all" — which is the first thing
    /// worth knowing when a user reports stale data. Returns whatever was thrown, matching the
    /// `Error?`-returning shape `AppEnvironment`'s lifecycle tasks already use.
    func runForegroundSync(now: Date) -> Error? {
        let startedAt = now
        do {
            let counts = try ingest.ingestAndDerive(now: now)
            record(kind: .foregroundSync, startedAt: startedAt, outcome: .completed, counts: counts)
            return nil
        } catch {
            record(kind: .foregroundSync, startedAt: startedAt, outcome: .error, counts: BackgroundWorkCounts())
            return error
        }
    }

    // MARK: - Automation bridge (EPIC-15)

    /// Run the async `AutomationEngine.evaluateDue` to completion and return the count of due
    /// schedules that actually ran, for `BackgroundWorkCounts.automationsEvaluated`.
    ///
    /// This blocks the calling thread on a semaphore, and that is correct HERE specifically: this
    /// runs inside a `BGAppRefreshTask` body, on the system-provided background queue
    /// `BackgroundTaskRegistrar` hands the handler (`using: nil`), and the whole point of the body
    /// is to finish its work *before* `setTaskCompleted(success:)` — an automation left running
    /// after the task completes would be killed mid-export when iOS suspends the app. The "never
    /// block" rule the Phase-0 audit fixed is about HealthKit's *observer completion handler* (the
    /// 3-strikes budget), which has already been called long before any `runAppRefresh` runs; it is
    /// not about the refresh task's own runtime, which exists to be spent on exactly this.
    ///
    /// No deadlock: the blocked thread is a `DispatchQueue` thread, never a Swift-concurrency
    /// cooperative-pool thread, so the `Task` below runs on the pool independently and signals. The
    /// engine's own work touches no main actor (the runner and repositories are off-actor); only
    /// the real pause-notifier hops to the main actor, and it does so fire-and-forget in its own
    /// detached `Task`, never awaited on this path.
    private func evaluateAutomationsBlocking(_ engine: AutomationEngine, now: Date) -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AutomationSummaryBox()
        Task {
            box.summary = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)
            semaphore.signal()
        }
        semaphore.wait()
        return box.summary.ran
    }

    // MARK: - Reporting

    /// The value-free rollup Diagnostics renders. Cheap enough to call from a screen's `.task`,
    /// which already gathers off the main actor.
    func healthSummary() throws -> BackgroundHealthSummary {
        try runs.summary(now: clock.now())
    }

    /// Write one `background_runs` row.
    ///
    /// A telemetry write must never be able to break a sync: a failed insert is logged and
    /// dropped, because the alternative — throwing out of a background handler — turns a
    /// diagnostics problem into a data problem.
    private func record(kind: BackgroundRunKind, startedAt: Date, outcome: BackgroundRunOutcome,
                        counts: BackgroundWorkCounts, completionHandlerCalledInMs: Int? = nil) {
        let finishedAt = clock.now()
        let run = BackgroundRun(
            id: ULID.newID(),
            kind: kind,
            startedAt: startedAt,
            durationMs: max(0, Int((finishedAt.timeIntervalSince(startedAt) * 1000).rounded())),
            outcome: outcome,
            // Omit an all-zero payload rather than storing `{}` on every idle wake: over 90 days
            // of hourly wakes that is the difference between a column that says something and one
            // that is mostly noise.
            workDone: counts.isEmpty ? nil : counts,
            completionHandlerCalledInMs: completionHandlerCalledInMs)
        do {
            try runs.insert(run)
        } catch {
            Log.logger.error("""
                Could not record background run: \(String(describing: type(of: error)), privacy: .public)
                """)
        }
    }

    private enum Log {
        static let logger = Logger(subsystem: "net.binjamshid.badan", category: "Background")
    }
}

/// Carries the async `evaluateDue` result across the semaphore in `evaluateAutomationsBlocking`.
/// `@unchecked Sendable` is safe by the happens-before the semaphore establishes: the `Task`'s
/// write completes before `signal()`, and the read follows `wait()`, so the two never race.
private final class AutomationSummaryBox: @unchecked Sendable {
    var summary = AutomationEvaluationSummary()
}

extension BackgroundRunKind {
    /// The run kind a `BGTaskScheduler` identifier produces (BUG-BG-01).
    ///
    /// Lives here rather than on the enum itself because `BackgroundRunKind` is the cross-platform
    /// row shape and knows nothing about iOS task identifiers; this is the one place the two
    /// vocabularies meet. `nil` for anything unrecognised, so a renamed identifier surfaces as an
    /// unmapped-identifier log line rather than as a plausible-looking row of the wrong kind.
    init?(taskIdentifier: String) {
        switch taskIdentifier {
        case BackgroundTaskIdentifier.refresh: self = .bgAppRefresh
        case BackgroundTaskIdentifier.processing: self = .bgProcessing
        default: return nil
        }
    }
}

extension BackgroundWorkCounts {
    /// Accumulate another step's counts. Used by multi-step processing runs so a run that expires
    /// halfway still records what it managed.
    mutating func add(_ other: BackgroundWorkCounts) {
        samples += other.samples
        intervals += other.intervals
        sessions += other.sessions
        suppressed += other.suppressed
        insightDays += other.insightDays
        pruned += other.pruned
        automationsEvaluated += other.automationsEvaluated
    }
}

// MARK: - The real ingest bridge

/// `BackgroundIngestPerforming` over the existing `SeedController` chain.
///
/// This type adds no ingestion logic of its own — it exists to (a) give the substrate a
/// dependency it can fake, and (b) be the one lock that serializes every caller of the pipeline.
final class BackgroundIngestBridge: BackgroundIngestPerforming {
    private let seedController: SeedController
    private let main: SQLiteConnection
    private let makePort: () -> HealthStorePort?
    private let connected: () -> Bool
    /// EPIC-26 score backfill. The coordinator re-derives a window (baselines → effort → sleep →
    /// readiness) and the store holds the queued window. Optional so a bridge built without the score
    /// engines (e.g. a narrow test) simply reports "nothing to backfill"; the composition root wires
    /// both. Run under the SAME `ingestLock` as ingest, so a backfill never writes derived rows
    /// concurrently with an ingest→derive pass.
    private let derivationCoordinator: DerivationCoordinator?
    private let scoreBackfillStore: ScoreBackfillRequestStore
    /// D-35 item 2b. `makeHistoricalPort` is a FACTORY rather than a stored port because the walk
    /// builds one reader per month chunk, and because a bridge wired without it (a narrow test, or
    /// a build where the feature is off) must report "nothing to resume" rather than half-run.
    private let historicalImportStore: HistoricalImportRequestStore
    private let makeHistoricalPort: (() -> HealthStorePort)?

    /// The single mutex around the ingest→derive chain.
    ///
    /// Before EPIC-04 there was exactly one caller (`AppEnvironment`'s `pipelineTask` chain), so
    /// serialization was a side effect of there being nowhere else to call from. Observer wakes
    /// and BG tasks break that: they run on their own queues, outside the main actor, and can
    /// land mid-foreground-sync. Two concurrent passes over the same HealthKit anchors would each
    /// read the same delta and write it twice — idempotent at the row level (upsert by external
    /// id), but it doubles the work and puts two independent `pendingAnchors` sets in flight
    /// against one `read_anchors` row, which is precisely the DATA-08 hazard the two-phase commit
    /// exists to avoid. One lock, every caller.
    private let ingestLock = NSLock()

    /// How many days of insights one `deriveAndGenerateInsights` call regenerates.
    ///
    /// Mirrors `SeedController.deriveAndGenerateInsights`'s loop bound. Duplicated rather than
    /// exposed from `SeedController` because this stage does not own that file; if the two ever
    /// disagree the only casualty is a count in the diagnostics log, never data — but fold this
    /// into `SeedController` the next time that file is opened.
    static let insightDaysPerDerive = 14

    /// The backfill window, matching every other caller of `ingestHealthData`.
    static let historyDays = 90

    init(seedController: SeedController, main: SQLiteConnection,
         makePort: @escaping () -> HealthStorePort?, connected: @escaping () -> Bool,
         derivationCoordinator: DerivationCoordinator? = nil,
         scoreBackfillStore: ScoreBackfillRequestStore = ScoreBackfillRequestStore(),
         historicalImportStore: HistoricalImportRequestStore = HistoricalImportRequestStore(),
         makeHistoricalPort: (() -> HealthStorePort)? = nil) {
        self.seedController = seedController
        self.main = main
        self.makePort = makePort
        self.connected = connected
        self.derivationCoordinator = derivationCoordinator
        self.scoreBackfillStore = scoreBackfillStore
        self.historicalImportStore = historicalImportStore
        self.makeHistoricalPort = makeHistoricalPort
    }

    var isHealthKitConnected: Bool { connected() }

    /// Age of the freshest persisted read anchor.
    ///
    /// Read straight off `read_anchors` rather than through `ReadAnchorRepository`, which exposes
    /// only per-`(store, platformType)` lookups and is not a file this stage owns. Fold this into
    /// that repository the next time it is touched — it belongs there, and a raw query in a
    /// bridge is the kind of thing that quietly multiplies.
    func anchorAge(now: Date) -> TimeInterval? {
        guard let row = try? main.query("SELECT MAX(updated_at) AS newest FROM read_anchors;").first,
              let newest = row.date("newest") else { return nil }
        return max(0, now.timeIntervalSince(newest))
    }

    func ingestAndDerive(now: Date) throws -> BackgroundWorkCounts {
        ingestLock.lock()
        defer { ingestLock.unlock() }
        return try performIngest(now: now)
    }

    func tryIngestAndDerive(now: Date) throws -> BackgroundWorkCounts? {
        guard ingestLock.try() else { return nil }
        defer { ingestLock.unlock() }
        return try performIngest(now: now)
    }

    func needsBackfillResume() -> Bool {
        (try? seedController.needsBackfillResume()) ?? false
    }

    func resumeBackfill(now: Date) throws -> BackgroundWorkCounts? {
        guard ingestLock.try() else { return nil }
        defer { ingestLock.unlock() }
        return try performIngest(now: now)
    }

    func hasPendingScoreBackfill() -> Bool {
        derivationCoordinator != nil && scoreBackfillStore.pending() != nil
    }

    /// Re-derive the queued window through the coordinator (baselines → effort → sleep → readiness),
    /// under the ingest lock so it never overlaps an ingest→derive pass, and clear the request only on
    /// success. `nil` (leaving the request queued) when nothing is queued, the score engines aren't
    /// wired, or another derivation holds the lock — so the next wake retries. Returns empty counts:
    /// the appended derived rows and the cleared request are the evidence; there is no honest existing
    /// `BackgroundWorkCounts` field for "score-days re-derived", and misusing one would be worse than
    /// leaving the (still-logged) processing run's payload empty.
    func runPendingScoreBackfill(now: Date) throws -> BackgroundWorkCounts? {
        guard let coordinator = derivationCoordinator, let window = scoreBackfillStore.pending() else { return nil }
        guard ingestLock.try() else { return nil }
        defer { ingestLock.unlock() }
        _ = try coordinator.backfill(from: window.from, to: window.to)
        scoreBackfillStore.clear()
        return BackgroundWorkCounts()
    }

    /// Resume an interrupted historical import from its persisted cursor.
    ///
    /// Under the same `ingestLock` as every other ingest, so a resumed walk can never interleave
    /// with a live sync — two passes writing the same rows would be idempotent but would also put
    /// two `pendingAnchors` sets in flight, which is the DATA-08 hazard the lock exists for.
    ///
    /// Returns empty counts for the same reason `runPendingScoreBackfill` does: the written rows and
    /// the cleared request are the evidence, and there is no honest `BackgroundWorkCounts` field for
    /// "months fetched" to borrow.
    func resumeHistoricalImportIfPending(now: Date) throws -> BackgroundWorkCounts? {
        guard let makeHistoricalPort, let coordinator = derivationCoordinator,
              historicalImportStore.resumePoint() != nil else { return nil }
        guard ingestLock.try() else { return nil }
        defer { ingestLock.unlock() }
        _ = HistoricalImportCoordinator(
            pipeline: seedController.ingestionPipeline, derivation: coordinator,
            requests: historicalImportStore, tz: TimeZone.current.identifier
        ).run(makeReader: makeHistoricalPort)
        return BackgroundWorkCounts()
    }

    /// The one ingest path. `ingestHealthData` runs HealthKit's anchored queries, so a repeat call
    /// is incremental, not a re-backfill — the same property `AppEnvironment.syncIfStale()` relies
    /// on (BUG-02) and the reason an observer wake can safely follow every change signal.
    private func performIngest(now: Date) throws -> BackgroundWorkCounts {
        guard let port = makePort() else { return BackgroundWorkCounts() }
        let summary = try seedController.ingestHealthData(from: port, historyDays: Self.historyDays, asOf: now)
        try seedController.deriveAndGenerateInsights(asOf: now)
        return BackgroundWorkCounts(samples: summary.samples, intervals: summary.intervals,
                                    sessions: summary.sessions, suppressed: summary.suppressed,
                                    insightDays: Self.insightDaysPerDerive)
    }
}
