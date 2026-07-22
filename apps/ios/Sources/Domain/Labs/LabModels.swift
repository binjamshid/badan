import Foundation

// MARK: - Lab notebook: canonical entity set (EPIC-41, Phase 3E MVP, plan §9.17 / §7A.4)
//
// "A notebook, not a chart": original artifacts are always preserved, structure is added where
// safe, source wording is kept where not, and a missing/absent range or value is never invented or
// guessed. Every type here is `Codable, Hashable, Sendable` per this codebase's convention.
//
// SCOPE (read before extending this file): this slice covers exactly two ingestion paths — manual
// entry and on-device-Vision-OCR-parsed documents — and exactly the entities `LabModels.swift` was
// asked to own. `SourceDocument`/`OCRExtraction` (the encrypted document vault + OCR pipeline) are a
// PARALLEL lane's types; `LabReport.documentRef` below is an opaque reference string into whatever
// table that lane owns, never a foreign key this file declares or depends on the shape of. No cloud
// OCR, no HealthKit Clinical Records / FHIR / provider-connector import, no AI summaries, no
// sharing/collections/packet-builder exist anywhere in this file — see the founder/legal
// do-not-build list (`docs/HANDOFF.md` §5) for why each of those is out of scope here.

// MARK: - Shared enums

/// A result's (or report's) place in the honesty pipeline BADAN owes the user about how a number
/// got here. `needsReview` is OCR's own default — never silently promoted. `corrected` means at
/// least one `UserCorrection` (or result revision) has been applied since the row was first
/// created. `conflictFlagged` means `DuplicateConflictResolver` flagged this row against another and
/// neither has been resolved.
public enum LabReviewState: String, Codable, Hashable, Sendable, CaseIterable {
    /// Arrived through a structured, non-OCR path with no extraction guess involved. Reserved for a
    /// future structured-import path (e.g. a lab portal's own structured export) — this slice's two
    /// ingestion paths (manual, on-device OCR) never produce this state themselves.
    case verifiedStructured
    /// OCR extraction the pipeline is confident about, but not yet reviewed by structure alone.
    case parsedHighConf
    /// OCR's default state for every extracted value (§7A.4: "OCR defaults `review_required`").
    case needsReview
    /// Typed by hand — no OCR/extraction involved at all.
    case userEntered
    /// At least one correction has been applied since this row (or its prior revision) was created.
    case corrected
    /// `DuplicateConflictResolver` flagged this row against another candidate; unresolved.
    case conflictFlagged
}

/// The three-tier sensitivity the plan requires on top of the sensitive-DB namespace boundary
/// itself (I7) — a finer display/export dial, never a substitute for the namespace: a `veryHigh`
/// row outside `badan_sensitive.db` would still be an I7 violation even with this column set
/// correctly. `high`/`veryHigh` examples from the plan: reproductive/STI/culture/drug-screen results
/// (`high`); genomic, pathology, HIV, fertility-treatment results (`veryHigh`, supports a
/// local-only-only override even where sync exists in a later phase).
public enum LabSensitivityTier: String, Codable, Hashable, Sendable, CaseIterable {
    case standard, high, veryHigh

    public var displayName: LocalizedString {
        switch self {
        case .standard: return LocalizedString(en: "Standard", ar: "عادي")
        case .high: return LocalizedString(en: "High", ar: "مرتفع")
        case .veryHigh: return LocalizedString(en: "Very high", ar: "مرتفع جداً")
        }
    }
}

/// What KIND of answer a result's value actually is — decides whether `numericValue` is meaningful.
public enum LabResultType: String, Codable, Hashable, Sendable, CaseIterable {
    /// A parseable magnitude — `numericValue` is populated whenever `rawValueText` actually parsed.
    case numeric
    /// Positive/Negative/Reactive/Non-reactive/Detected/Not detected style results. No magnitude.
    case qualitative
    /// Graded reads with no continuous magnitude (urinalysis trace/1+/2+/3+/4+, titers). No
    /// `numericValue` — an ordinal grade is not a number on the same scale a trend can average.
    case ordinal
    /// Free narrative (culture growth description, morphology notes). No `numericValue`.
    case textual
}

