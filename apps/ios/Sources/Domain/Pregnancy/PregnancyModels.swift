import Foundation

// MARK: - Pregnancy module: canonical entity set (A18/ADR-0010/D-25, EPIC-40 PREG-01, P0 slice)
//
// DOMAIN CORE ONLY. No SwiftUI, nothing under `Features/` or `App/` — those are a later slice, the
// same "domain core first" posture `CycleModels.swift` documents for the cycle module (its own
// closest sibling in this codebase). Grounded in `docs/BADAN_PREGNANCY_CALENDAR_RESEARCH.md`
// (read it before touching this file) and `docs/legal/reproductive-threat-model.md` — pregnancy
// data inherits every reason cycle data is BADAN's single highest-sensitivity family, PLUS its own
// sharper edge: a loss-suppression failure here is not an inconvenience, it is a re-traumatizing
// harm (research doc §9; plan's own inverse-requirement reject-table row). Four invariants are
// load-bearing across every type below:
//
//   * I7 (sensitive namespace). Every table backing a type here lives ONLY in
//     `badan_sensitive.db` (sensitive migration 8 in `Migrations.swift`) — never `badan.db`.
//   * No passive inference, ever. Nothing in this file, or anything that calls into it, may ever
//     derive a `PregnancyRecord`'s existence or `mode` from cycle data, missed periods, symptoms,
//     or any other signal. Every `PregnancyRecord` row and every `mode` transition exists only
//     because `PregnancyModeController` was called with an explicit, user-initiated
//     `PregnancyModeTransitionRequest` — there is no code path in this file that can manufacture
//     one from inference. This is this module's own restatement of `FertileWindowMode`'s "never
//     inferred, never on by default" framing (`CycleFertileWindowEngine.swift`), applied to the
//     pregnancy journey itself rather than to fertile-window estimation.
//   * No single-date due-date claim, ever. See `DueDateModels.swift` — `DueDateEstimate` has NO
//     field that could hold a bare "due on X" date, mirroring `CyclePrediction`'s exact structural
//     guarantee.
//   * Append-only, never mutated in place (I2). `PregnancyRecord` is an append-first revision
//     chain — the SAME shape as `CycleRecord`, not a settings flag: a mode transition (including a
//     loss declaration) APPENDS a new revision that supersedes the current head; nothing here ever
//     UPDATEs a `PregnancyRecord` row's `mode` in place. This is what makes "the record stays, only
//     the forward-looking presentation changes" (the founder's own loss-handling requirement)
//     mechanically true: the entire history of every mode this journey ever passed through survives
//     in `history(originalId:)`, exactly like `CycleRecord`'s own revision chain.
//
// OUT OF SCOPE for this P0 slice (see recon's own P0-scope reasoning — do not silently expand):
// kick-count/contraction-timer logging (PREG-07, gated on a safety-copy review), lab-notebook
// handoff (PREG-08), HealthKit `Pregnancy` category writes (PREG-09), mood check-ins/resources
// (PREG-10), postpartum recovery/feeding UI (PREG-11, the STATE is modeled below, the UI is not),
// partner sharing (PREG-12, standing do-not-build-without-explicit-gate), real week-by-week
// clinical content (PREG-03 ships a versioned shell + disclaimer only — see
// `PregnancyContentModels.swift`), and PREG-06 (entity reuse: weight/symptom/appointment logging
// tagged into this view and general history) — `BADAN_WHOOP_HAE_EXECUTION_PLAN.md` bundles PREG-06
// into this same EPIC-40 batch, but this P0 slice ships none of it; there is no
// `PregnancyWeightLog`/`PregnancySymptomLog`/`AppointmentLog` type anywhere in this module, and none
// of the four repositories below reference journal/weight/appointment data. Recorded here explicitly
// (general audit finding 2) precisely so this absence has the same paper trail PREG-07 through
// PREG-12 already had, rather than being a silent scope narrowing. If a change here starts drifting
// toward any of the above, stop — that is a different, separately-approved slice.

