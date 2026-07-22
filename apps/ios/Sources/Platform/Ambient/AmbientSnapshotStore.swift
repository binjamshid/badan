import Foundation

/// Reads/writes the single bounded JSON snapshot file the main app leaves for the `BadanWidgets`
/// extension in the shared app-group container (blueprint §24.1 "the snapshot pattern" — see
/// `AmbientSnapshotDto`'s header for the full rationale). This is the ONLY channel between BADAN
/// and its widgets.
///
/// *** Cross-target duplication is deliberate here, not an oversight. ***
/// A WidgetKit extension cannot import the main app's `Sources/` target (an App Extension links
/// against its own module), so `apps/ios/BadanWidgets/` needs its OWN copy of:
///   1. `AmbientSnapshotDto` (this file's sibling) — the identical field names/types/optionality,
///      so the JSON round-trips unchanged.
///   2. The READ half of this file's logic — resolving the app-group container URL at the same
///      relative path and decoding the JSON file there.
/// The two copies share ONLY the app-group container id (`containerGroupId`) and the filename
/// below, plus the DTO's JSON shape — never Swift source, a build target, or a binary framework.
/// This lane (`Sources/Platform/Ambient/`) owns the WRITE side (and reads its own writes back, for
/// its own consistency and for tests); the widget lane owns a separate, read-only twin under
/// `BadanWidgets/` that this lane must not create or edit.
struct AmbientSnapshotStore {
    /// Must match the identical string declared in both `apps/ios/App/BADAN.entitlements` and
    /// `apps/ios/BadanWidgets/BadanWidgets.entitlements` — see those files' comments for why a
    /// mismatch fails silently (empty reads, no runtime error) rather than loudly.
    static let containerGroupId = "group.net.binjamshid.badan"
    static let snapshotFilename = "ambient_snapshot.json"

    private let fileManager: FileManager
    /// Test-only override for the shared container root. Production always resolves the real
    /// app-group container; tests inject a throwaway temp directory instead, since a unit-test
    /// bundle is not guaranteed to carry the app-group entitlement/signing identity the real
    /// container URL resolution depends on. `nil` (the production default) means "ask
    /// `fileManager` for the real container."
    private let overrideContainerURL: URL?

    init(fileManager: FileManager = .default, overrideContainerURL: URL? = nil) {
        self.fileManager = fileManager
        self.overrideContainerURL = overrideContainerURL
    }

    /// The shared container URL, or `nil` if the app-group entitlement is missing/misconfigured.
    /// Callers treat that as "no snapshot available" rather than crashing — a provisioning-profile
    /// mistake must degrade to an empty widget state, never a startup crash.
    private func containerURL() -> URL? {
        overrideContainerURL ?? fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.containerGroupId)
    }

    private func snapshotURL() -> URL? {
        containerURL()?.appendingPathComponent(Self.snapshotFilename)
    }

    /// Overwrite the shared snapshot file. Called ONLY by the main app (the write side — the
    /// widget extension only ever calls `read()`). `.atomic` guards against partial-write
    /// corruption from a process death mid-write; there is no separate temp-file/rename dance
    /// beyond that, since the file is small and bounded (never a growing log) and losing one
    /// write to a rare race is invisible — the next debounced write a few seconds later corrects it.
    func write(_ dto: AmbientSnapshotDto) throws {
        guard let url = snapshotURL() else { throw AmbientSnapshotStoreError.containerUnavailable }
        if let dir = containerURL(), !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try Self.encoder.encode(dto)
        try data.write(to: url, options: .atomic)
    }

    /// Read the current snapshot, or `nil` if none has ever been written, the container is
    /// unavailable, or the file exists but fails to decode. A decode failure degrades to "no
    /// snapshot" — never a crash: a widget showing its placeholder/empty state is always safer
    /// than one that force-unwraps a corrupt read. N-1 schema tolerance lives on
    /// `AmbientSnapshotDto.init(from:)` itself (see that type) — this method is a thin,
    /// non-throwing wrapper over it, so a genuinely unreadable file (not just an older shape)
    /// still degrades quietly rather than propagating a decode error to a caller that has no
    /// good way to act on one.
    func read() -> AmbientSnapshotDto? {
        guard let url = snapshotURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(AmbientSnapshotDto.self, from: data)
    }

    // Deliberately unconfigured — see `AmbientSnapshotDto`'s header for why the plain Foundation
    // default (`.deferredToDate`) is the safer cross-target choice here than an explicit strategy.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}

enum AmbientSnapshotStoreError: Error {
    case containerUnavailable
}
