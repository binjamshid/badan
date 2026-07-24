import Foundation

// MARK: - Due-date provenance model (A18/ADR-0010/D-25, EPIC-40 PREG-02, P0 slice)
//
// Grounded in `docs/BADAN_PREGNANCY_CALENDAR_RESEARCH.md` §5 (read it before touching this file).
// Two shapes, mirroring the RAW/DERIVED split `CycleModels.swift`'s own header documents for the
// cycle module (and `Migrations.swift` sensitive migration 6's identical split):
//   * RAW/MEASURED (`DueDateSourceEntry`) — what the user actually typed in (a provider's date, an
//     ultrasound-adjusted date, a conception date, an LMP date). Carries full `Provenance` (I1):
//     each is a user-asserted fact with an origin. APPEND-ONLY per source type — a correction
//     inserts a FRESH row for the same `sourceType`, never an UPDATE of a prior one, so the full
//     history of what a user entered and how they later corrected it survives.
//   * DERIVED (`DueDateEstimate`) — what `DueDateEstimator` computes from the highest-priority live
//     source entry on file. Append-only (I2), no embedded provenance (computed, not measured),
//     mirroring `CyclePrediction`'s exact shape.
//
// THE FOUR-SOURCE PRIORITY MODEL, restated precisely per the research doc's own framing (NOT the
// execution plan's flattened `provider > ultrasound-adjusted > conception-based > LMP` chain, which
// erases a real nuance): tiers 1 and 2 are ONE clinician-sourced lineage, not two independent
// peers. The research doc's own words (§5, line 51): an ultrasound-adjusted date is "an update to
// the provider-given source, not a new independent calculation." `DueDateEstimator` honors this by
// treating `.ultrasoundAdjusted` as the more-precise, more-recent member of the SAME clinician tier
// — if one is on file it is used, and its `resolvedSourceType` still reports `.ultrasoundAdjusted`
// distinctly (never collapsed into `.providerGiven`) so the UI can say "your due date, adjusted by
// ultrasound" rather than erasing which one actually produced the number — but the two are never
// treated as independent, separately-rankable peers the way conception-based/LMP-based are.
//
// NO SINGLE-DATE CLAIM, structurally, not by convention: `DueDateEstimate.rangeLow/Center/High` are
// the only date-bearing fields, all optional and populated together or not at all — mirroring
// `CyclePrediction`'s and `CycleFertileWindowEstimate`'s identical structural guarantee. Even a
// provider-given/ultrasound-adjusted date (a clinician's own figure) is presented as a narrow RANGE,
// never a bare date — due dates are inherently estimates in real obstetric practice, and this
// module's own "no false precision" rule applies with equal force to a clinician-sourced figure.
//
// CLINICAL-REVIEW-PENDING (ADR-0010 A18, `docs/adr/ADR-0010-approvals-a9-a16-a17-a18-a21-a22-a24-a25.md:76-88`):
// every day-count and range-width constant below (the 280-day/266-day gestation conventions, the
// per-tier range widths, the confidence values) is a standard obstetric APPROXIMATION wired for
// engineering completeness, not a clinically validated formula. `docs/DECISIONS.md` D-25 and ADR-0010
// both say engineering may proceed while ship-readiness stays gated on that review — this file's
// numbers must not be read as "reviewed and correct" until that review actually clears them.

// MARK: - DueDateSourceType (the four-tier priority vocabulary)

/// Highest-to-lowest priority order is the enum's OWN case order — `DueDateEstimator` walks
/// `allCases` and does not hand-maintain a second ranking list that could drift from this one.
public enum DueDateSourceType: String, Codable, Hashable, Sendable, CaseIterable {
    /// Tier 1 (clinician-sourced lineage). A provider's own asserted due date always overrides app
    /// math.
    case providerGiven
    /// Tier 1 (clinician-sourced lineage, same tier as `.providerGiven` — see this file's header).
    /// An update TO the provider-given source, not an independent calculation; when present, it is
    /// preferred within the tier because it is the more recent, more precise clinician figure.
    case ultrasoundAdjusted
    /// Tier 2. For TTC-tracked users with a known/estimated conception date.
    case conceptionBased
    /// Tier 3. Least precise — flagged explicitly by the research doc due to natural cycle-length
    /// variation; produces the widest range of the four tiers.
    case lmpBased

    public var displayName: LocalizedString {
        switch self {
        case .providerGiven: return LocalizedString(en: "Provider-given date", ar: "تاريخ من مقدّم الرعاية")
        case .ultrasoundAdjusted: return LocalizedString(en: "Ultrasound-adjusted date", ar: "تاريخ مُعدَّل بالموجات فوق الصوتية")
        case .conceptionBased: return LocalizedString(en: "Estimated from conception date", ar: "مقدَّر من تاريخ الإخصاب")
        case .lmpBased: return LocalizedString(en: "Estimated from last period", ar: "مقدَّر من آخر دورة شهرية")
        }
    }
}

