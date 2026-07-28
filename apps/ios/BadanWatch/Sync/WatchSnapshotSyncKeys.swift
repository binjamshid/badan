import Foundation

/// A22/EPIC-42. Must match `WatchSnapshotSync.applicationContextKey` on the phone side
/// (`apps/ios/Sources/Platform/Ambient/WatchSnapshotSync.swift`) EXACTLY — this target cannot
/// import that file (separate watchOS module), so, like `Snapshot/AmbientSnapshotDto.swift`'s DTO
/// shape, this is a deliberate hand-kept duplicate rather than a shared Swift symbol. A mismatch
/// here fails silently: this watch app would simply never find a "snapshot" key in whatever
/// `WCSession` hands it, and stay in the honest `.neverSynced` state forever rather than throwing
/// an error anywhere. `WatchSnapshotSyncTests` (the iOS side) and `SnapshotReceiverTests` (this
/// target) each pin their own side's literal, which is the closest either side can get to a
/// compiler-checked guarantee across this boundary.
enum WatchSnapshotSyncKeys {
    static let applicationContextKey = "snapshot"

    /// D-34. Must match `WatchSnapshotSync.refreshRequestKey` on the phone side, with the same
    /// silent-failure consequence as `applicationContextKey`: a mismatch means the phone quietly
    /// never hears a Sync tap, and the watch waits for a push that is never triggered.
    static let refreshRequestKey = "requestRefresh"
}
