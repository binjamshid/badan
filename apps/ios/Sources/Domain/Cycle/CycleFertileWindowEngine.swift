import Foundation

// MARK: - CycleFertileWindowEngine (EPIC-39 CYCLE-12, fertile-window estimation, A17/ADR-0010/D-24)
//
// Grounded in `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §5 ("Fertile-window estimation" — the
// calendar-only / signal-assisted / suppressed three-level model) and
// `docs/legal/reproductive-threat-model.md` §5's "never a single-date confidence claim" mitigation,
// applied here with EQUAL force (that section's own words: fertile-window claims are "arguably more
// acutely" sensitive than a period-date range, since they bear more directly on conception timing).
//
// A SIBLING to `CyclePredictionEngine`/`CycleAnomalyEngine`, not an extension of either: pure,
// storage-free, `enum`-namespaced, no clock reads (`asOf` always injected), no I/O. Consumes the
// same `[CycleRecord]`/`ContraceptiveContextLog?` inputs `CyclePredictionEngine.estimatePhase`
// does, but returns its own distinct, explicitly-labeled output type
// (`CycleFertileWindowEstimate`) — it never reuses or mutates `CyclePrediction`/`CyclePhaseEstimate`,
// and `CyclePredictionEngine.estimatePhase`'s own internal ovulation-day math stays exactly what its
// file header already says it is: an input to PHASE estimation only, never a fertile-window claim.
// This file re-derives its own ovulation-day estimate independently, from the same public tuning
// constants (`CyclePredictionEngine.lutealPhaseLengthDays`, `.matureHistoryWindowCap`,
// `.phaseMinimumCompletedCycles` — the biological/statistical assumptions genuinely are shared, so
// reusing those PUBLIC constants directly is more honest than silently forking a second copy of the
// same number), while re-deriving its own PURE MATH (completed-cycle observations, recency-weighted
// mean) locally rather than reaching into `CyclePredictionEngine`'s private internals — the same
// per-file-math convention `CycleAnomalyEngine`'s own header documents and follows.
//
// ONE EXCEPTION to that "re-derive per file" convention, and it is deliberate: contraceptive-context
// SUPPRESSION is not shared math, it is a shared POLICY GATE with exactly one honest definition —
// this file calls `CyclePredictionEngine.isSuppressive(_:)` directly (that function's visibility was
// widened from `private` to internal specifically for this reuse; see its own doc comment) rather
// than forking a second `suppressiveMethodTypes` set that could silently drift from the original
// (e.g. if `.iud` handling ever changes). CYCLE-07's suppression mechanism is reused, never rebuilt.
//
// THE SEQUENCING GAP THIS FILE RESOLVES EXPLICITLY, NOT SILENTLY: the research doc's own
// "signal-assisted mode" (§5) is defined as narrowing the estimate only when a positive ovulation
// test, a BBT shift, or a cervical-mucus pattern exists — and EVERY ONE of those three signal
// sources lives behind CYCLE-10 (BBT/ovulation-test/cervical-mucus logging), which stays P1.5/
// deferred and explicitly out of scope for this file (see `CycleModels.swift`'s own header). There
// is therefore NO real signal input this codebase can honestly consult today. Rather than either (a)
// silently dropping signal-assisted as a selectable mode, or (b) fabricating a narrower/falsely-
// confident window under a "signal-assisted" label with nothing behind it, this file takes the third
// documented option: `FertileWindowMode.signalAssisted` is a REAL, selectable user-declared mode
// (`estimateFertileWindow` accepts it and computes a normal, active estimate for it), but the actual
// computation for BOTH `.calendar` and `.signalAssisted` runs through the exact same calendar-only
// code path below, and `CycleFertileWindowEstimate.evidenceBasis` is ALWAYS `.calendarOnly` while
// that remains true — it is never set to a stronger basis with nothing behind it. `mode` on the
// returned row still records what the user actually selected (for UI/audit honesty: a caller can
// tell a user who picked signal-assisted mode that no additional signals are logged yet, without the
// ENGINE ever lying about what evidence actually produced the number). The day CYCLE-10 lands and a
// real signal array becomes available as an input here, THIS is the file that gains a genuine
// evidence-basis upgrade path — not a rewrite, an addition.
public enum CycleFertileWindowEngine {

