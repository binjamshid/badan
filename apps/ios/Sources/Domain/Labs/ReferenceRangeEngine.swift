import Foundation

/// Pure rendering + personal-baseline logic built around THE FOUR-CONCEPT REFERENCE-RANGE LAW
/// (plan §7A.4 / §9.17): a result's "is this normal" story is FOUR SEPARATE, NEVER-CONFLATED
/// concepts —
///   1. Source interval — the reference range THE LAB ITSELF printed.
///   2. Source flag — whatever flag/annotation THE LAB ITSELF printed.
///   3. Personal baseline — BADAN's own computed baseline from the user's own history.
///   4. User-defined threshold — a threshold the user sets themselves.
/// Nothing in this file ever blends two of these into one number or one label; `render` keeps all
/// four labeled and independently presentable, and a concept the source didn't provide, or that
/// hasn't been computed/set, renders ABSENT — never invented, never looked up from a generic table.
public enum ReferenceRangeEngine {

    // MARK: - Rendering (concepts 1–4, kept apart by construction)

    /// The rendering-ready summary: four independently-optional slots, one per concept. There is no
    /// fifth field a caller could read as "the" normal range — the type itself is the guarantee.
    public struct RenderableRange: Equatable, Sendable {
        public struct SourceInterval: Equatable, Sendable {
            public let low: Double?
            public let high: Double?
            public let text: String?
            public let unit: String?
        }
        /// Concept 1. `nil` exactly when the source printed nothing.
        public let sourceInterval: SourceInterval?
        /// Concept 2. `nil` exactly when the source printed no flag.
        public let sourceFlag: String?
        /// Concept 3. `nil` when no personal baseline has been computed (e.g. too few points yet).
        public let personalBaseline: PersonalBaselineView?
        /// Concept 4. `nil` when the user has not set a threshold for this analyte.
        public let userThreshold: UserLabThreshold?

        public var hasAnyConcept: Bool {
            sourceInterval != nil || sourceFlag != nil || personalBaseline != nil || userThreshold != nil
        }
    }

    /// A read-only view of concept 3, independent of `DerivedTrend`'s storage shape.
    public struct PersonalBaselineView: Equatable, Sendable {
        public let center: Double
        public let bandLow: Double
        public let bandHigh: Double
        public let unit: String
        public let nPoints: Int
        public let provisional: Bool
        public let windowDays: Int
    }

    /// Renders the four concepts for one result. Deliberately dumb: it copies `range`'s two source
    /// fields across UNCHANGED (never derives, never guesses a missing one) and passes `baseline`/
    /// `threshold` through as their own labeled slots. The "conflating" failure mode this function
    /// exists to prevent — computing ONE band from some mix of the four and presenting it as if it
    /// were the lab's own interval — has no code path here that could produce it, because the four
    /// inputs are never combined at all, only relabeled.
    public static func render(range: ReferenceRange?, baseline: DerivedTrend?,
                              threshold: UserLabThreshold?) -> RenderableRange {
        let sourceInterval: RenderableRange.SourceInterval? = {
            guard let range, range.hasSourceInterval else { return nil }
            return RenderableRange.SourceInterval(
                low: range.sourceIntervalLow, high: range.sourceIntervalHigh,
                text: range.sourceIntervalText, unit: range.sourceIntervalUnit)
        }()
        let personalBaseline = baseline.map {
            PersonalBaselineView(center: $0.center, bandLow: $0.bandLow, bandHigh: $0.bandHigh,
                                 unit: $0.unit, nPoints: $0.nPoints, provisional: $0.provisional,
                                 windowDays: $0.windowDays)
        }
        return RenderableRange(sourceInterval: sourceInterval, sourceFlag: range?.sourceFlag,
                               personalBaseline: personalBaseline, userThreshold: threshold)
    }

    /// The only honest phrasing for concept 1 (plan §7A.4) — never "abnormal", never "unhealthy".
    /// Callers needing display copy for concept 1 alone should use this rather than composing their
    /// own wording, so the wellness-safe phrasing can't drift screen-by-screen.
    public static let sourceIntervalCaption = LocalizedString(
        en: "Outside this laboratory's stated reference interval",
        ar: "خارج نطاق المرجع الذي حدده هذا المختبر")

    // MARK: - Concept 4: user-defined threshold

