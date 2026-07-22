import Foundation

// MARK: - Cycle anomaly engine (EPIC-39 CYCLE-05, Phase 3F slice 1)
//
// Pure, storage-free detection over already-fetched `[CycleRecord]`/`[FlowLog]` arrays — mirrors
// the pure-function posture of `Domain/Labs/DuplicateConflictResolver.swift`: no I/O, no clock read,
// no repository, nothing mutated. A caller (a later slice's repository) fetches the live rows,
// calls `CycleAnomalyEngine.detectAnomalies`, and persists whatever comes back as new, APPENDED
// `CycleAnomalyEvent` rows (I2) — this file never decides persistence, never runs a cross-invocation
// escalation state machine, and never writes anything itself.
//
// Grounded in `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §6 ("Anomaly detection model" — the 7-row
// anomaly matrix and its exact minimum-history/message/escalation columns) and
// `docs/legal/reproductive-threat-model.md` (cycle data is BADAN's single highest-sensitivity
// family; anomaly copy that reads as alarming is exactly the kind of screen content an abusive
// partner glancing at a phone would find most exploitable — see that document's §5).
//
// THIS FILE BUILDS EXACTLY THE TOP-5 v1 SUBSET the research doc names, no more:
// cycle length deviation, period duration deviation, flow deviation, missed expected period,
// repeated irregularity. It deliberately does NOT build symptom-cluster-shift or
// context-linked-change (the matrix's other two rows) — those need cross-feature symptom/context
// infrastructure this slice does not have. It also never touches fertile-window/ovulation,
// BBT/cervical-mucus/ovulation-test logging, sexual-activity logging, or sharing — all separately
// gated, out of scope for this slice (see `CycleModels.swift`'s own header for the full list). If a
// change here starts drifting toward any of those, stop.
//
// WELLNESS-SAFE LANGUAGE, ENFORCED STRUCTURALLY: `CycleAnomalyEvent.messageKey` is a KEY, never
// rendered text (see that struct's own doc). `CycleAnomalyMessages` below is the ONLY place this
// slice defines the bilingual copy those keys resolve to, using only the approved phrasing patterns
// from research doc §14 ("different from your recent pattern", "this can happen for many reasons",
// "consider talking with a healthcare professional if this continues or concerns you") and never the
// banned vocabulary from §6 ("abnormal", "possible disorder", "this suggests PCOS", "pregnancy
// likely", "hormone imbalance detected", etc.) — `CycleAnomalyEngineTests` greps every literal in
// this file's own message table against that banned list, in both languages, as a standing test.
//
// NEUTRAL-LANGUAGE DEFAULT: per the threat model §5 ("Neutral-by-default language choice... default
// to the more neutral framing pending the actual legal/cultural review"), every rendered string below
// says "cycle" rather than "period" — matching the domain type's own name (`CycleRecord`, not
// "PeriodRecord") and staying inside the honesty boundary the threat model's §6 sets for this data
// family generally.
public enum CycleAnomalyEngine {

    // MARK: - Minimum-history gates (research doc §6: "single-cycle anomaly calls require at least 3
    // completed cycles of baseline history, while pattern-level anomaly calls require at least 4 to
    // 6 cycles depending on the anomaly class")
    //
    // "Baseline" here means history STRICTLY BEFORE the point being tested — the same
    // baseline-precedes-the-reading-it-classifies convention this codebase already uses elsewhere
    // (`BaselineEngine`/`DeviationEngine`: a stored band is computed from history, then a LATER
    // reading is classified against it, never against a band that already includes itself). Testing
    // the single most recent data point against a personal band drawn from at least 3 EARLIER points
    // is the safer reading of the research doc's own "baseline history" language, and sparse data is
    // named there as the primary false-alarm risk this engine must not create.
    private static let minimumBaselineCount = 3
    /// Pattern-level calls (`repeatedIrregularity`) additionally require a rolling window of 4-6
    /// cycle-length points to look across (matrix: "4 to 6 cycles"). 4 is the floor; 6 caps the
    /// window so one old irregular patch cannot haunt the pattern card indefinitely.
    private static let minimumPatternWindow = 4
    private static let maximumPatternWindow = 6

