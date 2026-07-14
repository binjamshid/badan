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

        // Idempotent regeneration. Delete + up to `keyMetrics.count` inserts batched into one
        // transaction instead of one commit+fsync per write; `insights` is the only repo written
        // here, so its connection covers the whole batch (PERF-02 (audit 2026-07-12)).
        try insights.transaction {
            try insights.deleteForPeriod(periodKey)

            for metricId in Self.keyMetrics {
                let records = try measurements.intervalRecords(metricId: metricId, from: dayStart, to: dayEnd)
                guard let record = records.filter({ $0.startAt < dayEnd }).last else { continue }
                guard let baseline = try derivation.latestBaseline(metricId: metricId) else { continue }

                guard let templateId = Self.templateId(for: metricId, baseline: baseline, value: record.value),
                      let template = templates.template(templateId) else { continue }

                let def = registry.definitionOrFallback(metricId)
                // (FIX-08) Render each language's value/baseline tokens separately — a shared
                // Latin-only string ("7h 12m", "62 bpm") baked into `rendered_ar` regardless of
                // language defeats the bilingual contract just as surely as leaving `ar` blank.
                let valueEn = Self.formatValue(record.value, unit: record.unit, language: .en)
                let valueAr = Self.formatValue(record.value, unit: record.unit, language: .ar)
                let baselineEn = Self.formatValue(baseline.center, unit: baseline.unit, language: .en)
                let baselineAr = Self.formatValue(baseline.center, unit: baseline.unit, language: .ar)

                let rendered = LocalizedString(
                    en: Self.fill(template.textEn, ["metric": def.nameEn, "value": valueEn, "baseline": baselineEn]),
                    ar: Self.fill(template.textAr, ["metric": def.nameAr, "value": valueAr, "baseline": baselineAr]))

                let insight = Insight(
                    id: ULID.newID(), insightType: "statusExplanation", templateId: template.templateId,
                    templateVersion: "1", metricIds: [metricId], periodKey: periodKey,
                    depthVariant: .casual, renderedText: rendered,
                    evidenceRefs: [record.id, baseline.id], generatedAt: clock.now())
                try insights.insert(insight)
            }
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

    /// Durations (canonical seconds) render as "Xh Ym" (en) / "Xس Yد" (ar); everything else is
    /// a rounded number plus its unit, translated for Arabic via `arabicUnitAbbreviation`.
    /// Digits stay plain in both languages — the UI localises numerals separately (the
    /// Arabic-digit preference lives in the App-layer `CustomizationProfile`, which Domain must
    /// not depend on).
    ///
    /// (FIX-08) `rendered_ar` used to reuse this same function's Latin-only output verbatim
    /// ("7h 12m", "62 bpm" baked into the Arabic string), because `formatValue` had no notion of
    /// language at all. It now takes `language` and produces Arabic duration/unit tokens.
    static func formatValue(_ value: Double, unit: String, language: AppLanguage) -> String {
        let rounded = Int(value.rounded())
        if unit == "s" {
            let hours = rounded / 3600
            let minutes = (rounded % 3600) / 60
            switch language {
            case .en: return "\(hours)h \(minutes)m"
            case .ar: return hours == 0 ? "\(minutes)د" : "\(hours)س \(minutes)د"
            }
        }
        guard !unit.isEmpty else { return "\(rounded)" }
        let label = language == .ar ? Self.arabicUnitAbbreviation(unit) : unit
        return "\(rounded) \(label)"
    }

    /// Small Arabic unit-abbreviation map for the handful of units `keyMetrics` actually
    /// renders insights for (sleep duration is handled directly in `formatValue` above; this
    /// covers RHR/HRV and the ratio units baselines can carry). Kept deliberately tiny and
    /// duplicated rather than shared: this is Domain, which must not import App-layer code, and
    /// the fuller canonical map for display purposes lives in
    /// `Sources/App/ValueFormatter.localizedUnit(_:)` (D-4 duplicated-logic budget — see
    /// `Units.swift`'s header comment for the same tradeoff made elsewhere).
    private static func arabicUnitAbbreviation(_ unit: String) -> String {
        switch unit {
        case "bpm": return "ن/د"
        case "ms": return "مي.ث"
        case "%", "percent": return "٪"
        default: return unit
        }
    }

    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (key, value) in values {
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return out
    }
}
