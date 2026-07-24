import Foundation

// MARK: - Cycle intelligence: canonical entity set (EPIC-39 CYCLE-01, Phase 3F slice 1)
//
// DOMAIN CORE ONLY. No SwiftUI, nothing under `Features/` or `App/` — those are a later slice.
// Grounded in `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` and `docs/legal/reproductive-threat-model.md`
// (read both before touching this file), which is why this file carries more defensive doc-comment
// weight than most: per the threat model's own §1, reproductive-cycle data is the single
// highest-sensitivity family BADAN handles — the one that can be used as evidence in a legal
// proceeding, and the one most likely to be weaponized by an abusive partner specifically because
// it reveals a missed period or contraceptive use. Three invariants are load-bearing across every
// type below, not stylistic preferences:
//
//   * I7 (sensitive namespace). Every table backing a type here lives ONLY in
//     `badan_sensitive.db` (sensitive migration 6 in `Migrations.swift`) — never `badan.db`. A
//     cycle row landing in the main database would silently downgrade
//     `Database.purgeSensitiveNamespace()` from a literal file deletion to a best-effort sweep for
//     exactly the data family the threat model names as needing that guarantee hardest.
//   * No single-date predictions, ever. `CyclePrediction` has NO field that could hold a bare
//     "due on X" date — only a low/center/high range, a named `method`, and a `confidence`. This is
//     both this codebase's standing false-precision rule (no bare dates presented as fact) and,
//     per the threat model §5, a safety property: a falsely-confident date is a worse harm surface
//     than an honest range, including for whoever might glance at the screen over the user's
//     shoulder. This rule extends to every doc comment and future test/UI copy describing this
//     data — never write "due on X" anywhere, including as illustrative prose.
//   * No diagnostic/clinical/named-condition language anywhere in this file. `CycleAnomalyEvent`
//     stores a `messageKey` — a lookup key into a bilingual message-template table a separate lane
//     owns — never rendered text. `severity` is a surfacing PRIORITY only, never a clinical-
//     importance claim (research doc §10). Nothing here names or implies "abnormal", "irregular" as
//     a verdict, or any named condition.
//
// OUT OF SCOPE for this slice — do not extend this file toward any of these; they are later,
// separately-gated slices per the plan's own CYCLE-01…14 backlog:
//   * Fertile-window/ovulation estimation was gated on founder decision A17; A17 is now approved
//     (ADR-0010/D-24) and CYCLE-12 implements it in its own sibling files
//     (`CycleFertileWindowEngine.swift` for the domain model/engine,
//     `Storage/Repositories/CycleFertileWindowEstimateRepository.swift` for persistence) rather than
//     extending this one — this file's own entity set is unchanged by that build.
//   * BBT / ovulation-test / cervical-mucus logging (CYCLE-10+, P1.5+) — still fully out of scope;
//     CYCLE-12's `signalAssisted` mode has no real signal input from any of these yet and does not
//     invent one (see `CycleFertileWindowEngine.swift`'s own header).
//   * Sexual-activity logging (CYCLE-13, founder/legal-gated, off-by-default even once built).
//   * Sharing of any kind (CYCLE-14, standing do-not-build).
//   * Symptom overlay (CYCLE-09, P1.5).
// If a field here starts drifting toward any of the above, stop — that is a different,
// separately-approved slice, not an extension of this one.

// MARK: - CycleRecord (append-first revision chain — same pattern as LabResult/StrengthSet)

/// How much a logged flow moment was, as the user actually described it. This is the CLOSED
/// dictionary a quick-log UI (a later slice) offers as tap targets — it is deliberately NOT the
/// storage shape of `FlowLog.originalLabel` below, which also accepts free text, so an intensity
/// word the dictionary doesn't cover is never blocked (same "dictionary key or free text" posture
/// `LabResult`/`JournalEntry` already use elsewhere in this codebase).
public enum CycleFlowIntensity: String, Codable, Hashable, Sendable, CaseIterable {
    case spotting, light, medium, heavy
}

