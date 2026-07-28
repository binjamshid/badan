import Foundation
import WatchConnectivity
import os

/// A22/EPIC-42 (Phase 4). The ONE new phone-to-watch transport this slice adds, exactly as the
/// blueprint's §24.4 "data-sync decision" names it: `WCSession.updateApplicationContext` carrying
/// the SAME `AmbientSnapshotDto` `AmbientSnapshotStore` already writes for `BadanWidgets` —
/// "guaranteed-latest semantics fit snapshot data" (the blueprint's own phrase).
/// `updateApplicationContext` replaces any previously queued context rather than accumulating a
/// backlog, which is exactly right for "only the newest snapshot matters" data.
///
/// This is deliberately the ONLY phone-to-watch channel this slice opens: read-only, one-way, no
/// bidirectional message protocol, no live `WCSession.sendMessage`. A Watch and an iPhone are
/// separate physical devices with separate filesystems — the app-group container `BadanWidgets`
/// reads never reaches the watch at all (confirmed absent from every existing code path; see this
/// slice's own recon) — so WatchConnectivity is the only mechanism available for this hop, not a
/// choice among several.
///
/// Delivery is best-effort by design: a failed or as-yet-undelivered context update is never
/// retried by this type. `updateApplicationContext`'s own documented guarantee ("delivered next
/// time the watch app is reachable, superseding any earlier undelivered context") is already the
/// right behavior for snapshot data — see `BadanWatch/Sync/SnapshotReceiver.swift` and
/// `BadanWatch/Snapshot/SnapshotFreshness.swift` for what the watch shows while nothing has landed
/// yet, or the last landed context is old.
final class WatchSnapshotSync: NSObject {
    static let shared = WatchSnapshotSync()

    /// The dictionary key `sync(_:)` files the encoded snapshot under — `SnapshotReceiver`
    /// (`BadanWatch/Sync/SnapshotReceiver.swift`) reads this SAME literal string back out of
    /// `WCSession`'s `applicationContext`/`didReceiveApplicationContext`. Kept as one named
    /// constant here (rather than a bare string on both sides) precisely because, per this file's
    /// own header, the two sides can never be type-checked against each other — a typo in either
    /// copy is a silent "the watch never receives anything," never a compiler error.
    static let applicationContextKey = "snapshot"

    /// The message body the watch sends to ask the phone for a fresh sync. Same hand-kept-duplicate
    /// discipline as `applicationContextKey`: `WatchSnapshotSyncKeys` on the watch side carries the
    /// identical literal, because the two targets cannot be type-checked against each other and a
    /// typo here is silence, never a compile error.
    static let refreshRequestKey = "requestRefresh"

    /// Called when the watch asks for a refresh. Set by the composition root.
    ///
    /// D-34: this makes the channel bidirectional, which this file's own header previously ruled
    /// out ("no bidirectional message protocol, no live `WCSession.sendMessage`"). The narrower
    /// reading of that decision survives intact and is what made the reversal acceptable: snapshot
    /// DELIVERY is still one-way `updateApplicationContext`, still latest-wins, still with no
    /// queue to drain. What is added is a zero-payload nudge in the other direction — the watch
    /// carries no data to the phone and asks for none, it only says "the user tapped Sync". Without
    /// it a Sync button on the watch cannot exist at all, since the watch holds no HealthKit
    /// ingestion path of its own.
    ///
    /// A `var` closure rather than a constructor parameter for the same reason
    /// `BackgroundCoordinator.onIngestCompleted` is: this is a singleton created before
    /// `AppEnvironment` finishes initialising, so the capture has to happen afterwards.
    var onRefreshRequested: (() -> Void)?

    private let session: WCSession?
    private static let logger = Logger(subsystem: "net.binjamshid.badan", category: "WatchSnapshotSync")
    private static let encoder = JSONEncoder()

    /// Real production wiring: `WCSession.isSupported()` is false on devices with no Watch pairing
    /// capability at all (a real, common, honest state, not an error) — `session` stays `nil` and
    /// `sync(_:)` becomes a harmless no-op rather than crashing on `WCSession.default`.
    private override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// Test seam: a test supplies `session: nil` to exercise the "unsupported"/no-op path without
    /// touching the real WatchConnectivity runtime, which a plain unit-test bundle has no
    /// pairing/entitlement state for anyway. Production only ever calls the no-arg initializer
    /// above. (A plain designated initializer, not a `convenience` one, so it stays independent of
    /// the no-arg initializer's own `override` obligation to `NSObject.init()`.)
    init(session: WCSession?) {
        self.session = session
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// Encode `dto` and push it as the watch's application context. Bound as `AmbientSnapshotWriter`
    /// `syncToWatch` closure (see that type's init) — invoked once per successful write, right
    /// alongside the app-group file write and the widget-timeline reload, so every transport this
    /// app has stays in lockstep off the ONE dto the writer assembled. Never throws to its caller:
    /// a sync failure here must not fail the write that already landed on disk for `BadanWidgets`.
    func sync(_ dto: AmbientSnapshotDto) {
        guard let session, session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext(Self.applicationContext(for: dto))
        } catch {
            Self.logger.error("watch snapshot sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Pure, side-effect-free translation from a snapshot to the wire payload `updateApplicationContext`
    /// carries — factored out specifically so it is directly unit-testable without a real,
    /// activated `WCSession` (this host has no paired Watch to activate a session against, and
    /// `WCSession.isSupported()` reliably returns `false` inside a plain unit-test bundle anyway,
    /// so `sync(_:)`'s own guard would make its encode step untestable otherwise). `sync(_:)` above
    /// is the only production caller.
    static func applicationContext(for dto: AmbientSnapshotDto) throws -> [String: Any] {
        [applicationContextKey: try encoder.encode(dto)]
    }
}

extension WatchSnapshotSync: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            Self.logger.error("WCSession activation failed: \(String(describing: error), privacy: .public)")
        }
    }

    // iOS-only `WCSessionDelegate` requirements (iOS supports multiple paired Watches across a
    // device's lifetime; watchOS's own delegate protocol has neither). No state to reset on either
    // callback — this type holds nothing beyond the session reference itself.
    /// The watch asked for a refresh (D-34). Both delivery routes land here: `sendMessage` when the
    /// phone is reachable, `transferUserInfo` when it is not and the request is queued for later.
    ///
    /// Deliberately ignores the message CONTENTS beyond checking the flag. The watch is not a
    /// trusted commander of this app — it is allowed to say "the user tapped Sync" and nothing else,
    /// and treating the payload as data to act on would turn a nudge into a remote-control surface.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message[Self.refreshRequestKey] != nil else { return }
        onRefreshRequested?()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[Self.refreshRequestKey] != nil else { return }
        onRefreshRequested?()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for a newly paired Watch, per Apple's documented pattern for this callback.
        session.activate()
    }
}
