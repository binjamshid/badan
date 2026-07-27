import Foundation

/// EPIC-33 (Phase 3D) — the bounded JSON snapshot handed from the main app to the `BadanWidgets`
/// extension (blueprint §24.1, "the snapshot pattern"). This is the ONLY channel between the two:
/// the widget extension never opens the SQLCipher database directly (extension memory limits,
/// Data-Protection key-availability-before-first-unlock, and cross-process SQLite locking all
/// argue against it), so everything a widget can ever show is whatever this struct carries.
///
/// **Frozen shape — do not rename fields, change types, or change optionality without both lanes
/// agreeing.** A WidgetKit extension cannot import the main app's `Sources/` target (an App
/// Extension links against its own module), so `apps/ios/BadanWidgets/` keeps an independent copy
/// of this exact struct — the two copies can only ever be kept in sync by hand, never by the
/// compiler, which is exactly why the shape is pinned in writing here rather than left to drift.
///
/// **Date encoding.** `AmbientSnapshotStore` (this file's sibling) writes and reads with a plain,
/// unconfigured `JSONEncoder`/`JSONDecoder` — Foundation's default `Date` strategy
/// (`.deferredToDate`, a `Double` `timeIntervalSinceReferenceDate`), deliberately NOT
/// `.iso8601`/`.millisecondsSince1970`/etc. The two lanes cannot coordinate live, and "the
/// unconfigured default" is the one choice a reader of this file is most likely to land on
/// independently without having read this comment at all. If the widget-side copy of this struct
/// ever fails to decode a real snapshot, check this first.
struct AmbientSnapshotDto: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    /// "en" | "ar" — matches `AppLanguage.rawValue`. The extension has no access to the main app's
    /// `AppEnvironment`/`CustomizationProfile`, so the writer bakes the user's current language
    /// choice into the snapshot itself; a widget just picks `.en` or `.ar` off each bundled
    /// `LocalizedString`-shaped pair using this field, never reading a live app setting.
    let language: String

    let readiness: RingSnapshot?
    let sentence: SentenceSnapshot?
    let sleep: SleepSnapshot?
    /// Entirely nil/absent when the user has NOT granted the meds-due widget's own consent key
    /// (medications are sensitive-plus — plan's "per-widget opt-in consent key
    /// `consent.widget.<family>`"). When present with an EMPTY `items` array, that is a real,
    /// different state: consent IS granted and nothing happens to be due right now. A widget must
    /// render "turn this on in Settings" for `nil` and "nothing due" for an empty array — never
    /// the same copy for both.
    let medsDue: MedsDueSnapshot?
    /// A22/EPIC-42 (Phase 4). Added for `BadanWatch`'s glanceable "today" view, which needs
    /// Readiness/Effort/Sleep together (the same three cards `HomeScreen`'s flagship first screen
    /// leads with). Nothing in `BadanWidgets` renders this field today, but per this file's own
    /// "one writer, multiple bounded readers" discipline it lives on the ONE shared snapshot rather
    /// than a second, watch-only DTO — `BadanWidgets`' copy of this struct gained the field too
    /// (kept in lockstep, same as every other field here) even though no widget reads it yet.
    /// `nil` when today's effort has no zone-based 0–100 score yet — either nothing computed, or
    /// only the reduced-input activity-load variant is available (a different, non-comparable
    /// magnitude/unit; see `AmbientSnapshotWriter.buildEffortSnapshot`) — never a fabricated score.
    let effort: EffortSnapshot?

    /// W-11 (EPIC-44). What the widgets are permitted to render from this snapshot. Stamped by the
    /// main app from `AmbientPrivacyConfig` so the extension never has to reason about privacy —
    /// it reads flags and obeys. See `AmbientPrivacySnapshot`.
    let privacy: AmbientPrivacySnapshot

    init(schemaVersion: Int = AmbientSnapshotDto.currentSchemaVersion, generatedAt: Date, language: String,
         readiness: RingSnapshot?, sentence: SentenceSnapshot?, sleep: SleepSnapshot?, medsDue: MedsDueSnapshot?,
         effort: EffortSnapshot? = nil, privacy: AmbientPrivacySnapshot = .standard) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.language = language
        self.readiness = readiness
        self.sentence = sentence
        self.sleep = sleep
        self.medsDue = medsDue
        self.effort = effort
        self.privacy = privacy
    }

    /// N-1 schema tolerance (see `AmbientSnapshotTests`): a snapshot
    /// written by an older app version — one that shipped a lower `schemaVersion` and therefore
    /// may be missing a key this version added — must still decode to *something*, never crash
    /// and never fail the whole read. Every field falls back to an honest, harmless default rather
    /// than throwing: a widget reading a stale/older-shaped file degrades gracefully (a missing
    /// sentence, a missing ring) instead of showing nothing at all because one absent key failed
    /// the entire decode. Mirrors this codebase's established tolerant-decode pattern (see
    /// `CustomizationProfile.init(from:)` / `NotificationPreference.init(from:)`).
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
        // Absent key = a snapshot written before W-11 existed. Defaults to `.standard`, which is
        // what those older snapshots' content already assumed — this key changes how existing
        // content is rendered, it does not gate content that was previously ungated, so defaulting
        // permissive here reveals nothing that the same file was not already showing. The one truly
        // non-negotiable rule (`lockScreenValuesAllowed == false` for medications) does not depend
        // on this decode at all: `MedsDueWidget` refuses on the Lock Screen unconditionally.
        privacy = try c.decodeIfPresent(AmbientPrivacySnapshot.self, forKey: .privacy) ?? .standard
    }
}