// MARK: - PregnancyJourneyMode (the 6 STORED modes) + week-by-week as a computed sub-mode

/// The pregnancy journey's stored modes — six of the seven named in the research doc's journey
/// model (`docs/BADAN_PREGNANCY_CALENDAR_RESEARCH.md` §4). The SEVENTH named mode,
/// "week-by-week gestational tracking," is deliberately NOT a stored case here: the research doc
/// itself calls it "an automatic sub-mode," and storing it as a distinct `PregnancyRecord.mode`
/// value would mean computing and persisting it from gestational-week date math — which is exactly
/// the kind of automatic inference this module's own "no passive inference, ever" invariant
/// forbids applying to STATE. Instead it is modeled as a pure, computed DISPLAY value —
/// `GestationalWeekDisplay.currentWeek(dueDateEstimate:asOf:)` below — derived from an already
/// user-declared `.pregnancyConfirmed`/`.latePregnancy` record plus the due-date estimate, and
/// recomputed fresh on every read rather than stored as a transition. This resolves the tension
/// exactly: the state machine is honest and complete (all seven named modes are represented, one
/// stored per user action, one computed per read), and no mode is ever inferred into existence.
///
/// `.lossDeclared` is reachable from `.ttc`, `.pregnancyConfirmed`, or `.latePregnancy` at ANY
/// point (research doc §9, line 40) — see `PregnancyModeController.legalTransitions` for the exact
/// transition table. It is a terminal mode for this journey: nothing transitions FORWARD out of
/// `.lossDeclared` within the SAME `PregnancyRecord` chain — a subsequent pregnancy is a brand new,
/// separately user-initiated `PregnancyRecord` (a new `originalId`), never a "reactivation" of a
/// journey that was declared lost. `.postpartumHandoff` is the other terminal mode (a new journey
/// after birth is, again, a new `PregnancyRecord`, not a transition of this one).
///
/// Critically, "terminal for this chain" does NOT mean "blocks every other chain forever" — see
/// `blocksNewJourney` below. A live `.lossDeclared` record stays live (and visible) permanently as
/// this journey's own history, exactly as this header always said, but it must never be the thing
/// standing between a grieving user and a genuinely new, separate journey (loss-handling audit
/// finding 1: this was previously a real bug — `beginJourney`'s guard treated ANY live record,
/// `.lossDeclared` included, as blocking, so the only way out of a declared loss was deleting it).
public enum PregnancyJourneyMode: String, Codable, Hashable, Sendable, CaseIterable {
    case ttc
    case pregnancyConfirmed
    case latePregnancy
    case birthDelivery
    case postpartumHandoff
    case lossDeclared

    public var displayName: LocalizedString {
        switch self {
        case .ttc: return LocalizedString(en: "Trying to conceive", ar: "نحاول الإنجاب")
        case .pregnancyConfirmed: return LocalizedString(en: "Pregnant", ar: "حامل")
        case .latePregnancy: return LocalizedString(en: "Late pregnancy", ar: "الحمل المتأخر")
        case .birthDelivery: return LocalizedString(en: "Birth logged", ar: "تم تسجيل الولادة")
        case .postpartumHandoff: return LocalizedString(en: "Postpartum", ar: "ما بعد الولادة")
        case .lossDeclared: return LocalizedString(en: "Loss recorded", ar: "تم تسجيل الفقدان")
        }
    }

    /// Modes from which `.lossDeclared` is reachable (research doc §9, line 40: "reachable from TTC
    /// through late pregnancy at any point"). Named separately from `PregnancyModeController`'s
    /// transition table so the "which modes even show a loss-declaration entry point" UI question
    /// can be answered without duplicating the full legal-transition map.
    public var canDeclareLossFromThisMode: Bool {
        switch self {
        case .ttc, .pregnancyConfirmed, .latePregnancy: return true
        case .birthDelivery, .postpartumHandoff, .lossDeclared: return false
        }
    }