    // MARK: - Robust-band constants
    //
    // `madToSigma` is the standard MAD→sigma consistency constant for normally-distributed data
    // (the same constant `BaselineEngine`/`StressEngine` use, independently re-derived here since
    // this is a different domain/window with its own tuning, not a shared contract). `anomalyBandSigmas`
    // is deliberately WIDER than `BaselineSpec`'s own display-band `bandSigmas` (1.0) — this is a
    // DEVIATION ALARM threshold, not a "normal band" display width, and research doc §6 explicitly
    // names over-sensitive flagging as the primary anti-pattern to avoid ("prefer robust thresholds
    // over naive means... escalate only on persistence or magnitude, not on one noisy point").
    private static let madToSigma: Double = 1.4826
    private static let anomalyBandSigmas: Double = 2.0
    /// A floor under the MAD-derived spread so a person whose recent cycles are extremely regular
    /// (MAD == 0 or near it) does not get flagged for one day's ordinary natural drift — biological
    /// cycles vary by a day or two even for very regular cyclers. Chosen per-quantity below.
    private static let cycleLengthSpreadFloorDays: Double = 1.0
    private static let periodDurationSpreadFloorDays: Double = 1.0
    /// `FlowLog.normalizedIntensity` lives on a 0...1 scale per logged moment, so a period's summed
    /// flow spans a materially smaller numeric range than cycle-length/duration days; this floor is a
    /// judgment call sized to that scale, not a borrowed day-count constant.
    private static let flowSumSpreadFloor: Double = 0.2

    /// A small grace window added on top of a forecast's OWN confidence-band high edge before
    /// `missedExpectedPeriod` fires. The high edge is already an honest uncertainty bound the
    /// forecast itself published — this is a small EXTRA cushion per the per-type instruction ("end
    /// of the CyclePrediction's confidence band + a small user threshold"), not a second guess at the
    /// forecast's own math.
    private static let missedPeriodGraceDays: Double = 2.0

    // MARK: - Entry point

    /// Detects the top-5 v1 anomaly classes from already-fetched, possibly-stale-or-superseded
    /// `cycles`/`flowLogs` arrays. Filters to live rows internally (`CycleRecordLedger.liveRecords`,
    /// mirroring `ReferenceRangeEngine`'s own use of `LabResultLedger.liveResults` on caller-supplied
    /// history) so a caller can simply pass whatever it already fetched.
    ///
    /// `prediction` is the latest `CyclePrediction` (or `nil` if none has ever been generated yet) —
    /// added to this signature beyond the originally-sketched
    /// `(cycles:flowLogs:asOf:algorithmVersion:)` shape specifically because `missedExpectedPeriod`
    /// needs the forecast to know what "expected" even means; every other anomaly type ignores it.
    ///
    /// `originDeviceId` is also added beyond that original sketch: `CycleAnomalyEvent.originDeviceId`
    /// is a required, non-optional field with no other honest source inside a pure function, so it
    /// must come from the caller — the same pattern `ReferenceRangeEngine.makeTrend` already uses for
    /// its own `originDeviceId` parameter.
    ///
    /// Below any given type's minimum-history gate, that type simply never appears in the result —
    /// never a low-confidence guess, per the standing instruction.
    public static func detectAnomalies(
        cycles: [CycleRecord],
        flowLogs: [FlowLog],
        prediction: CyclePrediction?,
        asOf: Date,
        algorithmVersion: String,
        originDeviceId: String
    ) -> [CycleAnomalyEvent] {
        let liveCycles = CycleRecordLedger.liveRecords(cycles).sorted(by: chronologicalOrder)
        let liveFlowLogs = flowLogs.filter { $0.deletedAt == nil }

        var events: [CycleAnomalyEvent] = []
        if let event = detectCycleLengthDeviation(liveCycles, asOf: asOf, algorithmVersion: algorithmVersion,
                                                    originDeviceId: originDeviceId) {
            events.append(event)
        }
        if let event = detectPeriodDurationDeviation(liveCycles, asOf: asOf, algorithmVersion: algorithmVersion,
                                                       originDeviceId: originDeviceId) {
            events.append(event)
        }
        if let event = detectFlowDeviation(liveCycles, liveFlowLogs, asOf: asOf, algorithmVersion: algorithmVersion,
                                            originDeviceId: originDeviceId) {
            events.append(event)
        }
        if let event = detectMissedExpectedPeriod(liveCycles, prediction: prediction, asOf: asOf,
                                                    algorithmVersion: algorithmVersion, originDeviceId: originDeviceId) {
            events.append(event)
        }
        if let event = detectRepeatedIrregularity(liveCycles, asOf: asOf, algorithmVersion: algorithmVersion,
                                                   originDeviceId: originDeviceId) {
            events.append(event)
        }
        return events
    }