    // MARK: - Tuning constants

    /// Below this many completed cycles, no fertile-window estimate is attempted at all — reuses
    /// `CyclePredictionEngine.phaseMinimumCompletedCycles` directly (not a re-derived copy): a
    /// fertile-window estimate depends on the identical central-cycle-length calculation phase
    /// estimation does, so the same evidence floor applies for the identical reason.
    public static var minimumCompletedCyclesForEstimate: Int { CyclePredictionEngine.phaseMinimumCompletedCycles }

    /// Rolling window cap on how many recent completed cycle lengths feed the central-length
    /// calculation — reuses `CyclePredictionEngine.matureHistoryWindowCap` directly for the same
    /// "six cycles as the baseline window" reason that constant's own doc gives.
    public static var recentCycleWindowCap: Int { CyclePredictionEngine.matureHistoryWindowCap }

    /// Luteal-phase length assumption — reuses `CyclePredictionEngine.lutealPhaseLengthDays`
    /// directly. This is a biological assumption, not a per-engine tuning knob, so both files must
    /// share the identical number rather than risk two independently-tuned copies drifting apart.
    public static var lutealPhaseLengthDays: Int { CyclePredictionEngine.lutealPhaseLengthDays }

    /// Days BEFORE the estimated ovulation day counted as the start of the fertile window — a
    /// commonly-cited approximation of sperm viability, not a per-user measurement (the same
    /// "documented approximation, not a measurement" posture
    /// `CyclePredictionEngine.defaultBleedDurationDays`'s own doc comment takes). Deliberately its
    /// own constant, separate from `CyclePredictionEngine.ovulatoryToleranceDays` (a narrower,
    /// different-purpose band around the phase estimate's own "ovulatory" phase label) — the
    /// research doc frames a fertile-window estimate as a deliberately BROADER "higher-likelihood
    /// fertility window," not the same tolerance band reused under a new name.
    public static let preOvulationFertileDays = 5
    /// Days AFTER the estimated ovulation day still counted as fertile — a commonly-cited
    /// approximation of egg viability, same documented-approximation posture as the constant above.
    public static let postOvulationFertileDays = 1

    /// Confidence tuning. Deliberately, structurally LOWER than `CyclePredictionEngine`'s own
    /// phase-estimate confidence (`phaseConfidence`, base 0.40 rising to 0.55) for the identical
    /// completed-cycle count — per the research doc's own "Ovulation-day estimation" section:
    /// calendar-only ovulation/fertile-window estimation is named explicitly as "the weakest
    /// evidence class," strictly weaker than the calendar-only PHASE estimate this confidence
    /// deliberately stays under, not just a different number chosen independently.
    /// `testFertileWindowConfidenceNeverReachesOrExceedsPhaseConfidenceForTheSameCompletedCount`
    /// is the standing regression test for this ordering.
    public static let confidenceBase = 0.20
    public static let confidencePerExtraCycle = 0.03

    /// Internal-facing only (mirrors `CyclePredictionEngine.suppressionReason*` constants exactly)
    /// — never rendered to a user; a UI lane writes its own calm copy for each case instead.
    public static let suppressionReasonUserDeclaredSuppressed = "user_declared_suppressed_mode"
    public static let suppressionReasonSuppressiveContraceptiveContext = "suppressive_contraceptive_context_active"
    /// See `CyclePredictionEngine.unstampedOriginDeviceId`'s own doc for why this placeholder
    /// exists and who is responsible for overwriting it (the persistence/composition layer, not
    /// this pure engine).
    public static let unstampedOriginDeviceId = "engine-unstamped"

    // MARK: - Public API

