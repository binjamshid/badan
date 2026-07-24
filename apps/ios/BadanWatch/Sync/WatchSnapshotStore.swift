import Foundation

/// A22/EPIC-42. A purely local, on-watch cache of the last-received snapshot — NOT an app-group
/// (there is no app-group mechanism between a Watch and an iPhone at all; see `Snapshot/
/// AmbientSnapshotDto.swift`'s header for why). This exists only so `SnapshotReceiver` can recover
/// the last known state across a watch-app relaunch: `WCSession.receivedApplicationContext` (the
/// OS's own cache) already hands back the latest context synchronously, but only for as long as the
/// underlying WatchConnectivity daemon retains it for this process — persisting the decoded pair
/// ourselves is a small, cheap belt-and-suspenders duplicate of that. A fresh install with no cache
/// file yet is an honest `nil`, not an error.
struct WatchSnapshotStore {
    private struct CachedEntry: Codable {
        let snapshot: AmbientSnapshotDto
        let receivedAt: Date
    }

    private let fileManager: FileManager
    /// Test-only override for the cache directory — production always resolves the real
    /// per-app Application Support directory; a test injects a throwaway temp directory instead.
    private let overrideDirectory: URL?

    init(fileManager: FileManager = .default, overrideDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.overrideDirectory = overrideDirectory
    }

    private func fileURL() -> URL? {
        let directory = overrideDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return directory?.appendingPathComponent("watch_snapshot_cache.json")
    }

    /// Best-effort: a failed write here just means a future cold relaunch falls back to
    /// `WCSession.receivedApplicationContext` (or an honest `.neverSynced` state) instead of this
    /// cache — never worth crashing or surfacing an error for a small local convenience cache.
    func write(snapshot: AmbientSnapshotDto, receivedAt: Date) {
        guard let url = fileURL() else { return }
        do {
            let directory = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let data = try Self.encoder.encode(CachedEntry(snapshot: snapshot, receivedAt: receivedAt))
            try data.write(to: url, options: .atomic)
        } catch {
            // Intentionally swallowed — see this method's doc.
        }
    }

    func read() -> (snapshot: AmbientSnapshotDto, receivedAt: Date)? {
        guard let url = fileURL(), let data = try? Data(contentsOf: url),
              let entry = try? Self.decoder.decode(CachedEntry.self, from: data) else { return nil }
        return (entry.snapshot, entry.receivedAt)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
