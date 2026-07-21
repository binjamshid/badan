import Foundation

// MARK: - Fluid type

/// The display/grouping category of a logged drink. Stored as a bare string on `HydrationEntry`
/// (the same open-vocabulary choice `WorkoutEntry.activityType` makes) so a future beverage the
/// dictionary doesn't yet list is never rejected — this enum only names the curated set for
/// bilingual display and defaulting. `water` is the safe default for anything unrecognized.
///
/// A fluid type is *never* a hydration weight. §7A.1 rejects "net hydration" multipliers outright:
/// 500 mL of coffee is logged as 500 mL, exactly like 500 mL of water. The category is for grouping
/// and display, nothing more.
public enum HydrationFluidType: String, Codable, Hashable, Sendable, CaseIterable {
    case water, coffee, tea, dairy, juice, softDrink = "soft_drink", electrolyte, other

    public var displayLabel: LocalizedString {
        switch self {
        case .water: return LocalizedString(en: "Water", ar: "ماء")
        case .coffee: return LocalizedString(en: "Coffee", ar: "قهوة")
        case .tea: return LocalizedString(en: "Tea", ar: "شاي")
        case .dairy: return LocalizedString(en: "Dairy", ar: "منتجات الألبان")
        case .juice: return LocalizedString(en: "Juice", ar: "عصير")
        case .softDrink: return LocalizedString(en: "Soft drink", ar: "مشروب غازي")
        case .electrolyte: return LocalizedString(en: "Electrolyte drink", ar: "مشروب إلكتروليت")
        case .other: return LocalizedString(en: "Other drink", ar: "مشروب آخر")
        }
    }

    /// Folds an arbitrary stored string to a known category for display, defaulting to `.water`.
    public static func known(_ raw: String) -> HydrationFluidType { HydrationFluidType(rawValue: raw) ?? .water }
}

// MARK: - Beverage & container catalog

