import Foundation
import CryptoKit

/// Why a report could not be generated.
enum ReportError: Error, Equatable {
    case invalidPeriodKey(String)
}

/// Builds a periodic report (EPIC-31) — WHOOP's Performance Assessment, transparent edition.
///
/// The heart of it is `build`, a **pure** function from already-loaded rows to a `ReportModel`:
/// given the same period and the same derived-value / adherence rows, it produces an identical
/// model (identical `sha256`), which is what lets a rendered artifact be verified against a
/// re-derivation and never be a source of truth (migration v8). Purity is also why the report is
/// testable with fixtures alone — no database in the loop — and why the acceptance test can assert
/// that *every claim resolves to a real evidence ref*: the refs come straight from the input rows'
/// ids, so they cannot point at anything that was not there.
///
/// `generate` is the thin loading shell around it: it resolves a period, reads the latest derived
/// value per day per score metric plus the period's adherence events, and calls `build`. Adherence
/// is aggregated to **counts only** (never medication names/dosages), so the report artifact never
/// carries the sensitive-plus namespace's contents across (I7); `includeAdherence` lets the
/// composition root omit it entirely.
final class ReportBuilder {
    private let derivation: DerivationRepository
    private let logging: LoggingRepository

    init(derivation: DerivationRepository, logging: LoggingRepository) {
        self.derivation = derivation
        self.logging = logging
    }

    // MARK: - Published algorithm identity + constants

    /// The report-building algorithm identity. Written to `reports.algorithm_version_id` and
    /// `ReportModel.algorithmVersionId`; part of a report's identity, so a change here makes the
    /// next generation a genuinely new report rather than a replacement (v8 unique index).
    static let algorithm = AlgorithmVersion(
        algorithmId: "report.periodic", semver: "1.0.0",
        params: [
            "minComparableDays": Double(minComparableDays),
            "changeRelThreshold": changeRelThreshold,
            "changeAbsFloor": changeAbsFloor,
            "flatRelThreshold": flatRelThreshold,
        ],
        introducedIn: "0.1.0")

    /// A period-over-period delta is only computed when BOTH periods have at least this many days
    /// with a value — comparing a 2-day week against a full one would manufacture a "change".
    static let minComparableDays = 3
    /// Relative shift (|Δmean| / priorMean) at or above which a change is "notable" enough for the
    /// changes section. 10%.
    static let changeRelThreshold = 0.10
    /// Absolute shift used only when priorMean is 0 (no relative change is defined).
    static let changeAbsFloor = 5.0
    /// Relative band inside which a direction reads as `flat` rather than up/down.
    static let flatRelThreshold = 0.02

    /// Score metrics per section (only those present with a value appear). Sleep leads with
    /// performance and, when present, its debt/consistency companions.
    static let sleepMetrics = [MetricID.sleepPerformance, MetricID.sleepDebt, MetricID.sleepConsistency]
    static let effortMetrics = [MetricID.effortDay]
    static let readinessMetrics = [MetricID.readinessScore]
    /// The primary metrics the changes section is computed over (one headline per score family).
    static let changeMetrics = [MetricID.sleepPerformance, MetricID.effortDay, MetricID.readinessScore]

    static var allScoreMetrics: [String] { sleepMetrics + effortMetrics + readinessMetrics }

    // MARK: - Pure build inputs

    /// Everything `build` needs, pre-loaded — the seam that keeps the builder pure and the tests
    /// database-free. Each `[DerivedValue]` holds at most one row per day (the latest per day per
    /// metric), carrying its own `id` and `periodKey` for evidence.
    struct Inputs: Sendable {
        var period: ReportPeriod.Resolved
        var prior: ReportPeriod.Resolved
        var currentByMetric: [String: [DerivedValue]]
        var priorByMetric: [String: [DerivedValue]]
        var adherence: [AdherenceEvent]?
        var generatedAt: Date

        init(period: ReportPeriod.Resolved, prior: ReportPeriod.Resolved,
                    currentByMetric: [String: [DerivedValue]], priorByMetric: [String: [DerivedValue]],
                    adherence: [AdherenceEvent]?, generatedAt: Date) {
            self.period = period; self.prior = prior
            self.currentByMetric = currentByMetric; self.priorByMetric = priorByMetric
            self.adherence = adherence; self.generatedAt = generatedAt
        }
    }

    // MARK: - Pure build