    /// Chronological by `startAt`; ties break on `id` for a fully deterministic order regardless of
    /// input array order (two periods cannot both start at the exact same instant in practice, but a
    /// deterministic tie-break keeps this function's output reproducible even from adversarial test
    /// fixtures).
    private static func chronologicalOrder(_ a: CycleRecord, _ b: CycleRecord) -> Bool {
        if a.startAt != b.startAt { return a.startAt < b.startAt }
        return a.id < b.id
    }

    // MARK: - Cycle length deviation
    //
    // "Cycle length" is the gap between the START of one period and the START of the next — it is
    // known as soon as the NEXT period starts, independent of whether the earlier period's own bleed
    // (`ongoing`/`endAt`) has finished. This is why the length points below are built from every live
    // cycle's `startAt`, with no `ongoing`/`endAt` filter — that filter belongs to
    // `periodDurationDeviation` (a different, bleed-duration quantity) below, not to this one.

    private struct LengthPoint {
        let cycle: CycleRecord
        let nextCycleId: String
        let days: Double
    }

    /// One point per known start-to-start gap. `n` live cycles yield `n - 1` points (the most recent
    /// live cycle's own forward length is not yet known — there is no next start to close it).
    private static func cycleLengthPoints(_ sortedCycles: [CycleRecord]) -> [LengthPoint] {
        guard sortedCycles.count >= 2 else { return [] }
        var points: [LengthPoint] = []
        points.reserveCapacity(sortedCycles.count - 1)
        for i in 0..<(sortedCycles.count - 1) {
            let days = sortedCycles[i + 1].startAt.timeIntervalSince(sortedCycles[i].startAt) / 86400
            points.append(LengthPoint(cycle: sortedCycles[i], nextCycleId: sortedCycles[i + 1].id, days: days))
        }
        return points
    }

    private static func detectCycleLengthDeviation(
        _ sortedCycles: [CycleRecord], asOf: Date, algorithmVersion: String, originDeviceId: String
    ) -> CycleAnomalyEvent? {
        let points = cycleLengthPoints(sortedCycles)
        guard points.count >= minimumBaselineCount + 1 else { return nil }

        let baseline = points.dropLast()
        let current = points[points.count - 1]
        let band = robustBand(baseline.map(\.days), spreadFloor: cycleLengthSpreadFloorDays)
        guard current.days < band.low || current.days > band.high else { return nil }

        let basisIds = Set(baseline.map(\.cycle.id) + baseline.map(\.nextCycleId)
                            + [current.cycle.id, current.nextCycleId])
        return CycleAnomalyEvent(
            id: ULID.newID(), type: .cycleLengthDeviation, detectedAt: asOf,
            basisWindowCycleIds: basisIds.sorted(), severity: .medium,
            messageKey: CycleAnomalyMessageKey.cycleLengthDeviation.rawValue, state: .active,
            algorithmVersion: algorithmVersion, confidence: confidenceForBaselineCount(baseline.count),
            updatedAt: asOf, originDeviceId: originDeviceId)
    }

    // MARK: - Period duration deviation
    //
    // Bleed duration (`endAt - startAt`) for a completed, non-ongoing period only — an in-progress
    // period's partial duration is not comparable to a finished one's, so it is excluded from both
    // the baseline and from ever being treated as "current" here (per the per-type instruction:
    // "only for completed/non-ongoing records").

    private struct DurationPoint {
        let cycle: CycleRecord
        let days: Double
    }

    private static func periodDurationPoints(_ sortedCycles: [CycleRecord]) -> [DurationPoint] {
        sortedCycles.compactMap { cycle in
            guard !cycle.ongoing, let endAt = cycle.endAt else { return nil }
            return DurationPoint(cycle: cycle, days: endAt.timeIntervalSince(cycle.startAt) / 86400)
        }
    }

    private static func detectPeriodDurationDeviation(
        _ sortedCycles: [CycleRecord], asOf: Date, algorithmVersion: String, originDeviceId: String
    ) -> CycleAnomalyEvent? {
        let points = periodDurationPoints(sortedCycles)
        guard points.count >= minimumBaselineCount + 1 else { return nil }

        let baseline = points.dropLast()
        let current = points[points.count - 1]
        let band = robustBand(baseline.map(\.days), spreadFloor: periodDurationSpreadFloorDays)
        guard current.days < band.low || current.days > band.high else { return nil }

        let basisIds = (baseline.map(\.cycle.id) + [current.cycle.id]).sorted()
        return CycleAnomalyEvent(
            id: ULID.newID(), type: .periodDurationDeviation, detectedAt: asOf,
            basisWindowCycleIds: basisIds, severity: .medium,
            messageKey: CycleAnomalyMessageKey.periodDurationDeviation.rawValue, state: .active,
            algorithmVersion: algorithmVersion, confidence: confidenceForBaselineCount(baseline.count),
            updatedAt: asOf, originDeviceId: originDeviceId)
    }