    /// Whether a live record in THIS mode blocks `PregnancyModeController.beginJourney` from
    /// starting a brand-new, separate journey (loss-handling audit finding 1). `.lossDeclared` is
    /// the one mode that does NOT block — the terminal loss record stays live and fully intact as
    /// this journey's own history forever (I2, unchanged), but per this file's own header ("a
    /// subsequent pregnancy is a brand new, separately user-initiated `PregnancyRecord`... never a
    /// 'reactivation'"), a user who is TTC again or newly pregnant again after a loss must be able
    /// to say so without deleting or purging the record of the pregnancy they lost. Every other mode
    /// — including `.postpartumHandoff`, which this audit did not flag — keeps blocking, unchanged
    /// from this module's original behavior; only the loss case was a confirmed bug.
    public var blocksNewJourney: Bool {
        self != .lossDeclared
    }
}

// MARK: - PregnancyModeTransitionRequest (the explicit, user-initiated action vocabulary)

/// Every way a `PregnancyRecord`'s mode may ever change — one case per real button a human taps.
/// `PregnancyModeController` has NO other entry point that mutates `mode`, so a transition without
/// one of these named requests cannot happen; this enum IS the "never inferred" guarantee applied
/// structurally rather than left to caller discipline (the same role
/// `CycleFertileWindowEngine`'s three-way `FertileWindowMode` plays for its own feature, just for
/// state transitions instead of a settings mode).
public enum PregnancyModeTransitionRequest: String, Codable, Hashable, Sendable, CaseIterable {
    /// Begin a brand-new journey (no existing live `PregnancyRecord`) directly in `.ttc`.
    case beginTTC
    /// Begin a brand-new journey directly in `.pregnancyConfirmed` — a user who was not tracking
    /// TTC in BADAN and wants to start from a confirmed pregnancy.
    case beginPregnancyConfirmed
    /// `.ttc` -> `.pregnancyConfirmed`.
    case confirmPregnancy
    /// `.pregnancyConfirmed` -> `.latePregnancy`.
    case declareLatePregnancy
    /// `.pregnancyConfirmed` or `.latePregnancy` -> `.birthDelivery`.
    case declareBirth
    /// `.birthDelivery` -> `.postpartumHandoff`.
    case declarePostpartumHandoff
    /// `.ttc`, `.pregnancyConfirmed`, or `.latePregnancy` -> `.lossDeclared`. The one transition
    /// that must NEVER be gated behind anything beyond "the user tapped this" — see
    /// `PregnancyModuleServices.declareLoss` for the composition-layer suppression cascade this
    /// request triggers.
    case declareLoss
}

// MARK: - PregnancyRecord (append-first revision chain — same shape as CycleRecord)

