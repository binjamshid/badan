import Foundation

// MARK: - CyclePredictionEngine (EPIC-39 CYCLE-04 forecast + CYCLE-06 phase-estimation input,
// Phase 3F slice 1)
//
// Grounded in `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §5 ("Prediction and expectation model") and
// §7 ("Cycle phase as a cross-app covariate"), and `docs/legal/reproductive-threat-model.md` §5's
// "never a single-date confidence claim" mitigation. This slice implements prediction TIERS 1-4
// only (cold start / 1-2 cycles / 3-5 cycles / 6+ cycles) — rich-signal mode (BBT/ovulation tests,
// CYCLE-10) is still out of scope here. Fertile-window/ovulation estimation as a user-facing
// feature was gated on founder decision A17; A17 is now approved (ADR-0010/D-24) and CYCLE-12
// implements it as a SEPARATE SIBLING file, `CycleFertileWindowEngine.swift` — it does not extend
// this file. The "ovulation day" computed below remains an internal input to phase estimation
// ONLY, never surfaced as a fertile-window claim from THIS file; `CycleFertileWindowEngine`
// re-derives its own ovulation-day estimate independently (same public constants, own pure math),
// per this codebase's file-local-math convention (see `CycleAnomalyEngine`'s header).
//
// PURE AND STORAGE-FREE, mirroring `ReferenceRangeEngine.computePersonalBaseline`
// (`Domain/Labs/ReferenceRangeEngine.swift`): every function here operates only on arrays a caller
// already fetched. Nothing touches SQLite; nothing reads the wall clock (`asOf` is always
// injected, matching this codebase's "injected clock everywhere" rule).
//
// NO SINGLE-DATE PREDICTIONS, EVER. `predictNextCycle` only ever returns a low/center/high RANGE
// alongside a named `method` and a `confidence` — `CyclePrediction` has no field that could hold a
// bare "due on X" date (see `CycleModels.swift`'s own header), and this file must never be
// extended toward one. `estimatePhase` never guesses a phase from too little history: below the
// history threshold, or under a suppressive contraceptive context, it always returns `.unknown`
// with confidence pinned nearly to zero rather than an invented label.
//
// STATED GAP — `id`/`originDeviceId` on the returned rows: the shared cross-lane contract fixes
// `predictNextCycle`/`estimatePhase`'s signatures with no id or device-identity parameter (by
// design — see the exact signatures this file implements against). A fresh row `id` is minted here
// via `ULID.newID(clock:)` seeded from the caller's own `asOf` (matching `ULID.newID`'s own
// documented recommendation to embed the domain's actual time model rather than wall-clock "now").
// `originDeviceId` has no equivalent source this function can honestly derive — rather than
// fabricate a device identity, every returned row carries the documented placeholder
// `CyclePredictionEngine.unstampedOriginDeviceId`; the repository/persistence layer that actually
// inserts a row (a later slice, not owned by this file) MUST overwrite it with the real device id
// before persisting. This is a stated gap, not a silent invention — the same posture
// `ReferenceRangeEngine`'s own doc comments use for a comparable scope boundary.
public enum CyclePredictionEngine {

    // MARK: - Tuning constants (each documented at the point of use below)

    /// Below this many completed cycles, phase estimation does not attempt a calendar phase at
    /// all — distinct from (and stricter than) the prediction engine's own lowHistory/
    /// moderateHistory boundary, per this slice's brief ("with 0-2 completed cycles... phase =
    /// .unknown").
    public static let phaseMinimumCompletedCycles = 3

    /// Conservative fixed half-width (days) for the 1-2-cycle "low history" prediction tier. With
    /// only one or two observed lengths there is no statistically meaningful spread to compute (a
    /// two-point "range" is not a variance estimate), so per this slice's brief this is a
    /// documented flat constant rather than one derived from so little data. Chosen to land in the
    /// same several-day-wide territory as the illustrative low-confidence example
    /// `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §5 itself uses ("expected in about 5-9 days") — a
    /// wide band, never a single date.
    public static let lowHistoryHalfWidthDays = 4.0

