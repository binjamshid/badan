import Foundation

/// How a datum entered BADAN. Part of every record's provenance (INVARIANT I1).
public enum IngestionPath: String, Codable, Hashable, Sendable, CaseIterable {
    case platformStore   // HealthKit / Health Connect
    case manual          // typed by the user
    case fileImport = "import"
    case derived         // computed by BADAN's own engines
    case vendor          // reserved: direct vendor API / broker

    public var displayLabel: LocalizedString {
        switch self {
        case .platformStore: return LocalizedString(en: "Health app", ar: "تطبيق الصحة")
        case .manual: return LocalizedString(en: "Entered by you", ar: "أدخلتها بنفسك")
        case .fileImport: return LocalizedString(en: "Imported", ar: "مستورد")
        case .derived: return LocalizedString(en: "Computed by BADAN", ar: "محسوب بواسطة بدن")
        case .vendor: return LocalizedString(en: "Connected service", ar: "خدمة متصلة")
        }
    }
}

/// Honest quality annotations that travel with a datum and surface in power mode.
public enum QualityFlag: String, Codable, Hashable, Sendable, CaseIterable {
    case gapFilled
    case artifactSuspected
    case userCorrected
    case provisionalBaseline
    case estimate
    /// A derived value computed later than the day it describes, from history that arrived after
    /// the fact (an import/backfill filling in an earlier week). EPIC-23 chose a DEDICATED flag
    /// over reusing `.estimate`: a retroactively-computed score can ALSO be an estimate, and the
    /// two facts are independent — "how confident is this number" vs "when/from-what-history was it
    /// computed" — so collapsing them would erase one. It is a READ-TIME-DERIVED label (from a
    /// row's `periodKey` vs `computedAt`, `BaselineEngine.isRetroactive`), not a stored column: the
    /// fact is answerable directly from the data (I1) and needs no migration. See
    /// `docs/algorithms/baselines.md`.
    case retroactive
    case tzAssumed
    case lowCoverage
    /// This row was fabricated by `FakeHealthStore` for the "explore with sample data" mode —
    /// nobody measured it.
    ///
    /// A flag rather than a UI-only banner, because the fabrication has to be legible wherever
    /// the row travels. Sample rows were exported into a checksummed CSV/JSON bundle attributed
    /// to a real-looking Apple Watch, with nothing in the file, the manifest, or the database
    /// saying otherwise — so an export of invented readings was indistinguishable from a
    /// measured one the moment it left the app, which is precisely where "raw data is not
    /// paywalled, provenance is preserved" has to hold hardest.
    ///
    /// Stamped at the only place fabrication happens (`FakeHealthStore`), so it rides the
    /// existing `quality_flags` plumbing into the DB, the CSV column, the JSON bundle, the
    /// manifest's disclosure, and the power-mode chips without any path needing to remember.
    case sampleData
}

/// Provenance is embedded, denormalized structure on every health datum's own row
/// (D-3): never a join, never optional. This is what makes BADAN's "where did this
/// number come from" promise mechanically true rather than aspirational.
public struct Provenance: Codable, Hashable, Sendable {
    public var sourceId: String
    public var deviceId: String?
    public var ingestionPath: IngestionPath
    /// Upstream system's own id — the idempotency key for re-ingest (I: no duplicates).
    public var externalId: String?
    public var importBatchId: String?
    public var measuredAt: Date
    public var measuredTimezone: String   // IANA tz id, e.g. "Asia/Riyadh"
    public var recordedAt: Date
    public var ingestedAt: Date
    public var algorithmVersionId: String?
    public var qualityFlags: [QualityFlag]
    /// When set, this record was dedup-suppressed; points at the winning record's id.
    /// Suppress, never delete (INVARIANT I3).
    public var suppressedBy: String?

    public init(
        sourceId: String,
        deviceId: String? = nil,
        ingestionPath: IngestionPath,
        externalId: String? = nil,
        importBatchId: String? = nil,
        measuredAt: Date,
        measuredTimezone: String,
        recordedAt: Date,
        ingestedAt: Date,
        algorithmVersionId: String? = nil,
        qualityFlags: [QualityFlag] = [],
        suppressedBy: String? = nil
    ) {
        self.sourceId = sourceId
        self.deviceId = deviceId
        self.ingestionPath = ingestionPath
        self.externalId = externalId
        self.importBatchId = importBatchId
        self.measuredAt = measuredAt
        self.measuredTimezone = measuredTimezone
        self.recordedAt = recordedAt
        self.ingestedAt = ingestedAt
        self.algorithmVersionId = algorithmVersionId
        self.qualityFlags = qualityFlags
        self.suppressedBy = suppressedBy
    }

    public var isSuppressed: Bool { suppressedBy != nil }
}
