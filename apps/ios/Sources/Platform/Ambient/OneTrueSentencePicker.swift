import Foundation

/// EPIC-33 (Phase 3D) — picks the ONE bilingual sentence the `one_true_sentence` widget (and the
/// `sentence` field of every other widget's snapshot) shows to describe today. This concept did
/// not exist before this slice: every other insight surface in this codebase renders a LIST (up to
/// `InsightEngine.keyMetrics.count` rows on the Insights tab); a widget has room for exactly one
/// line.
///
/// Reuses `InsightEngine`'s already-rendered, already-hedged, already-bilingual `Insight` rows via
/// `InsightRepository.forPeriod(_:)` rather than inventing a second copy-templating system —
/// see `InsightEngine.swift` for the template-rendering machinery this reads from. This picker
/// adds no new template rendering of its own; it only RANKS what `InsightEngine.generate` already
/// wrote for the day and falls back to one static, wellness-safe sentence when nothing fired.
///
/// Priority order:
///   1. The most notable/actionable already-rendered insight for today — an out-of-band vitals
///      signal (sleep debt rising, HRV below band, RHR above band) outranks a calm "within your
///      usual range" note, which outranks a still-calibrating baseline note. See `templatePriority`.
///   2. A calm, generic fallback ("your data is ready") when nothing notable fired today — never
///      alarming, never diagnostic (this codebase's standing wellness-copy rule; see
///      `packages/contracts/insights/templates.json`'s `wellnessRules`, which this fallback
///      follows even though it isn't itself one of that file's authored templates).
enum OneTrueSentencePicker {
    /// Lower index = more notable/actionable. Scoped to the template ids `InsightEngine.keyMetrics`
    /// can actually produce (see `InsightEngine.templateId(for:baseline:value:)`) — an id outside
    /// this list is simply treated as least-notable (see `pick`), never a crash, so this staying
    /// in sync with `InsightEngine` is a quality-of-ranking concern, not a correctness one.
    static let templatePriority = [
        "sleep_debt_rising",     // sleep bank declining — the most actionable of the three
        "hrv_below_band",        // recovery signal down
        "rhr_above_band",        // elevated resting heart rate
        "vitals_within_band",    // calm — "right in your usual range"
        "baseline_provisional",  // calibration note — least notable, just "still learning"
    ]

    /// Shown when no insight fired for the day (fresh account, nothing notable enough to
    /// template, or the day's derivation hasn't run yet). Wellness-lint-safe by the same rules
    /// `insight_templates.json` documents: no diagnosis, no alarm, no moralizing, just a calm,
    /// neutral statement of fact.
    static let fallback = LocalizedString(
        en: "Your data is ready for today.",
        ar: "بياناتك جاهزة لهذا اليوم.")

    /// Pick today's one sentence. `dayKey` is a `DayAttribution.localDayKey`-shaped string; this
    /// prefixes it with `"day:"` itself to match `InsightEngine.generate`'s own `periodKey`
    /// convention, so callers pass the same bare day key they use everywhere else (readiness's
    /// period key, sleep's `localNight`, etc.) rather than re-deriving the prefixed form.
    static func pick(insights: InsightRepository, dayKey: String) throws -> LocalizedString {
        let rows = try insights.forPeriod("day:" + dayKey)
        guard !rows.isEmpty else { return fallback }

        // Most-notable-first: the element whose template id sorts earliest in `templatePriority`
        // (an id this list doesn't recognize ranks last, never crashes). `InsightEngine.generate`
        // writes at most one row per key metric per day, so ties are rare; `min(by:)` deterministically
        // keeps the first-encountered row on an exact tie, which is stable given `forPeriod`'s
        // fixed `ORDER BY generated_at DESC` read order.
        let ranked = rows.min { a, b in
            Self.rank(a.templateId) < Self.rank(b.templateId)
        }
        return ranked?.renderedText ?? fallback
    }

    private static func rank(_ templateId: String) -> Int {
        templatePriority.firstIndex(of: templateId) ?? Int.max
    }
}