    /// Minimum half-width FLOORS (days) for the moderate/mature prediction tiers — deliberately
    /// smaller than `lowHistoryHalfWidthDays` above (3, then 2) as a SAFETY MINIMUM only. Each tier's
    /// ACTUAL half-width is `max(floor, spread * spreadWidthMultiplier)`, so once a tier's OWN
    /// measured spread exceeds its floor, the floor plays no further role — the width is driven
    /// entirely by that tier's real data, per the research doc's explicit rejection of "generic
    /// 28-day" fixed-width forecasting.
    ///
    /// AUDIT CORRECTION: an earlier version of this comment additionally claimed the floors keep a
    /// higher-history-tier window from ever being proportionally WIDER than a lower tier's for the
    /// same underlying variance. That claim was FALSE and has been removed — it does not hold once
    /// measured spread exceeds `lowHistoryHalfWidthDays / spreadWidthMultiplier` (~2.67 days): a
    /// user with 3 genuinely irregular cycles can see a WIDER window (built honestly from their real
    /// spread) than a 1-2-cycle user's flat, less-informed guess, while ALSO getting a higher stated
    /// confidence for the same reason (more history is more trustworthy about the CENTRAL estimate,
    /// even when that history reveals real variability). This is not a bug: it is the intended
    /// consequence of "never a generic width" — width and confidence measure two different things
    /// (how honestly-uncertain the RANGE is vs. how trustworthy the ESTIMATE PROCESS is) and are not
    /// required to move together. What IS an invariant, and what this file's tests actually check, is
    /// that CONFIDENCE never inverts across tiers (`confidenceLowHistory` <
    /// `confidenceModerateHistoryFloor` < `confidenceMatureHistoryFloor` for every possible spread,
    /// by construction of the base/floor/penalty-cap constants below) — see
    /// `testConfidenceNeverInvertsAcrossTiersForAnyRealizableSpread`.
    public static let moderateHistoryFloorHalfWidthDays = 3.0
    public static let matureHistoryFloorHalfWidthDays = 2.0
    /// How strongly recent spread (mean absolute deviation of completed lengths from their
    /// recency-weighted mean) widens the interval beyond its floor.
    public static let spreadWidthMultiplier = 1.5

    /// Rolling window cap, per `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §5's "BADAN's blueprint
    /// already suggests six cycles as the baseline window for cycle-length stats" — only the six
    /// most recent completed lengths feed the mature-history prediction tier and the phase
    /// estimate's central-length calculation.
    public static let matureHistoryWindowCap = 6

    public static let confidenceColdStart = 0.0
    /// Flat — with only 1-2 points there is no reliable variance signal to modulate confidence by.
    public static let confidenceLowHistory = 0.3
    public static let confidenceModerateHistoryBase = 0.55
    public static let confidenceModerateHistoryFloor = 0.40
    public static let confidenceMatureHistoryBase = 0.80
    public static let confidenceMatureHistoryFloor = 0.65
    /// Cap on how much measured relative spread can pull a tier's confidence down from its base.
    /// Chosen together with the base/floor pairs above so that, for ANY spread, every
    /// lowHistory < every moderateHistory < every matureHistory confidence value — i.e. tier
    /// ordering never inverts, which is the invariant this file's tests check explicitly.
    public static let confidencePenaltyCap = 0.15

    /// Luteal-phase length is the far less variable half of the cycle across the population (the
    /// reason BBT is framed in the research doc as RETROSPECTIVE ovulation confirmation rather
    /// than a prospective predictor) — ovulation day is estimated as central cycle length minus
    /// this constant, per this slice's brief.
    public static let lutealPhaseLengthDays = 14
    /// Symmetric tolerance band (days) around the estimated ovulation day counted as `.ovulatory`.
    public static let ovulatoryToleranceDays = 2
    /// Conservative default bleed-duration assumption, used ONLY when the current cycle's own
    /// `CycleRecord.endAt` is nil (still `ongoing`). This function's FIXED cross-lane signature
    /// carries no `FlowLog` array, so the "use the current cycle's own FlowLog data if available"
    /// refinement this slice's brief describes cannot be implemented HERE — the closest available
    /// real signal is the current `CycleRecord`'s own `endAt` (used above whenever present), and
    /// this constant is the documented fallback only when even that is absent. Five days is a
    /// commonly-cited average menstrual bleed duration — a stated approximation, not a per-user
    /// measurement, and a future slice threading `FlowLog` history into this function would
    /// supersede it.
    public static let defaultBleedDurationDays = 5