    /// The pure core: rows in, model out, deterministic. No I/O, no clock beyond the supplied
    /// `generatedAt` (which is deliberately excluded from the content hash).
    static func build(_ inputs: Inputs) -> ReportModel {
        var sections: [ReportSection] = []

        // Score sections, in the fixed order sleep → effort → readiness.
        if let sleep = scoreSection(.sleep, metrics: sleepMetrics, inputs) { sections.append(sleep) }
        if let effort = scoreSection(.effort, metrics: effortMetrics, inputs) { sections.append(effort) }
        if let readiness = scoreSection(.readiness, metrics: readinessMetrics, inputs) { sections.append(readiness) }

        // Adherence, when supplied and non-empty.
        if let adherence = inputs.adherence, let summary = adherenceSummary(adherence), summary.logged > 0 {
            sections.append(ReportSection(kind: .adherence, adherence: summary))
        }

        // Notable changes, computed over the primary metrics; present only if any crossed threshold.
        let changes = changeItems(inputs)
        if !changes.isEmpty { sections.append(ReportSection(kind: .changes, changes: changes)) }

        var model = ReportModel(
            periodKey: inputs.period.periodKey, periodKind: inputs.period.kind,
            periodStart: inputs.period.start, periodEnd: inputs.period.end,
            timezone: inputs.period.timezone, generatedAt: inputs.generatedAt,
            algorithmVersionId: algorithm.id, hasSufficientData: !sections.isEmpty,
            sections: sections, sha256: "")
        model.sha256 = contentHash(of: model)
        return model
    }

    // MARK: - Sections

    private static func scoreSection(_ kind: ReportSectionKind, metrics: [String], _ inputs: Inputs) -> ReportSection? {
        var summaries: [MetricSummary] = []
        for metricId in metrics {
            let current = (inputs.currentByMetric[metricId] ?? []).sorted { $0.periodKey < $1.periodKey }
            guard !current.isEmpty else { continue }
            let prior = inputs.priorByMetric[metricId] ?? []
            summaries.append(metricSummary(metricId: metricId, current: current, prior: prior))
        }
        guard !summaries.isEmpty else { return nil }
        return ReportSection(kind: kind, metrics: summaries)
    }

    private static func metricSummary(metricId: String, current: [DerivedValue], prior: [DerivedValue]) -> MetricSummary {
        let values = current.map { $0.value }
        let count = values.count
        let mean = round4(values.reduce(0, +) / Double(count))
        let minV = round4(values.min() ?? 0)
        let maxV = round4(values.max() ?? 0)
        let latest = round4(current.last?.value ?? 0)   // current is sorted ascending by day key

        var deltaVsPrior: Double? = nil
        if count >= minComparableDays, prior.count >= minComparableDays {
            let priorMean = prior.map { $0.value }.reduce(0, +) / Double(prior.count)
            deltaVsPrior = round4(mean - priorMean)
        }
        let priorMean = prior.isEmpty ? nil : prior.map { $0.value }.reduce(0, +) / Double(prior.count)
        let direction = trend(deltaAbs: deltaVsPrior, priorMean: priorMean.map { round4($0) })

        let unit = current.first?.unit ?? ""
        let evidence = current.map { EvidenceRef(kind: .derivedValue, id: $0.id, periodKey: $0.periodKey) }
        return MetricSummary(metricId: metricId, unit: unit, count: count, mean: mean, min: minV,
                             max: maxV, latest: latest, deltaVsPrior: deltaVsPrior,
                             direction: direction, evidence: evidence)
    }

    private static func changeItems(_ inputs: Inputs) -> [ChangeItem] {
        var items: [ChangeItem] = []
        for metricId in changeMetrics {
            let current = inputs.currentByMetric[metricId] ?? []
            let prior = inputs.priorByMetric[metricId] ?? []
            guard current.count >= minComparableDays, prior.count >= minComparableDays else { continue }
            let currentMean = round4(current.map { $0.value }.reduce(0, +) / Double(current.count))
            let priorMean = round4(prior.map { $0.value }.reduce(0, +) / Double(prior.count))
            let deltaAbs = round4(currentMean - priorMean)
            let notable: Bool
            let deltaPct: Double?
            if priorMean != 0 {
                let pct = deltaAbs / priorMean
                deltaPct = round4(pct)
                notable = abs(pct) >= changeRelThreshold
            } else {
                deltaPct = nil
                notable = abs(deltaAbs) >= changeAbsFloor
            }
            guard notable else { continue }
            var evidence = current.sorted { $0.periodKey < $1.periodKey }
                .map { EvidenceRef(kind: .derivedValue, id: $0.id, periodKey: $0.periodKey) }
            evidence += prior.sorted { $0.periodKey < $1.periodKey }
                .map { EvidenceRef(kind: .derivedValue, id: $0.id, periodKey: $0.periodKey) }
            items.append(ChangeItem(metricId: metricId, currentMean: currentMean, priorMean: priorMean,
                                    deltaAbs: deltaAbs, deltaPct: deltaPct,
                                    direction: deltaAbs > 0 ? .up : (deltaAbs < 0 ? .down : .flat),
                                    evidence: evidence))
        }
        return items
    }

