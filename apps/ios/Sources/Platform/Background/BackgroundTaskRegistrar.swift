import BackgroundTasks
import Foundation
import os

/// The two identifiers ADR-0009 §A2 fixed and `project.yml` declares in
/// `BGTaskSchedulerPermittedIdentifiers`.
///
/// `BGTaskScheduler.register(forTaskWithIdentifier:)` raises — not returns false, *raises* — if
/// an identifier is absent from that plist array, so the list there and the constants here are
/// one unit. They read `net.albayyan.*` while `PRODUCT_BUNDLE_IDENTIFIER` is `net.binjamshid.badan`;
/// that mismatch is intentional and documented in `project.yml` (BGTaskScheduler does not require
/// the bundle-id prefix). Do not "correct" either side alone.
enum BackgroundTaskIdentifier {
    static let refresh = "net.albayyan.badan.refresh"
    static let processing = "net.albayyan.badan.processing"
}

/// Why `BGTaskScheduler.submit(_:)` refused a request (BUG-BG-01).
///
/// The two cases are not the same kind of event and must not be collapsed back into one:
/// `.unavailable` means BADAN will get *no* wakes of that class until something outside this
/// process changes, while everything else is a transient condition that the next submit clears.
/// The distinction is what makes an `error` row in `background_runs` actionable rather than noise.
enum BackgroundSubmitDecline {
    /// `BGTaskSchedulerError.unavailable`. A standing condition with three known causes, in the
    /// order worth checking: a missing `UIBackgroundModes` entry (the BUG-BG-01 defect itself —
    /// affects every install of the build), the user's Background App Refresh switch being off
    /// (affects one device, and is their choice), or the simulator, which schedules nothing at
    /// all. None of these resolve by retrying, which is why this is logged at error level and
    /// recorded — it is a configuration fact, not a hiccup.
    case unavailable
    /// Anything else — `.tooManyPendingTaskRequests` and friends. Genuinely transient.
    case transient
}

/// A thread-safe "the OS wants this task back" flag.
///
/// `BGTask.expirationHandler` fires on a different queue from the task body, and the body needs
/// to poll it between steps so it can checkpoint and exit cleanly rather than being killed
/// mid-step. Passed into the work as a plain `() -> Bool` so the coordinator's logic never has to
/// import `BackgroundTasks` to be testable.
final class ExpirationSignal {
    private let lock = NSLock()
    private var expired = false

    func markExpired() {
        lock.lock(); defer { lock.unlock() }
        expired = true
    }

    var isExpired: Bool {
        lock.lock(); defer { lock.unlock() }
        return expired
    }
}

/// `BGTaskScheduler` registration and submission (plan §13.4).
///
/// Two task types, deliberately different in weight:
/// - **`refresh`** (`BGAppRefreshTask`) — light. Top up sync if anchors are stale, evaluate due
///   automations, prune. Submitted on every backgrounding *and* re-submitted at the head of each
///   run, because a request is consumed when it runs and a chain that forgets to re-arm itself
///   stops after exactly one wake.
/// - **`processing`** (`BGProcessingTask`) — heavy and checkpointed. Historical backfills and
///   (once EPIC-13/14 land) large exports. Submitted only when there is heavy work pending, so
///   an idle install does not spend its share of a system-wide, battery-rationed budget on
///   waking up to discover there is nothing to do.
///
/// Nothing here promises a wall-clock time, and no caller may (plan §13.7). `earliestBeginDate`
/// is a *floor*, not a schedule: iOS decides when — or whether — these actually run, based on
/// usage patterns, battery, and thermal state. UI copy for anything driven by this says
/// "best-effort background".
final class BackgroundTaskRegistrar {
    /// The work a task performs. Returns `true` if the run completed, `false` if it checkpointed
    /// and exited early — which maps directly onto `BGTask.setTaskCompleted(success:)`.
    typealias TaskBody = (_ isExpired: @escaping () -> Bool) -> Bool

    /// Called when a submit is refused, with the request's identifier. Deliberately has no
    /// default: BUG-BG-01 shipped because a declined submit went nowhere, and a no-op default
    /// would let the next call site reintroduce exactly that.
    typealias DeclineHandler = (_ identifier: String, _ reason: BackgroundSubmitDecline) -> Void

    private let runRefresh: TaskBody
    private let runProcessing: TaskBody
    private let onSubmitDeclined: DeclineHandler
    private let lock = NSLock()
    private var hasRegistered = false

    init(runRefresh: @escaping TaskBody, runProcessing: @escaping TaskBody,
         onSubmitDeclined: @escaping DeclineHandler) {
        self.runRefresh = runRefresh
        self.runProcessing = runProcessing
        self.onSubmitDeclined = onSubmitDeclined
    }

    // MARK: - Registration