    /// Internal-facing only (see the file header's STATED GAP note) — never rendered to a user.
    public static let suppressionReasonSuppressiveContraceptiveContext = "suppressive_contraceptive_context_active"
    /// See the file header's STATED GAP note: this pure engine has no device-identity input, so
    /// every row it returns carries this placeholder until the persistence layer stamps the real
    /// device id.
    public static let unstampedOriginDeviceId = "engine-unstamped"

    /// Methods that imply an ONGOING suppressed/altered natural-cycling state, per this slice's
    /// exact brief. `.iud` is DELIBERATELY excluded — this type doesn't distinguish hormonal from
    /// copper IUDs, and a copper IUD does not suppress ovulation at all, so treating any `.iud`
    /// context as suppressive would be a fabricated assumption this codebase's "never invent a
    /// value" posture forbids. `.emergencyContraception` is excluded too: it is a one-off event,
    /// not an ongoing suppressive state.
    private static let suppressiveMethodTypes: Set<ContraceptiveMethodType> = [
        .pill, .patch, .ring, .injection, .implant, .hormoneTherapy,
    ]

    // MARK: - Public API

    /// Forecasts the next period's start window. Tier is selected PURELY by completed-cycle count
    /// (0 -> coldStart, 1-2 -> lowHistory, 3-5 -> moderateHistory, 6+ -> matureHistory); see
    /// `completedCycleObservations` for exactly what counts as "completed". Never returns a
    /// non-nil predicted date at the coldStart tier, and never returns a predicted date at all
    /// when `contraceptiveContext` is an active, suppressive method (see
    /// `suppressiveMethodTypes`) — in that case `status == .paused`, `suppressionReason` is set,
    /// and all three predicted-date fields are nil, regardless of tier.
    public static func predictNextCycle(history: [CycleRecord], contraceptiveContext: ContraceptiveContextLog?,
                                        asOf: Date, algorithmVersion: String) -> CyclePrediction {
        let live = sortedLiveRecords(history)
        let observations = completedCycleObservations(live)
        let method = tier(forCompletedCount: observations.count)
        let freshId = ULID.newID(clock: FixedClock(asOf))

        if isSuppressive(contraceptiveContext) {
            return CyclePrediction(
                id: freshId, generatedAt: asOf,
                predictedNextStartLow: nil, predictedNextStartCenter: nil, predictedNextStartHigh: nil,
                confidence: 0, method: method, status: .paused,
                suppressionReason: suppressionReasonSuppressiveContraceptiveContext,
                algorithmVersion: algorithmVersion, inputCycleIds: [],
                updatedAt: asOf, originDeviceId: unstampedOriginDeviceId)
        }

        guard method != .coldStart, let anchor = live.last else {
            // coldStart (zero completed cycles): the "day-one state" — no predicted date at all,
            // zero confidence, still `.active` (nothing to pause; there's simply nothing to predict
            // yet).
            return CyclePrediction(
                id: freshId, generatedAt: asOf,
                predictedNextStartLow: nil, predictedNextStartCenter: nil, predictedNextStartHigh: nil,
                confidence: confidenceColdStart, method: .coldStart, status: .active, suppressionReason: nil,
                algorithmVersion: algorithmVersion, inputCycleIds: [],
                updatedAt: asOf, originDeviceId: unstampedOriginDeviceId)
        }

        let used: [CompletedCycleObservation] = method == .matureHistory
            ? Array(observations.suffix(matureHistoryWindowCap))
            : observations // lowHistory: 1-2 total; moderateHistory: 3-5 total — already the whole set.
        let lengths = used.map(\.length)

        // lowHistory uses a SIMPLE average ("Use simple average cycle length" per the research
        // doc); moderate/mature use a recency-weighted mean favoring recent cycles.
        let center = method == .lowHistory
            ? lengths.reduce(0, +) / Double(lengths.count)
            : recencyWeightedMean(lengths)
        let spread = meanAbsoluteDeviation(lengths, center: center)

        let halfWidth: Double
        switch method {
        case .lowHistory: halfWidth = lowHistoryHalfWidthDays
        case .moderateHistory: halfWidth = max(moderateHistoryFloorHalfWidthDays, spread * spreadWidthMultiplier)
        case .matureHistory: halfWidth = max(matureHistoryFloorHalfWidthDays, spread * spreadWidthMultiplier)
        case .coldStart: halfWidth = 0 // unreachable — guarded above.
        }

        let confidence: Double
        switch method {
        case .lowHistory:
            confidence = confidenceLowHistory
        case .moderateHistory:
            confidence = max(confidenceModerateHistoryFloor,
                             confidenceModerateHistoryBase - relativeSpreadPenalty(spread: spread, center: center))
        case .matureHistory:
            confidence = max(confidenceMatureHistoryFloor,
                             confidenceMatureHistoryBase - relativeSpreadPenalty(spread: spread, center: center))
        case .coldStart:
            confidence = confidenceColdStart // unreachable — guarded above.
        }

        let tz = anchor.provenance.measuredTimezone
        let centerDays = Int(center.rounded())
        let lowDays = Int((center - halfWidth).rounded())
        let highDays = Int((center + halfWidth).rounded())

        return CyclePrediction(
            id: freshId, generatedAt: asOf,
            predictedNextStartLow: DayAttribution.addingDays(lowDays, to: anchor.startAt, tz: tz),
            predictedNextStartCenter: DayAttribution.addingDays(centerDays, to: anchor.startAt, tz: tz),
            predictedNextStartHigh: DayAttribution.addingDays(highDays, to: anchor.startAt, tz: tz),
            confidence: confidence, method: method, status: .active, suppressionReason: nil,
            algorithmVersion: algorithmVersion, inputCycleIds: inputCycleIds(from: used),
            updatedAt: asOf, originDeviceId: unstampedOriginDeviceId)
    }

