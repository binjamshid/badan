import Foundation
import WatchConnectivity
import Observation

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

    /// Real production wiring: `WCSession.isSupported()` is false on devices with no companion-app
    /// pairing capability at all — `session` stays `nil` and this app falls back to whatever
    /// `store` has cached (or an honest `.neverSynced` state) rather than crashing.
    private override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        self.store = WatchSnapshotStore()
        super.init()
        restoreFromCache()
        activateAndCheckPendingContext()
    }

    /// Test seam: a test supplies `session: nil` and/or an overridden `store` to exercise this
    /// type's decode/cache logic without touching the real WatchConnectivity runtime (unsupported
    /// in a plain unit-test bundle anyway) or the real on-disk Application Support directory. (A
    /// plain designated initializer, not `convenience`, so it stays independent of the no-arg
    /// initializer's own `override` obligation to `NSObject.init()`.)
    init(session: WCSession?, store: WatchSnapshotStore) {
        self.session = session
        self.store = store
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
        // `receivedApplicationContext` is available synchronously the moment the session object
        // exists, even before `activate()`'s completion or any delegate callback fires — covers
        // the case where the phone pushed a context while this watch app was not running at all.
        if let context = session?.receivedApplicationContext,
           let data = context[WatchSnapshotSyncKeys.applicationContextKey] as? Data {
            apply(data: data, receivedAt: .now)
        }
    }

    /// Exposed (not `private`) so tests can feed raw payload bytes directly, exercising the exact
    /// decode path `didReceiveApplicationContext` uses, without needing a real `WCSession` push.
    func apply(data: Data, receivedAt: Date) {
        guard let dto = try? Self.decoder.decode(AmbientSnapshotDto.self, from: data) else { return }
        self.snapshot = dto
        self.receivedAt = receivedAt
        store.write(snapshot: dto, receivedAt: receivedAt)
    }

    private static let decoder = JSONDecoder()
}

extension SnapshotReceiver: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSnapshotSyncKeys.applicationContextKey] as? Data else { return }
        // WCSessionDelegate callbacks land on a background queue by default — every reader of
        // `snapshot`/`receivedAt` is watch-side SwiftUI, so hop to main before mutating.
        DispatchQueue.main.async { [weak self] in
            self?.apply(data: data, receivedAt: .now)
        }
    }
}