    // MARK: - Flow deviation
    //
    // Sum of `FlowLog.normalizedIntensity` across a completed period's own logs (chosen over peak
    // intensity as the single v1 statistic — a sum reflects overall logged volume across the whole
    // period, the more common everyday reading of "heavier/lighter than usual"). Periods with ZERO
    // flow logs are excluded from both the minimum-history count and the comparison entirely — never
    // treated as a zero-flow data point, per the per-type instruction.

    private struct FlowSumPoint {
        let cycle: CycleRecord
        let sum: Double
    }

    private static func flowSumPoints(_ sortedCycles: [CycleRecord], _ flowLogs: [FlowLog]) -> [FlowSumPoint] {
        let logsByCycle = Dictionary(grouping: flowLogs, by: \.cycleId)
        var points: [FlowSumPoint] = []
        for cycle in sortedCycles where !cycle.ongoing {
            guard let logs = logsByCycle[cycle.id], !logs.isEmpty else { continue }
            let sum = logs.reduce(0.0) { $0 + $1.normalizedIntensity }
            points.append(FlowSumPoint(cycle: cycle, sum: sum))
        }
        return points
    }

    private static func detectFlowDeviation(
        _ sortedCycles: [CycleRecord], _ flowLogs: [FlowLog], asOf: Date, algorithmVersion: String,
        originDeviceId: String
    ) -> CycleAnomalyEvent? {
        let points = flowSumPoints(sortedCycles, flowLogs)
        guard points.count >= minimumBaselineCount + 1 else { return nil }

        let baseline = points.dropLast()
        let current = points[points.count - 1]
        let band = robustBand(baseline.map(\.sum), spreadFloor: flowSumSpreadFloor)
        guard current.sum < band.low || current.sum > band.high else { return nil }

        let basisIds = (baseline.map(\.cycle.id) + [current.cycle.id]).sorted()
        return CycleAnomalyEvent(
            id: ULID.newID(), type: .flowDeviation, detectedAt: asOf,
            basisWindowCycleIds: basisIds, severity: .low,
            messageKey: CycleAnomalyMessageKey.flowDeviation.rawValue, state: .active,
            algorithmVersion: algorithmVersion, confidence: confidenceForBaselineCount(baseline.count),
            updatedAt: asOf, originDeviceId: originDeviceId)
    }

    // MARK: - Missed expected period
    //
    // Fires only when there IS an active forecast: a `.paused` prediction (e.g. CYCLE-07's
    // contraceptive-context suppression) has no "expected" period to miss, per the per-type
    // instruction — a paused forecast must never feed this check. Also never fires without a stated
    // high edge to measure the grace window from (a `coldStart` forecast may have no range at all).
    //
    // AUDIT FIX: this type's own minimum-history requirement (matrix: "3 cycles for forecast;
    // otherwise inactive") is stricter than "has a range at all" — a `.lowHistory` forecast (built
    // from just 1-2 completed cycles, `CyclePredictionEngine.tier(forCompletedCount:)`) DOES carry a
    // populated `predictedNextStartHigh`, so checking only for a non-nil high edge let a single-cycle
    // user's forecast fire this anomaly, which the research doc explicitly forbids for this type.
    // Gating on `prediction.method` (rather than re-deriving a cycle count here, which this function
    // has no access to) enforces the doc's 3-cycle floor using the SAME tier boundary
    // `CyclePredictionEngine` already computed it from — `.moderateHistory`/`.matureHistory` only.
    private static let missedExpectedPeriodMinimumMethods: Set<CyclePredictionMethod> = [.moderateHistory, .matureHistory]