    /// Estimates the fertile window relevant to the CURRENT (most-recently-started live) cycle —
    /// the same anchor `CyclePredictionEngine.estimatePhase` uses for its own "today's phase"
    /// estimate, applied here to the analogous "this cycle's fertile window" question.
    ///
    /// Three gates, checked in this exact order (the user-declared `mode` is the CEILING on what
    /// could ever be shown; contraceptive-context suppression is an independent FLOOR that can
    /// still force suppression even when the user opted into `.calendar`/`.signalAssisted`; the
    /// history-depth gate is the last, purely data-availability check):
    ///   1. `mode == .suppressed` -> `status: .suppressed` immediately, regardless of history or
    ///      context. This is the CYCLE-12 brief's own "real 'no estimate' state, not just a
    ///      lower-confidence version" requirement, and the safe default (a caller with a fresh
    ///      `CustomizationProfile` — `fertileWindowMode` defaults to `.suppressed` — gets this path
    ///      every time until the user explicitly changes it).
    ///   2. `CyclePredictionEngine.isSuppressive(contraceptiveContext)` -> `status: .suppressed`,
    ///      regardless of `mode` or history depth. Reuses CYCLE-07's exact existing mechanism (see
    ///      this file's own header) rather than building a second one.
    ///   3. Fewer than `minimumCompletedCyclesForEstimate` completed cycles -> `status: .active`
    ///      but every window field nil and confidence 0 (mirrors
    ///      `CyclePredictionEngine.predictNextCycle`'s own `coldStart` shape: "not enough data yet"
    ///      is a real, active-but-empty state, distinct from an explicit suppression).
    ///
    /// Otherwise returns a real `windowStart`/`windowEnd` pair (NEVER a bare date — the two fields
    /// are populated together or not at all, matching this codebase's structural "no single-date
    /// prediction" rule applied to a window instead of a point) alongside a confidence, the
    /// resolved `evidenceBasis` (always `.calendarOnly` today — see this file's header for why),
    /// and `inputCycleIds` (the same "why this estimate?" audit-manifest contract
    /// `CyclePrediction.inputCycleIds` already establishes).
    public static func estimateFertileWindow(
        history: [CycleRecord],
        contraceptiveContext: ContraceptiveContextLog?,
        mode: FertileWindowMode,
        asOf: Date,
        algorithmVersion: String
    ) -> CycleFertileWindowEstimate {
        let freshId = ULID.newID(clock: FixedClock(asOf))

        func suppressed(reason: String, basis: FertileWindowEvidenceBasis) -> CycleFertileWindowEstimate {
            CycleFertileWindowEstimate(
                id: freshId, generatedAt: asOf, windowStart: nil, windowEnd: nil, confidence: 0,
                mode: mode, evidenceBasis: basis, status: .suppressed, suppressionReason: reason,
                algorithmVersion: algorithmVersion, inputCycleIds: [], updatedAt: asOf,
                originDeviceId: unstampedOriginDeviceId)
        }

        // Gate 1 — the user-declared ceiling. Checked BEFORE anything else touches history or
        // context, per this slice's brief ("never inferred passively, never on by default").
        if mode == .suppressed {
            return suppressed(reason: suppressionReasonUserDeclaredSuppressed, basis: .suppressedByMode)
        }

        // Gate 2 — the contraceptive-context floor. Reuses CYCLE-07's exact mechanism; wins
        // regardless of `mode` (a user who opted into `.calendar`/`.signalAssisted` still sees this
        // when it applies).
        if CyclePredictionEngine.isSuppressive(contraceptiveContext) {
            return suppressed(reason: suppressionReasonSuppressiveContraceptiveContext, basis: .suppressedDueToContext)
        }

        // Gate 3 — history depth. A real, active-but-empty state, not a suppression.
        let live = CycleRecordLedger.liveRecords(history).sorted { $0.startAt < $1.startAt }
        let observations = completedCycleObservations(live)
        guard observations.count >= minimumCompletedCyclesForEstimate, let anchor = live.last else {
            return CycleFertileWindowEstimate(
                id: freshId, generatedAt: asOf, windowStart: nil, windowEnd: nil, confidence: 0,
                mode: mode, evidenceBasis: .insufficientHistory, status: .active, suppressionReason: nil,
                algorithmVersion: algorithmVersion, inputCycleIds: [], updatedAt: asOf,
                originDeviceId: unstampedOriginDeviceId)
        }

        let windowed = Array(observations.suffix(recentCycleWindowCap))
        let centralLength = recencyWeightedMean(windowed.map(\.length))
        let tz = anchor.provenance.measuredTimezone

        let ovulationDayOffset = Int(centralLength.rounded()) - lutealPhaseLengthDays
        let ovulationDay = DayAttribution.addingDays(ovulationDayOffset, to: anchor.startAt, tz: tz)
        let windowStart = DayAttribution.addingDays(-preOvulationFertileDays, to: ovulationDay, tz: tz)
        let windowEnd = DayAttribution.addingDays(postOvulationFertileDays, to: ovulationDay, tz: tz)

        return CycleFertileWindowEstimate(
            id: freshId, generatedAt: asOf, windowStart: windowStart, windowEnd: windowEnd,
            confidence: confidence(completedCount: observations.count), mode: mode,
            // Always `.calendarOnly` today, for BOTH `.calendar` and `.signalAssisted` mode — see
            // this file's header. `mode` above still records the user's real selection.
            evidenceBasis: .calendarOnly, status: .active, suppressionReason: nil,
            algorithmVersion: algorithmVersion, inputCycleIds: inputCycleIds(from: windowed),
            updatedAt: asOf, originDeviceId: unstampedOriginDeviceId)
    }