/// A user-added beverage definition (the built-ins ship in `beverages.json`; this table is the
/// custom half of the dictionary-vs-custom split, exactly like `symptoms.json` / `symptom_entries`).
///
/// `caffeineMgPer100ml` / `alcoholPct` / `electrolyteNote` are **display metadata only** this phase.
/// They are carried so a later phase can *show* them, but nothing reads them into a hydration total
/// or a "net hydration" multiplier — that is a §7A.1 Reject item. A logged mL is always one logged mL.
public struct BeverageDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var nameEn: String
    public var nameAr: String
    public var fluidType: String
    public var defaultVolumeMl: Double?
    public var caffeineMgPer100ml: Double?   // display metadata only — never a hydration weight
    public var alcoholPct: Double?           // display metadata only — never a hydration weight
    public var electrolyteNote: String?      // display metadata only — never a hydration weight
    public var isBuiltin: Bool
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var displayName: LocalizedString { LocalizedString(en: nameEn, ar: nameAr) }

    public init(id: String, nameEn: String, nameAr: String, fluidType: String,
                defaultVolumeMl: Double? = nil, caffeineMgPer100ml: Double? = nil,
                alcoholPct: Double? = nil, electrolyteNote: String? = nil, isBuiltin: Bool = false,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.nameEn = nameEn; self.nameAr = nameAr; self.fluidType = fluidType
        self.defaultVolumeMl = defaultVolumeMl; self.caffeineMgPer100ml = caffeineMgPer100ml
        self.alcoholPct = alcoholPct; self.electrolyteNote = electrolyteNote; self.isBuiltin = isBuiltin
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

/// A saved container ("My Bottle", "Glass") — the favorite that makes a log ≤2 actions and gives the
/// "Added 500 mL from My Bottle" confirmation its name. `beverageId` is the container's default
/// drink (nil = plain water).
public struct ContainerPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var nameEn: String
    public var nameAr: String
    public var volumeMl: Double
    public var beverageId: String?
    public var sortOrder: Int
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var displayName: LocalizedString { LocalizedString(en: nameEn, ar: nameAr) }

    public init(id: String, nameEn: String, nameAr: String, volumeMl: Double, beverageId: String? = nil,
                sortOrder: Int = 0, updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.nameEn = nameEn; self.nameAr = nameAr; self.volumeMl = volumeMl
        self.beverageId = beverageId; self.sortOrder = sortOrder; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - Hydration entry (append-first ledger)

/// One logged drink. The ledger is **append-first with an auditable revision chain** (§9.14): an
/// edit never overwrites a row, it appends a new one that supersedes the old, so "what the user
/// said, and how they later corrected it" is always recoverable (I2-flavored).
///
/// - `originalId` is the stable identity of a logical drink across every revision. An un-revised
///   entry has `originalId == id`.
/// - `supersedes` points at the row this one replaces (nil for an original). It is the backward link
///   that lets the LIVE view be computed without mutating any old row (see `HydrationLedger.liveEntries`).
/// - `revision` is a 1-based counter (1 = original), for honest "edited" display and chain ordering.
///
/// `note` is redacted from the default export (§7A.1) — stored, but withheld unless explicitly opted in.
public struct HydrationEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var volumeMl: Double        // canonical mL, always > 0
    public var fluidType: String       // category key, e.g. "water"
    public var beverageId: String?     // dictionary or custom beverage id
    public var containerId: String?    // container preset id, when logged from a favorite
    public var occurredAt: Date
    public var tzId: String
    public var note: String?           // REDACTED from the default export
    public var originalId: String
    public var supersedes: String?
    public var revision: Int
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var isOriginal: Bool { supersedes == nil }
    public var isRevised: Bool { revision > 1 }

    public init(id: String, volumeMl: Double, fluidType: String, beverageId: String? = nil,
                containerId: String? = nil, occurredAt: Date, tzId: String, note: String? = nil,
                originalId: String, supersedes: String? = nil, revision: Int = 1,
                provenance: Provenance, updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.volumeMl = volumeMl; self.fluidType = fluidType; self.beverageId = beverageId
        self.containerId = containerId; self.occurredAt = occurredAt; self.tzId = tzId; self.note = note
        self.originalId = originalId; self.supersedes = supersedes; self.revision = revision
        self.provenance = provenance; self.updatedAt = updatedAt; self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}

// MARK: - Ledger logic

/// Pure, storage-free logic for the hydration ledger: volume parsing (Arabic-numeral aware), building
/// originals and revisions, and computing the LIVE set. Everything here is a total function over its
/// inputs so it can be tested without a database, and the repository's SQL mirrors `liveEntries`
/// exactly (a divergence between the two is a bug on one side).
public enum HydrationLedger {

    /// Parses a user-typed volume as canonical mL, folding Eastern-Arabic / Extended Arabic-Indic
    /// digits and the Arabic decimal separator through the shared `DecimalParsing` (BUG-15) so a
    /// device set to Arabic can log "٥٠٠" as 500 mL. Rejects non-positive, non-finite, and
    /// unparseable input — a drink with no positive volume is not a log, it is a mistake.
    public static func parseVolumeMl(_ text: String) -> Double? {
        guard let value = DecimalParsing.parse(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Builds an original (first-time) entry: `originalId == id`, no `supersedes`, revision 1.
    public static func makeEntry(id: String, volumeMl: Double, fluidType: String, beverageId: String? = nil,
                                 containerId: String? = nil, occurredAt: Date, tzId: String, note: String? = nil,
                                 provenance: Provenance, updatedAt: Date, originDeviceId: String) -> HydrationEntry {
        HydrationEntry(id: id, volumeMl: volumeMl, fluidType: fluidType, beverageId: beverageId,
                       containerId: containerId, occurredAt: occurredAt, tzId: tzId, note: note,
                       originalId: id, supersedes: nil, revision: 1, provenance: provenance,
                       updatedAt: updatedAt, originDeviceId: originDeviceId)
    }

    /// Builds a revision that supersedes `live` — an APPEND, never a mutation of `live`. The new row
    /// inherits the chain's `originalId`, links back via `supersedes`, and bumps `revision`. Fields
    /// not passed are carried over from `live`, so a "just fix the volume" edit keeps everything else.
    public static func makeRevision(of live: HydrationEntry, id: String, volumeMl: Double? = nil,
                                    fluidType: String? = nil, beverageId: String?? = nil,
                                    containerId: String?? = nil, occurredAt: Date? = nil, tzId: String? = nil,
                                    note: String?? = nil, provenance: Provenance, updatedAt: Date,
                                    originDeviceId: String) -> HydrationEntry {
        HydrationEntry(
            id: id,
            volumeMl: volumeMl ?? live.volumeMl,
            fluidType: fluidType ?? live.fluidType,
            beverageId: beverageId ?? live.beverageId,
            containerId: containerId ?? live.containerId,
            occurredAt: occurredAt ?? live.occurredAt,
            tzId: tzId ?? live.tzId,
            note: note ?? live.note,
            originalId: live.originalId,
            supersedes: live.id,
            revision: live.revision + 1,
            provenance: provenance,
            updatedAt: updatedAt,
            originDeviceId: originDeviceId
        )
    }

    /// The LIVE set over a group of rows (any mix of chains): a row is live iff it is not tombstoned
    /// AND no *non-deleted* row supersedes it. That "non-deleted superseder" qualifier is what makes
    /// `undo` (tombstone one revision → the prior version becomes live again) and `delete` (tombstone
    /// the whole chain → nothing is live) both fall out of the same rule. Order is preserved from the
    /// input.
    public static func liveEntries(_ all: [HydrationEntry]) -> [HydrationEntry] {
        let supersededByLive = Set(all.compactMap { $0.deletedAt == nil ? $0.supersedes : nil })
        return all.filter { $0.deletedAt == nil && !supersededByLive.contains($0.id) }
    }
}
