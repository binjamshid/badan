import Foundation

// MARK: - Frozen shared DTO (EPIC-33 wave 1, blueprint §24.1 "snapshot pattern")
//
// This target (`BadanWidgets`) is a separate app-extension target with its own `sources:` entry
// in `project.yml` and CANNOT import anything from `apps/ios/Sources/` — WidgetKit extensions run
// under their own memory ceiling, can be launched before first-unlock (when a `NSFileProtection`-
// protected SQLCipher store is unreadable), and would contend with the main app for the same
// SQLite file locks if they opened it directly. So this extension NEVER opens the database. The
// ONLY channel from the main app is this bounded JSON snapshot file in the shared app-group
// container, written by the main app's `AmbientSnapshotStore` (apps/ios/Sources/Platform/Ambient/)
// and only ever READ here via `AmbientSnapshotReader` below.
//
// The struct shapes below are a byte-for-byte duplicate of the main app's copy at
// `apps/ios/Sources/Platform/Ambient/AmbientSnapshotDto.swift` — same field names, same order,
// same optionality, same date handling (both sides rely on `JSONEncoder`/`JSONDecoder`'s plain,
// unconfigured default `Date` strategy — deliberately NOT `.iso8601`, per the main-app copy's own
// header comment). This is a deliberate, expected duplication across the app/extension boundary,
// not a mistake to unify — but it also means the two copies are never type-checked against each
// other: a rename or shape change on one side without the other is a SILENT decode failure, never
// a compiler error. Change this file only in lockstep with the main app's copy.
struct AmbientSnapshotDto: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let generatedAt: Date
    /// "en" | "ar" — matches `AppLanguage.rawValue` on the main-app side. This extension has no
    /// access to the main app's `AppEnvironment`/`CustomizationProfile` (separate process, no
    /// shared runtime state beyond this file), so every widget resolves bilingual copy off THIS
    /// field alone, never a live app setting.
    let language: String

    let readiness: RingSnapshot?
    let sentence: SentenceSnapshot?
    let sleep: SleepSnapshot?
    /// nil = the meds-due widget's own per-widget consent key (`consent.widget.medsDue`,
    /// `CustomizationProfile.consentWidgetMedsDue` on the main-app side) has not been granted. An
    /// empty `items` array is a DIFFERENT, real state: consent IS granted and nothing happens to be
    /// due right now. `MedsDueWidget` renders these as two distinct states — never conflate
    /// "not consented" with "consented, nothing due".
    let medsDue: MedsDueSnapshot?

    init(schemaVersion: Int = AmbientSnapshotDto.currentSchemaVersion, generatedAt: Date, language: String,
         readiness: RingSnapshot?, sentence: SentenceSnapshot?, sleep: SleepSnapshot?, medsDue: MedsDueSnapshot?) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.language = language
        self.readiness = readiness
        self.sentence = sentence
        self.sleep = sleep
        self.medsDue = medsDue
    }

    /// N-1 schema tolerance, mirroring the main-app copy's own `init(from:)` exactly (see its
    /// header comment): a snapshot written by an older OR NEWER app version than this widget binary
    /// was compiled against must still decode to *something* — every field falls back to an
    /// honest, harmless default rather than one missing/renamed key failing the whole decode. A
    /// widget reading a stale/differently-shaped file degrades gracefully (a missing sentence, a
    /// missing ring) instead of showing nothing at all.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        readiness = try c.decodeIfPresent(RingSnapshot.self, forKey: .readiness)
        sentence = try c.decodeIfPresent(SentenceSnapshot.self, forKey: .sentence)
        sleep = try c.decodeIfPresent(SleepSnapshot.self, forKey: .sleep)
        medsDue = try c.decodeIfPresent(MedsDueSnapshot.self, forKey: .medsDue)
    }
}

struct RingSnapshot: Codable, Hashable, Sendable {
    /// 0–100 today (`composite.readiness_score`) — already fully resolved by the main app; no
    /// widget in this target performs any further computation on it.
    let score: Double
    let provisional: Bool
}

struct SentenceSnapshot: Codable, Hashable, Sendable {
    let en: String
    let ar: String
}

struct SleepSnapshot: Codable, Hashable, Sendable {
    let durationMinutes: Int
    /// nil when a sleep score could not be computed yet (e.g. no baseline yet) — the duration is
    /// still shown on its own; a widget must not fabricate a score to fill this gap.
    let score: Double?
    let provisional: Bool
}

struct MedsDueSnapshot: Codable, Hashable, Sendable {
    /// Empty = nothing due right now — a real, distinct state (see `medsDue`'s doc above), not the
    /// same as the field being absent.
    let items: [MedsDueItem]
}

struct MedsDueItem: Codable, Hashable, Sendable {
    let regimenId: String
    /// Medication NAME only — never dose/strength. This file transits an app-group container, not
    /// a push service, but a medication name is itself sensitive-plus (INVARIANTS.md I7) and the
    /// per-widget consent key is exactly what gates this field being present at all.
    let displayName: String
    /// Already-localized ("8:00 AM" / "٨:٠٠ ص") — the main-app writer resolves formatting once so
    /// no widget in this target needs its own locale-aware time formatter.
    let timeLabel: String
}

// MARK: - Read-only app-group reader

/// Minimal, read-only counterpart to the main app's `AmbientSnapshotStore` writer. This type never
/// writes the snapshot file — only the main app does — and every failure mode (container
/// unavailable, file missing, genuinely undecodable JSON) collapses to a plain `nil`, which every
/// widget in this target already renders as a calm "no data yet" state rather than an error. A
/// different-than-expected `schemaVersion` is NOT one of those failure modes — see
/// `AmbientSnapshotDto.init(from:)`'s doc comment for why it degrades field-by-field instead.
enum AmbientSnapshotReader {
    /// Must match `com.apple.security.application-groups` in BOTH `apps/ios/App/BADAN.entitlements`
    /// and `apps/ios/BadanWidgets/BadanWidgets.entitlements` exactly — a mismatch fails silently
    /// (this reader just sees no container) rather than with any runtime error.
    static let appGroupId = "group.net.binjamshid.badan"

    /// Filename agreed with the parallel lane's `AmbientSnapshotStore.swift` writer (this slice's
    /// task notes: "if you start before that lane's file exists, use ambient_snapshot.json and it
    /// WILL match").
    static let filename = "ambient_snapshot.json"

    private static let decoder = JSONDecoder()

    static func read() -> AmbientSnapshotDto? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return nil }
        let url = container.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // No separate `schemaVersion` gate here: `AmbientSnapshotDto.init(from:)` already tolerates
        // an older-or-newer schema by defaulting any field it can't find (see that initializer's
        // doc comment) rather than failing the whole decode over one key — a genuinely undecodable
        // file (not just a different shape) is the only thing that still collapses to `nil` below.
        return try? decoder.decode(AmbientSnapshotDto.self, from: data)
    }
}