/// The comparator a lab prints in front of a value at an assay's detection limit ("<0.1", "≥1000").
/// `nil` on `LabResult.comparator` means an exact reported value — no comparator at all.
public enum LabComparator: String, Codable, Hashable, Sendable, CaseIterable {
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
    case approximately = "~"
}

/// The conversion-safety class an analyte's unit conversions fall into (`UnitNormalization`'s own
/// gate). Only `.safe` analytes ever get an auto-computed value in a second (canonical) unit; the
/// other three classes keep ONLY the as-entered value/unit, with normalization fields left absent —
/// never zero, never guessed. `.none` means the analyte has effectively one unit in practice, so
/// there is nothing to convert TO, not that conversion is unsafe.
public enum ConversionSafetyClass: String, Codable, Hashable, Sendable, CaseIterable {
    case safe, conditional, unsafe, none
}

/// What a `UserCorrection` or `LabAnnotation` is attached to — the two entities in this file whose
/// own table has no revision chain of its own (a `LabReport`'s metadata, or a lightweight field-level
/// fix on a `LabResult` that doesn't warrant a whole new result revision).
public enum LabAttachmentTarget: String, Codable, Hashable, Sendable, CaseIterable {
    case report, result
}

// MARK: - LabReport

/// Report-level metadata: which lab, when the specimen was collected, a reference to the source
/// document (owned by a parallel vault lane), and this report's own review state.
///
/// `ingestionPath` is a bare `IngestionPath` value rather than an embedded `Provenance` struct —
/// deliberately, and unlike `LabResult` below. A report's provenance story this slice ever produces
/// is exactly one of two values (`.manual` or `.fileImport`), and the measurement-bearing half of
/// provenance (WHEN was an analyte actually measured, in what timezone, by what algorithm/OCR
/// version) belongs on each `LabResult` — results within one report can legitimately have DIFFERENT
/// answers to those questions (a glucose-tolerance panel draws at 0/60/120 minutes; a single result
/// might later be hand-corrected while its siblings remain OCR-original). Duplicating a report-wide
/// provenance block here would either be redundant with every result's own, or wrong the moment the
/// two diverge.
public struct LabReport: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// As printed/entered — nil when the user didn't specify one (a quick single-marker entry need
    /// not name a lab).
    public var sourceLabName: String?
    /// The specimen collection date. Required — even the smallest quick manual entry needs a date
    /// its one result is filed under.
    public var collectionAt: Date
    /// The date the lab issued/reported the results, when known. Frequently absent for a manual
    /// quick entry or an older document; never invented when absent.
    public var reportedAt: Date?
    public var tzId: String
    /// Opaque reference into the document vault (owned by a parallel lane) — nil for a report with
    /// no backing document (pure manual entry).
    public var documentRef: String?
    public var reviewState: LabReviewState
    public var ingestionPath: IngestionPath
    public var sensitivityTier: LabSensitivityTier
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, sourceLabName: String? = nil, collectionAt: Date, reportedAt: Date? = nil,
                tzId: String, documentRef: String? = nil, reviewState: LabReviewState,
                ingestionPath: IngestionPath, sensitivityTier: LabSensitivityTier = .standard,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.sourceLabName = sourceLabName; self.collectionAt = collectionAt
        self.reportedAt = reportedAt; self.tzId = tzId; self.documentRef = documentRef
        self.reviewState = reviewState; self.ingestionPath = ingestionPath
        self.sensitivityTier = sensitivityTier; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - LabPanel