/// The root journey entity. One logical journey (`originalId`) accumulates a chain of revisions —
/// exactly `CycleRecord`'s own append-first shape (`Domain/Cycle/CycleModels.swift`) — where every
/// mode transition, including a loss declaration, APPENDS a fresh row rather than mutating the
/// existing one. `PregnancyRecordLedger.liveRecords` (below) derives the current visible state from
/// the tombstone + supersedes links, never from a mutated `mode` column.
///
/// Carries a full embedded `Provenance` (I1): a declared journey state — "I am trying to conceive,"
/// "I am pregnant," "this pregnancy ended in loss" — is a fact with an origin, exactly like
/// `CycleRecord`/`ContraceptiveContextLog` are. `ingestionPath == .manual` always, for the same
/// reason those two types' own docs give: no platform pregnancy-state read exists (PREG-09,
/// HealthKit `Pregnancy` category, is explicitly deferred and would be write-only even once built).
public struct PregnancyRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var mode: PregnancyJourneyMode
    /// Whether this journey is a multiples pregnancy — optional context a user may not know or set
    /// at declaration time; defaults `false` and is corrected via a later revision, never mutated
    /// in place.
    public var multiplesFlag: Bool
    /// Whether this journey involves fertility-treatment context — research doc §9 line 136: an
    /// OPTIONAL flag that adjusts pacing (e.g. a gentler tone after a loss) WITHOUT requiring
    /// disclosure of treatment specifics. Never required, never inferred.
    public var fertilityTreatmentContext: Bool
    /// Stable identity across every revision of this logical journey. `originalId == id` for a
    /// first-time (un-revised) record.
    public var originalId: String
    /// The id of the row this one supersedes; nil for the journey's first row.
    public var supersedes: String?
    /// 1-based counter (1 = original).
    public var revision: Int
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var isOriginal: Bool { supersedes == nil }
    public var isRevised: Bool { revision > 1 }

    public init(id: String, mode: PregnancyJourneyMode, multiplesFlag: Bool = false,
                fertilityTreatmentContext: Bool = false, originalId: String, supersedes: String? = nil,
                revision: Int = 1, provenance: Provenance, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil) {
        self.id = id; self.mode = mode; self.multiplesFlag = multiplesFlag
        self.fertilityTreatmentContext = fertilityTreatmentContext; self.originalId = originalId
        self.supersedes = supersedes; self.revision = revision; self.provenance = provenance
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

/// Pure, storage-free live-view logic for the `PregnancyRecord` revision chain — the domain-level
/// mirror of `CycleRecordLedger.liveRecords`. A divergence between this Swift rule and the
/// repository's own SQL is a bug on one side, not an acceptable difference.
public enum PregnancyRecordLedger {
    /// A record is live iff it is not tombstoned AND no non-deleted row supersedes it.
    public static func liveRecords(_ all: [PregnancyRecord]) -> [PregnancyRecord] {
        let supersededByLive = Set(all.compactMap { $0.deletedAt == nil ? $0.supersedes : nil })
        return all.filter { $0.deletedAt == nil && !supersededByLive.contains($0.id) }
    }
}

// MARK: - PregnancyModeController (pure, storage-free state machine)

/// The ONLY function in this codebase that may decide a `PregnancyRecord`'s next `mode`. Pure,
/// storage-free, no clock reads (`asOf` always injected) — a sibling to `CycleFertileWindowEngine`
/// in shape, not an extension of it. Every transition requires an explicit
/// `PregnancyModeTransitionRequest`; there is no path here that inspects cycle data, symptom logs,
/// or anything else to decide a mode on the caller's behalf.
public enum PregnancyModeController {
    public enum TransitionError: Error, Equatable {
        /// `beginTTC`/`beginPregnancyConfirmed` was requested but a live journey already exists —
        /// starting a second concurrent journey is not this module's model; declare the prior one's
        /// outcome (birth, postpartum, or loss) first, or this is a genuinely new, separate journey
        /// the caller must treat as such (a fresh `originalId`, not a transition).
        case liveJourneyAlreadyExists
        /// A transition request (not `begin*`) was made with no current record to transition.
        case noActiveJourney
        /// The request is not legal from the current mode — see `legalTransitions`.
        case illegalTransition(from: PregnancyJourneyMode, request: PregnancyModeTransitionRequest)
        /// `beginJourney` was called with a request other than `.beginTTC`/`.beginPregnancyConfirmed`
        /// — a caller-side misuse of this entry point, not a mode-transition-legality question, so
        /// it deliberately does NOT reuse `.illegalTransition`: `beginJourney` runs before any
        /// "current mode" exists on this path (or, when a live `.lossDeclared` record permitted this
        /// call through, that record's mode isn't what's actually illegal here — the REQUEST is).
        /// Fixes general audit finding 3: `.illegalTransition` previously reported a fabricated
        /// `from: .ttc` on this path regardless of the real situation.
        case invalidBeginRequest(request: PregnancyModeTransitionRequest)
    }

    /// The full legal-transition table. Read this, not tribal knowledge, as the single source of
    /// truth for "what can happen from mode X" — `PregnancyModeControllerTests` asserts every entry
    /// and asserts that nothing outside this table is ever reachable.
    public static let legalTransitions: [PregnancyJourneyMode: Set<PregnancyModeTransitionRequest>] = [
        .ttc: [.confirmPregnancy, .declareLoss],
        .pregnancyConfirmed: [.declareLatePregnancy, .declareBirth, .declareLoss],
        .latePregnancy: [.declareBirth, .declareLoss],
        .birthDelivery: [.declarePostpartumHandoff],
        .postpartumHandoff: [],
        .lossDeclared: [],
    ]

    /// The mode a (non-`begin*`) request transitions TO, independent of the current mode — the
    /// legality check (`legalTransitions`) is what varies by current mode, not this mapping.
    private static func targetMode(for request: PregnancyModeTransitionRequest) -> PregnancyJourneyMode? {
        switch request {
        case .beginTTC, .beginPregnancyConfirmed: return nil // handled by beginJourney, not here
        case .confirmPregnancy: return .pregnancyConfirmed
        case .declareLatePregnancy: return .latePregnancy
        case .declareBirth: return .birthDelivery
        case .declarePostpartumHandoff: return .postpartumHandoff
        case .declareLoss: return .lossDeclared
        }
    }

    /// Start a brand-new journey. `currentLiveRecord` must be `nil`, or already deleted/superseded,
    /// OR in a mode that does not block a new journey (`PregnancyJourneyMode.blocksNewJourney` —
    /// today, exactly `.lossDeclared`; loss-handling audit finding 1) — this never overwrites an
    /// existing ACTIVE live journey; see `TransitionError.liveJourneyAlreadyExists`.
    public static func beginJourney(
        request: PregnancyModeTransitionRequest, currentLiveRecord: PregnancyRecord?, id: String,
        multiplesFlag: Bool = false, fertilityTreatmentContext: Bool = false, provenance: Provenance,
        asOf: Date, originDeviceId: String
    ) throws -> PregnancyRecord {
        if let currentLiveRecord, currentLiveRecord.mode.blocksNewJourney {
            throw TransitionError.liveJourneyAlreadyExists
        }
        let mode: PregnancyJourneyMode
        switch request {
        case .beginTTC: mode = .ttc
        case .beginPregnancyConfirmed: mode = .pregnancyConfirmed
        default: throw TransitionError.invalidBeginRequest(request: request)
        }
        return PregnancyRecord(id: id, mode: mode, multiplesFlag: multiplesFlag,
                               fertilityTreatmentContext: fertilityTreatmentContext, originalId: id,
                               supersedes: nil, revision: 1, provenance: provenance, updatedAt: asOf,
                               originDeviceId: originDeviceId)
    }

    /// Apply a transition to an EXISTING live journey, producing the NEXT revision row (never a
    /// mutation of `current`). Validates against `legalTransitions` first — an illegal request
    /// throws and nothing is returned, so a caller can never accidentally persist a mode the state
    /// machine does not recognize.
    public static func applyTransition(
        current: PregnancyRecord, request: PregnancyModeTransitionRequest, newId: String,
        provenance: Provenance, asOf: Date, originDeviceId: String
    ) throws -> PregnancyRecord {
        guard request != .beginTTC, request != .beginPregnancyConfirmed else {
            throw TransitionError.illegalTransition(from: current.mode, request: request)
        }
        guard legalTransitions[current.mode]?.contains(request) == true,
              let nextMode = targetMode(for: request) else {
            throw TransitionError.illegalTransition(from: current.mode, request: request)
        }
        return PregnancyRecord(
            id: newId, mode: nextMode, multiplesFlag: current.multiplesFlag,
            fertilityTreatmentContext: current.fertilityTreatmentContext,
            originalId: current.originalId, supersedes: current.id, revision: current.revision + 1,
            provenance: provenance, updatedAt: asOf, originDeviceId: originDeviceId)
    }
}

// MARK: - GestationalWeekDisplay (pure, computed — the "automatic sub-mode," never stored)

/// Computes a display-only gestational week number from an already-declared pregnancy and its
/// due-date estimate. NEVER stored, NEVER a `PregnancyRecord.mode` value — see this file's own
/// header for why storing this would violate "no passive inference." A caller (a later UI slice)
/// recomputes this fresh on every read; there is nothing here for a stale value to ever contradict.
public enum GestationalWeekDisplay {
    /// Standard obstetric convention: a full-term pregnancy is 280 days (40 weeks) counted from the
    /// due-date estimate's own anchor. This constant is NOT independently clinically validated by
    /// this build — see `DueDateEstimator`'s own header for the same flag; both derive from the
    /// same standard 280-day convention, so they are kept in one place conceptually (this constant)
    /// even though `DueDateEstimator` computes the DUE DATE and this type only re-derives a WEEK
    /// NUMBER from an already-computed estimate's center date.
    public static let fullTermDays = 280

    /// The current gestational week (1-based), or `nil` when there is no usable due-date estimate to
    /// derive it from, or the computed value would be nonsensical (e.g. `asOf` is far past the
    /// estimate's own range, or far before conception could plausibly have occurred). Deliberately
    /// conservative: this returns `nil` rather than a guessed week, matching this module's own
    /// "never state something with more confidence than the evidence supports" posture.
    public static func currentWeek(dueDateEstimate: DueDateEstimate?, asOf: Date,
                                   calendar: Calendar = Calendar(identifier: .gregorian)) -> Int? {
        guard let center = dueDateEstimate?.rangeCenter else { return nil }
        guard let daysUntilDue = calendar.dateComponents([.day], from: asOf, to: center).day else { return nil }
        let daysPregnant = fullTermDays - daysUntilDue
        guard daysPregnant > 0, daysPregnant <= fullTermDays + 21 else { return nil } // allow a post-term margin
        // Ceiling division, 1-based: days 1-7 are week 1, days 8-14 are week 2, ... — the standard
        // obstetric convention where completing exactly 280 days (40*7) is "40 weeks," not "41."
        // `(daysPregnant / 7) + 1` would be off by one at every exact week boundary (280 -> 41).
        return min(42, ((daysPregnant - 1) / 7) + 1)
    }
}

// MARK: - LossDeclarationRecord (minimal fields, highest privacy tier, independently deletable)

/// Optional gestational-stage context at the time of loss — research doc §9 line 126: minimum
/// fields only, never a required explanation. Deliberately coarse (trimester-level), never a
/// clinical/diagnostic classification.
public enum LossGestationalStage: String, Codable, Hashable, Sendable, CaseIterable {
    case earlyPregnancy   // roughly first trimester
    case midPregnancy     // roughly second trimester
    case latePregnancy    // roughly third trimester
    case unspecified
}

/// The three-way, unpressured, revisitable data-disposition choice — research doc §9 line 132: no
/// default biased toward either keeping or deleting. There is deliberately no `Codable` default
/// value on `LossDeclarationRecord.dataDisposition` for this reason: every call site must pass one
/// explicitly, so "the user was never actually asked" cannot silently compile to a biased default.
public enum LossDataDisposition: String, Codable, Hashable, Sendable, CaseIterable {
    case keep, archive, delete
}

/// A user's declaration that a pregnancy journey ended in loss. Deliberately MINIMAL — research doc
/// §9 line 126: "minimum fields only — approximate date, optional gestational stage, optional free
/// text — never a required explanation or cause." `pregnancyRecordOriginalId` links to exactly one
/// `PregnancyRecord` journey (research doc §9 line 178/282) — the suppression this declaration
/// triggers is scoped to THAT journey and is permanent for it; see `PregnancyModuleServices
/// .declareLoss`'s own doc for the full suppression cascade this record's existence drives.
///
/// Carries a full embedded `Provenance` (I1): a loss declaration is still a fact with an origin.
/// NOT a revision chain (unlike `PregnancyRecord`) — a loss is declared once; `dataDisposition` is
/// the one field this type expects to be UPDATEd in place after the fact (research doc §9 line 132:
/// "revisitable later, not a one-time forced decision"), mirroring `CycleAnomalyEvent.state`'s
/// exact "detection fact frozen, one lifecycle field transitions" shape. Independently deletable
/// (research doc §9 lines 150, 161-162, 178) via its own `deletedAt` tombstone, separate from
/// deleting the `PregnancyRecord` it references.
public struct LossDeclarationRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pregnancyRecordOriginalId: String
    public var declaredAt: Date
    /// User-entered, approximate by design — never a clinically-precise date requirement.
    public var approximateDate: Date
    public var gestationalStage: LossGestationalStage?
    /// Optional free text — never required, never a "cause" field (research doc §9 line 126).
    public var freeTextNote: String?
    public var dataDisposition: LossDataDisposition
    /// Echoes `PregnancyRecord.fertilityTreatmentContext` at declaration time — research doc §9
    /// line 136: adjusts pacing of any FUTURE journey's copy without requiring re-disclosure.
    public var fertilityTreatmentContext: Bool
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, pregnancyRecordOriginalId: String, declaredAt: Date, approximateDate: Date,
                gestationalStage: LossGestationalStage? = nil, freeTextNote: String? = nil,
                dataDisposition: LossDataDisposition, fertilityTreatmentContext: Bool = false,
                provenance: Provenance, updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.pregnancyRecordOriginalId = pregnancyRecordOriginalId
        self.declaredAt = declaredAt; self.approximateDate = approximateDate
        self.gestationalStage = gestationalStage; self.freeTextNote = freeTextNote
        self.dataDisposition = dataDisposition; self.fertilityTreatmentContext = fertilityTreatmentContext
        self.provenance = provenance; self.updatedAt = updatedAt; self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}

