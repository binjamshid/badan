import Foundation

/// NEW-01: the onboarding "first fact" payoff. After a connected backfill finishes, onboarding
/// shows one real, wellness-safe fact before entering the app — the trust ladder's first rung
/// (`docs/design/screens-spec.json` S-10…S-17). Priority order:
///   (a) the freshest generated insight (already template-rendered, hedged, bilingual — see
///       `InsightEngine`/`insight_templates.json`);
///   (b) failing that, a direct baseline statement for a well-known metric, composed here with
///       the same hedged, self-referenced tone (`insight_templates.json`'s `wellnessRules`) and
///       rendered through the shared `ValueFormatter` so the numeral formatting matches the rest
///       of the app.
/// `nil` means neither is available yet (fresh account, still-sparse data) — callers must show
/// an honest fallback instead of blocking or fabricating a fact.
enum FirstFact {
    /// Metrics considered for the baseline-statement fallback, in priority order. Sleep duration
    /// is the most broadly meaningful "this is you" fact; resting heart rate is the fallback
    /// when sleep hasn't calibrated yet (mirrors `InsightEngine.keyMetrics`' ordering intent).
    static let baselineMetricOrder = [MetricID.timeAsleep, MetricID.restingHeartRate]

    static func select(insights: InsightRepository, derivation: DerivationRepository,
                       format: ValueFormatter) throws -> LocalizedString? {
        if let latest = try insights.recent(limit: 1).first {
            return latest.renderedText
        }
        return try baselineStatement(derivation: derivation, format: format)
    }

    /// A hedged, self-referenced baseline comparison — never "healthy"/"normal", matching the
    /// wellness-safe rules `insight_templates.json` documents for the InsightEngine templates.
    /// Skips a still-provisional baseline (not enough days yet) rather than presenting thin data
    /// as a settled fact.
    private static func baselineStatement(derivation: DerivationRepository,
                                          format: ValueFormatter) throws -> LocalizedString? {
        for metricId in baselineMetricOrder {
            guard let baseline = try derivation.latestBaseline(metricId: metricId), !baseline.provisional else { continue }
            let valueStr = format.full(metricId: metricId, canonicalValue: baseline.center)
            switch metricId {
            case MetricID.timeAsleep:
                return Loc.firstFactSleepBaseline.filling(["value": valueStr])
            case MetricID.restingHeartRate:
                return Loc.firstFactRHRBaseline.filling(["value": valueStr])
            default:
                continue
            }
        }
        return nil
    }
}