/// The rendering permissions the main app stamps into each snapshot (W-11).
///
/// Deliberately booleans rather than the `AmbientPrivacyMode` enum itself: the extension holds a
/// byte-for-byte duplicate of these structs and cannot import the main app's types, so shipping
/// resolved answers ("may I show a number?") instead of a mode the extension would have to
/// interpret keeps the policy in one place. A future mode needs no extension-side change.
struct AmbientPrivacySnapshot: Codable, Hashable, Sendable {
    /// May a widget render numeric values and sentences at all (Home Screen / StandBy / watch)?
    let valuesAllowed: Bool
    /// May any personal content appear, even unlabelled shapes?
    let contentAllowed: Bool
    /// May values render on a LOCK SCREEN widget specifically. Always false for medications
    /// regardless of this flag — see `AmbientPrivacyConfig.neverOnLockScreen`.
    let lockScreenValuesAllowed: Bool

    static let standard = AmbientPrivacySnapshot(valuesAllowed: true, contentAllowed: true,
                                                 lockScreenValuesAllowed: true)

    init(valuesAllowed: Bool, contentAllowed: Bool, lockScreenValuesAllowed: Bool) {
        self.valuesAllowed = valuesAllowed
        self.contentAllowed = contentAllowed
        self.lockScreenValuesAllowed = lockScreenValuesAllowed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        valuesAllowed = try c.decodeIfPresent(Bool.self, forKey: .valuesAllowed) ?? true
        contentAllowed = try c.decodeIfPresent(Bool.self, forKey: .contentAllowed) ?? true
        lockScreenValuesAllowed = try c.decodeIfPresent(Bool.self, forKey: .lockScreenValuesAllowed) ?? true
    }
}

struct RingSnapshot: Codable, Hashable, Sendable {
    /// 0-100 today (`composite.readiness_score`) — already resolved, no further computation
    /// needed by a widget.
    let score: Double
    let provisional: Bool
}

struct SentenceSnapshot: Codable, Hashable, Sendable {
    let en: String
    let ar: String
}

struct SleepSnapshot: Codable, Hashable, Sendable {
    let durationMinutes: Int
    /// nil when a sleep score could not be computed (e.g. no baseline yet) — the duration is
    /// still shown.
    let score: Double?
    let provisional: Bool
}

struct MedsDueSnapshot: Codable, Hashable, Sendable {
    /// Empty = nothing due right now, a real state (see this type's usage doc on
    /// `AmbientSnapshotDto.medsDue`).
    let items: [MedsDueItem]
}

/// A22/EPIC-42. Today's zone-based effort score only (`effort.day`'s `score_0_100`-unit reading) —
/// mirrors `SleepSnapshot.score`'s existing "nil when not available" discipline rather than a new
/// one. The reduced-input activity-load variant (`HomeEffortSummary.Kind.activityLoad` on the
/// main-app side — a raw movement magnitude in its own unit, not comparable to a 0–100 score) is
/// deliberately NOT carried here; it would need its own unit label to render honestly and no reader
/// of this bounded snapshot needs it yet.
struct EffortSnapshot: Codable, Hashable, Sendable {
    let score: Double
    let provisional: Bool
}

struct MedsDueItem: Codable, Hashable, Sendable {
    let regimenId: String
    /// Medication name only — no dose/strength (this file transits an app-group container, not a
    /// push service, but a medication NAME is itself sensitive-plus and this consent key is what
    /// gates it).
    let displayName: String
    /// Already-localized "8:00 AM" / "٨:٠٠ ص" — the writer resolves formatting once so no widget
    /// needs a locale-aware formatter.
    let timeLabel: String
}
