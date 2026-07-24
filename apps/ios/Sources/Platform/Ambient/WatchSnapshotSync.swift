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
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for a newly paired Watch, per Apple's documented pattern for this callback.
        session.activate()
    }
}