    // MARK: - Confidence

    private static func confidence(completedCount: Int) -> Double {
        let capped = min(completedCount, recentCycleWindowCap)
        return confidenceBase + confidencePerExtraCycle * Double(capped - minimumCompletedCyclesForEstimate)
    }

    // MARK: - Completed-cycle observations (re-derived locally, not shared with
    // `CyclePredictionEngine`'s private internals — see this file's header for why)

    private struct CompletedCycleObservation {
        let length: Double
        let earlierRecordId: String
        let laterRecordId: String
    }

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

    private static func inputCycleIds(from observations: [CompletedCycleObservation]) -> [String] {
        var ids: [String] = []
        for o in observations {
            if !ids.contains(o.earlierRecordId) { ids.append(o.earlierRecordId) }
            if !ids.contains(o.laterRecordId) { ids.append(o.laterRecordId) }
        }
        return ids
    }

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

    private static func daysBetween(_ earlier: Date, _ later: Date, tz: String) -> Int? {
        let earlierKey = DayAttribution.localDayKey(earlier, tz: tz)
        let laterKey = DayAttribution.localDayKey(later, tz: tz)
        guard let earlierDate = DayAttribution.date(fromDayKey: earlierKey, tz: "UTC"),
              let laterDate = DayAttribution.date(fromDayKey: laterKey, tz: "UTC") else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: earlierDate, to: laterDate).day
    }
}

// MARK: - FertileWindowMode (user-declared, three-way — CustomizationProfile.fertileWindowMode)

/// The three modes `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §5 names for fertile-window estimation.
/// `.suppressed` deliberately covers BOTH "the user hasn't chosen anything yet" (the required
/// default) and "the user explicitly chose to hide fertile-window estimates" — both cases behave
/// identically (no estimate ever computed), so one case correctly represents both, mirroring this
/// codebase's other user-declared-mode enums (`AppTheme`, `DepthPolicy`) in NOT inventing a
/// separate "unset" state where the behavior would be indistinguishable anyway.
public enum FertileWindowMode: String, Codable, Hashable, Sendable, CaseIterable {
    case suppressed, calendar, signalAssisted

    public var displayName: LocalizedString {
        switch self {
        case .suppressed: return LocalizedString(en: "Off", ar: "إيقاف")
        case .calendar: return LocalizedString(en: "Calendar-based", ar: "بالاعتماد على التقويم")
        case .signalAssisted: return LocalizedString(en: "Signal-assisted", ar: "بمساعدة الإشارات")
        }
    }
}