// MARK: - PregnancyContentGate (structural loss-suppression guarantee for forward-looking content)

/// Every content FAMILY a future pregnancy UI slice could render — named exhaustively here so a
/// future content screen has no way to invent a new forward-looking surface that forgets to consult
/// `visibleForwardLookingSections` below. PREG-03 (this P0 slice) ships no real content behind any
/// of these; this enum and the gate below are the structural seam real content plugs into later.
public enum PregnancyContentSection: String, Codable, Hashable, Sendable, CaseIterable {
    case gestationalMilestoneNarrative
    case weekByWeekProgress
    case dueDateCountdown
    case upcomingAppointmentPrep
    case birthPrepTips
}

/// The single structural gate every forward-looking/celebratory pregnancy content surface — in
/// this module's own screens, and any future ambient/widget/notification surface that ever renders
/// pregnancy content — MUST consult before rendering. This is deliberately a PURE FUNCTION of a
/// journey's current live `PregnancyRecord`, not a separate "is suppressed" flag that a caller
/// could read stale or forget to check: once `record.mode == .lossDeclared`, this function has
/// exactly one path through it and that path returns the empty set, structurally, the same way
/// `CyclePrediction` has no field that could hold a bare date. There is no "suppressed" boolean
/// anywhere in this module a future bug could leave un-set; the suppression IS the mode.
public enum PregnancyContentGate {
    public static func visibleForwardLookingSections(for record: PregnancyRecord?) -> Set<PregnancyContentSection> {
        guard let record, record.deletedAt == nil else { return [] }
        switch record.mode {
        case .lossDeclared:
            // The one-way gate (research doc §9): permanent for THIS journey. Nothing forward-
            // looking or celebratory is ever visible again for this `originalId`.
            return []
        case .ttc:
            // No pregnancy-specific forward content applies yet (there is no pregnancy to count
            // down or show milestones for).
            return []
        case .pregnancyConfirmed, .latePregnancy:
            return Set(PregnancyContentSection.allCases)
        case .birthDelivery, .postpartumHandoff:
            // Pregnancy is over; only forward-looking POSTPARTUM content (out of this section's
            // vocabulary — a later slice's own concern) would apply. None of the pregnancy-forward
            // sections named here still make sense once birth is logged.
            return []
        }
    }
}
