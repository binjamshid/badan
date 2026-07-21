import Foundation

/// The typed, language-neutral model a periodic report is built from (EPIC-31) — the shared shape
/// described by `packages/contracts/report_model.schema.json` and mirrored on Android as
/// `ReportModel.kt`.
///
/// WHOOP's Performance Assessment, transparent edition: every *claim* in a report (a
/// `MetricSummary`, a `ChangeItem`, or the `AdherenceSummary`) carries the ids of the rows it rests
/// on (`EvidenceRef`), so the report can always answer "where did this number come from" by
/// resolving those ids back to real derived-value / adherence rows. The model is **numeric and
/// evidence-bearing, never prose** — the localized, wellness-safe sentences live in
/// `ReportRenderer`, which is exactly what lets a model snapshot fixture pin the numbers and refs
/// rather than any wording, and what makes the Arabic report the same report as the English one
/// (D-5, one model / two altitudes / two languages).
public struct ReportModel: Codable, Hashable, Sendable {
    public static let schemaVersionValue = "1.0"

    public var schemaVersion: String
    public var periodKey: String
    public var periodKind: ReportPeriodKind
    public var periodStart: Date
    public var periodEnd: Date        // exclusive: the period is [periodStart, periodEnd)
    public var timezone: String
    public var generatedAt: Date      // EXCLUDED from `sha256`
    public var algorithmVersionId: String
    public var hasSufficientData: Bool
    public var sections: [ReportSection]
    public var sha256: String

    public init(schemaVersion: String = ReportModel.schemaVersionValue, periodKey: String,
                periodKind: ReportPeriodKind, periodStart: Date, periodEnd: Date, timezone: String,
                generatedAt: Date, algorithmVersionId: String, hasSufficientData: Bool,
                sections: [ReportSection], sha256: String) {
        self.schemaVersion = schemaVersion; self.periodKey = periodKey; self.periodKind = periodKind
        self.periodStart = periodStart; self.periodEnd = periodEnd; self.timezone = timezone
        self.generatedAt = generatedAt; self.algorithmVersionId = algorithmVersionId
        self.hasSufficientData = hasSufficientData; self.sections = sections; self.sha256 = sha256
    }

    /// The ids of the sections present — exactly what `reports.sections_included` stores.
    public var sectionsIncluded: [String] { sections.map { $0.kind.rawValue } }

    /// Convenience lookup for the renderer / screen.
    public func section(_ kind: ReportSectionKind) -> ReportSection? {
        sections.first { $0.kind == kind }
    }
}

public enum ReportPeriodKind: String, Codable, Hashable, Sendable {
    case week, month
}

public enum ReportSectionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case sleep, effort, readiness, adherence, changes
}

/// The direction of a period-over-period shift — never a value judgement. `insufficient` when
/// either period lacked enough days to compare; the renderer maps every case to neutral,
/// wellness-safe copy.
public enum TrendDirection: String, Codable, Hashable, Sendable {
    case up, down, flat, insufficient
}

public enum EvidenceKind: String, Codable, Hashable, Sendable {
    case derivedValue, adherenceEvent, baseline
}

/// A pointer to a real row a report claim rests on — the transparency contract. `id` resolves in
/// the store named by `kind`; nothing about the row's content is copied here.
public struct EvidenceRef: Codable, Hashable, Sendable {
    public var kind: EvidenceKind
    public var id: String
    public var periodKey: String?

    public init(kind: EvidenceKind, id: String, periodKey: String? = nil) {
        self.kind = kind; self.id = id; self.periodKey = periodKey
    }
}

/// One report section. A uniform shape across kinds so the set can grow without a schema break: a
/// score section (sleep/effort/readiness) populates `metrics`; `changes` populates `changes`;
/// `adherence` populates `adherence`. Fields not relevant to a kind stay empty/nil.
public struct ReportSection: Codable, Hashable, Sendable {
    public var kind: ReportSectionKind
    public var metrics: [MetricSummary]
    public var changes: [ChangeItem]
    public var adherence: AdherenceSummary?

    public init(kind: ReportSectionKind, metrics: [MetricSummary] = [], changes: [ChangeItem] = [],
                adherence: AdherenceSummary? = nil) {
        self.kind = kind; self.metrics = metrics; self.changes = changes; self.adherence = adherence
    }
}

/// A claim about one metric over the period: how many days had a value, the central/extreme values,
/// and the shift versus the prior period. Every questionable field is backed by `evidence`.
public struct MetricSummary: Codable, Hashable, Sendable {
    public var metricId: String
    public var unit: String
    public var count: Int
    public var mean: Double?
    public var min: Double?
    public var max: Double?
    public var latest: Double?
    public var deltaVsPrior: Double?
    public var direction: TrendDirection
    public var evidence: [EvidenceRef]

    public init(metricId: String, unit: String, count: Int, mean: Double? = nil, min: Double? = nil,
                max: Double? = nil, latest: Double? = nil, deltaVsPrior: Double? = nil,
                direction: TrendDirection, evidence: [EvidenceRef]) {
        self.metricId = metricId; self.unit = unit; self.count = count; self.mean = mean
        self.min = min; self.max = max; self.latest = latest; self.deltaVsPrior = deltaVsPrior
        self.direction = direction; self.evidence = evidence
    }
}

/// A notable period-over-period change for one metric. Present only when the shift crossed the
/// published threshold, so the changes section is the "what changed" highlight, not a repeat of
/// every metric.
public struct ChangeItem: Codable, Hashable, Sendable {
    public var metricId: String
    public var currentMean: Double
    public var priorMean: Double
    public var deltaAbs: Double
    public var deltaPct: Double?
    public var direction: TrendDirection
    public var evidence: [EvidenceRef]

    public init(metricId: String, currentMean: Double, priorMean: Double, deltaAbs: Double,
                deltaPct: Double? = nil, direction: TrendDirection, evidence: [EvidenceRef]) {
        self.metricId = metricId; self.currentMean = currentMean; self.priorMean = priorMean
        self.deltaAbs = deltaAbs; self.deltaPct = deltaPct; self.direction = direction
        self.evidence = evidence
    }
}

/// Medication-adherence roll-up. COUNTS ONLY — no medication names, dosages, or any sensitive
/// content, so this aggregate never carries the sensitive-plus namespace's contents into the
/// report artifact (I7). Skip-with-reason counts equally to taken (non-punitive by design).
public struct AdherenceSummary: Codable, Hashable, Sendable {
    public var taken: Int
    public var late: Int
    public var skipped: Int
    public var logged: Int
    public var adherenceRate: Double?
    public var evidence: [EvidenceRef]

    public init(taken: Int, late: Int, skipped: Int, logged: Int, adherenceRate: Double? = nil,
                evidence: [EvidenceRef]) {
        self.taken = taken; self.late = late; self.skipped = skipped; self.logged = logged
        self.adherenceRate = adherenceRate; self.evidence = evidence
    }
}