// MARK: - DueDateSourceEntry (raw, user-entered, append-only per source type)

/// One user-entered due-date INPUT. `enteredDate` holds different meanings per `sourceType`: for
/// `.providerGiven`/`.ultrasoundAdjusted` it IS the due date the clinician gave; for
/// `.conceptionBased`/`.lmpBased` it is the ANCHOR date (conception date / LMP start date)
/// `DueDateEstimator` computes forward from — never itself displayed as a due date.
///
/// Carries a full embedded `Provenance` (I1). APPEND-ONLY per `(pregnancyRecordOriginalId,
/// sourceType)`: a correction (the user mis-typed a date, or a new ultrasound updates a prior one)
/// inserts a FRESH row for the same pair — `DueDateSourceEntryRepository.liveEntry` reads the most
/// recently recorded live row per pair, never an UPDATE in place — so the full input history stays
/// auditable, mirroring `CycleRecord`'s append-first posture without needing a full
/// `originalId`/`supersedes`/`revision` chain (there is no "supersede a specific prior revision"
/// need here — the latest live row per pair always wins, unlike `CycleRecord`'s branching chain).
public struct DueDateSourceEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pregnancyRecordOriginalId: String
    public var sourceType: DueDateSourceType
    public var enteredDate: Date
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, pregnancyRecordOriginalId: String, sourceType: DueDateSourceType,
                enteredDate: Date, provenance: Provenance, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil) {
        self.id = id; self.pregnancyRecordOriginalId = pregnancyRecordOriginalId
        self.sourceType = sourceType; self.enteredDate = enteredDate; self.provenance = provenance
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - DueDateEstimate (derived, append-only — NEVER a single-date claim)

/// An append-only computed due-date estimate. APPEND-ONLY (I2): a recompute always inserts a NEW
/// row with a fresh `generatedAt`; nothing here is ever UPDATEd — mirrors `CyclePrediction`'s exact
/// shape reasoning. No embedded `Provenance` (this row is COMPUTED from already-provenanced
/// `DueDateSourceEntry` rows, not measured with its own source).
///
/// **No single-date claim, structurally.** `rangeLow`/`rangeCenter`/`rangeHigh` are the only
/// date-bearing fields, all optional and populated together or not at all — see this file's header.
public struct DueDateEstimate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pregnancyRecordOriginalId: String
    public var generatedAt: Date
    public var rangeLow: Date?
    public var rangeCenter: Date?
    public var rangeHigh: Date?
    /// Which tier actually produced this estimate, or `nil` when no source entry exists yet at all
    /// (no estimate to show). ALWAYS surfaced alongside the range — this module's own restatement
    /// of the cycle module's "never a bare date, always show method + why" discipline.
    public var resolvedSourceType: DueDateSourceType?
    /// 0...1.
    public var confidence: Double
    public var algorithmVersion: String
    /// Which `DueDateSourceEntry` id(s) fed this estimate — the same "why does it say that" audit
    /// manifest `CyclePrediction.inputCycleIds` establishes.
    public var inputSourceEntryIds: [String]
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, pregnancyRecordOriginalId: String, generatedAt: Date, rangeLow: Date? = nil,
                rangeCenter: Date? = nil, rangeHigh: Date? = nil, resolvedSourceType: DueDateSourceType? = nil,
                confidence: Double, algorithmVersion: String, inputSourceEntryIds: [String] = [],
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.pregnancyRecordOriginalId = pregnancyRecordOriginalId
        self.generatedAt = generatedAt; self.rangeLow = rangeLow; self.rangeCenter = rangeCenter
        self.rangeHigh = rangeHigh; self.resolvedSourceType = resolvedSourceType
        self.confidence = confidence; self.algorithmVersion = algorithmVersion
        self.inputSourceEntryIds = inputSourceEntryIds; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }

    /// A real estimate exists iff the range is fully populated — mirrors
    /// `CyclePrediction`'s implicit "all three or none" contract, made explicit here as a named
    /// check so a caller never has to test one field and assume the other two.
    public var hasRange: Bool { rangeLow != nil && rangeCenter != nil && rangeHigh != nil }
}

// MARK: - DueDateEstimator (pure, storage-free engine)

/// Computes a `DueDateEstimate` from the live `DueDateSourceEntry` rows for one pregnancy journey.
/// Pure, storage-free, no clock reads (`asOf` always injected) — a sibling to
/// `CycleFertileWindowEngine`/`CyclePredictionEngine` in shape.
public enum DueDateEstimator {
    /// Internal-facing placeholder (mirrors `CyclePredictionEngine.unstampedOriginDeviceId` /
    /// `DueDateEstimator.unstampedOriginDeviceId` exactly, kept as this engine's OWN
    /// constant rather than reaching into a sibling module's — the same "re-derive per file, don't
    /// silently couple two unrelated engines" convention `CycleFertileWindowEngine`'s own header
    /// documents): this pure engine has no device-identity input, so every row it returns carries
    /// this placeholder; the composition/persistence layer is responsible for overwriting it with
    /// the real device id before the row is ever stored.
    public static let unstampedOriginDeviceId = "engine-unstamped"