// MARK: - CycleFertileWindowEstimate (append-only derived, I2 — NEVER a single-date claim)

/// What actually produced a `CycleFertileWindowEstimate`'s window (if any) — distinct from `mode`
/// above, which records what the user SELECTED. `evidenceBasis` never claims stronger evidence than
/// what was actually available; see `CycleFertileWindowEngine`'s own header for why `.calendarOnly`
/// is the only basis this build's engine can ever produce for an active estimate, even under
/// `.signalAssisted` mode.
public enum FertileWindowEvidenceBasis: String, Codable, Hashable, Sendable {
    case calendarOnly, insufficientHistory, suppressedByMode, suppressedDueToContext
}

/// Whether a `CycleFertileWindowEstimate` carries a real window, or is a real "no estimate" state.
/// `.suppressed` is NOT a low-confidence version of `.active` — per this slice's brief, suppression
/// is a distinct state with no window fields populated at all (mirrors
/// `CyclePredictionStatus.paused`'s exact shape, renamed here to match this feature's own
/// "suppressed mode" vocabulary rather than borrowing "paused," a word this feature's mode picker
/// does not use).
public enum FertileWindowStatus: String, Codable, Hashable, Sendable { case active, suppressed }

/// An append-only estimate of the current cycle's fertile window. APPEND-ONLY (I2): a recompute
/// always inserts a NEW row with a fresh `generatedAt`, mirroring `CyclePrediction`/
/// `CyclePhaseEstimate`'s exact shape reasoning — this row is COMPUTED, never measured, so no
/// embedded `Provenance`.
///
/// **No single-date claim, structurally, not just by convention.** `windowStart`/`windowEnd` are
/// BOTH optional and nil together exactly when there isn't a real estimate to show (suppressed, or
/// not enough history yet) — never backfilled with a guessed window, and never populated as a lone
/// date without its pair. This is the identical structural guarantee `CyclePrediction`'s own header
/// documents, applied to a window instead of a point-with-a-range.
///
/// `suppressionReason` is set ONLY when `status == .suppressed` and is itself internal, non-
/// user-facing placeholder text — never rendered directly, exactly like
/// `CyclePrediction.suppressionReason`'s own doc requires; a UI lane writes its own calm copy keyed
/// off `evidenceBasis`/`status` instead.
///
/// `inputCycleIds` is the same "why does it say that" audit manifest `CyclePrediction.inputCycleIds`
/// already establishes — exactly which `CycleRecord`s fed this specific estimate.
public struct CycleFertileWindowEstimate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var generatedAt: Date
    public var windowStart: Date?
    public var windowEnd: Date?
    /// 0...1. Always 0 when `status == .suppressed`.
    public var confidence: Double
    /// What the user had selected when this row was generated — an audit/UI field, distinct from
    /// `evidenceBasis` (what actually computed the number). See `CycleFertileWindowEngine`'s header.
    public var mode: FertileWindowMode
    public var evidenceBasis: FertileWindowEvidenceBasis
    public var status: FertileWindowStatus
    public var suppressionReason: String?
    public var algorithmVersion: String
    public var inputCycleIds: [String]
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, generatedAt: Date, windowStart: Date? = nil, windowEnd: Date? = nil,
                confidence: Double, mode: FertileWindowMode, evidenceBasis: FertileWindowEvidenceBasis,
                status: FertileWindowStatus = .active, suppressionReason: String? = nil,
                algorithmVersion: String, inputCycleIds: [String] = [], updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.generatedAt = generatedAt; self.windowStart = windowStart
        self.windowEnd = windowEnd; self.confidence = confidence; self.mode = mode
        self.evidenceBasis = evidenceBasis; self.status = status; self.suppressionReason = suppressionReason
        self.algorithmVersion = algorithmVersion; self.inputCycleIds = inputCycleIds
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}