    private static func adherenceSummary(_ events: [AdherenceEvent]) -> AdherenceSummary? {
        guard !events.isEmpty else { return nil }
        var taken = 0, late = 0, skipped = 0
        for e in events {
            switch e.kind {
            case .taken: taken += 1
            case .late: late += 1
            case .skipped: skipped += 1
            }
        }
        let logged = taken + late + skipped
        let rate = logged > 0 ? round4(Double(taken + late) / Double(logged)) : nil
        // Evidence: ids only, never event content (I7). Sorted by id for a stable model.
        let evidence = events.map { $0.id }.sorted().map { EvidenceRef(kind: .adherenceEvent, id: $0) }
        return AdherenceSummary(taken: taken, late: late, skipped: skipped, logged: logged,
                                adherenceRate: rate, evidence: evidence)
    }

    // MARK: - Helpers

    private static func trend(deltaAbs: Double?, priorMean: Double?) -> TrendDirection {
        guard let d = deltaAbs, let p = priorMean else { return .insufficient }
        let rel = p != 0 ? d / abs(p) : d
        if abs(rel) < flatRelThreshold { return .flat }
        return rel > 0 ? .up : .down
    }

    static func round4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }

    /// Lowercase-hex SHA-256 of the model's content — everything except `generatedAt` (zeroed) and
    /// `sha256` (blanked). Deterministic within a platform: `JSONCoding.encoder` sorts keys and
    /// encodes dates as millis, and all doubles are pre-rounded, so the same content hashes the
    /// same across runs regardless of when it was generated.
    static func contentHash(of model: ReportModel) -> String {
        var copy = model
        copy.generatedAt = Date(epochMillis: 0)
        copy.sha256 = ""
        let data = (try? JSONCoding.encoder.encode(copy)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Loading shell

    /// Resolve `periodKey` in `tz` and generate the report from the derived store (+ adherence).
    func generate(periodKey: String, tz: String, now: Date, includeAdherence: Bool = true) throws -> ReportModel {
        guard let period = ReportPeriod.resolve(periodKey: periodKey, tz: tz) else {
            throw ReportError.invalidPeriodKey(periodKey)
        }
        return try generate(period: period, tz: tz, now: now, includeAdherence: includeAdherence)
    }

    /// Generate from an already-resolved period.
    func generate(period: ReportPeriod.Resolved, tz: String, now: Date, includeAdherence: Bool = true) throws -> ReportModel {
        let prior = ReportPeriod.prior(period, tz: tz)
        var currentByMetric: [String: [DerivedValue]] = [:]
        var priorByMetric: [String: [DerivedValue]] = [:]
        for metric in Self.allScoreMetrics {
            currentByMetric[metric] = try load(metric, dayKeys: period.dayKeys)
            priorByMetric[metric] = try load(metric, dayKeys: prior.dayKeys)
        }
        var adherence: [AdherenceEvent]? = nil
        if includeAdherence {
            // `to` is inclusive in the repository; the period end is exclusive (start of the next
            // day), so step back one millisecond to avoid counting an event at exactly midnight.
            let toInclusive = Date(epochMillis: period.end.epochMillis - 1)
            adherence = try logging.adherence(from: period.start, to: toInclusive)
        }
        let inputs = Inputs(period: period, prior: prior, currentByMetric: currentByMetric,
                            priorByMetric: priorByMetric, adherence: adherence, generatedAt: now)
        return Self.build(inputs)
    }

    private func load(_ metricId: String, dayKeys: [String]) throws -> [DerivedValue] {
        var out: [DerivedValue] = []
        for key in dayKeys {
            if let dv = try derivation.latestDerived(metricId: metricId, periodKey: "day:" + key) {
                out.append(dv)
            }
        }
        return out
    }
}
