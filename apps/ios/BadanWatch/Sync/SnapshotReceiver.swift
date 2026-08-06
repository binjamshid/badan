import Foundation
import WatchConnectivity
import Observation
import WidgetKit

/// blueprint §24.4's named receiver for the phone's `WatchSnapshotSync.updateApplicationContext`
/// pushes (`apps/ios/Sources/Platform/Ambient/WatchSnapshotSync.swift`). This is the ONLY inbound
/// channel this target has: no HealthKit read, no SQLite, no direct app-group access (a Watch and
/// an iPhone are separate physical devices with separate filesystems — see `Snapshot/
/// AmbientSnapshotDto.swift`'s header). Every screen in `BadanWatch` renders off whatever this type
/// currently holds, nothing else.
@Observable
final class SnapshotReceiver: NSObject {
    static let shared = SnapshotReceiver()

    /// The most recently received snapshot, or `nil` if this watch has never received one at all —
    /// a real, distinct, honestly-labelled state (`SnapshotFreshness.State.neverSynced`), never
    /// conflated with an old one.
    private(set) var snapshot: AmbientSnapshotDto?
    /// When THIS device (the watch) last received an application-context push — distinct from
    /// `snapshot?.generatedAt` (when the PHONE computed it, which is the number
    /// `TodayViewState`/`SnapshotFreshness` actually key off). Kept for completeness/diagnostics;
    /// no screen in this slice reads it directly.
    private(set) var receivedAt: Date?

    private let session: WCSession?
    private let store: WatchSnapshotStore

    /// Test seam, mirroring `AmbientSnapshotWriter.reloadWidgets` on the phone side exactly:
    /// production always nudges the real WidgetKit runtime, a test injects a counting/no-op closure
    /// instead, since a plain unit-test bundle has no installed complication to observe reloading.
    private let reloadComplications: () -> Void