    /// Calendar-only phase estimate for the day `asOf` falls on — CYCLE-06's input. Returns
    /// `.unknown` with `evidenceBasis == .suppressedDueToContext` when `contraceptiveContext` is
    /// active and suppressive, REGARDLESS of history depth (a suppressed cycle has no reliable
    /// calendar phase, even with years of prior history); returns `.unknown` with
    /// `evidenceBasis == .insufficientHistory` below `phaseMinimumCompletedCycles` completed
    /// cycles. Both `.unknown` paths carry confidence pinned to zero — never a guessed phase from
    /// too little evidence. This slice implements TIERS 1-4 (calendar-only) only; rich-signal
    /// refinement (BBT/ovulation tests) is CYCLE-10, out of scope.
    public static func estimatePhase(history: [CycleRecord], contraceptiveContext: ContraceptiveContextLog?,
                                     asOf: Date, algorithmVersion: String) -> CyclePhaseEstimate {
        let live = sortedLiveRecords(history)
        let observations = completedCycleObservations(live)
        let freshId = ULID.newID(clock: FixedClock(asOf))

        func unknown(basis: CyclePhaseEvidenceBasis) -> CyclePhaseEstimate {
            CyclePhaseEstimate(id: freshId, dateRangeStart: asOf, dateRangeEnd: asOf, phase: .unknown,
                               confidence: 0, evidenceBasis: basis, algorithmVersion: algorithmVersion,
                               computedAt: asOf, updatedAt: asOf, originDeviceId: unstampedOriginDeviceId)
        }

        // Suppression is checked FIRST and wins regardless of history depth, per this slice's brief.
        if isSuppressive(contraceptiveContext) { return unknown(basis: .suppressedDueToContext) }
        guard observations.count >= phaseMinimumCompletedCycles, let anchor = live.last else {
            return unknown(basis: .insufficientHistory)
        }

        let windowed = Array(observations.suffix(matureHistoryWindowCap))
        let centralLength = recencyWeightedMean(windowed.map(\.length))
        let tz = anchor.provenance.measuredTimezone
        let cycleStart = anchor.startAt

        let bleedEnd = anchor.endAt ?? DayAttribution.addingDays(defaultBleedDurationDays, to: cycleStart, tz: tz)
        let ovulationDayOffset = Int(centralLength.rounded()) - lutealPhaseLengthDays
        let ovulationDay = DayAttribution.addingDays(ovulationDayOffset, to: cycleStart, tz: tz)
        let ovulatoryStart = DayAttribution.addingDays(-ovulatoryToleranceDays, to: ovulationDay, tz: tz)
        let ovulatoryEnd = DayAttribution.addingDays(ovulatoryToleranceDays, to: ovulationDay, tz: tz)
        let nextExpectedStart = DayAttribution.addingDays(Int(centralLength.rounded()), to: cycleStart, tz: tz)

        let confidence = phaseConfidence(completedCount: observations.count)
        let key: (Date) -> String = { DayAttribution.localDayKey($0, tz: tz) }
        let asOfKey = key(asOf)

        func estimate(_ phase: CyclePhase, start: Date, end: Date) -> CyclePhaseEstimate {
            CyclePhaseEstimate(id: freshId, dateRangeStart: start, dateRangeEnd: end, phase: phase,
                              confidence: confidence, evidenceBasis: .calendarOnly,
                              algorithmVersion: algorithmVersion, computedAt: asOf, updatedAt: asOf,
                              originDeviceId: unstampedOriginDeviceId)
        }

        // Priority order: actual/assumed bleeding first (the most concrete signal), then the
        // ovulatory tolerance band, then follicular (before it) or luteal (after it, through the
        // next expected start).
        if asOfKey <= key(bleedEnd) {
            return estimate(.menstrual, start: cycleStart, end: bleedEnd)
        }
        if asOfKey >= key(ovulatoryStart) && asOfKey <= key(ovulatoryEnd) {
            return estimate(.ovulatory, start: ovulatoryStart, end: ovulatoryEnd)
        }
        if asOfKey < key(ovulatoryStart) {
            let follicularStart = DayAttribution.addingDays(1, to: bleedEnd, tz: tz)
            let follicularEnd = DayAttribution.addingDays(-1, to: ovulatoryStart, tz: tz)
            return estimate(.follicular, start: follicularStart, end: follicularEnd)
        }
        let lutealStart = DayAttribution.addingDays(1, to: ovulatoryEnd, tz: tz)
        let lutealEnd = max(lutealStart, DayAttribution.addingDays(-1, to: nextExpectedStart, tz: tz))
        return estimate(.luteal, start: lutealStart, end: lutealEnd)
    }