    private static func detectMissedExpectedPeriod(
        _ sortedCycles: [CycleRecord], prediction: CyclePrediction?, asOf: Date, algorithmVersion: String,
        originDeviceId: String
    ) -> CycleAnomalyEvent? {
        guard let prediction, prediction.status == .active,
              missedExpectedPeriodMinimumMethods.contains(prediction.method),
              let high = prediction.predictedNextStartHigh else { return nil }

        let cutoff = high.addingTimeInterval(missedPeriodGraceDays * 86400)
        guard asOf > cutoff else { return nil }

        // If any live cycle has already started since this forecast was generated, the forecast was
        // fulfilled (whether or not it landed inside the stated band) — this is not a MISS.
        let arrivedSincePrediction = sortedCycles.contains { $0.startAt > prediction.generatedAt }
        guard !arrivedSincePrediction else { return nil }

        return CycleAnomalyEvent(
            id: ULID.newID(), type: .missedExpectedPeriod, detectedAt: asOf,
            basisWindowCycleIds: prediction.inputCycleIds, severity: .medium,
            messageKey: CycleAnomalyMessageKey.missedExpectedPeriod.rawValue, state: .active,
            algorithmVersion: algorithmVersion, confidence: prediction.confidence,
            updatedAt: asOf, originDeviceId: originDeviceId)
    }

    // MARK: - Repeated irregularity
    //
    // Reuses the SAME cycle-length points as `cycleLengthDeviation` above, and the SAME
    // baseline-excludes-current band, so the two checks can never disagree about what "the personal
    // band" is. Fires when 2+ CONSECUTIVE points in the last-4-to-6 window fall outside that band, OR
    // 3-of-the-last-4 do (matrix: "2+ consecutive cycles or 3 of last 4 outside baseline band").

    private static func detectRepeatedIrregularity(
        _ sortedCycles: [CycleRecord], asOf: Date, algorithmVersion: String, originDeviceId: String
    ) -> CycleAnomalyEvent? {
        let points = cycleLengthPoints(sortedCycles)
        guard points.count >= minimumPatternWindow else { return nil }

        let baseline = points.dropLast()
        guard baseline.count >= minimumBaselineCount else { return nil }
        let band = robustBand(baseline.map(\.days), spreadFloor: cycleLengthSpreadFloorDays)

        let window = Array(points.suffix(min(maximumPatternWindow, points.count)))
        let outsideFlags = window.map { $0.days < band.low || $0.days > band.high }

        let hasTwoConsecutive = zip(outsideFlags, outsideFlags.dropFirst()).contains { $0 && $1 }
        let lastFour = outsideFlags.suffix(4)
        let threeOfLastFour = lastFour.count == 4 && lastFour.filter { $0 }.count >= 3

        guard hasTwoConsecutive || threeOfLastFour else { return nil }

        let outsideCount = outsideFlags.filter { $0 }.count
        let basisIds = Set(baseline.map(\.cycle.id) + window.map(\.cycle.id) + window.map(\.nextCycleId))
        return CycleAnomalyEvent(
            id: ULID.newID(), type: .repeatedIrregularity, detectedAt: asOf,
            basisWindowCycleIds: basisIds.sorted(), severity: .medium,
            messageKey: CycleAnomalyMessageKey.repeatedIrregularity.rawValue, state: .active,
            algorithmVersion: algorithmVersion, confidence: min(0.9, 0.5 + 0.1 * Double(outsideCount)),
            updatedAt: asOf, originDeviceId: originDeviceId)
    }

    // MARK: - Shared robust-band math (median + MAD, local to this file — mirrors the per-file
    // pure-math convention `Domain/Labs/DuplicateConflictResolver.swift`/`Domain/Derivation/
    // CorrelationEngine.swift` already use rather than reaching into an unrelated engine's internals)

    private struct Band { let low: Double; let high: Double }

