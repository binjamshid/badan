import Foundation

/// Deterministic, template-rendered insight generation (no LLM). For a handful of key metrics
/// it compares the day's value to the personal baseline and picks a wellness-safe template,
/// filling `{metric}`/`{value}`/`{baseline}` in both languages. Regeneration is idempotent:
/// the day's insights are cleared and rebuilt so evidence always ties back to live derivations.
final class InsightEngine {
    /// The metrics that carry a daily status explanation on the home surface.
    static let keyMetrics = [MetricID.timeAsleep, MetricID.restingHeartRate, MetricID.hrv]

    private let insights: InsightRepository
    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let templates: InsightTemplateStore
    private let registry: MetricRegistry
    private let clock: Clock
    private let deviceId: String

    init(insights: InsightRepository, derivation: DerivationRepository,
         measurements: MeasurementRepository, templates: InsightTemplateStore,
         registry: MetricRegistry, clock: Clock, deviceId: String) {
        self.insights = insights
        self.derivation = derivation
        self.measurements = measurements
        self.templates = templates
        self.registry = registry
        self.clock = clock
        self.deviceId = deviceId
    }

    /// Rebuild the day's status-explanation insights for the key metrics in timezone `tz`.
    func generate(forDay date: Date, tz: String) throws {
        let dayKey = DayAttribution.localDayKey(date, tz: tz)
        let periodKey = "day:" + dayKey
        let dayStart = DayAttribution.startOfDay(date, tz: tz)
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)

        // Idempotent regeneration.
        try insights.deleteForPeriod(periodKey)

        for metricId in Self.keyMetrics {
            let records = try measurements.intervalRecords(metricId: metricId, from: dayStart, to: dayEnd)
            guard let record = records.filter({ $0.startAt < dayEnd }).last else { continue }
            guard let baseline = try derivation.latestBaseline(metricId: metricId) else { continue }

            guard let templateId = Self.templateId(for: metricId, baseline: baseline, value: record.value),
                  let template = templates.template(templateId) else { continue }

            let def = registry.definitionOrFallback(metricId)
            let valueStr = Self.formatValue(record.value, unit: record.unit)
            let baselineStr = Self.formatValue(baseline.center, unit: baseline.unit)

            let rendered = LocalizedString(
                en: Self.fill(template.textEn, ["metric": def.nameEn, "value": valueStr, "baseline": baselineStr]),
                ar: Self.fill(template.textAr, ["metric": def.nameAr, "value": valueStr, "baseline": baselineStr]))

            let insight = Insight(
                id: ULID.newID(), insightType: "statusExplanation", templateId: template.templateId,
                templateVersion: "1", metricIds: [metricId], periodKey: periodKey,
                depthVariant: .balanced, renderedText: rendered,
                evidenceRefs: [record.id, baseline.id], generatedAt: clock.now())
            try insights.insert(insight)
        }
    }

    // MARK: - Template selection

    /// Map a metric's position against its baseline to a template id, or nil to skip when no
    /// safe template fits the direction (never fabricate a template that isn't authored).
    static func templateId(for metricId: String, baseline: Baseline, value: Double) -> String? {
        if baseline.provisional { return "baseline_provisional" }
        switch baseline.position(of: value) {
        case .within:
            return "vitals_within_band"
        case .below:
            if metricId == MetricID.hrv { return "hrv_below_band" }
            if metricId == MetricID.timeAsleep { return "sleep_debt_rising" }
            return nil            // e.g. RHR below band is a good sign; no authored template
        case .above:
            if metricId == MetricID.restingHeartRate { return "rhr_above_band" }
            return nil            // HRV/sleep above band is a good sign; no authored template
        }
    }

    // MARK: - Formatting

    /// Durations (canonical seconds) render as "Xh Ym"; everything else is a rounded number
    /// plus its unit. Digits stay plain — the UI localises numerals separately.
    static func formatValue(_ value: Double, unit: String) -> String {
        if unit == "s" {
            let total = Int(value.rounded())
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
        let rounded = Int(value.rounded())
        return unit.isEmpty ? "\(rounded)" : "\(rounded) \(unit)"
    }

    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (key, value) in values {
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return out
    }
}