    // MARK: - Suppression

    /// True when `context` is currently active AND its method implies suppressed/altered natural
    /// cycling. Uses `ContraceptiveContextLog.isActive` exactly as the shared contract defines it
    /// (endAt == nil && deletedAt == nil) rather than re-deriving activeness from `asOf`.
    ///
    /// INTERNAL, not `private` (CYCLE-12 audit note): `CycleFertileWindowEngine` reuses this EXACT
    /// function as its own contraceptive-context suppression gate, per that slice's own brief
    /// ("reuse the exact existing suppression mechanism, do not build a second one") — a fertile-
    /// window estimate must suppress under precisely the same conditions a phase estimate already
    /// does, and duplicating `suppressiveMethodTypes` into a second file would risk the two silently
    /// drifting (e.g. if `.iud` handling ever changes). This is the one exception to this codebase's
    /// otherwise-standard "pure math re-derived per file" convention (see `CycleAnomalyEngine`'s own
    /// header for that convention) — a POLICY gate, unlike shared math, has exactly one honest
    /// definition and must never have two.
    static func isSuppressive(_ context: ContraceptiveContextLog?) -> Bool {
        guard let context, context.isActive else { return false }
        return suppressiveMethodTypes.contains(context.methodType)
    }

    // MARK: - Tier selection

    private static func tier(forCompletedCount count: Int) -> CyclePredictionMethod {
        switch count {
        case 0: return .coldStart
        case 1...2: return .lowHistory
        case 3...5: return .moderateHistory
        default: return .matureHistory
        }
    }

    /// Confidence for a successfully-computed calendar-only phase estimate: rises with completed-
    /// cycle count (capped at `matureHistoryWindowCap` cycles' worth) but stays well below 1.0 —
    /// calendar-only evidence is the WEAKEST evidence class per the research doc's ovulation-
    /// estimation discussion (§5); BBT/ovulation-test corroboration, which would justify higher
    /// confidence, is out of this slice's scope (CYCLE-10).
    private static func phaseConfidence(completedCount: Int) -> Double {
        let capped = min(completedCount, matureHistoryWindowCap)
        return 0.40 + 0.05 * Double(capped - phaseMinimumCompletedCycles)
    }

    /// How much measured relative spread (spread / center) pulls a tier's confidence down from its
    /// base, capped at `confidencePenaltyCap`.
    private static func relativeSpreadPenalty(spread: Double, center: Double) -> Double {
        guard center > 0 else { return confidencePenaltyCap }
        return min(confidencePenaltyCap, (spread / center) * 0.3)
    }