/// One logged period: a start, an optional end, and an explicit `ongoing` flag rather than
/// inferring "still happening" from `endAt == nil` alone — a period entered after the fact with a
/// known end uses `endAt`; a period still in progress leaves `endAt` nil AND sets `ongoing = true`,
/// so a row can never be ambiguously "ended, we just don't know when" versus "still happening"
/// (the read side must never guess one for the other).
///
/// `originalId`/`supersedes`/`revision` are the same append-first revision chain `LabResult`/
/// `StrengthSet` already establish elsewhere in this codebase (I2-flavored): a correction (the
/// user mis-entered a start date) APPENDS a new row and tombstones the old one via
/// `CycleRecordRepository.deleteChain`/insert of a new revision — it never UPDATEs a logged
/// period. Carries a full embedded `Provenance` (I1): a manually-asserted period is still a fact
/// with an origin, and `ingestionPath == .manual` is what this slice's ingestion path is expected
/// to be (no platform HealthKit/Health Connect cycle read exists yet).
public struct CycleRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var startAt: Date
    /// `nil` while the period is ongoing — see the type doc above for why this is never used
    /// alone to infer "still happening" without also checking `ongoing`.
    public var endAt: Date?
    public var ongoing: Bool
    public var note: String?
    /// Stable identity across every revision of this logical record. `originalId == id` for a
    /// first-time (un-revised) record.
    public var originalId: String
    /// The id of the row this one supersedes; nil for an original.
    public var supersedes: String?
    /// 1-based counter (1 = original).
    public var revision: Int
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var isOriginal: Bool { supersedes == nil }
    public var isRevised: Bool { revision > 1 }

    public init(id: String, startAt: Date, endAt: Date? = nil, ongoing: Bool, note: String? = nil,
                originalId: String, supersedes: String? = nil, revision: Int = 1, provenance: Provenance,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.startAt = startAt; self.endAt = endAt; self.ongoing = ongoing
        self.note = note; self.originalId = originalId; self.supersedes = supersedes
        self.revision = revision; self.provenance = provenance; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - FlowLog

/// A single flow-intensity moment logged against a period (`CycleRecord`). `originalLabel` is kept
/// exactly as entered/tapped ("light"/"medium"/custom free text) — notebook-style source-wording
/// preservation, the same posture `LabResult.rawValueText`/`JournalEntry.customLabel` take —
/// because a future revision to `CycleFlowIntensity`'s dictionary must never rewrite what a user
/// actually said. `normalizedIntensity` is a SEPARATE, additional 0...1 scale mapped from
/// `originalLabel` at write time, purely so anomaly/trend math (flow-deviation detection) has a
/// consistent numeric axis to compare across both dictionary and custom-labeled entries — it is
/// never a replacement for, or back-derivation into, `originalLabel`.
///
/// Carries a full embedded `Provenance` (I1) for the same reason `JournalEntry` does: a manually
/// logged flow moment is still a fact with an origin. No revision chain (unlike `CycleRecord`) —
/// a flow-intensity correction is expected to be a plain tombstone-and-relog, not a chain, since
/// there is no downstream "which revision was this" audit need for a single flow tap the way there
/// is for a period's own start/end dates.
public struct FlowLog: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var cycleId: String
    public var occurredAt: Date
    /// As entered: "light"/"medium"/custom text. Never rewritten to match a dictionary value.
    public var originalLabel: String
    /// Internal 0...1 scale mapped from `originalLabel` — additive structure, never a substitute
    /// for the source wording above.
    public var normalizedIntensity: Double
    public var note: String?
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, cycleId: String, occurredAt: Date, originalLabel: String,
                normalizedIntensity: Double, note: String? = nil, provenance: Provenance,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.cycleId = cycleId; self.occurredAt = occurredAt
        self.originalLabel = originalLabel; self.normalizedIntensity = normalizedIntensity
        self.note = note; self.provenance = provenance; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - ContraceptiveContextLog

/// The hormonal/contraceptive methods this module is aware of, per the threat model's CYCLE-07
/// mitigation: awareness of an active method is what lets `CyclePrediction` PAUSE or BROADEN a
/// forecast instead of confidently predicting through a context where a calendar-only model's
/// normal assumptions don't hold.
public enum ContraceptiveMethodType: String, Codable, Hashable, Sendable, CaseIterable {
    case pill, iud, patch, ring, injection, implant, emergencyContraception, hormoneTherapy
}

/// A declared interval of contraceptive-method use. `endAt == nil` means still active — the SAME
/// "open interval, normal case not an edge case" posture `ContextStatus` already uses elsewhere in
/// this codebase, not a special/malformed state. `isActive` additionally requires `deletedAt ==
/// nil`, so a tombstoned-but-technically-still-open row is never read as active by a caller that
/// only checked `endAt`.
///
/// There should only ever be zero or one row with `isActive == true` at a time (a person is not
/// usually on two hormonal methods at once), but this type and its repository deliberately do not
/// enforce that as a hard invariant — `ContraceptiveContextRepository.activeContext()`'s own doc
/// explains why a malformed multi-active state must degrade gracefully rather than crash.
///
/// Carries a full embedded `Provenance` (I1): a declared contraceptive context is still a fact with
/// an origin, exactly like `CycleRecord`/`FlowLog`.
public struct ContraceptiveContextLog: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var methodType: ContraceptiveMethodType
    public var startAt: Date
    /// `nil` = still active. See the type doc above — this is the normal open-interval case.
    public var endAt: Date?
    public var adherenceNote: String?
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var isActive: Bool { endAt == nil && deletedAt == nil }

    public init(id: String, methodType: ContraceptiveMethodType, startAt: Date, endAt: Date? = nil,
                adherenceNote: String? = nil, provenance: Provenance, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.methodType = methodType; self.startAt = startAt; self.endAt = endAt
        self.adherenceNote = adherenceNote; self.provenance = provenance; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - CyclePrediction (append-only derived, I2 — NEVER a single-date claim)

/// Which evidentiary tier produced a `CyclePrediction` — an honesty label surfaced alongside the
/// range/confidence, mirroring this codebase's "scheduling honesty" and "no false precision"
/// standing rules applied to cycle forecasting specifically: a `coldStart` forecast (little to no
/// history yet) must never be presented with the same visual confidence as a `matureHistory` one.
public enum CyclePredictionMethod: String, Codable, Hashable, Sendable {
    case coldStart, lowHistory, moderateHistory, matureHistory
}

/// Whether `CyclePrediction` forecasting is currently running normally, or has been deliberately
/// paused. `.paused` is the CYCLE-07 contraceptive-context mitigation from the threat model §5: a
/// wrong prediction rendered confidently through active hormonal contraceptive use is not just
/// inaccurate, it can misinform a real decision, so the engine pauses rather than guesses.
public enum CyclePredictionStatus: String, Codable, Hashable, Sendable { case active, paused }

/// An append-only forecast of the next period's start window. APPEND-ONLY (I2): a recompute always
/// inserts a NEW row with a fresh `generatedAt`; nothing here is ever UPDATEd, mirroring
/// `DerivedTrend`'s shape (`Domain/Labs/LabModels.swift`) rather than embedding a full `Provenance`
/// — this row is COMPUTED, not measured-with-a-source, so a `sourceId`/`measuredAt` pair would be a
/// lie the way it would be on `DerivedTrend`/`derived_values` elsewhere in this codebase.
///
/// **No single-date claim, structurally, not just by convention.** There is no field here that
/// could hold a bare "predicted date" — only `predictedNextStartLow`/`Center`/`High` (a range), a
/// named `method`, and a `confidence`. All three range fields are OPTIONAL and nil together exactly
/// when there isn't yet enough evidence to state even a wide range (e.g. a fresh `coldStart` with
/// zero completed cycles) — never backfilled with a guessed range to avoid an empty-looking screen.
///
/// `suppressionReason` is set ONLY when `status == .paused` (see `CyclePredictionStatus` above) and
/// is itself non-diagnostic, calm text — never a claim about why in clinical terms.
///
/// `inputCycleIds` is the audit manifest: exactly which `CycleRecord`s fed this forecast, the same
/// "why does it say that" transparency `InputManifest`/`DerivedTrend` already provide elsewhere —
/// a forecast whose inputs can't be named is not trustworthy in this codebase's own terms.
public struct CyclePrediction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var generatedAt: Date
    public var predictedNextStartLow: Date?
    public var predictedNextStartCenter: Date?
    public var predictedNextStartHigh: Date?
    /// 0...1.
    public var confidence: Double
    public var method: CyclePredictionMethod
    public var status: CyclePredictionStatus
    /// Set only when `status == .paused` — calm, non-diagnostic text (e.g. "paused while an active
    /// contraceptive context is logged"), never a clinical claim.
    public var suppressionReason: String?
    public var algorithmVersion: String
    /// Which `CycleRecord`s (by id) fed this forecast — the input manifest for "why does it say
    /// that".
    public var inputCycleIds: [String]
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, generatedAt: Date, predictedNextStartLow: Date? = nil,
                predictedNextStartCenter: Date? = nil, predictedNextStartHigh: Date? = nil,
                confidence: Double, method: CyclePredictionMethod, status: CyclePredictionStatus = .active,
                suppressionReason: String? = nil, algorithmVersion: String, inputCycleIds: [String] = [],
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.generatedAt = generatedAt; self.predictedNextStartLow = predictedNextStartLow
        self.predictedNextStartCenter = predictedNextStartCenter
        self.predictedNextStartHigh = predictedNextStartHigh; self.confidence = confidence
        self.method = method; self.status = status; self.suppressionReason = suppressionReason
        self.algorithmVersion = algorithmVersion; self.inputCycleIds = inputCycleIds
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - CyclePhaseEstimate (append-only derived, I2 — phase-as-covariate)

/// The four cycle phases this module can estimate from calendar history alone, plus an explicit
/// `unknown` — never left as an absence. A phase that cannot be determined is a real, displayable
/// state ("not enough data yet"), the same "explicit unknown, never a silent nil" posture
/// `cycle_contexts.phase` already established (sensitive migration 3) before this fuller model
/// superseded it.
public enum CyclePhase: String, Codable, Hashable, Sendable, CaseIterable {
    case menstrual, follicular, ovulatory, luteal, unknown
}

/// What kind of evidence (or lack of it) backs a `CyclePhaseEstimate` — an honesty label, not a
/// confidence NUMBER, for the specific and common cases where the honest answer is "we didn't even
/// try" (`suppressedDueToContext`, e.g. an active contraceptive context) rather than "we tried and
/// got a low-confidence answer".
public enum CyclePhaseEvidenceBasis: String, Codable, Hashable, Sendable {
    case calendarOnly, insufficientHistory, suppressedDueToContext
}

/// An append-only, one-row-per-computed-window phase estimate — the input `BaselineEngine`'s
/// phase-conditioned baselines (EPIC-39's defining feature, per the plan) read as a covariate.
/// APPEND-ONLY (I2), same shape reasoning as `CyclePrediction` above: a recompute inserts a fresh
/// row at a new `computedAt` rather than overwriting the previous belief, and no embedded
/// `Provenance` because this is a computation over already-provenanced `CycleRecord`/`FlowLog`
/// rows, not a measurement of its own.
public struct CyclePhaseEstimate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var dateRangeStart: Date
    public var dateRangeEnd: Date
    public var phase: CyclePhase
    /// 0...1.
    public var confidence: Double
    public var evidenceBasis: CyclePhaseEvidenceBasis
    public var algorithmVersion: String
    public var computedAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, dateRangeStart: Date, dateRangeEnd: Date, phase: CyclePhase, confidence: Double,
                evidenceBasis: CyclePhaseEvidenceBasis, algorithmVersion: String, computedAt: Date,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.dateRangeStart = dateRangeStart; self.dateRangeEnd = dateRangeEnd
        self.phase = phase; self.confidence = confidence; self.evidenceBasis = evidenceBasis
        self.algorithmVersion = algorithmVersion; self.computedAt = computedAt; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - CycleAnomalyEvent (append-only derived, I2 — messageKey only, never rendered text)

/// The top-5 anomaly classes this slice's engine can flag — pattern-DEVIATION classes, never
/// diagnostic labels. Each name describes a deviation from the user's OWN recent pattern, not a
/// clinical judgment about the deviation's meaning (research doc §10's 7-class anomaly matrix,
/// narrowed to this slice's 5).
public enum CycleAnomalyType: String, Codable, Hashable, Sendable {
    case cycleLengthDeviation, periodDurationDeviation, flowDeviation, missedExpectedPeriod, repeatedIrregularity
}

/// A surfacing PRIORITY only — deliberately capped at `medium` (no `high`/`critical`), and never a
/// clinical-importance claim. Nothing in this codebase's anomaly copy escalates language based on
/// this value; it exists purely to help a UI decide what to show first.
public enum CycleAnomalySeverity: String, Codable, Hashable, Sendable { case low, medium }

/// The lifecycle of one flagged anomaly. `suppressed` covers the case where a later recompute
/// determined the anomaly no longer applies (e.g. context arrived that explains it) without a user
/// action of their own — distinct from `dismissed`, which is the user's own "not now" — and from
/// `acknowledged`, which is the user's own "seen, still relevant".
public enum CycleAnomalyState: String, Codable, Hashable, Sendable { case active, acknowledged, dismissed, suppressed }

/// An append-only, calmly-worded anomaly flag. APPEND-ONLY (I2) at creation time, same reasoning as
/// `CyclePrediction`/`CyclePhaseEstimate` above — a new detection inserts a new row; `state`
/// transitions (acknowledge/dismiss) are the one exception, applied via a plain UPDATE through
/// `CycleAnomalyEventRepository.updateState`, mirroring `DataConflictRepository.markResolved`'s
/// "detection facts stay frozen, only the lifecycle state transitions" pattern exactly.
///
/// **`messageKey` is a KEY, never rendered text — this is the load-bearing non-diagnostic-language
/// guarantee, enforced structurally rather than by writer discipline.** This struct has no field
/// that could hold a diagnostic sentence; a separate lane owns the bilingual key→template lookup
/// table, so the actual displayed copy can be reviewed, translated, and changed independently of
/// this schema, and can never accidentally be written here as a raw diagnostic string. `severity`
/// is a surfacing priority ONLY (see `CycleAnomalySeverity`), never a clinical-importance claim —
/// repeating that guarantee here because it is the single easiest place for this invariant to
/// silently erode if a future edit adds a "details" string field.
public struct CycleAnomalyEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: CycleAnomalyType
    public var detectedAt: Date
    /// Which `CycleRecord`s (by id) the detection window was computed over — the same
    /// "why does it say that" audit manifest `CyclePrediction.inputCycleIds` provides.
    public var basisWindowCycleIds: [String]
    public var severity: CycleAnomalySeverity
    /// A KEY into a bilingual message-template lookup — never rendered/diagnostic text. See the
    /// type doc above.
    public var messageKey: String
    public var state: CycleAnomalyState
    public var algorithmVersion: String
    /// 0...1.
    public var confidence: Double
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, type: CycleAnomalyType, detectedAt: Date, basisWindowCycleIds: [String] = [],
                severity: CycleAnomalySeverity, messageKey: String, state: CycleAnomalyState = .active,
                algorithmVersion: String, confidence: Double, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil) {
        self.id = id; self.type = type; self.detectedAt = detectedAt
        self.basisWindowCycleIds = basisWindowCycleIds; self.severity = severity
        self.messageKey = messageKey; self.state = state; self.algorithmVersion = algorithmVersion
        self.confidence = confidence; self.updatedAt = updatedAt; self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}

// MARK: - CycleRecordLedger (pure, storage-free live-view helper)

/// Pure, storage-free live-view logic for the `CycleRecord` revision chain — the domain-level
/// mirror of `LabResultLedger.liveResults` (`Domain/Labs/LabModels.swift`), kept in sync with
/// `CycleRecordRepository`'s own SQL the same way that pair is kept in sync. A divergence between
/// this Swift rule and the repository's SQL is a bug on one side, not an acceptable difference.
public enum CycleRecordLedger {
    /// A record is live iff it is not tombstoned AND no non-deleted row supersedes it — the same
    /// two-part rule `LabResultLedger.liveResults` applies before ITS additional (LAB-16-specific)
    /// dedup-suppression check, which has no equivalent here: this slice defines no duplicate-
    /// detection/merge mechanism for cycle records, so there is nothing a third condition would
    /// ever filter. Order is preserved from the input.
    public static func liveRecords(_ all: [CycleRecord]) -> [CycleRecord] {
        let supersededByLive = Set(all.compactMap { $0.deletedAt == nil ? $0.supersedes : nil })
        return all.filter { $0.deletedAt == nil && !supersededByLive.contains($0.id) }
    }
}