/// A named group of results within one report, e.g. "CBC" or "Lipid Panel". `name` is kept exactly
/// as printed (notebook law: structure where safe, source wording where not) — there is no closed
/// vocabulary of panel names to map onto. `sortOrder` preserves the order panels appeared on the
/// source document/entry.
public struct LabPanel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var reportId: String
    public var name: String
    public var sortOrder: Int
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, reportId: String, name: String, sortOrder: Int = 0,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.reportId = reportId; self.name = name; self.sortOrder = sortOrder
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - LabResult

/// One observation within a report. `analyteId`/`customLabel` mirror how `JournalEntry`/`StrengthSet`
/// already handle "dictionary key OR free text" — exactly one is set, so an analyte the dictionary
/// doesn't recognize is NEVER blocked from being logged (§7A.4 reject: no closed analyte
/// dictionary). `rawValueText` is the value exactly as printed/typed — always present, never
/// reformatted — with `comparator`/`numericValue`/`rawUnit` as structure layered ADDITIONALLY on top
/// when the text actually parses. `canonicalValue`/`canonicalUnit` are a SECOND, independent,
/// safe-class-only pair (`UnitNormalization`) — present only when `analyte.conversionSafetyClass ==
/// .safe` and the conversion actually succeeded; every other case leaves both absent rather than
/// guessed.
///
/// `originalId`/`supersedes`/`revision` are the same append-first revision chain
/// `HydrationEntry`/`StrengthSet` already established (`HydrationLedger`/`LabResultLedger` below): a
/// hand correction or a LAB-16 amended-report supersession APPENDS a new row, never UPDATEs a logged
/// result.
///
/// Carries a full embedded `Provenance` (I1) — unlike its parent `LabReport` — because different
/// results in the SAME report can legitimately have different `measuredAt` instants (a
/// glucose-tolerance panel draws at 0/60/120 minutes) and, after a hand correction or a LAB-16
/// resolution, a different `ingestionPath`/`algorithmVersionId` than their siblings.
public struct LabResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var reportId: String
    /// The panel this result belongs to, or nil for a result logged outside any named panel (a quick
    /// single-marker entry has none).
    public var panelId: String?
    /// Dictionary key into `AnalyteDefinition` — exactly one of this and `customLabel` is set.
    public var analyteId: String?
    /// Free-text marker name when the dictionary doesn't (yet) recognize the analyte.
    public var customLabel: String?
    /// The value exactly as printed/typed — e.g. "5.2", "<0.1", "Positive", "Trace". Always present.
    public var rawValueText: String
    /// The comparator printed in front of the value, if any ("<", ">=", "~"…). Nil = an exact value.
    public var comparator: LabComparator?
    /// The as-reported numeric parse of `rawValueText`, in `rawUnit` — populated whenever
    /// `resultType == .numeric` and the text actually parsed as a number. This is DISTINCT from
    /// `canonicalValue`: this is a plain text→number parse in whatever unit was printed, never a unit
    /// conversion, so it is available for trend/baseline math even for analytes whose
    /// `conversionSafetyClass` forbids ever auto-converting their unit.
    public var numericValue: Double?
    /// The unit exactly as printed, when the result carries one.
    public var rawUnit: String?
    /// The additional, safe-class-only converted value (`UnitNormalization`) — nil unless the
    /// analyte's class is `.safe` and the conversion succeeded. Never replaces `numericValue`/`rawUnit`.
    public var canonicalValue: Double?
    /// The unit `canonicalValue` is expressed in — set together with `canonicalValue`, never alone.
    public var canonicalUnit: String?
    public var resultType: LabResultType
    public var reviewState: LabReviewState
    public var sensitivityTier: LabSensitivityTier
    /// Stable identity across every revision of this logical result. `originalId == id` for a
    /// first-time (un-revised) result.
    public var originalId: String
    /// The id of the row this one supersedes; nil for an original.
    public var supersedes: String?
    /// 1-based counter (1 = original).
    public var revision: Int
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var isOriginal: Bool { supersedes == nil }
    public var isRevised: Bool { revision > 1 }

    /// The identity key this result groups under for trend/baseline/duplicate-detection purposes —
    /// the dictionary id when recognized, or a normalized form of the free-text label otherwise. An
    /// unrecognized marker still accumulates a trend and still participates in duplicate detection;
    /// it is never excluded for lacking a dictionary id.
    public var analyteKey: String {
        if let analyteId, !analyteId.isEmpty { return analyteId }
        let normalized = (customLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "custom:" + normalized
    }

    public init(id: String, reportId: String, panelId: String? = nil, analyteId: String? = nil,
                customLabel: String? = nil, rawValueText: String, comparator: LabComparator? = nil,
                numericValue: Double? = nil, rawUnit: String? = nil, canonicalValue: Double? = nil,
                canonicalUnit: String? = nil, resultType: LabResultType, reviewState: LabReviewState,
                sensitivityTier: LabSensitivityTier = .standard, originalId: String, supersedes: String? = nil,
                revision: Int = 1, provenance: Provenance, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil) {
        self.id = id; self.reportId = reportId; self.panelId = panelId; self.analyteId = analyteId
        self.customLabel = customLabel; self.rawValueText = rawValueText; self.comparator = comparator
        self.numericValue = numericValue; self.rawUnit = rawUnit; self.canonicalValue = canonicalValue
        self.canonicalUnit = canonicalUnit; self.resultType = resultType; self.reviewState = reviewState
        self.sensitivityTier = sensitivityTier; self.originalId = originalId; self.supersedes = supersedes
        self.revision = revision; self.provenance = provenance; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

/// Pure, storage-free live-view logic for the `LabResult` revision chain — the domain-level mirror of
/// `HydrationLedger.liveEntries`/`StrengthSetLedger.liveSets`, kept in sync with the repository's SQL
/// the same way those two are.
public enum LabResultLedger {
    /// A result is live iff it is not tombstoned, AND no non-deleted row supersedes it, AND it is
    /// not dedup-suppressed (`provenance.suppressedBy` — LAB-16's `.merge` decision, I3: suppressed
    /// rows are hidden from every live view, never deleted). Order is preserved from the input.
    public static func liveResults(_ all: [LabResult]) -> [LabResult] {
        let supersededByLive = Set(all.compactMap { $0.deletedAt == nil ? $0.supersedes : nil })
        return all.filter { $0.deletedAt == nil && !supersededByLive.contains($0.id) && !$0.provenance.isSuppressed }
    }
}

// MARK: - ReferenceRange (four-concept law: concepts 1+2 ONLY)

/// Concepts 1 and 2 of the four-concept reference-range law — the source-printed interval and the
/// source-printed flag — and ONLY those two. Personal baseline (concept 3, `DerivedTrend`) and a
/// user-defined threshold (concept 4, `ReferenceRangeEngine.UserLabThreshold`) are computed/stored
/// entirely separately, on purpose: this struct has no field that could hold either, which is what
/// makes conflating the four concepts a compile-time impossibility rather than a discipline someone
/// has to remember to uphold.
///
/// Every field is optional and left `nil` exactly when the source printed nothing — a missing range
/// is NEVER invented, looked up from a generic table, or backfilled at read time.
public struct ReferenceRange: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var resultId: String
    public var sourceIntervalLow: Double?
    public var sourceIntervalHigh: Double?
    /// The printed interval verbatim, for the common case where it isn't a clean low/high pair
    /// ("Negative", "<5", "Not established") — source wording is preserved even when it can't be
    /// structured into two numbers.
    public var sourceIntervalText: String?
    /// The unit the source interval was printed in — normally mirrors the result's own `rawUnit`,
    /// but kept independent since a lab occasionally prints its range in a different unit than the
    /// value.
    public var sourceIntervalUnit: String?
    /// The lab's own flag/annotation, verbatim ("H", "L", "Critical", "AA") — never BADAN's own
    /// judgment of the value.
    public var sourceFlag: String?
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var hasSourceInterval: Bool {
        sourceIntervalLow != nil || sourceIntervalHigh != nil || sourceIntervalText != nil
    }
    public var hasSourceFlag: Bool { sourceFlag != nil }

    public init(id: String, resultId: String, sourceIntervalLow: Double? = nil,
                sourceIntervalHigh: Double? = nil, sourceIntervalText: String? = nil,
                sourceIntervalUnit: String? = nil, sourceFlag: String? = nil,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.resultId = resultId; self.sourceIntervalLow = sourceIntervalLow
        self.sourceIntervalHigh = sourceIntervalHigh; self.sourceIntervalText = sourceIntervalText
        self.sourceIntervalUnit = sourceIntervalUnit; self.sourceFlag = sourceFlag
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - AnalyteDefinition (contract data — packages/contracts/analytes/analytes.json)

/// One curated analyte in the bilingual ontology (`analytes.json`). Same dictionary-vs-custom split
/// as `BehaviorDefinition`/`BeverageDefinition`: the curated set ships as bundled contract data,
/// anything else is a free-text `LabResult.customLabel` (never blocked — §7A.4 reject: no closed
/// analyte dictionary).
///
/// `category` is kept as a bare string, not a closed Swift enum, for the same reason
/// `BehaviorDefinition.category`/`HydrationFluidType`'s underlying storage are bare strings: a
/// category new to a future contract revision must never fail to decode on an app that predates it.
/// `loincCode` is nil rather than a guessed/uncertain code — a wrong LOINC code is worse than an
/// absent one.
///
/// `canonicalUnit` is DELIBERATELY NOT required to exist in `Core/Units.swift`'s `Units.table`
/// (unlike `MetricDefinition.canonicalUnit`, which `DerivationFixTests.testRegistryCanonicalAndDisplayUnitsAreAllKnown`
/// does check against that table). Most lab units (mmol/L, U/L, IU/mL, x10^9/L…) simply are not
/// wearable/vitals units, `Units.table` was never meant to hold them, and this slice does not touch
/// `Core/Units.swift` to add them. `UnitNormalization`'s own per-analyte conversion table — not
/// `Units.convert` — is what actually moves a `.safe`-class value into this unit; see that file's
/// header doc for why a per-analyte table is the correct mechanism here, not a shared global one.
public struct AnalyteDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var nameEn: String
    public var nameAr: String
    /// One of the 20 §7A.4 categories (CBC, iron, metabolic, liver, kidney, lipids, glucose,
    /// glycemic, thyroid, reproductive, vitamins, inflammation, urinalysis, micro/culture, allergy,
    /// drug monitoring, genetic-meta, custom, user-defined, derived).
    public var category: String
    public var loincCode: String?
    public var canonicalUnit: String
    public var conversionSafetyClass: ConversionSafetyClass

    public var displayName: LocalizedString { LocalizedString(en: nameEn, ar: nameAr) }

    public init(id: String, nameEn: String, nameAr: String, category: String, loincCode: String? = nil,
                canonicalUnit: String, conversionSafetyClass: ConversionSafetyClass) {
        self.id = id; self.nameEn = nameEn; self.nameAr = nameAr; self.category = category
        self.loincCode = loincCode; self.canonicalUnit = canonicalUnit
        self.conversionSafetyClass = conversionSafetyClass
    }
}

// MARK: - UserCorrection (append-only overlay — NEVER destructive)

/// A field-level correction event, attached to either a `LabReport` or a `LabResult` (`targetType`
/// discriminates). Append-only: no update/delete path is ever defined against this table — a
/// correction, once recorded, is permanent audit trail, mirroring this codebase's existing
/// revision-chain convention (`StrengthSessionRunner`/`HydrationLedger`) one layer up, for the
/// entities that have no revision chain of their own to lean on (a `LabReport`'s metadata) or for a
/// lightweight fix that doesn't warrant minting a whole new `LabResult` revision.
public struct UserCorrection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var targetType: LabAttachmentTarget
    public var targetId: String
    /// The field being corrected, e.g. `"sourceLabName"`, `"rawUnit"` — a domain field name, not a
    /// storage column name, so it reads the same regardless of the underlying schema.
    public var fieldName: String
    /// The value before this correction, when there was one (nil covers "filled in for the first
    /// time", which uses the same shape as a correction).
    public var previousValueText: String?
    public var correctedValueText: String
    public var reason: String?
    public var correctedAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, targetType: LabAttachmentTarget, targetId: String, fieldName: String,
                previousValueText: String? = nil, correctedValueText: String, reason: String? = nil,
                correctedAt: Date, updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.targetType = targetType; self.targetId = targetId; self.fieldName = fieldName
        self.previousValueText = previousValueText; self.correctedValueText = correctedValueText
        self.reason = reason; self.correctedAt = correctedAt; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - LabAnnotation

/// A free-text note or clinician question tied to a report or result — the visit-prep
/// differentiator ("strongest differentiator vs generic dashboards", plan §7A.4). `resolved` is a
/// plain user-toggled flag (asked-and-answered at a visit), never a diagnostic state.
public enum LabAnnotationKind: String, Codable, Hashable, Sendable, CaseIterable {
    case note
    case clinicianQuestion
}

public struct LabAnnotation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var targetType: LabAttachmentTarget
    public var targetId: String
    public var kind: LabAnnotationKind
    public var text: String
    public var resolved: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, targetType: LabAttachmentTarget, targetId: String, kind: LabAnnotationKind,
                text: String, resolved: Bool = false, createdAt: Date, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.targetType = targetType; self.targetId = targetId; self.kind = kind
        self.text = text; self.resolved = resolved; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - DerivedTrend (four-concept law: concept 3 — personal baseline)

/// A computed per-analyte trend/baseline summary — concept 3 of the four-concept law
/// (`ReferenceRangeEngine.computePersonalBaseline`), append-only per I2 exactly like `Baseline`/the
/// sensitive DB's own `derived_values` (a recompute appends a fresh row at a new
/// `computedAt`/`validFrom`; the latest row per `analyteId` wins on read). `analyteId` holds
/// `LabResult.analyteKey` — the dictionary id OR a normalized custom-label key — so an unrecognized
/// marker still accumulates a trend rather than being excluded for lacking a dictionary entry.
///
/// Reuses `BaselineMethod` (`Domain/Derivation.swift`) rather than inventing a parallel enum: a
/// median+MAD band is the same computation regardless of which family of metric it's banding.
public struct DerivedTrend: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var analyteId: String
    public var windowDays: Int
    public var method: BaselineMethod
    public var center: Double
    public var spread: Double
    public var bandLow: Double
    public var bandHigh: Double
    public var nPoints: Int
    public var provisional: Bool
    public var algorithmVersion: String
    /// The unit this trend is computed in — the analyte's own as-reported or canonical unit, never a
    /// blend of several (see `ReferenceRangeEngine.computePersonalBaseline`).
    public var unit: String
    public var validFrom: Date
    public var computedAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, analyteId: String, windowDays: Int, method: BaselineMethod = .medianMAD,
                center: Double, spread: Double, bandLow: Double, bandHigh: Double, nPoints: Int,
                provisional: Bool, algorithmVersion: String, unit: String, validFrom: Date,
                computedAt: Date, updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.analyteId = analyteId; self.windowDays = windowDays; self.method = method
        self.center = center; self.spread = spread; self.bandLow = bandLow; self.bandHigh = bandHigh
        self.nPoints = nPoints; self.provisional = provisional; self.algorithmVersion = algorithmVersion
        self.unit = unit; self.validFrom = validFrom; self.computedAt = computedAt
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}