    /// Standard obstetric convention: 280 days (40 weeks) from LMP. CLINICAL-REVIEW-PENDING — see
    /// this file's header.
    public static let gestationDaysFromLMP = 280
    /// Standard obstetric convention: 266 days (38 weeks) from conception. CLINICAL-REVIEW-PENDING.
    public static let gestationDaysFromConception = 266

    /// Range half-widths per tier, in days — narrower for the clinician-sourced tier, widest for
    /// LMP-based (research doc §5: "flagged as least precise, explicitly due to natural cycle-length
    /// variation"). CLINICAL-REVIEW-PENDING — placeholder, defensible engineering values, not a
    /// clinically validated formula.
    public static func rangeHalfWidthDays(_ sourceType: DueDateSourceType) -> Int {
        switch sourceType {
        case .providerGiven, .ultrasoundAdjusted: return 3
        case .conceptionBased: return 5
        case .lmpBased: return 7
        }
    }

    /// Confidence per tier — deliberately ordered so a LOWER-tier source never reaches or exceeds a
    /// higher tier's confidence, the same "never a stronger claim than the evidence supports"
    /// discipline `CycleFertileWindowEngine.confidenceBase`'s own doc documents for its feature.
    public static func confidence(_ sourceType: DueDateSourceType) -> Double {
        switch sourceType {
        case .providerGiven: return 0.5
        case .ultrasoundAdjusted: return 0.55
        case .conceptionBased: return 0.4
        case .lmpBased: return 0.3
        }
    }

    /// `liveEntriesByType` must already be resolved to at most one LIVE entry per `DueDateSourceType`
    /// (the caller's repository read does this — "most recently recorded live row per type wins",
    /// per `DueDateSourceEntry`'s own doc). This function does not itself resolve ties; it trusts the
    /// caller handed it the current value per type.
    public static func estimate(
        pregnancyRecordOriginalId: String, liveEntriesByType: [DueDateSourceType: DueDateSourceEntry],
        asOf: Date, algorithmVersion: String, tz: String = "UTC"
    ) -> DueDateEstimate {
        let freshId = ULID.newID(clock: FixedClock(asOf))

        func noEstimate() -> DueDateEstimate {
            DueDateEstimate(id: freshId, pregnancyRecordOriginalId: pregnancyRecordOriginalId,
                            generatedAt: asOf, confidence: 0, algorithmVersion: algorithmVersion,
                            updatedAt: asOf, originDeviceId: DueDateEstimator.unstampedOriginDeviceId)
        }

        // Priority order == `DueDateSourceType.allCases` order (this file's own header: the enum
        // case order IS the ranking, never a second hand-maintained list). Within the tier-1 pair,
        // `.ultrasoundAdjusted` is declared before `.providerGiven` is NOT true — allCases order is
        // providerGiven, ultrasoundAdjusted, conceptionBased, lmpBased — so we explicitly prefer
        // ultrasoundAdjusted over providerGiven WITHIN the tier (the "update to the same lineage"
        // rule from this file's header), then fall through the remaining tiers in allCases order.
        let priorityOrder: [DueDateSourceType] = [.ultrasoundAdjusted, .providerGiven, .conceptionBased, .lmpBased]
        guard let (sourceType, entry) = priorityOrder.lazy
            .compactMap({ type in liveEntriesByType[type].map { (type, $0) } })
            .first else {
            return noEstimate()
        }

        let dueDateCenter: Date
        switch sourceType {
        case .providerGiven, .ultrasoundAdjusted:
            dueDateCenter = entry.enteredDate
        case .conceptionBased:
            dueDateCenter = DayAttribution.addingDays(gestationDaysFromConception, to: entry.enteredDate, tz: tz)
        case .lmpBased:
            dueDateCenter = DayAttribution.addingDays(gestationDaysFromLMP, to: entry.enteredDate, tz: tz)
        }
        let halfWidth = rangeHalfWidthDays(sourceType)
        let low = DayAttribution.addingDays(-halfWidth, to: dueDateCenter, tz: tz)
        let high = DayAttribution.addingDays(halfWidth, to: dueDateCenter, tz: tz)

        return DueDateEstimate(
            id: freshId, pregnancyRecordOriginalId: pregnancyRecordOriginalId, generatedAt: asOf,
            rangeLow: low, rangeCenter: dueDateCenter, rangeHigh: high, resolvedSourceType: sourceType,
            confidence: confidence(sourceType), algorithmVersion: algorithmVersion,
            inputSourceEntryIds: [entry.id], updatedAt: asOf,
            originDeviceId: DueDateEstimator.unstampedOriginDeviceId)
    }
}