    /// Concept 4 of the four-concept law.
    ///
    /// **Scope note (documented, not an oversight):** this slice implements the ENGINE's support for
    /// a user threshold as a plain value type so `render` can exercise and test the full four-concept
    /// law end to end. It deliberately does NOT add a persisted table/migration/repository for
    /// user-set thresholds — no Feature surface exists yet to let a user set one (this slice may not
    /// touch `Features/`), and none was asked for in this slice's owned-file list. Persisting a
    /// user's chosen thresholds is a follow-up slice's job; treat that absence as a stated gap.
    public struct UserLabThreshold: Equatable, Sendable {
        public enum Direction: String, Sendable { case above, below }
        public let analyteKey: String
        public let direction: Direction
        public let value: Double
        public let unit: String

        public init(analyteKey: String, direction: Direction, value: Double, unit: String) {
            self.analyteKey = analyteKey; self.direction = direction; self.value = value; self.unit = unit
        }
    }

    // MARK: - Concept 3: personal baseline computation

    /// Computes a personal baseline for one analyte from its own historical LIVE numeric results —
    /// the same robust median + MAD math `BaselineEngine.computeBaseline` already uses (reused, not
    /// re-derived, so the two engines can never quietly diverge on what "robust" means). Returns
    /// `nil` when there are fewer than `BaselineSpec.defaultShared.minPoints` usable points: the
    /// minimum-n gate deliberately MIRRORS `BaselineEngine`'s own convention rather than inventing a
    /// new threshold, per this slice's explicit brief.
    ///
    /// Only results whose resolved value's unit matches `unit` are used — mixing units here would be
    /// exactly the conflation the four-concept law exists to prevent, one level down (a baseline
    /// silently blending mg/dL and mmol/L readings would be meaningless). "Resolved value" prefers a
    /// result's `canonicalValue`/`canonicalUnit` (the safe-class conversion) when present, so a
    /// `.safe`-class analyte reported in two different original units across visits (HbA1c in %, then
    /// mmol/mol) still baselines as one consistent series, and falls back to `numericValue`/`rawUnit`
    /// otherwise. Callers pass history already scoped to one analyte (`LabResult.analyteKey`).
    static func computePersonalBaseline(history: [LabResult], unit: String,
                                        windowDays: Int = 365) -> BaselineComputation? {
        let spec = BaselineSpec.defaultShared
        let usable = LabResultLedger.liveResults(history).compactMap { result -> Double? in
            guard let resolved = resolvedValue(result), resolved.unit == unit else { return nil }
            return resolved.value
        }
        guard usable.count >= spec.minPoints else { return nil }
        let resolution = BaselineWindowResolution(windowDays: windowDays, transform: .identity)
        return BaselineEngine.computeBaseline(values: usable, resolution: resolution, spec: spec)
    }

    /// A convenience that also builds the `DerivedTrend` row ready to persist, using
    /// `BaselineEngine.baselineAlgorithm`'s id (the same published algorithm identity every other
    /// median/MAD band in this app carries, so a `DerivedTrend`'s `algorithmVersion` is traceable to
    /// the same methodology doc). Returns `nil` under the same conditions `computePersonalBaseline`
    /// does — a trend is never fabricated from too few points.
    public static func makeTrend(id: String, analyteKey: String, history: [LabResult], unit: String,
                                 windowDays: Int = 365, validFrom: Date, computedAt: Date,
                                 updatedAt: Date, originDeviceId: String) -> DerivedTrend? {
        guard let computation = computePersonalBaseline(history: history, unit: unit, windowDays: windowDays)
        else { return nil }
        return DerivedTrend(
            id: id, analyteId: analyteKey, windowDays: windowDays, method: .medianMAD,
            center: computation.center, spread: computation.spread, bandLow: computation.bandLow,
            bandHigh: computation.bandHigh, nPoints: computation.nPoints,
            provisional: computation.provisional, algorithmVersion: BaselineEngine.baselineAlgorithm.semver,
            unit: unit, validFrom: validFrom, computedAt: computedAt, updatedAt: updatedAt,
            originDeviceId: originDeviceId)
    }

    /// The value to baseline for one result: the canonical (safe-converted) pair when present, else
    /// the as-reported numeric pair. Never invents a value neither field carries.
    private static func resolvedValue(_ result: LabResult) -> (value: Double, unit: String)? {
        if let value = result.canonicalValue, let unit = result.canonicalUnit { return (value, unit) }
        if let value = result.numericValue, let unit = result.rawUnit { return (value, unit) }
        return nil
    }
}