    private static func robustBand(_ values: [Double], spreadFloor: Double) -> Band {
        let center = median(values)
        let spread = max(mad(values, center: center), spreadFloor)
        let half = madToSigma * anomalyBandSigmas * spread
        return Band(low: center - half, high: center + half)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Median absolute deviation about `center` — the robust spread the band above is built from.
    private static func mad(_ values: [Double], center: Double) -> Double {
        median(values.map { abs($0 - center) })
    }

    /// More baseline history makes a self-referential comparison more trustworthy; this never invents
    /// certainty from a thin baseline (floor at the minimum gate) and never overclaims from a modest
    /// one (capped well short of 1.0).
    private static func confidenceForBaselineCount(_ n: Int) -> Double {
        min(0.9, 0.6 + 0.1 * Double(max(0, n - minimumBaselineCount)))
    }
}

// MARK: - Bilingual message templates (the ONLY place this slice's anomaly copy is defined)

/// One key per anomaly type this engine can emit. `CycleAnomalyEvent.messageKey` stores this raw
/// value — never rendered text — so a UI lane resolves the actual bilingual copy via
/// `CycleAnomalyMessages.text(for:)` at render time, independently of this schema.
public enum CycleAnomalyMessageKey: String, CaseIterable, Sendable {
    case cycleLengthDeviation = "cycle.anomaly.cycle_length_deviation.v1"
    case periodDurationDeviation = "cycle.anomaly.period_duration_deviation.v1"
    case flowDeviation = "cycle.anomaly.flow_deviation.v1"
    case missedExpectedPeriod = "cycle.anomaly.missed_expected_period.v1"
    case repeatedIrregularity = "cycle.anomaly.repeated_irregularity.v1"
}

/// The bilingual copy library `CycleAnomalyMessageKey` resolves to. Every string here uses only the
/// approved phrasing patterns from `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §14 — "different from
/// your recent pattern", "this can happen for many reasons", "consider talking with a healthcare
/// professional if this continues or concerns you" — and never names a condition, implies pregnancy,
/// or uses traffic-light/verdict words. `CycleAnomalyEngineTests` asserts none of §6's banned
/// vocabulary (or this codebase's own banned traffic-light words) appears in any string below, in
/// either language, as a standing regression test — not a one-time review.
public enum CycleAnomalyMessages {
    public static let templates: [String: LocalizedString] = [
        CycleAnomalyMessageKey.cycleLengthDeviation.rawValue: LocalizedString(
            en: "This cycle's length looks different from your recent pattern. This can happen for "
                + "many reasons. Consider talking with a healthcare professional if this continues or "
                + "concerns you.",
            ar: "يبدو طول هذه الدورة مختلفًا عن نمطك المعتاد في الفترة الأخيرة. قد يحدث هذا لأسباب كثيرة. "
                + "يمكنك التفكير في التحدث مع أخصائي رعاية صحية إذا استمر هذا الأمر أو إذا كان يقلقك."),
        CycleAnomalyMessageKey.periodDurationDeviation.rawValue: LocalizedString(
            en: "This cycle lasted differently from your recent pattern. This can happen for many "
                + "reasons. Consider talking with a healthcare professional if this continues or "
                + "concerns you.",
            ar: "استمرت هذه الدورة بشكل مختلف عن نمطك المعتاد في الفترة الأخيرة. قد يحدث هذا لأسباب كثيرة. "
                + "يمكنك التفكير في التحدث مع أخصائي رعاية صحية إذا استمر هذا الأمر أو إذا كان يقلقك."),
        CycleAnomalyMessageKey.flowDeviation.rawValue: LocalizedString(
            en: "Your logged flow this cycle looks different from what you usually record. This can "
                + "happen for many reasons.",
            ar: "يبدو تدفقك المسجَّل في هذه الدورة مختلفًا عمّا تسجّله عادةً. قد يحدث هذا لأسباب كثيرة."),
        CycleAnomalyMessageKey.missedExpectedPeriod.rawValue: LocalizedString(
            en: "Your next cycle hasn't started within the expected range based on your recent logs. "
                + "This can happen for many reasons. Consider talking with a healthcare professional if "
                + "this continues or concerns you.",
            ar: "لم تبدأ دورتك القادمة ضمن النطاق المتوقع بناءً على تسجيلاتك الأخيرة. قد يحدث هذا لأسباب "
                + "كثيرة. يمكنك التفكير في التحدث مع أخصائي رعاية صحية إذا استمر هذا الأمر أو إذا كان "
                + "يقلقك."),
        CycleAnomalyMessageKey.repeatedIrregularity.rawValue: LocalizedString(
            en: "Recent cycles have been more variable than your usual pattern. This can happen for "
                + "many reasons. Consider talking with a healthcare professional if this continues or "
                + "concerns you.",
            ar: "كانت دوراتك الأخيرة أكثر تفاوتًا من نمطك المعتاد. قد يحدث هذا لأسباب كثيرة. يمكنك "
                + "التفكير في التحدث مع أخصائي رعاية صحية إذا استمر هذا الأمر أو إذا كان يقلقك."),
    ]

    /// Resolves a `CycleAnomalyEvent.messageKey` to its bilingual copy, or `nil` for an unrecognized
    /// key (e.g. a future engine version's key an older app build doesn't know yet — never a crash,
    /// never a fabricated fallback sentence).
    public static func text(for messageKey: String) -> LocalizedString? {
        templates[messageKey]
    }
}