    // MARK: - Completed-cycle observations

    /// One observed cycle length: the day-gap between two consecutive LIVE `CycleRecord` starts,
    /// plus the ids of the two records that produced it (so a prediction's `inputCycleIds` can
    /// name exactly what fed it, never just "everything the caller happened to pass in").
    private struct CompletedCycleObservation {
        let length: Double
        let earlierRecordId: String
        let laterRecordId: String
    }

    private static func sortedLiveRecords(_ history: [CycleRecord]) -> [CycleRecord] {
        CycleRecordLedger.liveRecords(history).sorted { $0.startAt < $1.startAt }
    }

    /// A cycle's length is only knowable once the START of the FOLLOWING cycle is known — so the
    /// most recent (possibly still-`ongoing`) record never contributes a length observation on its
    /// own, per this slice's brief; it only ever supplies the "current cycle start" the calendar
    /// math above anchors to. A non-positive day-gap (duplicate/out-of-order data) is dropped
    /// rather than treated as a zero/negative-length cycle — that would be a data anomaly, not a
    /// real observation.
    private static func completedCycleObservations(_ sortedLive: [CycleRecord]) -> [CompletedCycleObservation] {
        guard sortedLive.count >= 2 else { return [] }
        var result: [CompletedCycleObservation] = []
        for i in 0..<(sortedLive.count - 1) {
            let earlier = sortedLive[i]
            let later = sortedLive[i + 1]
            guard let days = daysBetween(earlier.startAt, later.startAt, tz: earlier.provenance.measuredTimezone),
                  days > 0 else { continue }
            result.append(CompletedCycleObservation(length: Double(days), earlierRecordId: earlier.id,
                                                     laterRecordId: later.id))
        }
        return result
    }

    /// The exact `CycleRecord` ids that fed a set of observations, in first-seen order, deduped —
    /// the honest input manifest for `CyclePrediction.inputCycleIds`: only what actually fed THIS
    /// forecast's window, not every record the caller happened to pass in (e.g. a matureHistory
    /// forecast windowed to the last six lengths cites only the ~seven records those lengths came
    /// from, not a user's entire multi-year history).
    private static func inputCycleIds(from observations: [CompletedCycleObservation]) -> [String] {
        var ids: [String] = []
        for o in observations {
            if !ids.contains(o.earlierRecordId) { ids.append(o.earlierRecordId) }
            if !ids.contains(o.laterRecordId) { ids.append(o.laterRecordId) }
        }
        return ids
    }

    // MARK: - Pure math helpers

    /// Recency-weighted mean: weights increase linearly toward the most recent value (oldest = 1
    /// ... most recent = count), per `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §5's "rolling
    /// weighted estimate... with recency weighting".
    private static func recencyWeightedMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var weightedSum = 0.0
        var weightTotal = 0.0
        for (index, value) in values.enumerated() {
            let weight = Double(index + 1)
            weightedSum += value * weight
            weightTotal += weight
        }
        return weightedSum / weightTotal
    }

    private static func meanAbsoluteDeviation(_ values: [Double], center: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0) { $0 + abs($1 - center) } / Double(values.count)
    }

    // MARK: - Day arithmetic

    /// Whole-day gap from `earlier` to `later`, computed via each date's own local day key (in
    /// `tz`) rather than raw `timeIntervalSince/86_400`, so it stays correct across DST — the same
    /// posture `DayAttribution`/`BaselineEngine` take everywhere else in this codebase. `nil` if
    /// either date's day key fails to parse (defensive; not expected in practice).
    private static func daysBetween(_ earlier: Date, _ later: Date, tz: String) -> Int? {
        let earlierKey = DayAttribution.localDayKey(earlier, tz: tz)
        let laterKey = DayAttribution.localDayKey(later, tz: tz)
        // Day keys are pure "YYYY-MM-DD" calendar dates at this point, so re-parsing them in a
        // fixed reference zone (UTC) for the day-count arithmetic is safe regardless of `tz`'s own
        // DST rules — there is no DST in UTC to trip over.
        guard let earlierDate = DayAttribution.date(fromDayKey: earlierKey, tz: "UTC"),
              let laterDate = DayAttribution.date(fromDayKey: laterKey, tz: "UTC") else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: earlierDate, to: laterDate).day
    }
}
