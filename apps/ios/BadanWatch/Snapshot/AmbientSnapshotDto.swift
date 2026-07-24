import Foundation

// MARK: - Frozen shared DTO, third copy (A22/EPIC-42, Phase 4)
//
// `BadanWatch` is a separate watchOS app target with its own `sources:` entry in `project.yml` and
// CANNOT import anything from `apps/ios/Sources/` OR `apps/ios/BadanWidgets/` — a watchOS app
// target links against its own module, and more fundamentally a Watch and an iPhone are separate
// physical devices with separate filesystems, so even the app-group container `BadanWidgets` reads
// never reaches this target at all. The ONLY channel into this app is `Sync/SnapshotReceiver.swift`,
// decoding whatever `WatchSnapshotSync` (`apps/ios/Sources/Platform/Ambient/WatchSnapshotSync.swift`)
// last pushed via `WCSession.updateApplicationContext`.
//
// The struct shapes below are a byte-for-byte duplicate of BOTH other copies —
// `apps/ios/Sources/Platform/Ambient/AmbientSnapshotDto.swift` (the writer's own copy) and
// `apps/ios/BadanWidgets/AmbientSnapshotDto.swift` (the widget extension's copy) — same field
// names, same order, same optionality, same `Date` handling (plain, unconfigured
// `JSONEncoder`/`JSONDecoder`, deliberately NOT `.iso8601` — see the main-app copy's header for
// why). This is now a deliberate THREE-way duplication across the app/extension/watch boundary, not
// a mistake to unify — and none of the three copies are ever type-checked against each other: a
// rename or shape change on any one side without the other two is a SILENT decode failure, never a
// compiler error. Change this file only in lockstep with the other two.
struct AmbientSnapshotDto: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let generatedAt: Date
    /// "en" | "ar" — matches `AppLanguage.rawValue` on the main-app side. This target has no access
    /// to the main app's `AppEnvironment`/`CustomizationProfile` (separate process, separate
    /// device), so `TodayView` resolves bilingual copy off THIS field alone, never a live app
    /// setting — same discipline `BadanWidgets`' `WidgetLanguage` documents.
    let language: String

    let readiness: RingSnapshot?
    let sentence: SentenceSnapshot?
    let sleep: SleepSnapshot?
    /// Present but unused by this target for this slice — `BadanWatch`'s "today" view ships no
    /// meds-due surface yet (no interactive take/skip, which would need a NEW bidirectional
    /// messaging protocol this slice deliberately does not add). Kept in the struct anyway because
    /// dropping a field this copy doesn't use would break the three-way byte-for-byte contract for
    /// no reason.
    let medsDue: MedsDueSnapshot?
    /// A22/EPIC-42. Today's zone-based effort score, when available — `TodayView`'s second row.
    /// `nil` when no score is available (nothing computed yet, or only the reduced-input
    /// activity-load variant exists — see the main-app copy's `AmbientSnapshotWriter
    /// .buildEffortSnapshot` for why that variant is never surfaced as a fabricated score here).
    let effort: EffortSnapshot?

    init(schemaVersion: Int = AmbientSnapshotDto.currentSchemaVersion, generatedAt: Date, language: String,
         readiness: RingSnapshot?, sentence: SentenceSnapshot?, sleep: SleepSnapshot?, medsDue: MedsDueSnapshot?,
         effort: EffortSnapshot? = nil) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.language = language
        self.readiness = readiness
        self.sentence = sentence
        self.sleep = sleep
        self.medsDue = medsDue
        self.effort = effort
    }

    /// N-1 schema tolerance, mirroring both other copies' `init(from:)` exactly: a snapshot pushed
    /// by an older OR NEWER phone-side app version than this watch binary was compiled against must
    /// still decode to *something* — every field falls back to an honest, harmless default rather
    /// than failing the whole decode. `TodayView` already renders a missing field as its own honest
    /// "no data yet" row (never fabricated), so a partially-decoded snapshot degrades gracefully
    /// the same way a `BadanWidgets` widget does.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        readiness = try c.decodeIfPresent(RingSnapshot.self, forKey: .readiness)
        sentence = try c.decodeIfPresent(SentenceSnapshot.self, forKey: .sentence)
        sleep = try c.decodeIfPresent(SleepSnapshot.self, forKey: .sleep)
        medsDue = try c.decodeIfPresent(MedsDueSnapshot.self, forKey: .medsDue)
        effort = try c.decodeIfPresent(EffortSnapshot.self, forKey: .effort)
    }
}

struct RingSnapshot: Codable, Hashable, Sendable {
    /// 0–100 today (`composite.readiness_score`) — already fully resolved by the main app; no
    /// computation in this target.
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
    /// still shown on its own; this target must not fabricate a score to fill this gap.
    let score: Double?
    let provisional: Bool
}

/// A22/EPIC-42. See the main-app copy's doc comment (`Sources/Platform/Ambient/
/// AmbientSnapshotDto.swift`) for the full rationale — byte-for-byte twin, same as every other
/// struct in this file.
struct EffortSnapshot: Codable, Hashable, Sendable {
    let score: Double
    let provisional: Bool
}

struct MedsDueSnapshot: Codable, Hashable, Sendable {
    let items: [MedsDueItem]
}

struct MedsDueItem: Codable, Hashable, Sendable {
    let regimenId: String
    let displayName: String
    let timeLabel: String
}