    /// Register both launch handlers. **Must run before the app finishes launching** — that is
    /// `BGTaskScheduler`'s hard requirement, and it is why `BADANApp.init()` calls this rather
    /// than the scene's `.task`, which runs too late and only when a scene actually connects.
    /// (iOS can launch BADAN straight into the background to run one of these; in that launch
    /// there may never be a connected scene at all.)
    ///
    /// Idempotent: a second call is a no-op. Registering the same identifier twice raises, and
    /// "called once from init" is the kind of assumption a future refactor breaks silently.
    func registerLaunchHandlers() {
        lock.lock()
        guard !hasRegistered else { lock.unlock(); return }
        hasRegistered = true
        lock.unlock()

        // `using: nil` runs the launch handler on a system-provided background queue, so the
        // work below runs inline rather than hopping — the task's wall-clock budget starts the
        // moment the handler is entered, and a queue hop spends it on nothing.
        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskIdentifier.refresh, using: nil) { [weak self] task in
                guard let self else { task.setTaskCompleted(success: false); return }
                self.run(task, body: self.runRefresh, resubmit: { self.scheduleAppRefresh() })
            }
        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskIdentifier.processing, using: nil) { [weak self] task in
                guard let self else { task.setTaskCompleted(success: false); return }
                // Processing is NOT re-armed automatically. It is submitted only when there is
                // heavy work pending (see `BackgroundCoordinator.applicationDidEnterBackground`);
                // re-arming unconditionally would keep asking the system for an expensive wake
                // in order to discover there is nothing to do.
                self.run(task, body: self.runProcessing, resubmit: nil)
            }

        Log.logger.info("""
            BGTask handlers registered — refresh: \(refreshRegistered, privacy: .public), \
            processing: \(processingRegistered, privacy: .public)
            """)
    }

    /// Shared body: wire expiration → signal, run the work, complete exactly once.
    ///
    /// Re-submission happens *first*, before the work. If the work throws the app into a crash or
    /// the OS kills it mid-run, a request submitted up front still keeps the chain alive; a
    /// request submitted after the work would be lost with it, and background refresh would
    /// silently never fire again until the next time the user backgrounded the app by hand.
    private func run(_ task: BGTask, body: TaskBody, resubmit: (() -> Void)?) {
        resubmit?()
        let signal = ExpirationSignal()
        task.expirationHandler = { signal.markExpired() }
        let success = body({ signal.isExpired })
        task.setTaskCompleted(success: success)
    }

    // MARK: - Submission

    /// Ask for a light refresh wake. Called on every backgrounding and at the head of each
    /// refresh run.
    ///
    /// `earliestBeginDate` is a floor of 15 minutes — the shortest interval iOS will honour at
    /// all — and emphatically not a promise that anything runs then.
    ///
    /// A submit that throws is not fatal to the caller — the app is fully up to date the moment
    /// the user opens it either way — but it is *not* nothing, which is what the pre-BUG-BG-01
    /// version of this comment claimed. A refused submit means this wake class never fires, and
    /// on a build missing its `UIBackgroundModes` entry it is refused every single time. See
    /// `submit(_:)`.
    func scheduleAppRefresh(earliestIn seconds: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskIdentifier.refresh)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        submit(request)
    }

    /// Ask for a heavy processing wake. Callers gate this on there actually being heavy work
    /// pending — see `BackgroundCoordinator.applicationDidEnterBackground()`.
    ///
    /// `requiresExternalPower = false` is the "charging-**preferred**, not required" of plan
    /// §13.4 and the EPIC-04 card. There is no "preferred" flag in `BGProcessingTaskRequest`;
    /// setting `requiresExternalPower = true` would make it a hard requirement and strand the
    /// backfill of any user who does not charge overnight with the phone unlocked. `BGProcessing`
    /// already favours charging-and-idle by system policy, so `false` yields the intended
    /// behaviour — "usually runs while charging" (the honest UI label, plan §13.7) — without the
    /// never-runs failure mode. Do not flip this to `true` to "make it more efficient".
    ///
    /// `requiresNetworkConnectivity = false` because BADAN has no backend (ADR-0002). Nothing in
    /// a processing run touches the network, and requiring connectivity would add a constraint
    /// the work cannot benefit from.
    func scheduleProcessing(earliestIn seconds: TimeInterval = 60 * 60) {
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskIdentifier.processing)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        submit(request)
    }

    /// BUG-BG-01. This method used to swallow every submit error at `.info` level and tell no one.
    /// That is how the app shipped for months with no `UIBackgroundModes` entry: on device
    /// `submit(_:)` threw `.unavailable` on every call, registration still succeeded, the launch
    /// handlers were simply never invoked, and the only evidence was an `.info` line nobody reads.
    /// `background_runs` looked plausible the whole time because observer wakes and foreground
    /// syncs kept writing rows. Every path out of here is now loud; if you find yourself quieting
    /// one, you are undoing the fix.
    ///
    /// `.unavailable` is separated from the rest because it is a *misconfiguration*, not a
    /// transient condition — see `BackgroundSubmitDecline.unavailable` for the three causes. It
    /// will not clear on its own, so retrying is pointless and treating it as noise is how it
    /// stays invisible.
    ///
    /// Still value-free, and for the same reason as before: identifiers and error codes only.
    /// A `BGTaskScheduler` error carries no health data, but the habit is the protection.
    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            let isUnavailable = (error as? BGTaskScheduler.Error)?.code == .unavailable
            let reason: BackgroundSubmitDecline = isUnavailable ? .unavailable : .transient
            Log.logger.error("""
                BGTask submit declined for \(request.identifier, privacy: .public): \
                \(String(describing: reason), privacy: .public) \
                (\(String(describing: type(of: error)), privacy: .public))
                """)
            // Off to `background_runs` via the coordinator, so a decline is visible in
            // Diagnostics and in the soak's outcome mix rather than only in a log stream nobody
            // is attached to on the device where it matters.
            onSubmitDeclined(request.identifier, reason)
        }
    }

    /// Drop pending requests. Used by tests and by nothing in the shipping app — noted because
    /// its absence from the app is deliberate: BADAN never cancels a pending wake, since a wake
    /// that finds nothing to do is cheap and a chain that cancels itself is hard to restart.
    func cancelAllPending() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }

    private enum Log {
        static let logger = Logger(subsystem: "net.binjamshid.badan", category: "BackgroundTasks")
    }
}