    /// Real production wiring: `WCSession.isSupported()` is false on devices with no companion-app
    /// pairing capability at all — `session` stays `nil` and this app falls back to whatever
    /// `store` has cached (or an honest `.neverSynced` state) rather than crashing.
    private override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        self.store = WatchSnapshotStore()
        self.reloadComplications = SnapshotReceiver.reloadRealComplications
        super.init()
        restoreFromCache()
        activateAndCheckPendingContext()
    }

    /// Test seam: a test supplies `session: nil` and/or an overridden `store` to exercise this
    /// type's decode/cache logic without touching the real WatchConnectivity runtime (unsupported
    /// in a plain unit-test bundle anyway) or the real on-disk Application Support directory. (A
    /// plain designated initializer, not `convenience`, so it stays independent of the no-arg
    /// initializer's own `override` obligation to `NSObject.init()`.)
    init(session: WCSession?, store: WatchSnapshotStore,
         reloadComplications: @escaping () -> Void = SnapshotReceiver.reloadRealComplications) {
        self.session = session
        self.store = store
        self.reloadComplications = reloadComplications
        super.init()
        restoreFromCache()
        activateAndCheckPendingContext()
    }

    private func restoreFromCache() {
        guard let cached = store.read() else { return }
        snapshot = cached.snapshot
        receivedAt = cached.receivedAt
    }

    private func activateAndCheckPendingContext() {
        session?.delegate = self
        session?.activate()
        // An opportunistic first look, NOT a guarantee. `receivedApplicationContext` is only
        // reliable once activation has completed, and `activate()` is asynchronous — reading the
        // property on the very next line can (and on a first launch after reinstall routinely
        // does) come back empty while a delivered context sits in the daemon, which is how the
        // watch ended up showing "Not synced with your phone yet" with real data already waiting.
        // The authoritative check is the one in `activationDidCompleteWith` below; this one just
        // saves a frame in the common case where the session was already activated.
        //
        // (This comment previously asserted the opposite — that the property "is available
        // synchronously the moment the session object exists, even before activate()'s completion".
        // It is not, and nothing re-checked afterwards, so the claim was the bug's cover story.)
        applyPendingContextIfAny()
    }

    /// Apply whatever context the WatchConnectivity daemon is currently holding for this app, if it
    /// is newer than what is already on screen.
    ///
    /// The freshness guard matters because this runs twice (once opportunistically before
    /// activation completes, once from the completion callback) and can also race a live
    /// `didReceiveApplicationContext` for the very same payload. `receivedApplicationContext` is
    /// the last context received, so re-applying it is at best a no-op — but re-applying it over a
    /// snapshot the phone generated LATER would walk the display backwards, and this app's whole
    /// contract is that it never shows an older number as the current one.
    private func applyPendingContextIfAny() {
        guard let context = session?.receivedApplicationContext,
              let data = context[WatchSnapshotSyncKeys.applicationContextKey] as? Data,
              let pending = try? Self.decoder.decode(AmbientSnapshotDto.self, from: data) else { return }
        if let current = snapshot, current.generatedAt >= pending.generatedAt { return }
        apply(pending, receivedAt: .now)
    }

    /// Ask the phone to sync now (D-34).
    ///
    /// The watch has no HealthKit ingestion path of its own — it renders a snapshot the phone
    /// assembles — so a Sync button here can only mean "phone, please go and look". This sends that
    /// nudge and nothing else: no payload, no data leaving the watch, no expectation of a reply. The
    /// refreshed snapshot arrives later through the ordinary one-way `applicationContext` push, the
    /// same route every other update takes.
    ///
    /// Two transports, chosen by reachability, because "reachable" is the exception on a watch and
    /// failing silently when the phone is in a pocket would make the button feel broken:
    /// - reachable → `sendMessage`, which arrives immediately.
    /// - not reachable → `transferUserInfo`, which the system queues and delivers when the phone
    ///   next wakes. The user's tap is not lost; it is deferred, which is the honest behaviour for a
    ///   device that is frequently out of contact.
    ///
    /// Returns whether the request was handed to the system at all — false only when there is no
    /// session (no pairing capability), which surfaces as a disabled control rather than a tap that
    /// appears to work and does nothing.
    @discardableResult
    func requestRefresh() -> Bool {
        guard let session, session.activationState == .activated else { return false }
        let body: [String: Any] = [WatchSnapshotSyncKeys.refreshRequestKey: true]
        if session.isReachable {
            // errorHandler is required for the delivery failure case; there is nothing to retry
            // here, since transferUserInfo below is the durable path and a failed live send simply
            // means the phone stopped being reachable mid-tap.
            session.sendMessage(body, replyHandler: nil) { _ in
                session.transferUserInfo(body)
            }
        } else {
            session.transferUserInfo(body)
        }
        return true
    }

    /// Exposed (not `private`) so tests can feed raw payload bytes directly, exercising the exact
    /// decode path `didReceiveApplicationContext` uses, without needing a real `WCSession` push.
    func apply(data: Data, receivedAt: Date) {
        guard let dto = try? Self.decoder.decode(AmbientSnapshotDto.self, from: data) else { return }
        apply(dto, receivedAt: receivedAt)
    }

    /// The single place a newly-known snapshot is committed — held, cached, and announced. Split
    /// out of `apply(data:receivedAt:)` so `applyPendingContextIfAny` can reuse it after its own
    /// decode rather than decoding the same bytes twice.
    private func apply(_ dto: AmbientSnapshotDto, receivedAt: Date) {
        self.snapshot = dto
        self.receivedAt = receivedAt
        store.write(snapshot: dto, receivedAt: receivedAt)
        // The complications are a SEPARATE process reading the cache this line above just rewrote
        // (`BadanWatchWidgets`, see that bundle's header) — writing the file tells them nothing.
        // Without this nudge their only refresh is the provider's own `.after(15 * 60)` policy,
        // which watchOS budgets and throttles, so a freshly-synced number could sit invisible on
        // the watch face for far longer than the snapshot it replaced was ever fresh. Announcing
        // it here — at the one moment new data actually exists — is the same discipline
        // `AmbientSnapshotWriter` follows on the phone, where every successful write reloads the
        // widget timelines rather than waiting for WidgetKit to come asking.
        reloadComplications()
    }

    private static let decoder = JSONDecoder()

    /// `reloadAllTimelines()` rather than three `reloadTimelines(ofKind:)` calls: all three
    /// complications read the SAME snapshot and every one of them is stale the instant a new one
    /// lands, so naming the kinds would only add a list to keep in sync with
    /// `BadanWatchWidgetsBundle` — and a kind renamed on one side without the other is a silent
    /// no-op, exactly the failure `AmbientSnapshotWriter.widgetKinds` documents living with.
    static func reloadRealComplications() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension SnapshotReceiver: WCSessionDelegate {
    /// Activation is asynchronous, and `receivedApplicationContext` is only dependable once it has
    /// completed — so this is where the pending-context check actually earns its keep. This
    /// callback used to be empty, which is why a first launch after a reinstall showed "Not synced
    /// with your phone yet" while a delivered context sat in the daemon, waiting for a push that
    /// had already happened and would not happen again.
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard error == nil, activationState == .activated else { return }
        // Same reason `didReceiveApplicationContext` hops: this callback lands on a background
        // queue, and every reader of `snapshot`/`receivedAt` is watch-side SwiftUI.
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingContextIfAny()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSnapshotSyncKeys.applicationContextKey] as? Data else { return }
        // WCSessionDelegate callbacks land on a background queue by default — every reader of
        // `snapshot`/`receivedAt` is watch-side SwiftUI, so hop to main before mutating.
        DispatchQueue.main.async { [weak self] in
            self?.apply(data: data, receivedAt: .now)
        }
    }
}
